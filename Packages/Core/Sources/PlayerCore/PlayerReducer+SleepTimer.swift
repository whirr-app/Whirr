extension PlayerReducer {
  mutating func handleSetSleepTimer(_ duration: SleepTimerDuration, now: Double) -> PlayerStepResult {
    sleepTimerCheckpoint = now
    switch duration {
    case .off:
      state.sleepTimer = .off
    case .endOfChapter:
      guard let item = state.item else {
        state.sleepTimer = .off
        break
      }
      let target = item.chapters.currentChapter(at: state.globalPosition)?.end ?? item.timeline.totalDuration
      state.sleepTimer = SleepTimerState(mode: .endOfChapter(atPosition: target))
    case .endOfItem:
      guard let item = state.item else {
        state.sleepTimer = .off
        break
      }
      state.sleepTimer = SleepTimerState(mode: .endOfChapter(atPosition: item.timeline.totalDuration))
    case .fifteenMinutes, .thirtyMinutes, .fortyFiveMinutes, .sixtyMinutes:
      guard let seconds = duration.seconds, seconds.isFinite, seconds > 0 else {
        state.sleepTimer = .off
        break
      }
      state.sleepTimer = SleepTimerState(
        mode: .countdown(remainingSeconds: seconds), configuredSeconds: seconds)
    case .custom(let seconds):
      guard seconds.isFinite, seconds > 0 else {
        state.sleepTimer = .off
        break
      }
      // A custom timer shorter than the fade window starts inside the fade, so a 10-second timer
      // begins already attenuated.
      state.sleepTimer = SleepTimerState(
        mode: .countdown(remainingSeconds: seconds), configuredSeconds: seconds)
    }
    return PlayerStepResult(effects: updateFadeVolume())
  }

  /// Starts `duration` again because the listener resumed shortly after it last stopped playback.
  /// Same as choosing it from the current position, except the timer carries `restartedOnResume`
  /// so the player can say why one is running.
  public mutating func restartSleepTimerOnResume(
    _ duration: SleepTimerDuration, now: Double
  ) -> PlayerStepResult {
    let result = handleSetSleepTimer(duration, now: now)
    if state.sleepTimer.mode != .off {
      state.sleepTimer.restartedOnResume = true
    }
    return result
  }

  /// Adds time to an already-running countdown. A no-op when the timer is off or set to
  /// end-of-chapter (not time-based), as there is nothing to extend.
  mutating func handleExtendSleepTimer(by seconds: Double, now: Double) -> PlayerStepResult {
    sleepTimerCheckpoint = now
    guard seconds.isFinite, seconds > 0 else {
      return PlayerStepResult(effects: updateFadeVolume())
    }
    guard case .countdown(let remaining) = state.sleepTimer.mode else {
      return PlayerStepResult(effects: updateFadeVolume())
    }
    // Rebuilt, not mutated: an extended countdown is not the preset it started as, so
    // `configuredSeconds` is nil and the menu does not claim a choice is in force.
    state.sleepTimer = SleepTimerState(mode: .countdown(remainingSeconds: remaining + seconds))
    return PlayerStepResult(effects: updateFadeVolume())
  }

  /// Advances the sleep timer by the segment that just ended and, on expiry, fires the same pause
  /// path as a user `.pause` and clears the timer, merged onto the wrapped step's effects and
  /// events. A repeat is harmless: `handlePause` is a no-op outside `.playing`, keeping expiry
  /// one-time.
  ///
  /// `wasPlaying` is the phase before the wrapped step; it gates both the credit and the expiry
  /// check, as the timer only runs while audio does. The checkpoint still advances
  /// unconditionally, so a frozen interval is discarded, not deferred.
  mutating func applySleepTimerTick(
    now: Double, wasPlaying: Bool, to result: PlayerStepResult
  ) -> PlayerStepResult {
    let elapsed = wasPlaying ? max(0, now - sleepTimerCheckpoint) : 0
    sleepTimerCheckpoint = now
    // Short-circuits: `sleepTimerExpired` writes the decremented remainder back, and
    // a frozen timer must not be touched at all.
    let expired = wasPlaying && sleepTimerExpired(elapsed: elapsed)
    let fadeEffects = updateFadeVolume()
    guard expired == false else {
      let expiringMode = state.sleepTimer.mode
      state.sleepTimer = .off
      // The sleep timer owns a boundary it shares with the segment: the listener asked for
      // silence, so nothing may read this step as the cue to start the next Up Next row.
      let result = droppingSegmentEnd(reachedIn: result)
      if let completion = completeItemAtSleepBoundary(expiringMode, now: now, wrapping: result) {
        return PlayerStepResult(
          effects: result.effects + fadeEffects + completion.effects,
          progressEvents: completion.progressEvents)
      }
      let pauseResult = handlePause(now: now)
      let restoreEffects = updateFadeVolume()
      // At the last track, `handleEngineEvent` has already emitted the authoritative `.ended`
      // tick. Keep that tick (it marks the item finished and drives delete-when-finished), but
      // annotate it so Up Next cannot turn a sleep boundary into another item starting.
      var progressEvents = result.progressEvents.map { event in
        guard event.phase == .ended else { return event }
        return PlaybackProgressEvent(
          sequence: event.sequence, itemId: event.itemId, episodeID: event.episodeID,
          phase: event.phase, currentTime: event.currentTime, listenedDelta: event.listenedDelta,
          trimmedDelta: event.trimmedDelta,
          speedSavedDelta: event.speedSavedDelta, trimmedSourceDelta: event.trimmedSourceDelta, endBehavior: .stop,
          sleepTimerExpiry: event.sleepTimerExpiry,
          skippedRange: event.skippedRange, segmentEnd: event.segmentEnd)
      }
      progressEvents.append(contentsOf: pauseResult.progressEvents)
      if let eventIndex =
        progressEvents.lastIndex(where: { $0.phase == .paused })
        ?? progressEvents.lastIndex(where: { $0.phase == .ended })
        ?? progressEvents.indices.last
      {
        let event = progressEvents[eventIndex]
        progressEvents[eventIndex] = PlaybackProgressEvent(
          sequence: event.sequence, itemId: event.itemId, episodeID: event.episodeID,
          phase: event.phase, currentTime: event.currentTime, listenedDelta: event.listenedDelta,
          trimmedDelta: event.trimmedDelta,
          speedSavedDelta: event.speedSavedDelta, trimmedSourceDelta: event.trimmedSourceDelta,
          endBehavior: event.endBehavior, sleepTimerExpiry: .expired,
          skippedRange: event.skippedRange, segmentEnd: event.segmentEnd)
      } else if let event = checkpoint(now: now, newPhase: state.phase) {
        progressEvents.append(
          PlaybackProgressEvent(
            sequence: event.sequence, itemId: event.itemId, episodeID: event.episodeID,
            phase: event.phase, currentTime: event.currentTime, listenedDelta: event.listenedDelta,
            trimmedDelta: event.trimmedDelta,
            speedSavedDelta: event.speedSavedDelta, trimmedSourceDelta: event.trimmedSourceDelta,
            endBehavior: event.endBehavior, sleepTimerExpiry: .expired))
      }
      return PlayerStepResult(
        effects: result.effects + fadeEffects + pauseResult.effects + restoreEffects,
        progressEvents: progressEvents)
    }
    if hasPlayedToSegmentEnd {
      let stop = reachSegmentEnd(now: now)
      return PlayerStepResult(
        effects: result.effects + fadeEffects + stop.effects,
        progressEvents: result.progressEvents + stop.progressEvents)
    }
    guard fadeEffects.isEmpty == false else { return result }
    return PlayerStepResult(
      effects: result.effects + fadeEffects, progressEvents: result.progressEvents)
  }

  private mutating func sleepTimerExpired(elapsed: Double) -> Bool {
    switch state.sleepTimer.mode {
    case .off:
      return false
    case .countdown(let remaining):
      let updated = remaining - elapsed
      // Mutate the mode rather than rebuilding the state: `configuredSeconds` describes the
      // choice that is running, so it has to survive every decrement of what is left of it.
      state.sleepTimer.mode = .countdown(remainingSeconds: updated)
      return updated <= 0
    case .endOfChapter(let atPosition):
      return state.globalPosition >= atPosition
    }
  }

  /// Recomputes the fade amplitude from the sleep timer's current shape and returns the effect to
  /// apply it, or nothing when it has not moved. The only place the reducer updates
  /// `state.volume`.
  mutating func updateFadeVolume() -> [PlayerEffect] {
    let target: Double
    switch state.sleepTimer.mode {
    case .off, .endOfChapter:
      // A chapter or episode end is already a natural break; only a countdown fades.
      target = 1.0
    case .countdown(let remaining):
      target = SleepTimerFade.volume(remainingSeconds: remaining)
    }

    guard abs(target - state.volume) > 0.0001 else { return [] }
    state.volume = target
    return [.setVolume(target)]
  }

  /// A sleep-timer boundary pinned at the old end of the item follows the item's new end. Left
  /// behind, it would fire early, inside surplus audio the correction revealed, and stop playback
  /// short of the real end, which `completeItemAtSleepBoundary` would not treat as a completion.
  /// Matched by tolerance because `.endOfChapter` pins the final chapter's own end, which
  /// routinely stops a fraction short of the declared duration.
  mutating func repinSleepTimerAtItemEnd(movedFrom previousEnd: Double, to newEnd: Double) {
    guard case .endOfChapter(let atPosition) = state.sleepTimer.mode else { return }
    guard abs(atPosition - previousEnd) <= Self.itemEndBoundaryTolerance else { return }
    // The same timer at a corrected position, so whatever else describes it stays as it was.
    state.sleepTimer.mode = .endOfChapter(atPosition: newEnd)
  }
}
