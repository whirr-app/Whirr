import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Which branch of `persistTick` handled a tick, and when none could, why. A failed
/// `recordLocalTick` must be distinguishable from a written one, and a row-lookup miss must leave a
/// record. These pin the durable fall-through and the record naming what happened.
///
/// Store failures are injected (`setTickWriter`), as a fixture cannot stage a SQLite write that
/// throws mid-listen (disk full, corruption).
@Suite struct PlaybackTickOutcomeTests {

  // MARK: - The ordinary routes

  @Test func anOrdinaryLocalTickReportsTheRouteThatTookIt() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-local")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-local", episodeID: nil)
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: "item-local", episodeID: nil, currentTime: 42, listenedDelta: 5, isFinished: false,
      isSeek: false)

    #expect(records.value.map(\.outcome) == [.persisted(.local)])
    #expect(records.value.first?.failedRoutes.isEmpty == true)
  }

  @Test func anOrdinaryOnlineTickReportsTheRouteThatTookIt() async throws {
    let h = try await OfflinePlaybackHarness()
    _ = try await h.makeItem(serverItemId: "item-online")
    h.enqueuePlayResponse(itemID: "item-online")
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-online", episodeID: nil)
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: "item-online", episodeID: nil, currentTime: 42, listenedDelta: 5, isFinished: false,
      isSeek: false)

    #expect(records.value.map(\.outcome) == [.persisted(.online)])
  }

  // MARK: - A failed write falls through instead of claiming the tick

  /// A throwing `recordLocalTick` must not count as handled, or the sessionless net never runs and
  /// the position silently stops advancing.
  @Test func aFailedLocalWriteFallsThroughToTheSessionlessNet() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-local-fault")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-local-fault", episodeID: nil)
    let records = await collectTickRecords(from: coordinator)
    await coordinator.setTickWriter(FaultingTickWriter(base: h.sessionStore, faults: [.local]))

    await coordinator.recordProgressTick(
      itemID: "item-local-fault", episodeID: nil, currentTime: 300, listenedDelta: 10,
      isFinished: false, isSeek: false)

    let progress = try #require(
      try MediaProgressDAO(database: h.database).fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: itemRowId)))
    #expect(progress.currentTime == 300, "a failed local write must not swallow the position")
    #expect(records.value.map(\.outcome) == [.persisted(.sessionless)])
    #expect(records.value.first?.failedRoutes == [.local])
  }

  /// The same on the streaming side: a throwing `recordNextTick` must fall through.
  @Test func aFailedOnlineWriteFallsThroughToTheSessionlessNet() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "item-online-fault")
    h.enqueuePlayResponse(itemID: "item-online-fault")
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-online-fault", episodeID: nil)
    let records = await collectTickRecords(from: coordinator)
    await coordinator.setTickWriter(FaultingTickWriter(base: h.sessionStore, faults: [.online]))

    await coordinator.recordProgressTick(
      itemID: "item-online-fault", episodeID: nil, currentTime: 300, listenedDelta: 10,
      isFinished: false, isSeek: false)

    let progress = try #require(
      try MediaProgressDAO(database: h.database).fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: itemRowId)))
    #expect(progress.currentTime == 300)
    #expect(records.value.map(\.outcome) == [.persisted(.sessionless)])
    #expect(records.value.first?.failedRoutes == [.online])
  }

  /// When the net cannot write either, the tick is lost and the record must say so.
  @Test func aTickEveryBranchFailedToWriteIsReportedAsDropped() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-all-fault")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-all-fault", episodeID: nil)
    let records = await collectTickRecords(from: coordinator)
    await coordinator.setTickWriter(
      FaultingTickWriter(base: h.sessionStore, faults: [.local, .sessionless]))

    await coordinator.recordProgressTick(
      itemID: "item-all-fault", episodeID: nil, currentTime: 300, listenedDelta: 10,
      isFinished: false, isSeek: false)

    #expect(records.value.map(\.outcome) == [.dropped(.everyWriteFailed)])
    #expect(records.value.first?.failedRoutes == [.local, .sessionless])
  }

  // MARK: - Drops name their reason

  @Test func aTickForAnItemWithNoRowNamesTheLookupThatMissed() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-rows")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-rows", episodeID: nil)
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: "item-never-synced", episodeID: nil, currentTime: 300, listenedDelta: 10,
      isFinished: false, isSeek: false)

    #expect(records.value.map(\.outcome) == [.dropped(.noItemRow)])
  }

  @Test func aTickForAnEpisodeWithNoRowIsDistinguishedFromAMissingItem() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-rows-episode", mediaKind: "podcast")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: "item-rows-episode", episodeID: "episode-never-synced", currentTime: 300,
      listenedDelta: 10, isFinished: false, isSeek: false)

    #expect(records.value.map(\.outcome) == [.dropped(.noEpisodeRow)])
  }

  /// A straggler for an item this device is no longer playing is dropped on purpose. `not-playing`
  /// tells the reader the net declined the tick rather than the store refusing it.
  @Test func aStragglerAfterAStopIsReportedAsNotPlaying() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-straggler")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-straggler", episodeID: nil)
    try await coordinator.stopSession()
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: "item-straggler", episodeID: nil, currentTime: 999, listenedDelta: 10,
      isFinished: false, isSeek: false)

    #expect(records.value.map(\.outcome) == [.dropped(.notPlayingThisItem)])
    let progress = try MediaProgressDAO(database: h.database).fetchCurrent(
      accountId: h.accountId, identity: .item(itemId: itemRowId))
    #expect(progress?.currentTime != 999, "a straggler must still be ignored, only visibly so")
  }

  /// A stop can run while the audio carries on. `performStop` clears `activePlaybackItem` and
  /// `displacedPlaybackItem`, so every `persistTick` branch would decline each tick. Stragglers and
  /// live audio are told apart by arrival: a straggler stops arriving, live audio does not.
  @Test func sustainedTicksAfterAStopAreTreatedAsLiveAudioNotStragglers() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-live-after-stop")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 3600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-live-after-stop", episodeID: nil)
    try await coordinator.stopSession()
    let records = await collectTickRecords(from: coordinator)

    // The straggler PlayerCore emitted as the stop landed is still dropped.
    await coordinator.recordProgressTick(
      itemID: "item-live-after-stop", episodeID: nil, currentTime: 20, listenedDelta: 5,
      isFinished: false, isSeek: false)

    // The audio never actually stopped, so ticks keep arriving long after any straggler would.
    h.clock.advance(by: 120)
    await coordinator.recordProgressTick(
      itemID: "item-live-after-stop", episodeID: nil, currentTime: 1714, listenedDelta: 15,
      isFinished: false, isSeek: false)

    #expect(
      records.value.map(\.outcome) == [.dropped(.notPlayingThisItem), .persisted(.sessionless)])
    let progress = try #require(
      try MediaProgressDAO(database: h.database).fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: itemRowId)))
    #expect(progress.currentTime == 1714, "live audio after a spurious stop must still persist")
  }

  /// Logout's retirement must never re-arm. `quiesceForLogout` goes through `performStop` like any
  /// stop, but ticks that outlive it belong to an account mid-removal, and writing progress there
  /// crosses the logout boundary however live the audio is.
  @Test func sustainedTicksAfterLogoutQuiesceStayDropped() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-live-after-logout")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 3600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-live-after-logout", episodeID: nil)
    await coordinator.quiesceForLogout()
    let records = await collectTickRecords(from: coordinator)

    h.clock.advance(by: 120)
    await coordinator.recordProgressTick(
      itemID: "item-live-after-logout", episodeID: nil, currentTime: 1714, listenedDelta: 15,
      isFinished: false, isSeek: false)

    #expect(records.value.map(\.outcome) == [.dropped(.notPlayingThisItem)])
    let progress = try MediaProgressDAO(database: h.database).fetchCurrent(
      accountId: h.accountId, identity: .item(itemId: itemRowId))
    #expect(progress?.currentTime != 1714, "a tick after logout quiesce must never write progress")
  }

  /// `PlaybackHardware` and its PlayerCore/AVPlayer state outlive an account-scoped coordinator.
  /// If that stack is replaced while audio survives, the new coordinator has no active, displaced
  /// or retired identity and no session row, while the replacement PlaybackModel forwards the
  /// shared player's live ticks. That is a birth state, not a stop, so the retired-item net above
  /// cannot arm it.
  @Test func sustainedLiveTicksArmANewCoordinatorThatHasNeverStartedTheItem() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemID = "podcast-unarmed"
    let episodeID = "episode-unarmed"
    let itemRowId = try await h.makeItem(serverItemId: itemID, mediaKind: "podcast")
    let episodeRowId = try await h.makePodcastEpisode(itemRowId: itemRowId, episodeID: episodeID)
    try h.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 3600,
      podcastEpisodeId: episodeRowId)
    let coordinator = try h.makeCoordinator()
    let records = await collectTickRecords(from: coordinator)

    // A lone event may still be a stale delivery from the displaced owner and remains dropped.
    await coordinator.recordProgressTick(
      itemID: itemID, episodeID: episodeID, currentTime: 20, listenedDelta: 5,
      isFinished: false, isSeek: false)

    // PlayerCore is live well beyond the straggler window, but no performStart armed this
    // coordinator and no local or online session exists for any ordinary route.
    h.clock.advance(by: 120)
    await coordinator.recordProgressTick(
      itemID: itemID, episodeID: episodeID, currentTime: 1714, listenedDelta: 15,
      isFinished: false, isSeek: false)

    #expect(
      records.value.map(\.outcome) == [.dropped(.notPlayingThisItem), .persisted(.sessionless)])
    let progress = try #require(
      try MediaProgressDAO(database: h.database).fetchCurrent(
        accountId: h.accountId,
        identity: .episode(itemId: itemRowId, podcastEpisodeId: episodeRowId)))
    #expect(progress.currentTime == 1714, "sustained live ticks must arm the replacement coordinator")
  }

  @Test func aStragglerAfterStopSessionDropsAndWritesNoProgressRow() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemID = "item-stopped-no-write"
    let itemRowId = try await h.makeItem(serverItemId: itemID)
    h.enqueuePlayResponse(itemID: itemID, id: "server-session-stopped")
    h.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: itemID, episodeID: nil)
    try await coordinator.stopSession()
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: itemID, episodeID: nil, currentTime: 999, listenedDelta: 10, isFinished: false,
      isSeek: false)

    #expect(records.value.map(\.outcome) == [.dropped(.notPlayingThisItem)])
    #expect(
      try h.fetchProgress(itemRowId: itemRowId) == nil,
      "a stopped straggler must not create a MediaProgress row")
    let progressRows = try h.database.read { db in
      try OutboxOperationRecord
        .filter(Column("accountId") == h.accountId)
        .filter(Column("entityKey") == itemID)
        .filter(Column("operationKind") == OutboxOperationKind.progress.rawValue)
        .fetchAll(db)
    }
    #expect(progressRows.isEmpty, "a stopped straggler must not enqueue a progress patch")
  }

  @Test func aTickForTheMostRecentlyDisplacedItemPersistsPositionAndQueuesAProgressPatch() async throws {
    let h = try await OfflinePlaybackHarness()
    let firstItemID = "item-switch-first"
    let secondItemID = "item-switch-second"
    let firstItemRowId = try await h.makeItem(serverItemId: firstItemID)
    _ = try await h.makeItem(serverItemId: secondItemID)
    h.enqueuePlayResponse(itemID: firstItemID, id: "server-session-first")
    h.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /sync
    h.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close
    h.enqueuePlayResponse(itemID: secondItemID, id: "server-session-second")
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: firstItemID, episodeID: nil)
    await coordinator.recordProgressTick(
      itemID: firstItemID, episodeID: nil, currentTime: 3652.9, listenedDelta: 10,
      isFinished: false, isSeek: false)
    let records = await collectTickRecords(from: coordinator)

    _ = try await coordinator.startSession(itemID: secondItemID, episodeID: nil)
    await coordinator.recordProgressTick(
      itemID: firstItemID, episodeID: nil, currentTime: 3700, listenedDelta: 10, isFinished: false,
      isSeek: false)

    let progress = try #require(try h.fetchProgress(itemRowId: firstItemRowId))
    #expect(
      progress.currentTime == 3700,
      "the outgoing item's final straggler position must survive the switch")
    let progressRows = try h.database.read { db in
      try OutboxOperationRecord
        .filter(Column("accountId") == h.accountId)
        .filter(Column("entityKey") == firstItemID)
        .filter(Column("operationKind") == OutboxOperationKind.progress.rawValue)
        .fetchAll(db)
    }
    #expect(
      progressRows.contains { $0.payloadCurrentTime == 3700 },
      "the displaced straggler must enqueue an outbox progress patch")
    #expect(
      records.value.map { PlaybackTickTrace.line($0) }
        == [
          "WHIRRSYNC tick outcome=persisted route=displaced failed=none item=\(firstItemID) episode=none position=3700.0"
        ],
      "the switch straggler must use the displaced trace route")
    #expect(records.value.map(\.outcome) == [.persisted(.displaced)])
  }

  @Test func aStragglerFromTwoStartsAgoIsStillDroppedAfterASecondSwitch() async throws {
    let h = try await OfflinePlaybackHarness()
    let firstItemID = "item-switch-oldest"
    let secondItemID = "item-switch-middle"
    let thirdItemID = "item-switch-newest"
    let firstItemRowId = try await h.makeItem(serverItemId: firstItemID)
    _ = try await h.makeItem(serverItemId: secondItemID)
    _ = try await h.makeItem(serverItemId: thirdItemID)
    h.enqueuePlayResponse(itemID: firstItemID, id: "server-session-first")
    h.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    h.enqueuePlayResponse(itemID: secondItemID, id: "server-session-second")
    h.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    h.enqueuePlayResponse(itemID: thirdItemID, id: "server-session-third")
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: firstItemID, episodeID: nil)
    _ = try await coordinator.startSession(itemID: secondItemID, episodeID: nil)
    _ = try await coordinator.startSession(itemID: thirdItemID, episodeID: nil)
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: firstItemID, episodeID: nil, currentTime: 999, listenedDelta: 10, isFinished: false,
      isSeek: false)

    #expect(records.value.map(\.outcome) == [.dropped(.notPlayingThisItem)])
    #expect(try h.fetchProgress(itemRowId: firstItemRowId) == nil)
  }

  @Test func restartingTheAlreadyActiveItemDoesNotCreateADisplacedRouteForItsOrdinaryTick() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemID = "item-same-restart"
    _ = try await h.makeItem(serverItemId: itemID)
    h.enqueuePlayResponse(itemID: itemID)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: itemID, episodeID: nil)
    _ = try await coordinator.startSession(itemID: itemID, episodeID: nil)
    let records = await collectTickRecords(from: coordinator)

    await coordinator.recordProgressTick(
      itemID: itemID, episodeID: nil, currentTime: 42, listenedDelta: 5, isFinished: false,
      isSeek: false)

    #expect(records.value.map(\.outcome) == [.persisted(.online)])
    #expect(h.http.requests.count == 1, "an idempotent restart must not create another session")
  }

  // MARK: - Helpers

  private func collectTickRecords(
    from coordinator: PlaybackSessionCoordinator
  ) async -> TickRecordBox {
    let records = TickRecordBox([])
    await coordinator.setTickRecordSink { record in
      records.withValue { $0.append(record) }
    }
    return records
  }
}

