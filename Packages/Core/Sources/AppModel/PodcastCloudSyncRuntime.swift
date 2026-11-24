import CoreSupport
import Foundation
import Persistence
import SyncEngine

/// The iCloud account as the runtime needs to see it, with no CloudKit type in sight.
public enum PodcastCloudAccountState: Sendable, Equatable {
  case available(userRecordID: String)
  /// Signed out, or restricted. The engine still starts so a later sign-in has a listener.
  case noAccount
  /// The account could not be read: offline, or temporarily unavailable. Nothing starts, because
  /// guessing either way is wrong: "signed out" would fence the namespace and "available" has no
  /// user to fence by. The next account change or foreground tries again.
  case unknown
}

public protocol PodcastCloudAccountReading: Sendable {
  func currentAccount() async -> PodcastCloudAccountState
}

/// What this installation remembers about its account epochs. Device-local: a fact about this
/// install's outbox namespaces, not about the account.
public struct PodcastCloudAccountEpochState: Codable, Sendable, Equatable {
  public var epoch: Int64
  /// The last account sync ran against. Kept through a sign-out so a different account signing
  /// in afterwards is recognised as a switch rather than a return.
  public var lastUserRecordID: String?
  /// Set whenever the account changed underneath a namespace; the next start opens a new one.
  public var bumpPending: Bool

  public static let initial = PodcastCloudAccountEpochState(epoch: 0, lastUserRecordID: nil, bumpPending: false)

  public init(epoch: Int64, lastUserRecordID: String?, bumpPending: Bool) {
    self.epoch = epoch
    self.lastUserRecordID = lastUserRecordID
    self.bumpPending = bumpPending
  }
}

public protocol PodcastCloudAccountEpochStoring: Sendable {
  func load() -> PodcastCloudAccountEpochState
  func save(_ state: PodcastCloudAccountEpochState)
}

public final class UserDefaultsPodcastCloudAccountEpochStore: PodcastCloudAccountEpochStoring,
  @unchecked Sendable
{
  public static let key = "podcasts.cloudSync.accountEpoch"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> PodcastCloudAccountEpochState {
    guard let data = defaults.data(forKey: Self.key),
      let state = try? JSONDecoder().decode(PodcastCloudAccountEpochState.self, from: data)
    else { return .initial }
    return state
  }

  public func save(_ state: PodcastCloudAccountEpochState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: Self.key)
  }
}

/// When sync last completed a fetch, kept across launches so Settings can show it before the new
/// session has reached iCloud. Device-local, like the epoch record.
public protocol PodcastCloudLastSyncStoring: Sendable {
  func load() -> Date?
  func save(_ date: Date?)
}

public final class UserDefaultsPodcastCloudLastSyncStore: PodcastCloudLastSyncStoring, @unchecked Sendable {
  public static let key = "podcasts.cloudSync.lastSuccessfulSync"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> Date? {
    defaults.object(forKey: Self.key) as? Date
  }

  public func save(_ date: Date?) {
    defaults.set(date, forKey: Self.key)
  }
}

/// The iCloud account rules as a pure decision.
public enum PodcastCloudAccountPolicy {
  public enum Decision: Sendable, Equatable {
    case start(epoch: Int64, userRecordID: String?)
    /// A different account than the one sync last ran against. Nothing is uploaded to it until
    /// the listener enables sync again, and that consent sheet is the explicit merge choice.
    case accountSwitched
    case wait
  }

  public static func decide(
    _ account: PodcastCloudAccountState, stored: PodcastCloudAccountEpochState
  ) -> (Decision, PodcastCloudAccountEpochState) {
    var next = stored
    switch account {
    case .unknown:
      return (.wait, stored)
    case .noAccount:
      next.bumpPending = true
      return (.start(epoch: stored.epoch, userRecordID: nil), next)
    case .available(let user):
      if let last = stored.lastUserRecordID, last != user {
        next.lastUserRecordID = nil
        next.bumpPending = true
        return (.accountSwitched, next)
      }
      if stored.bumpPending || stored.lastUserRecordID == nil { next.epoch += 1 }
      next.lastUserRecordID = user
      next.bumpPending = false
      return (.start(epoch: next.epoch, userRecordID: user), next)
    }
  }
}

