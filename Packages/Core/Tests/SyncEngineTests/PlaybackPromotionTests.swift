import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Coordinator-side stream → local promotion. The fixture starts online and only
/// completes the download afterwards, which is the transition this operation exists to cover.
@Suite struct PlaybackPromotionTests {
  fileprivate static let itemID = "item-promotion"
  fileprivate static let streamedDuration = 3_600.0

  @Test func aFullyDownloadedStreamingItemPromotesToANewLocalSession() async throws {
    let fixture = try await makeStreamingFixture()
    try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)

    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)

    let prepared = try #require(promoted)
    #expect(prepared.source == .local)
    let closedOnline = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))
    #expect(closedOnline.closePending)
    #expect(closedOnline.isOffline == false)

    let local = try #require(
      try fixture.harness.sessionStore.fetchActiveOfflineSession(accountId: fixture.harness.accountId))
    #expect(local.id != fixture.onlineSessionID)
    #expect(local.state == .active)
    #expect(local.isOffline)
  }

  @Test func promotionPreservesThePositionAndListeningDeltaAcrossTheSwap() async throws {
    let fixture = try await makeStreamingFixture()
    let position = 1_234.5
    let listenedDelta = 37.0
    await fixture.coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: position, listenedDelta: listenedDelta,
      isFinished: false, isSeek: false)
    try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)

    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: position, streamedDuration: nil)

    let prepared = try #require(promoted)
    #expect(prepared.source == .local)
    #expect(prepared.startPosition == position)

    let closedOnline = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))
    let local = try #require(
      try fixture.harness.sessionStore.fetchActiveOfflineSession(accountId: fixture.harness.accountId))
    #expect(closedOnline.globalPosition == position)
    #expect(closedOnline.listenedDeltaSeconds == listenedDelta)
    #expect(local.startPosition == position)
    #expect(local.globalPosition == 0)
    #expect(local.listenedDeltaSeconds == 0)
    #expect(closedOnline.listenedDeltaSeconds + local.listenedDeltaSeconds == listenedDelta)

    let progress = try #require(
      try fixture.harness.fetchProgress(itemRowId: fixture.itemRowId))
    #expect(progress.currentTime == position)
  }

  @Test func incompleteDownloadDeclinesWithoutTouchingTheOnlineSession() async throws {
    let fixture = try await makeStreamingFixture()
    try fixture.harness.pendingDownload(itemRowId: fixture.itemRowId, fileDurationSeconds: Self.streamedDuration)

    let before = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))
    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)
    let after = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))

    #expect(promoted == nil)
    #expect(after == before)
  }

  @Test func deletingDownloadDeclinesWithoutTouchingTheOnlineSession() async throws {
    let fixture = try await makeStreamingFixture()
    let downloadID = try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)
    try fixture.harness.markDeleting(downloadId: downloadID)

    let before = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))
    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)
    let after = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))

    #expect(promoted == nil)
    #expect(after == before)
  }

  @Test func anIdentityMismatchDeclinesEvenWhenTheEpisodeNilnessDiffers() async throws {
    let fixture = try await makeStreamingFixture()
    try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)

    let before = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))
    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: "episode-that-is-not-active", currentPosition: 120, streamedDuration: nil)
    let after = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))

    #expect(promoted == nil)
    #expect(after == before)
  }

  @Test func anAlreadyLocalSessionIsNeverPromoted() async throws {
    let harness = try await OfflinePlaybackHarness()
    let itemRowId = try await harness.makeItem(serverItemId: Self.itemID)
    try harness.completeDownload(
      itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)
    let coordinator = try harness.makeCoordinator()
    let original = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    let before = try #require(
      try harness.sessionStore.fetchActiveOfflineSession(accountId: harness.accountId))

    let promoted = await coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)
    let after = try #require(
      try harness.sessionStore.fetchActiveOfflineSession(accountId: harness.accountId))

    #expect(original.source == .local)
    #expect(promoted == nil)
    #expect(after == before)
  }

  @Test func aStreamAndLocalDurationMismatchDeclinesWithoutClosingTheStream() async throws {
    let fixture = try await makeStreamingFixture()
    try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0,
      fileDurationSeconds: Self.streamedDuration + PlaybackSessionCoordinator.promotionDurationTolerance + 0.1)

    let before = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))
    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)
    let after = try #require(
      try fixture.harness.sessionStore.fetchSession(id: fixture.onlineSessionID))

    #expect(promoted == nil)
    #expect(after == before)
  }

  @Test func promotionRestoresPlayingCadenceAfterItsSessionSwap() async throws {
    let fixture = try await makeStreamingFixture()
    try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)
    await fixture.coordinator.notifyPlaybackPhase(.playing)

    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)

    #expect(promoted?.source == .local)
    #expect(await fixture.coordinator.cadencePhase == .playing)
  }

  /// Promotion is legal while paused, and a paused listen must come back paused: restored as
  /// `.playing` it would keep the periodic deadline alive and stop the next backgrounding from
  /// closing the fresh local session (`closesWhenBackgrounded`).
  @Test func promotionWhilePausedRestoresPausedCadenceRatherThanPlaying() async throws {
    let fixture = try await makeStreamingFixture()
    try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)
    await fixture.coordinator.notifyPlaybackPhase(.paused)

    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)

    #expect(promoted?.source == .local)
    #expect(await fixture.coordinator.cadencePhase == .paused)
  }

  @Test func aPhaseNotificationDuringPromotionPreventsStalePlayingRestoration() async throws {
    let fixture = try await makeStreamingFixture()
    try fixture.harness.completeDownload(
      itemRowId: fixture.itemRowId, orderIndex: 0, fileDurationSeconds: Self.streamedDuration)
    await fixture.coordinator.notifyPlaybackPhase(.playing)
    let notificationSent = Locked(false)
    fixture.harness.http.setRequestHook { _ in
      let shouldNotify = notificationSent.withValue { sent in
        guard sent == false else { return false }
        sent = true
        return true
      }
      if shouldNotify {
        await fixture.coordinator.notifyPlaybackPhase(.paused)
      }
    }

    let promoted = await fixture.coordinator.promoteStreamingSessionToLocalDownload(
      itemID: Self.itemID, episodeID: nil, currentPosition: 120, streamedDuration: nil)

    #expect(promoted?.source == .local)
    #expect(notificationSent.value)
    #expect(await fixture.coordinator.cadencePhase != .playing)
  }
}

private struct StreamingPromotionFixture: Sendable {
  let harness: OfflinePlaybackHarness
  let coordinator: PlaybackSessionCoordinator
  let itemRowId: Int64
  let onlineSessionID: Int64
}

private func makeStreamingFixture(
  duration: Double = PlaybackPromotionTests.streamedDuration
) async throws -> StreamingPromotionFixture {
  let harness = try await OfflinePlaybackHarness()
  let itemRowId = try await harness.makeItem(serverItemId: PlaybackPromotionTests.itemID)
  harness.enqueuePlayResponse(itemID: PlaybackPromotionTests.itemID, duration: duration)
  let coordinator = try harness.makeCoordinator()
  let prepared = try await coordinator.startSession(
    itemID: PlaybackPromotionTests.itemID, episodeID: nil)
  #expect(prepared.source == .streaming)
  let onlineSessionID = try #require(
    try harness.sessionStore.fetchActiveSession(accountId: harness.accountId)?.id)
  return StreamingPromotionFixture(
    harness: harness, coordinator: coordinator, itemRowId: itemRowId, onlineSessionID: onlineSessionID)
}
