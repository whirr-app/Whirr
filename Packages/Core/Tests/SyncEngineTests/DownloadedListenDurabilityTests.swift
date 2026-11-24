import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The reported journey: a downloaded audiobook listened to for a long stretch, the app swiped
/// away (no stop, no close), and reopened. The position came back where the listen began.
///
/// A downloaded item plays as a local session, so every minute lands through `recordLocalTick`
/// alone: no `/play`, no `/sync`, nothing on the network. This suite pins the three places that
/// stretch can be lost. The ticks may never reach `MediaProgress`. A relaunch pull may overwrite
/// them with the server's older value (nothing uploaded, the listen having been on patchy signal).
/// And a session-gone recovery for an unrelated item may close the live session of the book being
/// listened to, which is the one that actually failed.
@Suite("A downloaded listen survives a swipe-away")
struct DownloadedListenDurabilityTests {

  private static let itemID = "item-downloaded-listen"
  /// Where the listen began ("chapter 18" in the report).
  private static let startPosition: Double = 3600
  /// Roughly 40 minutes further on ("chapter 21").
  private static let expectedEndPosition: Double = 3600 + 2400

  @Test("forty minutes of local ticks reach MediaProgress, not just the session row")
  func localTicksReachMediaProgress() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 20_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: Self.startPosition)
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    #expect(prepared.startPosition == Self.startPosition, "resumes where the listen left off")

    try await Self.listen(coordinator: coordinator, clock: h.clock, seconds: 2400)

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(
      progress.currentTime >= Self.expectedEndPosition - Self.persistInterval,
      "every persisted tick must land on the progress row, which is what a relaunch reads")
    let session = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(session.globalPosition >= Self.expectedEndPosition - Self.persistInterval)
  }

  /// A dead online session for some other item (an earlier stream whose `/sync` or `/close`
  /// finally 404s on patchy signal) asks the coordinator to open a replacement session for that
  /// item (`OutboxDrainer` -> `notifySessionGoneRecovery`, wired in `AppEnvironment`). The recovery
  /// is gated only on "somebody is still listening", and `performStart`'s close-before-play step
  /// is scoped to the account, not the item. So it closes the live local session of the downloaded
  /// book actually playing, and repoints `activePlaybackItem` at an item nobody is listening to.
  ///
  /// The audio never stops (PlayerCore is not involved), so it looks normal to the listener. No
  /// session of either kind is then active for the book, the sessionless net rejects its ticks as
  /// belonging to a displaced item, and the rest of the listen is discarded with no write, retry
  /// or trace.
  @Test("a session-gone recovery for another item never silences the book actually playing")
  func sessionGoneRecoveryForAnotherItemNeverSilencesTheLivePlayback() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 20_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: Self.startPosition)
    // The item the dead session belonged to: streamed earlier, not downloaded, not playing now.
    _ = try await h.makeItem(serverItemId: "item-streamed-earlier")

    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    await coordinator.notifyPlaybackPhase(.playing)
    try await Self.listen(coordinator: coordinator, clock: h.clock, seconds: 600)

    await coordinator.recoverFromSessionGone(itemID: "item-streamed-earlier", episodeID: nil)

    // The listener kept listening straight through it.
    try await Self.listen(
      coordinator: coordinator, clock: h.clock, seconds: 1800, from: Self.startPosition + 600)

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(
      try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)).itemId
        == itemRowId,
      "the live local session survives a recovery aimed at a different item")
    #expect(
      progress.currentTime >= Self.expectedEndPosition - Self.persistInterval,
      "the whole listen survives, not just the part before the recovery fired")
  }

  @Test("the listen survives the process ending with no stop, close, or upload")
  func listenSurvivesSwipeAway() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 20_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: Self.startPosition)

    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    try await Self.listen(coordinator: coordinator, clock: h.clock, seconds: 2400)

    // Swiped away: nothing calls `stopSession`, nothing closes the session, the coordinator and
    // every in-memory throttle cease to exist. Only what is already durable survives.
    let relaunched = try h.makeFreshCoordinatorForRelaunch()
    await relaunched.recoverOpenSessions()
    let resumed = try await relaunched.startSession(itemID: Self.itemID, episodeID: nil)

    #expect(
      resumed.startPosition >= Self.expectedEndPosition - Self.persistInterval,
      "reopening must resume where the listening actually reached")
  }

  @Test("a relaunch pull carrying the server's older position never rewinds the listen")
  func relaunchPullNeverRewindsTheListen() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 20_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: Self.startPosition)

    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    try await Self.listen(coordinator: coordinator, clock: h.clock, seconds: 2400)

    // Patchy signal throughout: not one of the mirrored progress rows ever reached the server, so
    // the first pull after relaunch still describes the position the listen started from,
    // carrying a `lastUpdate` newer than anything the local row has ever seen.
    let engine = try Self.makeEngine(h)
    h.enqueuePullCycle(
      itemID: Self.itemID, serverCurrentTime: Self.startPosition,
      serverLastUpdateEpochMillis: 2_000_000_000_000)

    await engine.refresh()

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(
      progress.currentTime >= Self.expectedEndPosition - Self.persistInterval,
      "a local session's unuploaded listening outranks the server row it never got to update")
  }

  // MARK: - Helpers

  /// Drives `seconds` of listening as PlayerCore would: one tick every five seconds of wall clock,
  /// each advancing the position by the same amount. Long enough to cross many
  /// `progressPersistInterval` boundaries, so the throttle's own coalescing is exercised rather
  /// than bypassed.
  private static func listen(
    coordinator: PlaybackSessionCoordinator, clock: FakeSyncClock, seconds: Double,
    from origin: Double = startPosition
  ) async throws {
    let step: Double = 5
    var elapsed: Double = 0
    while elapsed < seconds {
      elapsed += step
      clock.advance(by: step)
      await coordinator.recordProgressTick(
        itemID: itemID, episodeID: nil, currentTime: origin + elapsed,
        listenedDelta: step, isFinished: false, isSeek: false)
    }
  }

  /// One durable write lands per interval, so the final partial interval is legitimately still in
  /// memory when the process ends. That tail is the throttle working, not progress being lost.
  private static let persistInterval = PlaybackSessionCoordinator.progressPersistInterval

  private static func makeEngine(_ h: OfflinePlaybackHarness) throws -> SyncEngine {
    let client = ABSClient(server: h.server, httpClient: h.http, tokenStore: try h.makeTokenStore())
    return SyncEngine.make(
      client: client, database: h.database, diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(), clock: h.clock, randomSource: { 1 }, pageLimit: 100)
  }
}