/// The refresh path is composed once, at launch; the coordinator comes and goes with consent.
/// This stands between them so `RSSPodcastRefreshing` never holds a stale session.
public final class PodcastCloudRefreshRelay: PodcastRefreshCommitObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var target: (any PodcastRefreshCommitObserving)?

  public init() {}

  public func set(_ target: (any PodcastRefreshCommitObserving)?) {
    lock.lock()
    defer { lock.unlock() }
    self.target = target
  }

  public func feedRefreshCommitted(feedId: Int64) async {
    let target = lock.withLock { self.target }
    await target?.feedRefreshCommitted(feedId: feedId)
  }
}

/// The live sync lifetime: one coordinator, engine and local-change pump per consented session.
///
/// It is the only place that turns consent into CloudKit work. A session starts when the gate
/// opens and the account can be read, and ends when consent is withdrawn, the account changes, or
/// iCloud data is deleted. Everything below it (barrier, merge, projection) is the coordinator's.
public actor PodcastCloudSyncRuntime: PodcastCloudSyncControlling, PodcastPlaybackSettleObserving {
  public struct Destination: Sendable, Equatable {
    public let container: String
    public let environment: String
    public let zone: String

    public init(container: String, environment: String, zone: String) {
      self.container = container
      self.environment = environment
      self.zone = zone
    }
  }

  public typealias Consent = PodcastCloudSyncConsentReading & PodcastCloudSyncConsentWriting

  private struct Session {
    let coordinator: PodcastCloudSyncCoordinator
    let pump: Task<Void, Never>
    var enableFailed = false
  }

  private let database: AppDatabase
  private let anchor: any PodcastCloudInstallationAnchor
  private let consent: any Consent
  private let destinationReady: Bool
  private let destination: Destination
  private let account: any PodcastCloudAccountReading
  private let epochs: any PodcastCloudAccountEpochStoring
  private let lastSync: any PodcastCloudLastSyncStoring
  private let makeEngine: @Sendable (PodcastCloudSyncCoordinator) async -> any PodcastCloudSyncing
  private let makeKeyringStore: @Sendable () -> (any PodcastCloudKeyringStore)?
  private let refreshRelay: PodcastCloudRefreshRelay
  private let backgroundTime: any PodcastCloudBackgroundTimeGranting
  private let debounce: Duration
  private let now: @Sendable () -> Date
  /// The local row ids playing right now. SyncEngine cannot import AppModel, so the runtime is
  /// where the real `RSSActivePlaybackTracker` reaches the coordinator.
  private let activeEpisodeRowIDs: @Sendable () -> Set<Int64>
  private static let log = CoreLogging.logger(category: "PodcastCloudSync")
  /// Coming back to the app within this long of a completed fetch sends without fetching again,
  /// so switching between apps does not repeat the request.
  public static let foregroundFetchInterval: TimeInterval = 30

  private var wanted = false
  private var starting = false
  /// An account change that arrived while a start was reading the old account.
  private var restartAfterStart = false
  private var session: Session?
  /// Why the last start ended without a session. Launch swallows these, so this is the only place
  /// they surface; without it a consented device that never started would read as "Off".
  private var startFailure: PodcastCloudSyncStatus?
  /// The consent value `run()` most recently finished reconciling. Lets a test prove a consent
  /// change was acted on before asserting that nothing started.
  private(set) var lastReconciledConsent: Bool?

  public init(
    database: AppDatabase,
    anchor: any PodcastCloudInstallationAnchor,
    consent: any Consent,
    destinationReady: Bool,
    destination: Destination,
    account: any PodcastCloudAccountReading,
    epochs: any PodcastCloudAccountEpochStoring,
    lastSync: any PodcastCloudLastSyncStoring,
    refreshRelay: PodcastCloudRefreshRelay,
    backgroundTime: any PodcastCloudBackgroundTimeGranting = PodcastCloudNoBackgroundTime(),
    debounce: Duration = PodcastCloudLocalChangePump.defaultDebounce,
    now: @escaping @Sendable () -> Date = Date.init,
    activeEpisodeRowIDs: @escaping @Sendable () -> Set<Int64> = { [] },
    makeKeyringStore: @escaping @Sendable () -> (any PodcastCloudKeyringStore)?,
    makeEngine: @escaping @Sendable (PodcastCloudSyncCoordinator) async -> any PodcastCloudSyncing
  ) {
    self.database = database
    self.anchor = anchor
    self.consent = consent
    self.destinationReady = destinationReady
    self.destination = destination
    self.account = account
    self.epochs = epochs
    self.lastSync = lastSync
    self.refreshRelay = refreshRelay
    self.backgroundTime = backgroundTime
    self.debounce = debounce
    self.now = now
    self.activeEpisodeRowIDs = activeEpisodeRowIDs
    self.makeKeyringStore = makeKeyringStore
    self.makeEngine = makeEngine
  }

  /// Follows consent for as long as the calling task lives. Call once, at launch, after the
  /// database is open.
  public func run() async {
    for await consented in consent.observeConsent() {
      wanted = consented && destinationReady
      await reconcile()
      lastReconciledConsent = consented
    }
    await stopSession()
  }

  /// The platform reported an account change. The running namespace is finished with either way:
  /// a sign-out quarantines it, and a return or a switch needs a new one.
  public func accountDidChange() async {
    var stored = epochs.load()
    stored.bumpPending = true
    epochs.save(stored)
    if starting { restartAfterStart = true }
    await stopSession()
    await reconcile()
  }

  /// A retry point for a start that waited on an unreadable account, and a catch-up for a running
  /// session: silent pushes are not guaranteed to arrive, and a send the engine had scheduled may
  /// not have run before the app was suspended.
  public func sceneDidBecomeActive() async {
    await reconcile()
    guard let coordinator = runningCoordinator else { return }
    do {
      try await coordinator.catchUp(skippingFetchWithin: Self.foregroundFetchInterval)
    } catch {
      Self.log.notice(
        "Foreground catch-up failed: \(PodcastCloudSyncCoordinator.describe(error), privacy: .public)")
    }
  }

  /// iOS suspends the app within seconds of leaving the foreground, often before the engine's own
  /// schedule has sent.
  public func sceneDidEnterBackground() async {
    await sendPendingChanges()
  }

  /// A pause or close has made the final position durable. Returns at once: the playback bridge
  /// awaits its triggers in order, and a send must not hold up the next event.
  public nonisolated func playbackPositionSettled() {
    Task { await self.sendPendingChanges() }
  }

  private func sendPendingChanges() async {
    guard let coordinator = runningCoordinator else { return }
    await backgroundTime.run {
      do {
        try await coordinator.sendPendingChanges()
      } catch {
        Self.log.notice(
          "Background send failed: \(PodcastCloudSyncCoordinator.describe(error), privacy: .public)")
      }
    }
  }

  private var runningCoordinator: PodcastCloudSyncCoordinator? {
    guard let session, session.enableFailed == false else { return nil }
    return session.coordinator
  }

  var isRunning: Bool { session != nil }

  private func reconcile() async {
    guard wanted else {
      await stopSession()
      return
    }
    guard session == nil, starting == false else { return }
    starting = true
    await startSession()
    starting = false
    if restartAfterStart {
      restartAfterStart = false
      await stopSession()
      await reconcile()
    }
  }

  private func startSession() async {
    startFailure = nil
    guard
      case .resolved(let resolution) = try? await PodcastCloudInstallationResolver.resolve(
        database: database, anchor: anchor)
    else {
      Self.log.error("Podcast sync could not start: the installation did not resolve")
      startFailure = .interrupted
      return
    }
    let current = await account.currentAccount()
    let (decision, next) = PodcastCloudAccountPolicy.decide(current, stored: epochs.load())
    epochs.save(next)
    // Consent can be withdrawn while the account is read.
    guard wanted else { return }
    switch decision {
    case .wait:
      // Offline, or iCloud has not answered; the next foreground or account change retries.
      Self.log.error("Podcast sync waiting: the iCloud account could not be read")
      startFailure = .waiting(until: nil)
      return
    case .accountSwitched:
      lastSync.save(nil)
      consent.revoke()
      return
    case .start(let epoch, let user):
      let fence = PodcastCloudAccountFence(
        container: destination.container, environment: destination.environment,
        zone: destination.zone, iCloudUserRecordID: user, accountEpoch: epoch)
      let keys = PodcastCloudRecordNameKeyBox()
      let coordinator = PodcastCloudSyncCoordinator(
        database: database,
        applier: PodcastCloudProjectingApplier(recordNameKeys: keys, now: now),
        keyringStore: makeKeyringStore(), recordNameKeys: keys, now: now,
        activeEpisodeRowIDs: activeEpisodeRowIDs)
      await coordinator.attach(await makeEngine(coordinator))
      let pump = Task { [database, debounce] in
        await PodcastCloudLocalChangePump.run(
          database: database, coordinator: coordinator, debounce: debounce)
      }
      session = Session(coordinator: coordinator, pump: pump)
      refreshRelay.set(coordinator)
      do {
        try await coordinator.enable(resolution: resolution, fence: fence)
      } catch {
        Self.log.error(
          "Podcast sync could not enable: \(String(describing: type(of: error)), privacy: .public)")
        session?.enableFailed = true
      }
    }
  }

  private func stopSession() async {
    guard let session else { return }
    self.session = nil
    session.pump.cancel()
    refreshRelay.set(nil)
    await session.coordinator.disable()
  }

  // MARK: - PodcastCloudSyncControlling

  public func status() async -> PodcastCloudSyncStatus {
    guard let session else {
      guard wanted else { return .off }
      return starting ? .bootstrapping : startFailure ?? .off
    }
    if session.enableFailed { return .interrupted }
    return await session.coordinator.currentStatus
  }

  /// The session's latest successful fetch, or the one a previous launch stored. Refreshing the
  /// screen is never counted: only a completed fetch sets it.
  public func lastSuccessfulSync() async -> Date? {
    let stored = lastSync.load()
    guard let fetched = await session?.coordinator.lastSuccessfulFetch else { return stored }
    if stored.map({ fetched > $0 }) ?? true { lastSync.save(fetched) }
    return max(fetched, stored ?? fetched)
  }

  /// Publishes what the dirty log holds first, so Try Again sends the edit made a moment ago
  /// rather than waiting out the pump's debounce. A consented session that failed to start is
  /// started again first: the screen offers Try Again as the retry for it.
  public func syncNow() async throws {
    if wanted, session == nil || session?.enableFailed == true {
      await stopSession()
      await reconcile()
    }
    guard let session, session.enableFailed == false else {
      throw PodcastCloudSyncCoordinatorError.notEnabled
    }
    let coordinator = session.coordinator
    await coordinator.publishLocalChanges()
    try await coordinator.syncNow()
  }

  /// Confirmed recovery: recreates the zone, sends the retained outbox and resumes sync.
  public func recoverFromZoneLoss() async throws {
    guard let coordinator = runningCoordinator else {
      throw PodcastCloudSyncCoordinatorError.notEnabled
    }
    try await coordinator.recoverFromZoneLoss()
  }

  public func repairClock() async throws {
    guard let coordinator = runningCoordinator else {
      throw PodcastCloudSyncCoordinatorError.notEnabled
    }
    try await coordinator.repairClock()
  }

  /// A confirmed deletion turns sync off on this device too. Leaving consent on would let the next
  /// launch enable again and recreate the zone the listener just deleted.
  public func deleteCloudData() async throws {
    guard let coordinator = session?.coordinator else {
      throw PodcastCloudSyncCoordinatorError.notEnabled
    }
    try await coordinator.deleteCloudData()
    if await coordinator.currentStatus == .off {
      lastSync.save(nil)
      consent.revoke()
      await stopSession()
    }
  }
}
