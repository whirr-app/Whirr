import Foundation
import Persistence

extension PlaybackSessionCoordinator {
  // MARK: - Progress tick

  /// See the protocol doc comment. Runs on the device-keyed `serialized` chain shared with
  /// `startSession`/`stopSession`, so a tick can never land on a session that a concurrent
  /// switch or stop has begun freezing or closing.
  public func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool = false
  ) async {
    _ = try? await serialized {
      let landedSessionless = await self.performRecordProgressTick(
        itemID: itemID, episodeID: episodeID, currentTime: currentTime,
        listenedDelta: listenedDelta, isFinished: isFinished, isSeek: isSeek)
      // A tick the sessionless net had to persist is live audio with no session under it, so
      // hand the rest of the listen back to the session flow. Not for a finished or
      // timer-expiring tick, whose playback is ending.
      if landedSessionless, isFinished == false, sleepTimerExpired == false {
        await self.reopenSessionAfterSessionlessTick(itemID: itemID, episodeID: episodeID)
      }
      guard sleepTimerExpired, isFinished == false else { return }
      try await self.performSleepTimerLocalClose(itemID: itemID, episodeID: episodeID)
    }
  }

  /// A timer-owned pause closes only the local session that owns the marked event. Doing the
  /// lookup and close on this chain makes the final tick, session retirement and closure one
  /// ordered transition. An online session falls through untouched.
  private func performSleepTimerLocalClose(itemID: String, episodeID: String?) async throws {
    guard case .resolved(let rows) = resolveTickRows(itemID: itemID, episodeID: episodeID),
      let activeLocal = try await sessionStore.fetchActiveOfflineSessionAsync(accountId: rows.accountId),
      activeLocal.itemId == rows.itemRowId,
      activeLocal.podcastEpisodeId == rows.episodeRowId,
      activeLocal.id != nil
    else { return }

    flushPendingProgressTick()
    progressThrottle.reset()
    cachedOnlineTickTarget = nil
    let identity = ActivePlaybackItem(
      itemID: itemID, episodeID: episodeID, itemRowId: rows.itemRowId,
      episodeRowId: rows.episodeRowId, accountId: rows.accountId)
    let retiredAt = clock.now()
    if let activePlaybackItem {
      retiredPlaybackItem = RetiredPlaybackItem(item: activePlaybackItem, stoppedAt: retiredAt)
    } else {
      retiredPlaybackItem = RetiredPlaybackItem(item: identity, stoppedAt: retiredAt)
    }
    activePlaybackItem = nil
    unarmedPlaybackCandidate = nil
    displacedPlaybackItem = nil
    _ = try await closeActiveLocalSessionIfPresent(accountId: rows.accountId)
  }

  /// The throttle front-end: decides whether this tick persists now or accumulates.
  /// A seek, finished transition or item change is a boundary outside code can observe (segment
  /// coalescing), so the accumulation flushes into its own segment first and the boundary tick
  /// persists immediately. So does a tick while cadence is not `.playing` (pause cancels cadence
  /// before this final tick reaches the serialized chain, and AppModel requests its drain only
  /// after this write returns) and the first tick after a session or item change, so a relaunch
  /// resume is never a whole interval behind. Everything else merges in memory until
  /// `progressPersistInterval` elapses.
  ///
  /// Returns whether the durable write (if any) landed on the sessionless route, which
  /// `recordProgressTick` uses to attempt a reopen after the throttle bookkeeping.
  private func performRecordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool
  ) async -> Bool {
    // The decision carries the previous tick's `isFinished` for this item/episode stream, or
    // `nil` when there is nothing to compare against (a fresh stream, or one that just switched
    // item/episode). A not-finished to finished transition is itself a boundary, so only an
    // immediate decision needs to check it.
    let decision = progressThrottle.record(
      ProgressPersistThrottle.Tick(
        itemID: itemID, episodeID: episodeID, currentTime: currentTime,
        listenedDelta: listenedDelta, isFinished: isFinished),
      isSeek: isSeek, isPlaying: cadencePhase == .playing, now: clock.now())
    // A boundary flushes the held tick into its own segment first, then persists itself. The
    // reopen signal comes from the last write only.
    var landedSessionless = false
    for write in decision.writes {
      let record = persistTick(
        itemID: write.tick.itemID, episodeID: write.tick.episodeID,
        currentTime: write.tick.currentTime, listenedDelta: write.tick.listenedDelta,
        isFinished: write.tick.isFinished, isSeek: write.isSeek)
      landedSessionless = record.outcome == .persisted(.sessionless)
    }
    if decision.isImmediate {
      await handleFinishedTransition(
        itemID: itemID, episodeID: episodeID, isFinished: isFinished,
        previousFinished: decision.previousFinished)
    }
    return landedSessionless
  }

  private func handleFinishedTransition(
    itemID: String, episodeID: String?, isFinished: Bool, previousFinished: Bool?
  ) async {
    guard isFinished, previousFinished != true else { return }
    // Deleting a download needs a witnessed not-finished to finished transition. With `nil` (a
    // fresh stream) the first tick of an already-finished item would read as a completion and
    // delete a download the user had only just started. The reap below tolerates `nil`, since
    // reaping nothing is a silent no-op and deleting the wrong thing is not.
    if previousFinished == false, downloadPreferences.deleteWhenFinished {
      await requestFinishedDownloadDeletion(itemID, episodeID)
    }
    await reapIfEpisodeJustFinished(
      episodeID: episodeID, isFinished: isFinished, previousFinished: previousFinished)
  }

  /// Fires the injected reap request once per not-finished to finished transition of a podcast
  /// episode tick: never for a book (`episodeID == nil`) or later ticks of a finished stream, and
  /// only a reap, never a download pass. `previousFinished == nil` (a fresh stream) counts as not
  /// finished, so the first tick of an already-finished stream still reaps once; harmless, since
  /// reaping nothing is a silent no-op.
  private func reapIfEpisodeJustFinished(
    episodeID: String?, isFinished: Bool, previousFinished: Bool?
  ) async {
    guard let episodeID, episodeID.isEmpty == false, isFinished, previousFinished != true else {
      return
    }
    await requestPodcastAutoDownloadReap()
  }

  /// Durably writes whatever the throttle has accumulated, if anything. Synchronous; see
  /// `progressThrottle`'s doc comment.
  func flushPendingProgressTick() {
    guard let held = progressThrottle.takePending(now: clock.now()) else { return }
    persistTick(
      itemID: held.itemID, episodeID: held.episodeID, currentTime: held.currentTime,
      listenedDelta: held.listenedDelta, isFinished: held.isFinished, isSeek: false)
  }
}
