import Foundation
import GRDB
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The live lifetime against the fake cloud: consent starts and ends sessions, account rules
/// decide the namespace, and a session actually carries a follow from one device to another.
@Suite struct PodcastCloudSyncRuntimeTests {
  static let destination = PodcastCloudSyncRuntime.Destination(
    container: "iCloud.com.remoteconcern.whirr", environment: "development", zone: "PodcastState")
  static let feedURL = URL(string: "https://example.com/show.xml")!

  fileprivate struct Device {
    let database: AppDatabase
    let consent: PodcastCloudSyncConsentStore
    let account: FakeAccount
    let epochs: MemoryEpochs
    let lastSync: MemoryLastSync
    let anchor: FakePodcastCloudInstallationAnchor
    let relay = PodcastCloudRefreshRelay()
    let backgroundTime = RecordingBackgroundTime()
    let runtime: PodcastCloudSyncRuntime
    let running: Task<Void, Never>

    init(
      server: FakePodcastCloudServer, keyring: SharedKeyring,
      account: PodcastCloudAccountState = .available(userRecordID: "_user"),
      epochs: PodcastCloudAccountEpochState = .initial, destinationReady: Bool = true,
      anchor: FakePodcastCloudInstallationAnchor = FakePodcastCloudInstallationAnchor(),
      lastSync: MemoryLastSync = MemoryLastSync(),
      activeEpisodeRowIDs: @escaping @Sendable () -> Set<Int64> = { [] },
      sessions: CoordinatorWitness? = nil
    ) throws {
      database = try AppDatabase.inMemory()
      self.anchor = anchor
      self.lastSync = lastSync
      consent = PodcastCloudSyncConsentStore(defaults: MemoryDefaults(), identity: FixedIdentity())
      self.account = FakeAccount(account)
      self.epochs = MemoryEpochs(epochs)
      runtime = PodcastCloudSyncRuntime(
        database: database, anchor: anchor, consent: consent,
        destinationReady: destinationReady, destination: PodcastCloudSyncRuntimeTests.destination,
        account: self.account, epochs: self.epochs, lastSync: lastSync, refreshRelay: relay,
        backgroundTime: backgroundTime,
        debounce: .zero,
        now: { [server] in server.now },
        activeEpisodeRowIDs: activeEpisodeRowIDs,
        makeKeyringStore: { keyring },
        makeEngine: { coordinator in
          sessions?.saw(coordinator)
          return FakePodcastCloudEngine(server: server, handler: coordinator)
        })
      running = Task { [runtime] in await runtime.run() }
    }

    func subscribe() async throws {
      _ = try await RSSFeedStore(database: database).subscribe(
        feedURL: PodcastCloudSyncRuntimeTests.feedURL, title: "Show", author: nil, synopsis: nil,
        artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func feedCount() async throws -> Int {
      try await database.readAsync { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssFeed") ?? 0 }
    }

    func feedID() async throws -> Int64? {
      try await database.readAsync { db in try Int64.fetchOne(db, sql: "SELECT id FROM rssFeed LIMIT 1") }
    }

    /// Support for the active-episode check: an episode this device's copy of the feed describes,
    /// mirroring `PodcastCloudEntitySyncTests.Device.addEpisode` since the runtime harness has no
    /// episode helper of its own.
    @discardableResult
    func addEpisode(_ guid: String = "ep1") async throws -> Int64 {
      let feedId = try #require(try await feedID())
      let episodeId = try await database.writeAsync { db -> Int64 in
        try db.execute(
          sql: """
            INSERT INTO rssEpisode (feedId, identityKey, guid, title, enclosureURL, lastSeenGeneration)
            VALUES (?, ?, ?, 'Episode', ?, 0)
            """, arguments: [feedId, "guid:\(guid)", guid, "https://example.com/\(guid).mp3"])
        return db.lastInsertedRowID
      }
      await relay.feedRefreshCommitted(feedId: feedId)
      return episodeId
    }

    func state(_ episodeId: Int64) async throws -> RSSEpisodeStateRecord? {
      try await RSSEpisodeStateStore(database: database).fetchState(episodeId: episodeId)
    }
  }

  /// The shared waiter's serviced-poll budget without its own issue: every caller `#expect`s the
  /// result. A throwing condition counts as not yet met.
  static func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
    let outcome = await awaitCondition(
      "eventually", recordingIssue: false, until: { (try? await condition()) ?? false })
    if case .observed = outcome { return true }
    return false
  }

  @Test func aConsentedSessionCarriesAFollowAndWithdrawingConsentEndsIt() async throws {
    let server = FakePodcastCloudServer()
    let keyring = SharedKeyring()
    let a = try Device(server: server, keyring: keyring)
    let b = try Device(server: server, keyring: keyring)
    defer {
      a.running.cancel()
      b.running.cancel()
    }

    #expect(a.consent.grant() && b.consent.grant())
    #expect(try await Self.eventually { await a.runtime.status() == .upToDate })
    #expect(try await Self.eventually { await b.runtime.status() == .upToDate })

    try await a.subscribe()
    try await a.runtime.syncNow()
    try await b.runtime.syncNow()
    #expect(try await b.feedCount() == 1, "B follows the show A followed")

    a.consent.revoke()
    #expect(try await Self.eventually { await a.runtime.isRunning == false })
    #expect(await a.runtime.status() == .off)
    await #expect(throws: PodcastCloudSyncCoordinatorError.notEnabled) { try await a.runtime.syncNow() }
  }

  /// ADR 0018: the session owns its coordinator, so ending the session frees it, with its engine.
  @Test func withdrawingConsentFreesTheSessionsCoordinator() async throws {
    let sessions = CoordinatorWitness()
    let device = try Device(server: FakePodcastCloudServer(), keyring: SharedKeyring(), sessions: sessions)
    defer { device.running.cancel() }

    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
    #expect(sessions.started == 1)
    #expect(sessions.alive)

    device.consent.revoke()
    #expect(try await Self.eventually { await device.runtime.isRunning == false })
    #expect(try await Self.eventually { sessions.alive == false }, "nothing keeps an ended session alive")
  }

  @Test func withoutReadinessConsentStartsNothing() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(server: server, keyring: SharedKeyring(), destinationReady: false)
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.lastReconciledConsent == true })
    #expect(await device.runtime.isRunning == false)
    #expect(server.saveCount == 0)
    #expect(server.zoneExists == false)
  }

  @Test func aDifferentAccountTurnsSyncOffInsteadOfUploadingToIt() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(
      server: server, keyring: SharedKeyring(), account: .available(userRecordID: "_other"),
      epochs: PodcastCloudAccountEpochState(epoch: 3, lastUserRecordID: "_user", bumpPending: false))
    defer { device.running.cancel() }
    try await device.subscribe()

    #expect(device.consent.grant())
    #expect(try await Self.eventually { device.consent.hasConsent() == false })
    #expect(await device.runtime.isRunning == false)
    #expect(server.saveCount == 0, "nothing reached the other account")

    // Enabling again is the explicit choice, and it opens a new namespace for the new account.
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
    #expect(
      device.epochs.load() == PodcastCloudAccountEpochState(epoch: 4, lastUserRecordID: "_other", bumpPending: false))
  }

  @Test func anUnreadableAccountWaitsUntilTheNextActivation() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(server: server, keyring: SharedKeyring(), account: .unknown)
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(
      try await Self.eventually { await device.runtime.status() == .waiting(until: nil) },
      "reads as offline, not as off")
    #expect(await device.runtime.isRunning == false)

    device.account.set(.available(userRecordID: "_user"))
    await device.runtime.sceneDidBecomeActive()
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
  }

  /// Launch swallows an installation that cannot resolve, so it must not read as "Off" here: the
  /// listener turned sync on and nothing is syncing.
  @Test func aStartThatCannotResolveTheInstallationReadsAsInterrupted() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(
      server: server, keyring: SharedKeyring(), anchor: FakePodcastCloudInstallationAnchor(readsFail: true))
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .interrupted })
    #expect(await device.runtime.isRunning == false)

    device.anchor.setReadsFail(false)
    await device.runtime.sceneDidBecomeActive()
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
  }

  /// The screen offers Try Again as the retry, so it must be one.
  @Test func syncNowRetriesAStartThatFailed() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(
      server: server, keyring: SharedKeyring(), anchor: FakePodcastCloudInstallationAnchor(readsFail: true))
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .interrupted })

    device.anchor.setReadsFail(false)
    try await device.runtime.syncNow()
    #expect(await device.runtime.isRunning)
    #expect(await device.runtime.status() == .upToDate)
  }

  /// Two consented devices on one fake cloud, both past the barrier.
  private func runningPair() async throws -> (Device, Device, FakePodcastCloudServer) {
    let server = FakePodcastCloudServer()
    let keyring = SharedKeyring()
    let a = try Device(server: server, keyring: keyring)
    let b = try Device(server: server, keyring: keyring)
    #expect(a.consent.grant() && b.consent.grant())
    #expect(try await Self.eventually { await a.runtime.status() == .upToDate })
    #expect(try await Self.eventually { await b.runtime.status() == .upToDate })
    return (a, b, server)
  }

  /// iOS may suspend the app before the engine's own schedule sends, so leaving the foreground
  /// sends at once, inside the background time the platform grants.
  @Test func backgroundingSendsWhatIsPendingUnderBackgroundTime() async throws {
    let (a, b, _) = try await runningPair()
    defer {
      a.running.cancel()
      b.running.cancel()
    }

    try await a.subscribe()
    try await b.runtime.syncNow()
    #expect(try await b.feedCount() == 0, "nothing sends on its own in the fake")

    await a.runtime.sceneDidEnterBackground()
    #expect(a.backgroundTime.runs == 1)

    try await b.runtime.syncNow()
    #expect(try await b.feedCount() == 1)
  }

  /// A lock-screen pause never moves the scene, so a settled position sends on its own.
  @Test func aSettledPlaybackPositionIsSentUnderBackgroundTime() async throws {
    let (a, b, _) = try await runningPair()
    defer {
      a.running.cancel()
      b.running.cancel()
    }

    try await a.subscribe()
    a.runtime.playbackPositionSettled()

    #expect(
      try await Self.eventually {
        try await b.runtime.syncNow()
        return try await b.feedCount() == 1
      })
    #expect(a.backgroundTime.runs == 1)
  }

  @Test func becomingActiveFetchesWhatAnotherDeviceSentUnlessItJustFetched() async throws {
    let (a, b, server) = try await runningPair()
    defer {
      a.running.cancel()
      b.running.cancel()
    }

    try await a.subscribe()
    try await a.runtime.syncNow()

    await b.runtime.sceneDidBecomeActive()
    #expect(try await b.feedCount() == 0, "B fetched less than 30 seconds ago")

    server.advance(by: 31)
    await b.runtime.sceneDidBecomeActive()
    #expect(try await b.feedCount() == 1)
    #expect(b.backgroundTime.runs == 0, "a foreground catch-up needs no background time")
  }

  @Test func withoutASessionTheLifecycleHooksDoNothing() async throws {
    let device = try Device(server: FakePodcastCloudServer(), keyring: SharedKeyring())
    defer { device.running.cancel() }

    await device.runtime.sceneDidEnterBackground()
    await device.runtime.sceneDidBecomeActive()

    #expect(device.backgroundTime.runs == 0)
    #expect(await device.runtime.status() == .off)
  }

  @Test func theLastSuccessfulSyncOutlivesTheSessionAndDeletionClearsIt() async throws {
    let server = FakePodcastCloudServer()
    let lastSync = MemoryLastSync()
    let device = try Device(server: server, keyring: SharedKeyring(), lastSync: lastSync)
    defer { device.running.cancel() }
    #expect(await device.runtime.lastSuccessfulSync() == nil, "Never, before any sync")

    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
    let first = try #require(await device.runtime.lastSuccessfulSync())
    #expect(first == server.now)

    server.advance(by: 60)
    try await device.runtime.syncNow()
    #expect(await device.runtime.lastSuccessfulSync() == server.now)
    #expect(lastSync.load() == server.now, "kept for the next launch")

    // A relaunch reads the stored time before its own session has fetched anything.
    let relaunched = try Device(
      server: server, keyring: SharedKeyring(), destinationReady: false, lastSync: lastSync)
    defer { relaunched.running.cancel() }
    #expect(await relaunched.runtime.lastSuccessfulSync() == server.now)

    try await device.runtime.deleteCloudData()
    #expect(await device.runtime.lastSuccessfulSync() == nil)
  }

  @Test func theLastSyncStoreRoundTripsThroughUserDefaults() throws {
    let suite = "PodcastCloudLastSyncTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsPodcastCloudLastSyncStore(defaults: defaults)
    #expect(store.load() == nil)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    store.save(date)
    #expect(UserDefaultsPodcastCloudLastSyncStore(defaults: defaults).load() == date)
    store.save(nil)
    #expect(store.load() == nil)
  }

  @Test func anAccountChangeOpensANewNamespace() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(server: server, keyring: SharedKeyring())
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
    #expect(device.epochs.load().epoch == 1)

    await device.runtime.accountDidChange()
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
    #expect(device.epochs.load().epoch == 2, "the same account returning still gets a fresh epoch")
  }

  @Test func deletingICloudDataTurnsSyncOffOnThisDevice() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(server: server, keyring: SharedKeyring())
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })

    try await device.runtime.deleteCloudData()
    #expect(server.zoneExists == false)
    #expect(device.consent.hasConsent() == false)
    #expect(await device.runtime.status() == .off)
  }

  /// J7 end to end: the lost zone stops sync, and only the explicit recovery recreates it.
  @Test func recoveringFromALostZoneRecreatesItAndResumesSync() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(server: server, keyring: SharedKeyring())
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
    try await device.subscribe()
    try await device.runtime.syncNow()
    #expect(server.records.isEmpty == false)

    server.deleteZoneAsUser()
    try? await device.runtime.syncNow()
    #expect(await device.runtime.status() == .zoneLost(.userDeletedZone))
    #expect(server.zoneExists == false, "the zone is never recreated without the listener")

    try await device.runtime.recoverFromZoneLoss()
    #expect(server.zoneExists)
    #expect(await device.runtime.status() == .upToDate)
    _ = try await RSSFeedStore(database: device.database).subscribe(
      feedURL: URL(string: "https://example.com/another.xml")!, title: "Another", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: server.now)
    try await device.runtime.syncNow()
    #expect(server.records.isEmpty == false, "an edit made after the recovery reaches the new zone")
  }

  @Test func repairingTheClockLetsLocalEditsReachICloudAgain() async throws {
    let (a, b, server) = try await runningPair()
    defer {
      a.running.cancel()
      b.running.cancel()
    }
    let farAhead = Int64(server.now.timeIntervalSince1970 * 1000) + 10 * 86_400_000
    try await a.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudInstallation SET physicalMilliseconds = ? WHERE id = 1",
        arguments: [farAhead])
    }
    try await b.subscribe()
    try await b.runtime.syncNow()
    try await a.runtime.syncNow()
    #expect(await a.runtime.status() == .clockRepairRequired)

    try await a.runtime.repairClock()
    #expect(await a.runtime.status() == .upToDate)

    let saves = server.saveCount
    _ = try await RSSFeedStore(database: a.database).subscribe(
      feedURL: URL(string: "https://example.com/another.xml")!, title: "Another", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: server.now)
    try await a.runtime.syncNow()
    #expect(server.saveCount > saves, "an edit made after the repair is stamped and sent")
    #expect(await a.runtime.status() == .upToDate)
  }

  @Test func withoutASessionNeitherRecoveryRuns() async throws {
    let device = try Device(server: FakePodcastCloudServer(), keyring: SharedKeyring())
    defer { device.running.cancel() }
    await #expect(throws: PodcastCloudSyncCoordinatorError.notEnabled) {
      try await device.runtime.recoverFromZoneLoss()
    }
    await #expect(throws: PodcastCloudSyncCoordinatorError.notEnabled) {
      try await device.runtime.repairClock()
    }
  }

  @Test func theRelayFollowsTheSession() async throws {
    let server = FakePodcastCloudServer()
    let device = try Device(server: server, keyring: SharedKeyring())
    defer { device.running.cancel() }
    #expect(device.consent.grant())
    #expect(try await Self.eventually { await device.runtime.status() == .upToDate })
    // Resolution against a feed that does not exist is a harmless no-op; what matters is that
    // the relay reaches a live coordinator and survives the session ending.
    await device.relay.feedRefreshCommitted(feedId: 1)
    device.consent.revoke()
    #expect(try await Self.eventually { await device.runtime.isRunning == false })
    await device.relay.feedRefreshCommitted(feedId: 1)
  }

  // MARK: - The runtime's active-episode provider reaches the coordinator

  /// End-to-end through `PodcastCloudSyncRuntime.init(activeEpisodeRowIDs:)`, not just through the
  /// coordinator directly (`PodcastCloudEntitySyncTests` covers that): B reports its own episode as
  /// playing, and its unsent tick survives A's later reset of the same episode.
  @Test func theActiveEpisodeProviderProtectsUnsentListeningThroughTheRuntime() async throws {
    let server = FakePodcastCloudServer()
    let keyring = SharedKeyring()
    let a = try Device(server: server, keyring: keyring)
    let playing = MutableActiveEpisodeSet()
    let b = try Device(server: server, keyring: keyring, activeEpisodeRowIDs: { playing.read() })
    defer {
      a.running.cancel()
      b.running.cancel()
    }
    #expect(a.consent.grant() && b.consent.grant())
    #expect(try await Self.eventually { await a.runtime.status() == .upToDate })
    #expect(try await Self.eventually { await b.runtime.status() == .upToDate })

    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await a.runtime.syncNow()
    try await b.runtime.syncNow()
    #expect(try await b.feedCount() == 1, "B follows the show A followed")
    // B's own local copy of the feed's episode, matched to A's by identity key, not row id.
    let bEpisode = try await b.addEpisode()

    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 100, finished: false, capturedSequence: 0, now: server.now)
    try await a.runtime.syncNow()
    try await b.runtime.syncNow()
    #expect(try await b.state(bEpisode)?.position == 100)

    // B is playing the episode right now, with nothing dirty since that last fetch.
    playing.set([bEpisode])

    server.advance(by: 10)
    _ = try await aStore.resetProgress(episodeId: aEpisode, now: server.now)
    try await a.runtime.syncNow()
    try await b.runtime.syncNow()

    #expect(
      try await b.state(bEpisode)?.position == 100,
      "the runtime's provider reached the coordinator and protected B's listening")

    try await b.runtime.syncNow()
    try await a.runtime.syncNow()
    #expect(try await a.state(aEpisode)?.position == 100, "the fleet converges on B's protected value")
  }

  // MARK: - Policy

  @Test func theFirstStartOpensEpochOne() {
    let (decision, next) = PodcastCloudAccountPolicy.decide(
      .available(userRecordID: "u"), stored: .initial)
    #expect(decision == .start(epoch: 1, userRecordID: "u"))
    #expect(next == PodcastCloudAccountEpochState(epoch: 1, lastUserRecordID: "u", bumpPending: false))
  }

  @Test func aRelaunchOnTheSameAccountKeepsItsEpoch() {
    let stored = PodcastCloudAccountEpochState(epoch: 5, lastUserRecordID: "u", bumpPending: false)
    let (decision, next) = PodcastCloudAccountPolicy.decide(.available(userRecordID: "u"), stored: stored)
    #expect(decision == .start(epoch: 5, userRecordID: "u"))
    #expect(next == stored)
  }

  @Test func signingOutListensAndSigningBackInOpensANewEpoch() {
    let stored = PodcastCloudAccountEpochState(epoch: 5, lastUserRecordID: "u", bumpPending: false)
    let (signedOut, afterSignOut) = PodcastCloudAccountPolicy.decide(.noAccount, stored: stored)
    #expect(signedOut == .start(epoch: 5, userRecordID: nil))
    #expect(afterSignOut.bumpPending)
    let (back, _) = PodcastCloudAccountPolicy.decide(.available(userRecordID: "u"), stored: afterSignOut)
    #expect(back == .start(epoch: 6, userRecordID: "u"))
    let (other, afterOther) = PodcastCloudAccountPolicy.decide(.available(userRecordID: "v"), stored: afterSignOut)
    #expect(other == .accountSwitched)
    #expect(afterOther.lastUserRecordID == nil)
  }

  @Test func anUnknownAccountChangesNothing() {
    let stored = PodcastCloudAccountEpochState(epoch: 2, lastUserRecordID: "u", bumpPending: true)
    let (decision, next) = PodcastCloudAccountPolicy.decide(.unknown, stored: stored)
    #expect(decision == .wait)
    #expect(next == stored)
  }

  @Test func theEpochStoreRoundTripsThroughUserDefaults() throws {
    let suite = "PodcastCloudSyncRuntimeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsPodcastCloudAccountEpochStore(defaults: defaults)
    #expect(store.load() == .initial)
    let state = PodcastCloudAccountEpochState(epoch: 7, lastUserRecordID: "u", bumpPending: true)
    store.save(state)
    #expect(UserDefaultsPodcastCloudAccountEpochStore(defaults: defaults).load() == state)
  }
}

