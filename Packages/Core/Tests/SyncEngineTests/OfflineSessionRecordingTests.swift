import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Local (offline) session recording. A complete local item's ticks atomically update
/// `MediaProgress` and the session's position/delta with zero session outbox rows (only the
/// eventual `local-all` batch reports local listening). Close freezes the final delta and
/// enqueues one `localSessionUpload` row. Relaunch mid-session continues the same session. A
/// foreground pull never moves a live local position backward. Switching to or from a streaming
/// item runs close-before-play ordering on the active side. A local session never sends `/play`,
/// `/sync` or `/close`.
@Suite struct OfflineSessionRecordingTests {

  // MARK: - Fresh client UUID, isOffline, wall-clock timestamps

  @Test func anOfflineSessionRowGetsAFreshClientUUIDIsOfflineAndWallClockTimestamps() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-fresh")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 100)
    let coordinator = try h.makeCoordinator()

    _ = try await coordinator.startSession(itemID: "item-fresh", episodeID: nil)

    let active = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(active.isOffline == true)
    #expect(active.clientSessionId.isEmpty == false)
    #expect(active.startedAt == h.clock.now())
    #expect(active.updatedAt == h.clock.now())
    #expect(h.http.requests.isEmpty)
  }

  @Test func aFreshLocalSessionFreezesThePositionItResumedFrom() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-resume")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 20_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: 19_520.5)
    let coordinator = try h.makeCoordinator()

    _ = try await coordinator.startSession(itemID: "item-resume", episodeID: nil)

    let active = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    // The only record of where this session began: nothing server-side derives a start for a
    // local session, so its `local-all` upload and the History tab depend on it.
    #expect(active.startPosition == 19_520.5)

    // Ticking forward never moves it.
    let sessionId = try #require(active.id)
    _ = try h.sessionStore.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 19_600, isFinished: false, deltaSecondsSinceLastTick: 80, localSequence: 2,
        originKey: "device-uuid", segmentKey: "seg-0", now: h.clock.now()))
    let ticked = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(ticked.startPosition == 19_520.5)
    #expect(ticked.globalPosition == 19_600)
  }

  @Test func eachFreshLocalSessionGetsItsOwnDistinctClientUUID() async throws {
    let h = try await OfflinePlaybackHarness()
    let firstItem = try await h.makeItem(serverItemId: "item-a")
    try h.completeDownload(itemRowId: firstItem, orderIndex: 0, fileDurationSeconds: 30)
    let secondItem = try await h.makeItem(serverItemId: "item-b")
    try h.completeDownload(itemRowId: secondItem, orderIndex: 0, fileDurationSeconds: 30)
    let coordinator = try h.makeCoordinator()

    _ = try await coordinator.startSession(itemID: "item-a", episodeID: nil)
    let firstSession = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    _ = try await coordinator.startSession(itemID: "item-b", episodeID: nil)
    let secondSession = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))

    #expect(firstSession.clientSessionId != secondSession.clientSessionId)
    #expect(firstSession.itemId != secondSession.itemId)
  }

  // MARK: - Ticks: MediaProgress + session update atomically, zero outbox rows

  @Test func localTicksAtomicallyUpdateMediaProgressAndSessionWithZeroOutboxRows() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-tick")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-tick", episodeID: nil)
    let sessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    await coordinator.recordProgressTick(
      itemID: "item-tick", episodeID: nil, currentTime: 42, listenedDelta: 5, isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 42)
    #expect(session.listenedDeltaSeconds == 5)
    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 42)
    #expect(try h.sessionSyncOrCloseRows(sessionId: sessionId).isEmpty, "no sessionSync/sessionClose rows ever")
    #expect(try h.localSessionUploadRows(sessionId: sessionId).isEmpty, "no upload row until close")
    #expect(h.http.requests.isEmpty)
  }

  // MARK: - Seek/finish boundaries still track correctly

  @Test func seekAndFinishBoundariesStillUpdatePositionAndDeltaCorrectlyAcrossTicks() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "item-seek")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-seek", episodeID: nil)
    let sessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    await coordinator.recordProgressTick(
      itemID: "item-seek", episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    await coordinator.recordProgressTick(
      itemID: "item-seek", episodeID: nil, currentTime: 500, listenedDelta: 0, isFinished: false, isSeek: true)
    h.clock.advance(by: PlaybackSessionCoordinator.progressPersistInterval)
    await coordinator.recordProgressTick(
      itemID: "item-seek", episodeID: nil, currentTime: 510, listenedDelta: 5, isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 510)
    #expect(session.listenedDeltaSeconds == 10, "delta accumulates correctly across the seek boundary")
    #expect(try h.sessionSyncOrCloseRows(sessionId: sessionId).isEmpty)
  }

  // MARK: - Close freezes the final delta and enqueues exactly one localSessionUpload row

  @Test func closeFreezesTheFinalDeltaAndEnqueuesExactlyOneLocalSessionUploadRowTransactionally() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-close")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-close", episodeID: nil)
    let sessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)
    await coordinator.recordProgressTick(
      itemID: "item-close", episodeID: nil, currentTime: 42, listenedDelta: 5, isFinished: false, isSeek: false)

    try await coordinator.stopSession()

    let closed = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(closed.state == .closedAwaitingUpload)
    #expect(closed.globalPosition == 42)
    let uploadRows = try h.localSessionUploadRows(sessionId: sessionId)
    #expect(uploadRows.count == 1)
    #expect(uploadRows.first?.payloadCurrentTime == 42)
    #expect(uploadRows.first?.payloadAccumulatedDeltaSeconds == 5)
    #expect(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil, "slot freed for a fresh session")
    #expect(h.http.requests.isEmpty, "closing a local session never touches the network")
  }

  @Test func sleepTimerExpiryClosesTheLocalSessionOnTheSerializedTickChain() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-sleep-close")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-sleep-close", episodeID: nil)
    let firstSessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    await coordinator.recordProgressTick(
      itemID: "item-sleep-close", episodeID: nil, currentTime: 42, listenedDelta: 5,
      isFinished: false, isSeek: false, sleepTimerExpired: true)

    let closed = try #require(try h.sessionStore.fetchSession(id: firstSessionId))
    #expect(closed.state == .closedAwaitingUpload)
    #expect(closed.globalPosition == 42)
    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
    #expect(try h.localSessionUploadRows(sessionId: firstSessionId).count == 1)
    #expect(h.http.requests.isEmpty)

    // A tick delivered after the close is a straggler, not evidence for a replacement session.
    await coordinator.recordProgressTick(
      itemID: "item-sleep-close", episodeID: nil, currentTime: 43, listenedDelta: 1,
      isFinished: false, isSeek: false)
    let afterStraggler = try #require(try h.sessionStore.fetchSession(id: firstSessionId))
    #expect(afterStraggler.globalPosition == 42)
    #expect(try h.localSessionUploadRows(sessionId: firstSessionId).count == 1)

    // The next play is admitted only after the close completes, and opens a fresh row.
    _ = try await coordinator.startSession(itemID: "item-sleep-close", episodeID: nil)
    let secondSessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)
    #expect(secondSessionId != firstSessionId)
  }

  @Test func aFinishedSleepTimerTickLeavesClosureToTheNormalCompletionPath() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-sleep-end")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-sleep-end", episodeID: nil)
    let sessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    await coordinator.recordProgressTick(
      itemID: "item-sleep-end", episodeID: nil, currentTime: 600, listenedDelta: 5,
      isFinished: true, isSeek: false, sleepTimerExpired: true)

    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id == sessionId)
    #expect(try h.localSessionUploadRows(sessionId: sessionId).isEmpty)

    try await coordinator.stopSession()
    #expect(try h.localSessionUploadRows(sessionId: sessionId).count == 1)
    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
  }

  // MARK: - Local file URLs carry no stream authorization

  @Test func aLocalPreparationCarriesNoStreamAuthorization() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-local-only")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 120)
    let coordinator = try h.makeCoordinator()

    let prepared = try await coordinator.startSession(itemID: "item-local-only", episodeID: nil)

    #expect(prepared.source == .local)
    #expect(
      prepared.streamAuthorization == nil,
      "an app-container file URL is fetched by AVFoundation itself - stamping a Bearer header on it would ship a token nowhere it is needed"
    )
  }

  // MARK: - Relaunch mid-session recovers and continues the same session

  @Test func relaunchMidSessionRecoversAndContinuesTheSameSession() async throws {
    let h = try await OfflinePlaybackHarness(httpFailure: FakeHTTPClientError(message: "unreachable"))
    let itemRowId = try await h.makeItem(serverItemId: "item-relaunch")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let firstCoordinator = try h.makeCoordinator()
    _ = try await firstCoordinator.startSession(itemID: "item-relaunch", episodeID: nil)
    let originalSessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)
    await firstCoordinator.recordProgressTick(
      itemID: "item-relaunch", episodeID: nil, currentTime: 88, listenedDelta: 10, isFinished: false, isSeek: false)

    // Simulate a crash/relaunch: a brand-new coordinator instance, no in-memory cache carried over.
    let freshCoordinator = try h.makeFreshCoordinatorForRelaunch()
    let resumed = try await freshCoordinator.startSession(itemID: "item-relaunch", episodeID: nil)

    #expect(resumed.source == .local)
    #expect(resumed.startPosition == 88, "resumes from the last ticked position, not from scratch")
    let stillActive = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(stillActive.id == originalSessionId, "the same session row - never a second one")

    await freshCoordinator.recordProgressTick(
      itemID: "item-relaunch", episodeID: nil, currentTime: 100, listenedDelta: 5, isFinished: false, isSeek: false)
    let after = try #require(try h.sessionStore.fetchSession(id: originalSessionId))
    #expect(after.globalPosition == 100)
    #expect(after.listenedDeltaSeconds == 15, "continues accumulating on the very same session")
    #expect(h.http.requests.isEmpty)
  }

  // MARK: - A foreground pull cannot move a live local position backward

  @Test func aForegroundLibraryPullDuringLocalPlaybackCannotMovePositionBackward() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: "item-pull")
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: "item-pull", episodeID: nil)
    await coordinator.recordProgressTick(
      itemID: "item-pull", episodeID: nil, currentTime: 500, listenedDelta: 50, isFinished: false, isSeek: false)

    let engine = SyncEngine.make(
      client: ABSClient(server: h.server, httpClient: h.http, tokenStore: try h.makeTokenStore()),
      database: h.database, diagnostics: FakeDiagnosticsRecording(), appLifecycle: FakeAppLifecycle(),
      playback: coordinator, clock: h.clock, randomSource: { 1 }, pageLimit: 100)

    h.enqueuePullCycle(itemID: "item-pull", serverCurrentTime: 8, serverLastUpdateEpochMillis: 1_000_000_000_000)
    await engine.refresh()

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 500, "the actively-playing local position must never move backward")
  }

  // MARK: - Close-before-play ordering across a local/streaming switch

  @Test func switchingFromALocalItemToAStreamingItemClosesTheLocalSessionBeforePlayingTheNewOne() async throws {
    let h = try await OfflinePlaybackHarness()
    let localItemRowId = try await h.makeItem(serverItemId: "item-local-side")
    try h.completeDownload(itemRowId: localItemRowId, orderIndex: 0, fileDurationSeconds: 600)
    _ = try await h.makeItem(serverItemId: "item-streaming-side")
    h.enqueuePlayResponse(itemID: "item-streaming-side")
    let coordinator = try h.makeCoordinator()

    _ = try await coordinator.startSession(itemID: "item-local-side", episodeID: nil)
    let localSessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    let streamed = try await coordinator.startSession(itemID: "item-streaming-side", episodeID: nil)

    #expect(streamed.source == .streaming)
    #expect(h.http.requests.count == 1, "only the new item's /play - never any traffic for the local side")
    #expect(h.http.requests[0].url.path == "/api/items/item-streaming-side/play")
    let closedLocal = try #require(try h.sessionStore.fetchSession(id: localSessionId))
    #expect(closedLocal.state == .closedAwaitingUpload)
    #expect(try h.localSessionUploadRows(sessionId: localSessionId).count == 1)
    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
  }

  @Test func switchingFromAStreamingItemToALocalItemClosesTheOnlineSessionBeforeStartingTheLocalOne() async throws {
    let h = try await OfflinePlaybackHarness()
    _ = try await h.makeItem(serverItemId: "item-streaming-first")
    h.enqueuePlayResponse(itemID: "item-streaming-first", id: "server-session-first")
    h.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // /close for the online session
    let localItemRowId = try await h.makeItem(serverItemId: "item-local-second")
    try h.completeDownload(itemRowId: localItemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator()

    _ = try await coordinator.startSession(itemID: "item-streaming-first", episodeID: nil)
    let prepared = try await coordinator.startSession(itemID: "item-local-second", episodeID: nil)

    #expect(prepared.source == .local)
    #expect(h.http.requests.count == 2)
    #expect(h.http.requests[0].url.path == "/api/items/item-streaming-first/play")
    #expect(h.http.requests[1].url.path == "/api/session/server-session-first/close")
    #expect(try h.sessionStore.fetchActiveSession(accountId: h.accountId) == nil, "the online session was closed")
    #expect(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) != nil, "the local session is now active")
  }
}
