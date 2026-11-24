extension PlayerReducer {
  /// An expiry at the end of the item is a completion, not a pause. `positionUpdated` is clamped
  /// to the declared track duration (`PlaybackTimeline.globalOffset`), so when that under-runs the
  /// real audio (routine for podcast feeds) a periodic tick fires this timer before
  /// `AVPlayerItemDidPlayToEndTime` arrives. Pausing would leave the item part-played forever:
  /// `.ended` is the only phase marking durable completion (`PlaybackModel`), which drives the
  /// latest-episodes queue and delete-when-finished. Emitting it here makes both outcomes of that
  /// race identical.
  ///
  /// Returns nil, leaving the ordinary pause path, for a boundary short of the item end and when
  /// the wrapped step already carries the authoritative `.ended` tick.
  mutating func completeItemAtSleepBoundary(
    _ mode: SleepTimerMode, now: Double, wrapping result: PlayerStepResult
  ) -> PlayerStepResult? {
    guard case .endOfChapter(let atPosition) = mode, let item = state.item else { return nil }
    guard atPosition >= item.timeline.totalDuration - Self.itemEndBoundaryTolerance else { return nil }
    guard result.progressEvents.contains(where: { $0.phase == .ended }) == false else { return nil }
    guard state.phase != .ended else { return nil }

    state.isPlaybackIntended = false
    state.pausedAt = nil
    // The timeline, not the engine, is authoritative at the end (same snap as `.trackFinished` on
    // its last track), so a tick clamped a fraction short still reports the true end.
    state.globalPosition = item.timeline.totalDuration
    guard let event = checkpoint(now: now, newPhase: .ended) else { return nil }
    let restoreEffects = updateFadeVolume()
    return PlayerStepResult(
      effects: [.pause] + restoreEffects,
      progressEvents: result.progressEvents + [
        PlaybackProgressEvent(
          sequence: event.sequence, itemId: event.itemId, episodeID: event.episodeID,
          phase: .ended, currentTime: event.currentTime, listenedDelta: event.listenedDelta,
          trimmedDelta: event.trimmedDelta,
          speedSavedDelta: event.speedSavedDelta, trimmedSourceDelta: event.trimmedSourceDelta,
          endBehavior: .stop, sleepTimerExpiry: .expired)
      ])
  }

  /// A sleep timer pinned at the end of the item owns that boundary even when the listener reaches
  /// it by skipping, and even while paused. `completeItemAtSleepBoundary` only runs on a tick that
  /// was `.playing`. Without this, a paused skip past the end would advance the queue and `load`
  /// would clear the timer, starting audio on a device whose owner had asked for silence.
  func endBehaviorAtItemEnd() -> PlaybackProgressEvent.EndBehavior {
    guard let item = state.item else { return .advanceQueue }
    guard case .endOfChapter(let atPosition) = state.sleepTimer.mode else { return .advanceQueue }
    let end = item.timeline.totalDuration
    return abs(atPosition - end) <= Self.itemEndBoundaryTolerance ? .stop : .advanceQueue
  }

  /// The shared completion body: snap to the timeline's end, checkpoint into `.ended`, and stop
  /// the engine. `completeItemAtSleepBoundary` wraps this with its own event shape; `handleSkip`
  /// uses it directly. The `.pause` effect is required here, unlike a natural end: the engine
  /// still has live audio because the item's real extent is being cut short.
  mutating func completeItem(
    now: Double, endBehavior: PlaybackProgressEvent.EndBehavior
  ) -> PlayerStepResult {
    guard let item = state.item else { return .none }
    state.isPlaybackIntended = false
    state.pausedAt = nil
    outstandingSeekTarget = nil
    state.sleepTimer = .off
    segment = nil
    // The timeline, not the engine, is authoritative at the end (same snap as `.trackFinished`
    // on its last track).
    state.globalPosition = item.timeline.totalDuration
    guard let event = checkpoint(now: now, newPhase: .ended) else { return .none }
    let restoreEffects = updateFadeVolume()
    return PlayerStepResult(
      effects: [.pause] + restoreEffects,
      progressEvents: [
        PlaybackProgressEvent(
          sequence: event.sequence, itemId: event.itemId, episodeID: event.episodeID,
          phase: .ended, currentTime: event.currentTime, listenedDelta: event.listenedDelta,
          trimmedDelta: event.trimmedDelta,
          speedSavedDelta: event.speedSavedDelta, trimmedSourceDelta: event.trimmedSourceDelta,
          endBehavior: endBehavior)
      ])
  }
}
