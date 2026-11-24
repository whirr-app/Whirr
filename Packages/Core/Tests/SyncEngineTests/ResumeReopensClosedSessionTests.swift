import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Pause a downloaded book, lock the phone (`handleAppBackgrounded` closes the local session),
/// then resume from the lock screen. The bare `.play` reaches the engine without reopening a
/// session, so every remaining tick falls to the sessionless net: position stays right, but the
/// listen vanishes from session history and stats. A session reopens when a `.playing` phase
/// notification arrives for a retired item with no active one, the one signal every resume origin
/// shares.
@Suite("Resume reopens a session closed under a loaded player")
struct ResumeReopensClosedSessionTests {

  private static let itemID = "item-bedtime"

  /// Drives the diagnosed close: play, pause, backgrounded. Returns the closed session's id.
  private func closeViaPauseThenBackground(
    _ h: OfflinePlaybackHarness, _ coordinator: PlaybackSessionCoordinator,
    pausePosition: Double
  ) async throws -> Int64 {
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    let original = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    let originalId = try #require(original.id)

    await coordinator.notifyPlaybackPhase(.playing)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: pausePosition, listenedDelta: 6,
      isFinished: false, isSeek: false)
    await coordinator.notifyPlaybackPhase(.paused)
    await coordinator.handleAppBackgrounded()