// MARK: - Fakes

/// A settable stand-in for `RSSActivePlaybackTracker.activeEpisodeRowIDs`, so a test can start a
/// device with no episode playing and mark one active only once it exists.
private final class MutableActiveEpisodeSet: @unchecked Sendable {
  private let lock = NSLock()
  private var rowIDs: Set<Int64> = []

  func set(_ rowIDs: Set<Int64>) {
    lock.lock()
    defer { lock.unlock() }
    self.rowIDs = rowIDs
  }

  func read() -> Set<Int64> {
    lock.lock()
    defer { lock.unlock() }
    return rowIDs
  }
}

private final class RecordingBackgroundTime: PodcastCloudBackgroundTimeGranting, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var runs: Int { lock.withLock { count } }

  func run(_ work: @escaping @Sendable () async -> Void) async {
    lock.withLock { count += 1 }
    await work()
  }
}

private final class FakeAccount: PodcastCloudAccountReading, @unchecked Sendable {
  private let lock = NSLock()
  private var state: PodcastCloudAccountState

  init(_ state: PodcastCloudAccountState) { self.state = state }

  func set(_ state: PodcastCloudAccountState) {
    lock.lock()
    self.state = state
    lock.unlock()
  }

  func currentAccount() async -> PodcastCloudAccountState {
    lock.withLock { state }
  }
}