/// Small lock-protected box (`TestSupport.Locked` is not `public`).
private final class TickRecordBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [PlaybackTickTrace.Record]

  init(_ value: [PlaybackTickTrace.Record]) { storage = value }

  var value: [PlaybackTickTrace.Record] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func withValue(_ body: (inout [PlaybackTickTrace.Record]) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&storage)
  }
}

/// Delegates every tick write to the real store except the ones it is told to fail, since the
/// store itself cannot be made to throw from a fixture.
private struct FaultingTickWriter: PlaybackTickWriting {
  enum Fault: Hashable, Sendable {
    /// Both online routes (`recordNextTick`): the cached target and the freshly-resolved one.
    case online
    case local
    case sessionless
  }

  struct InjectedFault: Error {}

  let base: PlaybackSessionStore
  let faults: Set<Fault>

  func recordNextTick(sessionId: Int64, tick: PlaybackTick) throws -> PlaybackSessionRecord {
    guard faults.contains(.online) == false else { throw InjectedFault() }
    return try base.recordNextTick(sessionId: sessionId, tick: tick)
  }

  func recordLocalTick(sessionId: Int64, tick: PlaybackTick) throws -> PlaybackSessionRecord {
    guard faults.contains(.local) == false else { throw InjectedFault() }
    return try base.recordLocalTick(sessionId: sessionId, tick: tick)
  }

  func recordSessionlessTick(
    accountId: Int64, itemId: Int64, podcastEpisodeId: Int64?, serverItemId: String, tick: PlaybackTick
  ) throws -> MediaProgressRecord {
    guard faults.contains(.sessionless) == false else { throw InjectedFault() }
    return try base.recordSessionlessTick(
      accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
      serverItemId: serverItemId, tick: tick)
  }
}
