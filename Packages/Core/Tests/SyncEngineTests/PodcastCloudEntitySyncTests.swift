import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// Per-entity sync gate, end to end: local edits made through the ordinary stores, captured by
/// the v70 dirty log, stamped by the reconciler, carried by `FakePodcastCloudServer`, and
/// projected into the other device's tables by `PodcastCloudProjectingApplier`. Nothing here
/// writes a cloud record by hand, so a test passes only if capture, publication, admission and
/// projection all do their part.
@Suite struct PodcastCloudEntitySyncTests {
  static let fence = PodcastCloudAccountFence(
    container: "iCloud.com.remoteconcern.whirr", environment: "development", zone: "PodcastState",
    iCloudUserRecordID: "_user", accountEpoch: 1)
  static let feedURL = URL(string: "https://example.com/show.xml")!

  /// One account's key, shared by every device as the keyring would share it.
  let key = PodcastCloudRecordNameKey.mint()

  struct Device {
    let database: AppDatabase
    let anchor = FakePodcastCloudInstallationAnchor()
    let keys: PodcastCloudRecordNameKeyBox
    let server: FakePodcastCloudServer
    var coordinator: PodcastCloudSyncCoordinator
    var engine: FakePodcastCloudEngine

    var now: Date { server.now }

    /// One process's elapsed time, driven by the fake server's clock so `server.advance` is time
    /// passing on the device too. Made per coordinator: a relaunch starts with no anchor.
    static func monotonic(_ server: FakePodcastCloudServer) -> PodcastCloudMonotonicSource {
      PodcastCloudMonotonicSource(nowMilliseconds: { [server] in
        Int64((server.now.timeIntervalSince1970 * 1000).rounded(.down))
      })
    }

    static func make(
      key: PodcastCloudRecordNameKey, server: FakePodcastCloudServer, enable: Bool = true,
      activeEpisodeRowIDs: @escaping @Sendable () -> Set<Int64> = { [] }
    )
      async throws -> Device
    {
      let database = try AppDatabase.inMemory()
      let keys = PodcastCloudRecordNameKeyBox(key)
      let coordinator = PodcastCloudSyncCoordinator(
        database: database,
        applier: PodcastCloudProjectingApplier(recordNameKeys: keys, now: { [server] in server.now }),
        recordNameKeys: keys, now: { [server] in server.now },
        activeEpisodeRowIDs: activeEpisodeRowIDs, monotonic: monotonic(server))
      let engine = FakePodcastCloudEngine(server: server, handler: coordinator)
      await coordinator.attach(engine)
      var device = Device(
        database: database, keys: keys, server: server, coordinator: coordinator, engine: engine)
      if enable { try await device.enable() }
      return device
    }

    mutating func enable() async throws {
      guard
        case .resolved(let resolution) = try await PodcastCloudInstallationResolver.resolve(
          database: database, anchor: anchor)
      else { throw Failure.unresolved }
      try await coordinator.enable(resolution: resolution, fence: PodcastCloudEntitySyncTests.fence)
    }

    /// Publish what the dirty log holds, then a full fetch and send.
    func sync() async throws {
      await coordinator.publishLocalChanges()
      try await coordinator.syncNow()
    }

    // MARK: Local catalogue, as a refresh would build it

    @discardableResult
    func subscribe(at date: Date? = nil) async throws -> Int64 {
      try await RSSFeedStore(database: database).subscribe(
        feedURL: PodcastCloudEntitySyncTests.feedURL, title: "Show", author: "Host", synopsis: nil,
        artworkURL: nil, subscribedAt: date ?? now)
    }

    func feedID() async throws -> Int64? {
      try await database.readAsync { db in try Int64.fetchOne(db, sql: "SELECT id FROM rssFeed") }
    }

    /// Process death and relaunch: the database survives, the coordinator and engine do not.
    mutating func relaunch() async throws {
      await engine.stop()
      let coordinator = PodcastCloudSyncCoordinator(
        database: database,
        applier: PodcastCloudProjectingApplier(recordNameKeys: keys, now: { [server] in server.now }),
        recordNameKeys: keys, now: { [server] in server.now }, monotonic: Self.monotonic(server))
      let engine = FakePodcastCloudEngine(server: server, handler: coordinator)
      await coordinator.attach(engine)
      self.coordinator = coordinator
      self.engine = engine
      try await enable()
    }

    /// The episode as this device's copy of the feed describes it.
    @discardableResult
    func addEpisode(_ guid: String = "ep1", identityKey: String? = nil) async throws -> Int64 {
      let feedId = try #require(try await feedID())
      let episodeId = try await database.writeAsync { db -> Int64 in
        try db.execute(
          sql: """
            INSERT INTO rssEpisode (feedId, identityKey, guid, title, enclosureURL, lastSeenGeneration)
            VALUES (?, ?, ?, 'Episode', ?, 0)
            """, arguments: [feedId, identityKey ?? "guid:\(guid)", guid, "https://example.com/\(guid).mp3"])
        return db.lastInsertedRowID
      }
      // The refresh path's own entry point, as `RSSPodcastRefreshing` calls it.
      await coordinator.feedRefreshCommitted(feedId: feedId)
      return episodeId
    }