    #expect(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil,
      "backgrounded-while-paused closes the local session (deliberate, rule 7a)")
    return originalId
  }

  // MARK: - The bedtime reproduction

  @Test func lockScreenResumeAfterABackgroundedPauseCloseReopensAFreshLocalSession() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: 36_560)
    let coordinator = try h.makeCoordinator()
    let originalId = try await closeViaPauseThenBackground(h, coordinator, pausePosition: 36_566)

    // The lock-screen play resumes the engine; the only thing SyncEngine hears is the phase.
    await coordinator.notifyPlaybackPhase(.playing)

    let reopened = try #require(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId),
      "a resume of a retired item with no session must reopen one")
    #expect(reopened.id != originalId)
    #expect(
      reopened.startPosition == 36_566,
      "the reopened session starts where the close preserved the position")
  }

  @Test func ticksAfterTheReopenLandInTheFreshSessionNotTheSessionlessNet() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: 36_560)
    let coordinator = try h.makeCoordinator()
    let originalId = try await closeViaPauseThenBackground(h, coordinator, pausePosition: 36_566)

    await coordinator.notifyPlaybackPhase(.playing)
    let reopenedId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)
    h.clock.advance(by: PlaybackSessionCoordinator.progressPersistInterval)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 36_581, listenedDelta: 15,
      isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: reopenedId))
    #expect(session.globalPosition == 36_581)
    #expect(session.listenedDeltaSeconds > 0, "the listening accrues on the session flow again")
    let frozen = try #require(try h.sessionStore.fetchSession(id: originalId))
    #expect(frozen.globalPosition == 36_566, "the closed session stays frozen where it closed")
  }

  // MARK: - The reopened session must survive the next backgrounding

  @Test func aSecondBackgroundingWhilePlayingKeepsTheReopenedSessionOpen() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    _ = try await closeViaPauseThenBackground(h, coordinator, pausePosition: 100)

    await coordinator.notifyPlaybackPhase(.playing)
    let reopenedId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    // performStart's close-before-play step resets the cadence phase. If the reopen leaves it
    // there, the next lock closes the fresh session under live audio.
    await coordinator.handleAppBackgrounded()

    let stillActive = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(stillActive.id == reopenedId, "playing keeps the session open across backgrounding")
  }

  // MARK: - No reopen when it must not fire

  @Test func playingPhaseDuringAnOrdinaryListenNeverChurnsTheSession() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    let sessionId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    await coordinator.notifyPlaybackPhase(.playing)
    await coordinator.notifyPlaybackPhase(.paused)
    await coordinator.notifyPlaybackPhase(.playing)

    let active = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(active.id == sessionId, "pause/resume with a live session reopens nothing")
  }

  @Test func playingPhaseAfterALogoutQuiesceReopensNothing() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    await coordinator.notifyPlaybackPhase(.playing)

    await coordinator.quiesceForLogout()
    await coordinator.notifyPlaybackPhase(.playing)

    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
  }

  // MARK: - The close no phase change follows (the commute shape)

  /// Drives the racing-close state: the session closes while the cadence phase stays `.playing`,
  /// so `notifyPlaybackPhase` never fires the resume hook. Returns the closed session's id.
  private func closeUnderLiveAudioWithoutAPhaseChange(
    _ h: OfflinePlaybackHarness, _ coordinator: PlaybackSessionCoordinator,
    closePosition: Double
  ) async throws -> Int64 {
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    let originalId = try #require(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)
    await coordinator.notifyPlaybackPhase(.playing)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: closePosition, listenedDelta: 6,
      isFinished: false, isSeek: false, sleepTimerExpired: true)
    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
    return originalId
  }

  @Test func sustainedTicksAfterACloseUnderLiveAudioReopenAFreshLocalSession() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    try await h.seedLocalProgress(itemRowId: itemRowId, currentTime: 20_000)
    let coordinator = try h.makeCoordinator()
    let originalId = try await closeUnderLiveAudioWithoutAPhaseChange(
      h, coordinator, closePosition: 20_006)

    // No phase change arrives; the audio keeps ticking past the straggler grace.
    h.clock.advance(by: PlaybackSessionCoordinator.stragglerGrace + 1)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 20_040, listenedDelta: 15,
      isFinished: false, isSeek: false)

    let reopened = try #require(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId),
      "a tick the sessionless net persisted must reopen a session behind it")
    #expect(reopened.id != originalId)
    #expect(
      reopened.startPosition == 20_040,
      "the reopened session starts where the sessionless tick left the position")
  }

  @Test func ticksAfterTheTickPathReopenAccrueInTheFreshSession() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    let originalId = try await closeUnderLiveAudioWithoutAPhaseChange(
      h, coordinator, closePosition: 20_006)

    h.clock.advance(by: PlaybackSessionCoordinator.stragglerGrace + 1)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 20_040, listenedDelta: 15,
      isFinished: false, isSeek: false)
    let reopenedId = try #require(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 20_055, listenedDelta: 15,
      isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: reopenedId))
    #expect(session.globalPosition == 20_055)
    #expect(session.listenedDeltaSeconds > 0, "the listening accrues on the session flow again")
    let frozen = try #require(try h.sessionStore.fetchSession(id: originalId))
    #expect(frozen.globalPosition == 20_006, "the closed session stays frozen where it closed")
  }

  @Test func backgroundingAfterTheTickPathReopenKeepsTheSessionOpen() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    _ = try await closeUnderLiveAudioWithoutAPhaseChange(h, coordinator, closePosition: 100)

    h.clock.advance(by: PlaybackSessionCoordinator.stragglerGrace + 1)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 140, listenedDelta: 15,
      isFinished: false, isSeek: false)
    let reopenedId = try #require(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    // As with the phase-path reopen, performStart's close-before-play resets the cadence phase.
    // Left at `.idle`, the next lock would close the fresh session under live audio.
    await coordinator.handleAppBackgrounded()

    let stillActive = try #require(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(stillActive.id == reopenedId)
  }

  @Test func aStragglerInsideTheGraceWindowReopensNothing() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    _ = try await closeUnderLiveAudioWithoutAPhaseChange(h, coordinator, closePosition: 100)

    // Inside the grace window the net drops the tick as a stop straggler; nothing persisted
    // sessionless, so nothing may reopen.
    h.clock.advance(by: 10)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 110, listenedDelta: 10,
      isFinished: false, isSeek: false)

    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
  }

  @Test func aDisplacedStragglerAfterASwitchNeverChurnsTheNewSession() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let otherRowId = try await h.makeItem(serverItemId: "item-switched-to")
    try h.completeDownload(itemRowId: otherRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()

    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    await coordinator.notifyPlaybackPhase(.playing)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 100, listenedDelta: 6,
      isFinished: false, isSeek: false)
    _ = try await coordinator.startSession(itemID: "item-switched-to", episodeID: nil)
    await coordinator.notifyPlaybackPhase(.playing)
    let switchedId = try #require(
      try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)

    // A late tick from the displaced item takes the displaced route, not the sessionless one.
    // It must never reopen the old item over the session that displaced it.
    h.clock.advance(by: PlaybackSessionCoordinator.stragglerGrace + 1)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 130, listenedDelta: 15,
      isFinished: false, isSeek: false)

    let active = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(active.id == switchedId)
  }

  @Test func sustainedTicksAfterALogoutQuiesceReopenNothing() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    _ = try await closeUnderLiveAudioWithoutAPhaseChange(h, coordinator, closePosition: 100)
    await coordinator.quiesceForLogout()

    h.clock.advance(by: PlaybackSessionCoordinator.stragglerGrace + 1)
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 140, listenedDelta: 15,
      isFinished: false, isSeek: false)

    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
  }

  // MARK: - The sleep-timer close gets the same net

  @Test func aBareResumeAfterTheSleepTimerCloseReopensAFreshLocalSession() async throws {
    let h = try await OfflinePlaybackHarness()
    let itemRowId = try await h.makeItem(serverItemId: Self.itemID)
    try h.completeDownload(itemRowId: itemRowId, orderIndex: 0, fileDurationSeconds: 60_000)
    let coordinator = try h.makeCoordinator()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    let originalId = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId)?.id)
    await coordinator.notifyPlaybackPhase(.playing)

    // The timer-owned close. AppModel's latch is the primary net for the next play; this is the
    // coordinator-side backstop for any play-shaped path that misses it.
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: 1_200, listenedDelta: 5,
      isFinished: false, isSeek: false, sleepTimerExpired: true)
    #expect(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId) == nil)
    await coordinator.notifyPlaybackPhase(.paused)

    await coordinator.notifyPlaybackPhase(.playing)

    let reopened = try #require(try h.sessionStore.fetchActiveOfflineSession(accountId: h.accountId))
    #expect(reopened.id != originalId)
  }
}