private final class MemoryEpochs: PodcastCloudAccountEpochStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var state: PodcastCloudAccountEpochState

  init(_ state: PodcastCloudAccountEpochState) { self.state = state }

  func load() -> PodcastCloudAccountEpochState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  func save(_ state: PodcastCloudAccountEpochState) {
    lock.lock()
    self.state = state
    lock.unlock()
  }
}

final class MemoryLastSync: PodcastCloudLastSyncStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date?

  func load() -> Date? {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func save(_ date: Date?) {
    lock.lock()
    self.date = date
    lock.unlock()
  }
}

/// The account's keyring record, shared by every device on the account.
private actor SharedKeyring: PodcastCloudKeyringStore {
  private var stored: Data?

  func fetchKeyring() async throws -> PodcastCloudKeyringFetch {
    stored.map { .present(recordNameKey: $0) } ?? .absent
  }

  func saveNewKeyring(_ key: PodcastCloudRecordNameKey) async throws -> PodcastCloudKeyringSave {
    if let stored { return .serverRecordChanged(recordNameKey: stored) }
    stored = key.bytes
    return .saved
  }
}

private struct FixedIdentity: DeviceInstallIdentity {
  func currentToken() -> DeviceInstallTokenRead { .token("install") }
}

private final class MemoryDefaults: PodcastCloudSyncConsentDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Any] = [:]

  func boolValue(forKey key: String) -> Bool? { read(key) as? Bool }
  func setBoolValue(_ value: Bool, forKey key: String) { write(key, value) }
  func stringValue(forKey key: String) -> String? { read(key) as? String }
  func setStringValue(_ value: String, forKey key: String) { write(key, value) }
  func removeValue(forKey key: String) { write(key, nil) }

  private func read(_ key: String) -> Any? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  private func write(_ key: String, _ value: Any?) {
    lock.lock()
    values[key] = value
    lock.unlock()
  }
}

/// Sees each session's coordinator without keeping it.
private final class CoordinatorWitness: @unchecked Sendable {
  private let lock = NSLock()
  private weak var latest: PodcastCloudSyncCoordinator?
  private var count = 0

  func saw(_ coordinator: PodcastCloudSyncCoordinator) {
    lock.withLock {
      latest = coordinator
      count += 1
    }
  }

  var started: Int { lock.withLock { count } }
  var alive: Bool { lock.withLock { latest != nil } }
}