    func state(_ episodeId: Int64) async throws -> RSSEpisodeStateRecord? {
      try await RSSEpisodeStateStore(database: database).fetchState(episodeId: episodeId)
    }

    func isSaved(_ episodeId: Int64) async throws -> Bool {
      try await database.readAsync { db in
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS (SELECT 1 FROM rssSavedShelfEntry WHERE rssEpisodeId = ?)",
          arguments: [episodeId]) ?? false
      }
    }

    func registryEntry() async throws -> PodcastCloudRegistryEntry? {
      let uuid = try #require(
        PodcastCloudIdentity.subscriptionUUID(feedURL: PodcastCloudEntitySyncTests.feedURL.absoluteString))
      return try await PodcastCloudRegistryStore(database: database).entry(
        subscriptionUUID: uuid.uuidString.lowercased())
    }

    func pendingWork() async throws -> PodcastCloudOutstandingWork {
      let namespace = try PodcastCloudSyncCoordinator.namespace(for: PodcastCloudEntitySyncTests.fence)
      return try await PodcastCloudTransportStore(database: database).outstandingWork(namespace: namespace)
    }
  }

  enum Failure: Error { case unresolved }

  static func settle(_ devices: [Device]) async throws {
    for _ in 0..<4 {
      for device in devices { try await device.sync() }
    }
  }

  static func expectQuiet(_ devices: [Device], server: FakePodcastCloudServer) async throws {
    let saves = server.saveCount
    try await settle(devices)
    #expect(server.saveCount == saves, "a converged pair sent more records")
    for device in devices { #expect(try await device.pendingWork().isEmpty) }
  }

  // MARK: - Subscriptions

  @Test func aFollowReachesTheOtherDeviceAndAnUnfollowRetiresItThere() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)

    try await a.subscribe()
    try await Self.settle([a, b])
    #expect(try await b.feedID() != nil, "B follows the show A followed")
    #expect(try await b.registryEntry()?.generationUUID == a.registryEntry()?.generationUUID)

    server.advance(by: 60)
    let bFeed = try #require(try await b.feedID())
    try await RSSFeedStore(database: b.database).unsubscribe(feedId: bFeed)
    try await Self.settle([a, b])
    #expect(try await a.feedID() == nil, "A drops the show B unfollowed")
    #expect(try await a.registryEntry()?.isFollowed == false)
    try await Self.expectQuiet([a, b], server: server)
  }

  @Test func customOrderAndFollowAreIndependentRegisters() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    try await Self.settle([a, b])

    // B reorders, and later A (offline from B) unfollows. Both registers survive the merge: the
    // unfollow wins the follow register, and the order B set is still the order on record.
    server.advance(by: 10)
    let bFeed = try #require(try await b.feedID())
    try await RSSFeedStore(database: b.database).replaceCustomOrder(feedIds: [bFeed])
    await b.coordinator.publishLocalChanges()
    server.advance(by: 10)
    let aFeed = try #require(try await a.feedID())
    try await RSSFeedStore(database: a.database).unsubscribe(feedId: aFeed)
    await a.coordinator.publishLocalChanges()
    try await Self.settle([a, b])

    #expect(try await b.feedID() == nil)
    #expect(try await b.registryEntry()?.isFollowed == false)
    #expect(try await a.registryEntry()?.isFollowed == false)
    try await Self.expectQuiet([a, b], server: server)
  }

  @Test func aRefollowOpensAFreshGenerationEverywhere() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    let feed = try await a.subscribe()
    try await Self.settle([a, b])
    let first = try #require(try await a.registryEntry()?.generationUUID)

    server.advance(by: 10)
    try await RSSFeedStore(database: a.database).unsubscribe(feedId: feed)
    try await Self.settle([a, b])
    server.advance(by: 10)
    try await b.subscribe()
    try await Self.settle([a, b])

    let refollowed = try #require(try await a.registryEntry())
    #expect(refollowed.isFollowed)
    #expect(refollowed.generationUUID != first)
    #expect(try await b.registryEntry()?.generationUUID == refollowed.generationUUID)
    #expect(try await a.feedID() != nil)
  }

  // MARK: - Settings

  @Test func theLaterOfTwoOfflineGlobalEditsWinsOnBoth() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)

    try await NativePodcastSettingsStore(database: a.database).setGlobalKeepLatestCount(5)
    await a.coordinator.publishLocalChanges()
    server.advance(by: 10)
    try await NativePodcastSettingsStore(database: b.database).setGlobalKeepLatestCount(9)
    try await RSSFeedStore(database: b.database).setSortMode(.mostRecent)
    await b.coordinator.publishLocalChanges()
    try await Self.settle([a, b])

    for device in [a, b] {
      let settings = await NativePodcastSettingsStore(database: device.database).fetchGlobalSettings()
      #expect(settings.keepLatestCount == 9)
      #expect(
        try await device.database.readAsync { db in try String.fetchOne(db, sql: "SELECT mode FROM rssShowOrder") }
          == "mostRecent")
    }
    try await Self.expectQuiet([a, b], server: server)
  }

  /// Once a device has fetched a record its clock is anchored, and from then on its stamps must
  /// still move with elapsed time. Run in both directions because equal stamps fall to the
  /// installation tie-break, which would let a frozen clock pass one direction by luck.
  @Test func theLaterEditWinsOnceBothClocksAreAnchored() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    // Each device fetches a record the other wrote, which anchors both clocks.
    try await NativePodcastSettingsStore(database: a.database).setGlobalKeepLatestCount(2)
    try await Self.settle([a, b])
    server.advance(by: 10)
    try await NativePodcastSettingsStore(database: b.database).setGlobalKeepLatestCount(3)
    try await Self.settle([a, b])
    for device in [a, b] {
      let clock = try await device.database.readAsync { db in try PodcastCloudInstallationStore.clock(in: db) }
      #expect(clock?.anchorServerMilliseconds != nil)
    }

    for (earlier, later, count) in [(a, b, 9), (b, a, 4)] {
      server.advance(by: 60)
      try await NativePodcastSettingsStore(database: earlier.database).setGlobalKeepLatestCount(count + 1)
      await earlier.coordinator.publishLocalChanges()
      server.advance(by: 600)
      try await NativePodcastSettingsStore(database: later.database).setGlobalKeepLatestCount(count)
      await later.coordinator.publishLocalChanges()
      try await Self.settle([a, b])
      for device in [a, b] {
        let settings = await NativePodcastSettingsStore(database: device.database).fetchGlobalSettings()
        #expect(settings.keepLatestCount == count, "the edit made ten minutes later wins")
      }
    }
    try await Self.expectQuiet([a, b], server: server)
  }

  @Test func feedSettingsFollowTheirSubscription() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    let feed = try await a.subscribe()
    try await RSSFeedSettingsStore(database: a.database).setKeepLatestOverride(feedId: feed, count: 3)
    try await Self.settle([a, b])

    let bFeed = try #require(try await b.feedID())
    #expect(try await RSSFeedSettingsStore(database: b.database).settings(feedId: bFeed)?.keepLatest == 3)

    server.advance(by: 10)
    try await RSSFeedSettingsStore(database: b.database).setKeepLatestOverride(feedId: bFeed, count: nil)
    try await Self.settle([a, b])
    #expect(try await RSSFeedSettingsStore(database: a.database).settings(feedId: feed)?.keepLatest == nil)
    try await Self.expectQuiet([a, b], server: server)
  }

  /// A feed's Trim Silences setting follows it to the listener's other devices, and saving
  /// another setting there keeps it.
  @Test func aFeedsTrimSilencesSettingTravelsAndSurvivesAnotherEdit() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    let feed = try await a.subscribe()
    try await RSSFeedSettingsStore(database: a.database).setTrimSilencesOverride(feedId: feed, override: .maximum)
    try await Self.settle([a, b])

    let bFeed = try #require(try await b.feedID())
    let bStore = RSSFeedSettingsStore(database: b.database)
    #expect(try await bStore.fetchTrimSilencesOverrides() == [bFeed: .maximum])

    server.advance(by: 10)
    try await bStore.setKeepLatestOverride(feedId: bFeed, count: 2)
    try await Self.settle([a, b])
    let aStore = RSSFeedSettingsStore(database: a.database)
    #expect(try await aStore.fetchTrimSilencesOverrides() == [feed: .maximum])
    #expect(try await aStore.settings(feedId: feed)?.keepLatest == 2)

    server.advance(by: 10)
    try await bStore.setTrimSilencesOverride(feedId: bFeed, override: .inherit)
    try await Self.settle([a, b])
    #expect(try await aStore.fetchTrimSilencesOverrides().isEmpty)
    try await Self.expectQuiet([a, b], server: server)
  }

  /// A device on a build from before Trim Silences saves the feed's settings without the new
  /// fields. The devices that have them keep their own value, and republish it.
  @Test func aSettingsRecordFromAnOlderBuildKeepsTheTrimSilencesSetting() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    let feed = try await a.subscribe()
    try await RSSFeedSettingsStore(database: a.database).setTrimSilencesOverride(feedId: feed, override: .off)
    try await Self.settle([a, b])

    let (recordName, published) = try #require(
      server.fields.compactMap { name, fields in
        (try? PodcastCloudRecordCodec.decodeFeedSettings(fields)).map { (name, $0) }
      }.first)
    #expect(published.trimSilencesOverride == "off")
    #expect(published.voiceBoostOverride == "inherit")
    server.advance(by: 10)
    let olderBuild = FeedSettingsSnapshot(
      autoDownload: published.autoDownload, keepLatest: 7, deleteAfterPlayed: published.deleteAfterPlayed,
      rateStep: published.rateStep, includeInLatest: published.includeInLatest,
      notificationOverride: published.notificationOverride,
      stamp: try PodcastCloudMutationStamp(
        physicalMilliseconds: Int64(server.now.timeIntervalSince1970 * 1_000), logicalCounter: 0,
        installationUUID: UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!,
        mutationUUID: UUID(uuidString: "00000000-0000-4000-8000-0000000000ab")!))
    let olderFields = try PodcastCloudRecordCodec.encode(feedSettings: olderBuild, recordName: recordName)
    #expect(olderFields.encrypted["trimSilencesOverride"] == nil)
    server.saveAsAnotherDevice(olderFields)
    try await Self.settle([a, b])

    let bFeed = try #require(try await b.feedID())
    for (device, feedId) in [(a, feed), (b, bFeed)] {
      let store = RSSFeedSettingsStore(database: device.database)
      #expect(try await store.settings(feedId: feedId)?.keepLatest == 7)
      #expect(try await store.fetchTrimSilencesOverrides() == [feedId: .off])
    }
    let republished = try PodcastCloudRecordCodec.decodeFeedSettings(try #require(server.fields[recordName]))
    #expect(republished.trimSilencesOverride == "off")
    #expect(republished.keepLatest == 7)
    try await Self.expectQuiet([a, b], server: server)
  }

  // MARK: - Episode state

  /// B's still-unsent tick outranks A's later, newer finish, and B's session keeps its sequence
  /// rather than being refused as stale.
  @Test func progressTravelsAndAnUnsentTickOutranksALaterFinish() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()

    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 120, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b])
    #expect(try await b.state(bEpisode)?.position == 120, "progress reaches B")

    // Offline from each other: A finishes, then B (which never heard) keeps listening.
    server.advance(by: 10)
    _ = try await aStore.setFinished(episodeId: aEpisode, finished: true, now: a.now)
    await a.coordinator.publishLocalChanges()
    server.advance(by: 10)
    let bStore = RSSEpisodeStateStore(database: b.database)
    let bSequence = try #require(try await b.state(bEpisode)?.localSequence)
    _ = try await bStore.recordTick(
      episodeId: bEpisode, position: 400, finished: false, capturedSequence: bSequence, now: b.now)
    await b.coordinator.publishLocalChanges()
    try await Self.settle([a, b])

    #expect(try await a.state(aEpisode)?.finished == false, "B's unsent listening outranks the finish")
    #expect(try await a.state(aEpisode)?.position == 400)
    #expect(try await b.state(bEpisode)?.finished == false)
    #expect(try await b.state(bEpisode)?.position == 400)

    // B's own row was never touched by the finish it outranked: its session sequence
    // carried on, so its next tick is accepted rather than refused as stale.
    _ = try await bStore.recordTick(
      episodeId: bEpisode, position: 420, finished: false, capturedSequence: bSequence + 1, now: b.now)
    try await Self.settle([a, b])
    try await Self.expectQuiet([a, b], server: server)
  }

  @Test func aStateForAnEpisodeNotYetSeenIsHeldUntilTheRefreshThatBringsIt() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    _ = try await RSSEpisodeStateStore(database: a.database).setFinished(
      episodeId: aEpisode, finished: true, now: a.now)
    try await Self.settle([a, b])

    // B follows now but its feed copy has no episodes until it refreshes.
    let bEpisode = try await b.addEpisode()
    #expect(try await b.state(bEpisode)?.finished == true)
    try await Self.expectQuiet([a, b], server: server)
  }

  @Test func resetAndDismissalAreExplicitAndTravel() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()
    let aStore = RSSEpisodeStateStore(database: a.database)

    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 300, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b])
    server.advance(by: 10)
    _ = try await RSSEpisodeStateStore(database: b.database).setHiddenFromContinueListening(
      episodeId: bEpisode, isHidden: true, now: b.now)
    try await Self.settle([a, b])
    #expect(try await a.state(aEpisode)?.hideFromContinueListening == true)

    server.advance(by: 10)
    _ = try await aStore.resetProgress(episodeId: aEpisode, now: a.now)
    try await Self.settle([a, b])
    let reset = try #require(try await b.state(bEpisode))
    #expect(reset.position == 0)
    #expect(reset.finished == false)
    try await Self.expectQuiet([a, b], server: server)
  }

  /// B's copy of the feed keys the episode by something other than its GUID, so the two devices
  /// name its records differently and B can only match A's by GUID. Each device must adopt the
  /// other's value under its own name, or they would republish the same value to each other
  /// forever.
  @Test func devicesThatKeyAnEpisodeDifferentlyStillSettle() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode(identityKey: "enclosure:https://example.com/ep1.mp3")

    _ = try await RSSEpisodeStateStore(database: a.database).setFinished(
      episodeId: aEpisode, finished: true, now: a.now)
    try await Self.settle([a, b])
    #expect(try await b.state(bEpisode)?.finished == true)
    try await Self.expectQuiet([a, b], server: server)

    server.advance(by: 10)
    _ = try await RSSEpisodeStateStore(database: b.database).setFinished(
      episodeId: bEpisode, finished: false, now: b.now)
    try await Self.settle([a, b])
    #expect(try await a.state(aEpisode)?.finished == false)
    try await Self.expectQuiet([a, b], server: server)
  }

  // MARK: - A change that cannot be published

  /// A local edit the reconciler cannot express is kept in the dirty log and reported, rather than
  /// cleared and forgotten until the same row changes again. Correcting the row publishes it.
  @Test func anUnpublishableEditStaysQueuedAndReadsAsInterruptedUntilItSends() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()
    _ = try await RSSEpisodeStateStore(database: a.database).recordTick(
      episodeId: aEpisode, position: 60, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b])

    // No store writes a negative position; this stands in for any row the layout refuses.
    server.advance(by: 10)
    try await a.database.writeAsync { db in
      try db.execute(sql: "UPDATE rssEpisodeState SET position = -1 WHERE episodeId = ?", arguments: [aEpisode])
    }
    await a.coordinator.publishLocalChanges()
    #expect(await a.coordinator.currentStatus == .interrupted)
    let pending = try await a.database.readAsync { db in try PodcastCloudDirtyLog.entries(in: db) }
    #expect(pending == [PodcastCloudDirtyEntry(kind: .episodeState, key: String(aEpisode))])
    try await a.sync()
    #expect(await a.coordinator.currentStatus == .interrupted, "a clean fetch does not hide a stuck edit")

    server.advance(by: 10)
    try await a.database.writeAsync { db in
      try db.execute(sql: "UPDATE rssEpisodeState SET position = 90 WHERE episodeId = ?", arguments: [aEpisode])
    }
    try await Self.settle([a, b])
    #expect(try await a.database.readAsync { db in try PodcastCloudDirtyLog.isEmpty(in: db) })
    #expect(try await b.state(bEpisode)?.position == 90, "the corrected edit reaches B")
    #expect(await a.coordinator.currentStatus == .upToDate)
  }

  // MARK: - Last successful sync

  @Test func aSuccessfulFetchIsRecorded() async throws {
    let server = FakePodcastCloudServer()
    var a = try await Device.make(key: key, server: server, enable: false)
    #expect(await a.coordinator.lastSuccessfulFetch == nil)

    try await a.enable()
    #expect(await a.coordinator.lastSuccessfulFetch == server.now, "the bootstrap fetch counts")

    server.advance(by: 60)
    try await a.sync()
    #expect(await a.coordinator.lastSuccessfulFetch == server.now)
  }

  // MARK: - Process death

  @Test(arguments: [FakePodcastCloudEngine.CrashPoint.afterServerWrite, .afterFetchedChanges])
  func aDeviceThatDiesMidSyncStillConverges(_ crash: FakePodcastCloudEngine.CrashPoint) async throws {
    let server = FakePodcastCloudServer()
    var a = try await Device.make(key: key, server: server)
    var b = try await Device.make(key: key, server: server)
    let feed = try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()

    server.advance(by: 10)
    _ = try await RSSEpisodeStateStore(database: a.database).setFinished(
      episodeId: aEpisode, finished: true, now: a.now)
    try await RSSFeedSettingsStore(database: a.database).setKeepLatestOverride(feedId: feed, count: 2)
    server.advance(by: 10)
    try await NativePodcastSettingsStore(database: b.database).setGlobalKeepLatestCount(6)

    a.engine.crash(at: crash)
    b.engine.crash(at: crash)
    try? await a.sync()
    try? await b.sync()
    try? await a.sync()
    try await a.relaunch()
    try await b.relaunch()
    try await Self.settle([a, b])

    #expect(try await b.state(bEpisode)?.finished == true)
    let bFeed = try #require(try await b.feedID())
    #expect(try await RSSFeedSettingsStore(database: b.database).settings(feedId: bFeed)?.keepLatest == 2)
    #expect(await NativePodcastSettingsStore(database: a.database).fetchGlobalSettings().keepLatestCount == 6)
    try await Self.expectQuiet([a, b], server: server)
  }

  // MARK: - Saved for Later

  @Test func saveAndUnsaveTravelAndFinishingRemovesEverywhere() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()

    let aFeed = try #require(try await a.feedID())
    let identity = SavedShelfIdentity.rssEpisode(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: aFeed)?.itemId), episodeID: "guid:ep1")
    try await NativeSavedShelfStore(database: a.database).save(identity)
    try await Self.settle([a, b])
    #expect(try await b.isSaved(bEpisode))

    server.advance(by: 10)
    let bFeed = try #require(try await b.feedID())
    let bIdentity = SavedShelfIdentity.rssEpisode(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: bFeed)?.itemId), episodeID: "guid:ep1")
    try await NativeSavedShelfStore(database: b.database).remove(bIdentity)
    try await Self.settle([a, b])
    #expect(try await a.isSaved(aEpisode) == false)
    try await Self.expectQuiet([a, b], server: server)
  }

  // MARK: - Bookmark

  @Test func theBookmarkMovesWithoutAnythingPlaying() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    let feed = try await a.subscribe()
    try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()

    try await RSSPlaybackBookmarkStore(database: a.database).setBookmark(
      feedId: feed, episodeID: "guid:ep1", now: a.now)
    try await Self.settle([a, b])
    #expect(try await RSSPlaybackBookmarkStore(database: b.database).fetchBookmarkedEpisodeId() == bEpisode)
    try await Self.expectQuiet([a, b], server: server)
  }

  // MARK: - Reinstall and legacy history

  @Test func aDeviceWithHistoryFromBeforeSyncMergesRatherThanLosing() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    _ = try await RSSEpisodeStateStore(database: a.database).recordTick(
      episodeId: aEpisode, position: 90, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a])

    // B finished the episode long ago, before sync existed, and joins only now.
    var b = try await Device.make(key: key, server: server, enable: false)
    try await b.subscribe(at: Date(timeIntervalSince1970: 1_700_000_000))
    let bEpisode = try await b.addEpisode()
    _ = try await RSSEpisodeStateStore(database: b.database).setFinished(
      episodeId: bEpisode, finished: true, now: Date(timeIntervalSince1970: 1_700_000_100))
    try await b.enable()
    try await Self.settle([a, b])

    #expect(try await a.state(aEpisode)?.finished == true, "an old explicit finish outranks a tick")
    #expect(try await b.state(bEpisode)?.finished == true)
    #expect(try await a.registryEntry()?.generationUUID == b.registryEntry()?.generationUUID)
    try await Self.expectQuiet([a, b], server: server)
  }

  @Test func aFreshInstallTakesTheAccountsSettingsInsteadOfOverwritingThem() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    try await NativePodcastSettingsStore(database: a.database).setGlobalKeepLatestCount(4)
    try await Self.settle([a])

    let b = try await Device.make(key: key, server: server)
    try await Self.settle([a, b])
    for device in [a, b] {
      #expect(await NativePodcastSettingsStore(database: device.database).fetchGlobalSettings().keepLatestCount == 4)
    }
    try await Self.expectQuiet([a, b], server: server)
  }

  // MARK: - Composition

  @Test func thePumpPublishesALocalEditWithoutBeingAsked() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    let pump = Task { [database = a.database, coordinator = a.coordinator] in
      await PodcastCloudLocalChangePump.run(
        database: database, coordinator: coordinator, debounce: .zero)
    }
    defer { pump.cancel() }

    try await a.subscribe()
    await waitUntil("the follow reaches the outbox with no explicit publish") {
      (try? await a.pendingWork().isEmpty == false) ?? false
    }

    // Only the transport runs by hand from here: B learns of the follow through A's send.
    try await a.coordinator.syncNow()
    try await b.coordinator.syncNow()
    #expect(try await b.feedID() != nil)
  }

  // MARK: - Unsent listening beats a reset

  /// A settable stand-in for `RSSActivePlaybackTracker.activeEpisodeRowIDs`, so a test can start a
  /// device with no episode playing and mark one active only once it exists.
  final class MutableActiveEpisodeSet: @unchecked Sendable {
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

  /// A conflict retry hands over a server record the fetch path never admitted, so the clock has
  /// not observed its epoch. The re-stamp must still outrank it, or the reset wins after all.
  @Test func aRestampOutranksARemoteEpochTheClockHasNotObserved() async throws {
    let server = FakePodcastCloudServer()
    let device = try await Device.make(key: key, server: server)
    let (restamped, remoteEpoch) = try await device.database.writeAsync {
      db -> (PodcastCloudEpisodeState, PodcastCloudMutationStamp) in
      let clock = try PodcastCloudClockState(try #require(try PodcastCloudInstallationStore.clock(in: db)))
      let nowMilliseconds = Int64((server.now.timeIntervalSince1970 * 1000).rounded(.down))
      let ahead = max(clock.physicalMilliseconds, nowMilliseconds) + 60 * 60 * 1000
      let remoteEpoch = try PodcastCloudMutationStamp(
        physicalMilliseconds: ahead, logicalCounter: 3, installationUUID: UUID(), mutationUUID: UUID())
      let recordName =
        "v1.state.0a0a0a0a-0a0a-8a0a-8a0a-0a0a0a0a0a0a.0b0b0b0b-0b0b-8b0b-8b0b-0b0b0b0b0b0b."
        + String(repeating: "c", count: 64)
      let identity = PodcastCloudEpisodeIdentityFields(identityKey: "guid:one")
      let local = try PodcastCloudRecordCodec.encode(
        episodeState: try PodcastCloudEpisodeState(
          position: 1_200, isFinished: false, isDismissed: false, explicitEpoch: .bottom,
          writeStamp: try PodcastCloudMutationStamp(
            physicalMilliseconds: clock.physicalMilliseconds, logicalCounter: 0,
            installationUUID: clock.installationUUID, mutationUUID: UUID())),
        identity: identity, recordName: recordName)
      let reset = try PodcastCloudRecordCodec.encode(
        episodeState: try PodcastCloudEpisodeState(
          position: 0, isFinished: false, isDismissed: false, explicitEpoch: remoteEpoch,
          writeStamp: remoteEpoch),
        identity: identity, recordName: recordName)
      let fields = try PodcastCloudSyncCoordinator.restampedEpisodeState(
        local,
        over: PodcastCloudFetchedRecord(
          fields: reset, systemFields: Data(),
          serverModificationDate: Date(timeIntervalSince1970: Double(ahead) / 1000)),
        receivedAt: server.now, in: db)
      return (try PodcastCloudRecordCodec.decodeEpisodeState(fields).state, remoteEpoch)
    }
    #expect(restamped.explicitEpoch > remoteEpoch)
    #expect(restamped.writeStamp == restamped.explicitEpoch)
    #expect(restamped.position == 1_200)
  }

  /// B's unsent tick outranks A's reset, and the whole fleet, including a third device that
  /// never touched the episode, converges on B's listening.
  @Test func anUnsentTickBeatsAResetAndTheWholeFleetConverges() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    let c = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b, c])
    let bEpisode = try await b.addEpisode()
    let cEpisode = try await c.addEpisode()
    try await Self.settle([a, b, c])

    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 100, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b, c])
    #expect(try await b.state(bEpisode)?.position == 100)
    #expect(try await c.state(cEpisode)?.position == 100)

    // Offline from each other: A resets to zero, B keeps listening past that point.
    server.advance(by: 10)
    _ = try await aStore.resetProgress(episodeId: aEpisode, now: a.now)
    await a.coordinator.publishLocalChanges()
    server.advance(by: 10)
    let bStore = RSSEpisodeStateStore(database: b.database)
    let bSequence = try #require(try await b.state(bEpisode)?.localSequence)
    _ = try await bStore.recordTick(
      episodeId: bEpisode, position: 1_200, finished: false, capturedSequence: bSequence, now: b.now)
    await b.coordinator.publishLocalChanges()
    try await Self.settle([a, b, c])

    #expect(try await a.state(aEpisode)?.position == 1_200, "the fleet converges on B's listening")
    #expect(try await b.state(bEpisode)?.position == 1_200)
    #expect(try await c.state(cEpisode)?.position == 1_200)
    #expect(try await b.state(bEpisode)?.finished == false)

    // B's own row was never touched by the reset it refused: its sequence carried on.
    _ = try await bStore.recordTick(
      episodeId: bEpisode, position: 1_210, finished: false, capturedSequence: bSequence + 1, now: b.now)
    try await Self.settle([a, b, c])
    try await Self.expectQuiet([a, b, c], server: server)
  }

  /// B is playing the episode with nothing dirty when the reset arrives. Its next
  /// tick is accepted rather than refused as stale, and the fleet converges on B's position.
  @Test func theEpisodePlayingRightNowIsProtectedWithNoDirtyEntry() async throws {
    let server = FakePodcastCloudServer()
    let activePlayback = MutableActiveEpisodeSet()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(
      key: key, server: server, activeEpisodeRowIDs: { activePlayback.read() })
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()
    try await Self.settle([a, b])

    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 1_200, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b])
    let bSequence = try #require(try await b.state(bEpisode)?.localSequence)
    #expect(try await b.state(bEpisode)?.position == 1_200)

    // B is playing, with no local edit since the last sync: nothing dirty, nothing pending.
    activePlayback.set([bEpisode])
    #expect(try await b.pendingWork().isEmpty)

    _ = try await aStore.resetProgress(episodeId: aEpisode, now: a.now)
    try await Self.settle([a, b])

    #expect(try await b.state(bEpisode)?.position == 1_200, "B's row is untouched by the reset")
    #expect(try await a.state(aEpisode)?.position == 1_200, "A adopts B's re-stamped listening")

    // The session's next tick is accepted rather than refused as stale: admission never bumped
    // B's row sequence.
    _ = try await RSSEpisodeStateStore(database: b.database).recordTick(
      episodeId: bEpisode, position: 1_210, finished: false, capturedSequence: bSequence, now: b.now)
    try await Self.settle([a, b])
    try await Self.expectQuiet([a, b], server: server)
  }

  /// Listening that had already reached iCloud before the reset still loses to it. The rule only
  /// protects a session that is unsent or playing right now.
  @Test func listeningAlreadySyncedStillLosesToAReset() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()
    try await Self.settle([a, b])

    let bStore = RSSEpisodeStateStore(database: b.database)
    _ = try await bStore.recordTick(
      episodeId: bEpisode, position: 1_200, finished: false, capturedSequence: 0, now: b.now)
    try await Self.settle([a, b])
    #expect(try await a.state(aEpisode)?.position == 1_200, "B's listening already reached iCloud")

    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.resetProgress(episodeId: aEpisode, now: a.now)
    try await Self.settle([a, b])

    #expect(try await b.state(bEpisode)?.position == 0, "already-synced listening still loses")
    #expect(try await b.state(bEpisode)?.finished == false)
    try await Self.expectQuiet([a, b], server: server)
  }

  /// A pending explicit action on B (a dismissal) against A's newer explicit reset resolves by
  /// ordinary stamp comparison. The rule never overrides an explicit-against-explicit conflict;
  /// only a strictly newer remote epoch meeting an unsent tick does (`isUnsentTick` is false here
  /// as B's dismissal is explicit, epoch == write stamp, per
  /// `PodcastCloudRecordMergeTests.isUnsentTickOnlyTrueForAPositionChangingTick`).
  ///
  /// Which stamp is higher is the HLC's concern: with both devices anchored to the same server
  /// timestamp (after the shared settle above), a tie falls to each device's logical counter and
  /// then installation UUID, not wall-clock order. This only shows the fleet converges on exactly
  /// one of the two candidates, never a blend, and that nothing republishes afterwards (the
  /// signature of the rule firing wrongly).
  @Test func anExplicitPendingActionAgainstANewerResetResolvesByStamp() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()
    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 300, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b])

    // B dismisses (an explicit action) but goes offline before sending it.
    server.advance(by: 10)
    _ = try await RSSEpisodeStateStore(database: b.database).setHiddenFromContinueListening(
      episodeId: bEpisode, isHidden: true, now: b.now)
    await b.coordinator.publishLocalChanges()

    // A resets (also explicit) before hearing about B's dismissal.
    server.advance(by: 10)
    _ = try await aStore.resetProgress(episodeId: aEpisode, now: a.now)
    await a.coordinator.publishLocalChanges()
    try await Self.settle([a, b])

    let bResult = try await b.state(bEpisode)
    let aResult = try await a.state(aEpisode)
    #expect(bResult?.position == aResult?.position, "the fleet converges on one candidate")
    #expect(bResult?.finished == aResult?.finished)
    #expect(bResult?.hideFromContinueListening == aResult?.hideFromContinueListening)
    let isResetOutcome = bResult?.position == 0 && bResult?.hideFromContinueListening == false
    let isDismissOutcome = bResult?.position == 300 && bResult?.hideFromContinueListening == true
    #expect(
      isResetOutcome || isDismissOutcome,
      "the result is exactly one of the two candidates, not a blend - proving no adoption")
    try await Self.expectQuiet([a, b], server: server)
  }

  /// Unsent listening also beats a newer remote finish, the same way it beats a reset. The rule
  /// does not special-case which explicit action the remote value carries.
  @Test func anUnsentTickBeatsANewerRemoteFinish() async throws {
    let server = FakePodcastCloudServer()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b])
    let bEpisode = try await b.addEpisode()
    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 100, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b])

    server.advance(by: 10)
    _ = try await aStore.setFinished(episodeId: aEpisode, finished: true, now: a.now)
    await a.coordinator.publishLocalChanges()
    server.advance(by: 10)
    let bStore = RSSEpisodeStateStore(database: b.database)
    let bSequence = try #require(try await b.state(bEpisode)?.localSequence)
    _ = try await bStore.recordTick(
      episodeId: bEpisode, position: 1_800, finished: false, capturedSequence: bSequence, now: b.now)
    await b.coordinator.publishLocalChanges()
    try await Self.settle([a, b])

    #expect(try await b.state(bEpisode)?.position == 1_800, "unsent listening beats the finish")
    #expect(try await b.state(bEpisode)?.finished == false)
    #expect(try await a.state(aEpisode)?.position == 1_800)
    #expect(try await a.state(aEpisode)?.finished == false)

    _ = try await bStore.recordTick(
      episodeId: bEpisode, position: 1_810, finished: false, capturedSequence: bSequence + 1, now: b.now)
    try await Self.settle([a, b])
    try await Self.expectQuiet([a, b], server: server)
  }

  /// A mixed fleet. B protects its unsent listening; C is modelled as an older build by never
  /// reporting anything playing, so its own listening at the moment of the reset is unprotected
  /// and it adopts whatever wins, which is B's re-stamped value once it reaches C.
  @Test func aMixedFleetConvergesOnTheNewRuleDevicesValue() async throws {
    let server = FakePodcastCloudServer()
    let activePlayback = MutableActiveEpisodeSet()
    let a = try await Device.make(key: key, server: server)
    let b = try await Device.make(
      key: key, server: server, activeEpisodeRowIDs: { activePlayback.read() })
    let c = try await Device.make(key: key, server: server)
    try await a.subscribe()
    let aEpisode = try await a.addEpisode()
    try await Self.settle([a, b, c])
    let bEpisode = try await b.addEpisode()
    let cEpisode = try await c.addEpisode()
    try await Self.settle([a, b, c])

    let aStore = RSSEpisodeStateStore(database: a.database)
    _ = try await aStore.recordTick(
      episodeId: aEpisode, position: 1_200, finished: false, capturedSequence: 0, now: a.now)
    try await Self.settle([a, b, c])
    #expect(try await b.state(bEpisode)?.position == 1_200)
    #expect(try await c.state(cEpisode)?.position == 1_200)

    // Both B and C are playing the episode, with nothing dirty; only B reports it. C's
    // coordinator has no active-episode provider, as on an older build.
    activePlayback.set([bEpisode])

    _ = try await aStore.resetProgress(episodeId: aEpisode, now: a.now)
    try await Self.settle([a, b, c])

    #expect(try await b.state(bEpisode)?.position == 1_200, "the new-rule device kept its listening")
    #expect(try await a.state(aEpisode)?.position == 1_200, "the fleet converges on B's value")
    #expect(try await c.state(cEpisode)?.position == 1_200, "C adopts B's value like any newer one")
    try await Self.expectQuiet([a, b, c], server: server)
  }
}
