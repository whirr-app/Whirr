extension PlayerReducer {
  mutating func handlePlay(now: Double) -> PlayerStepResult {
    guard isLegalForPlaybackIntents else { return .none }
    state.isPlaybackIntended = true
    hasEverPlayedThisItem = true
    let restoreEffects = state.sleepTimer.mode == .off ? updateFadeVolume() : []
    switch state.phase {
    case .ready:
      state.pausedAt = nil
      guard let event = checkpoint(now: now, newPhase: .playing) else {
        return PlayerStepResult(effects: restoreEffects)
      }
      return PlayerStepResult(effects: restoreEffects + [.play], progressEvents: [event])
    case .paused:
      let pausedAt = state.pausedAt
      state.pausedAt = nil
      guard isSmartRewindEnabled, let pausedAt, now > pausedAt else {
        guard let event = checkpoint(now: now, newPhase: .playing) else {
          return PlayerStepResult(effects: restoreEffects)
        }
        return PlayerStepResult(effects: restoreEffects + [.play], progressEvents: [event])
      }

      let target = flooredAtConsumedRanges(
        SmartRewind.resumeTarget(
          from: state.globalPosition,
          pausedFor: now - pausedAt,
          chapterStart: state.item?.chapters.currentChapter(at: state.globalPosition)?.start),
        from: state.globalPosition)
      guard target < state.globalPosition else {
        guard let event = checkpoint(now: now, newPhase: .playing) else {
          return PlayerStepResult(effects: restoreEffects)
        }
        return PlayerStepResult(effects: restoreEffects + [.play], progressEvents: [event])
      }

      let seekResult = handleSeek(toGlobalOffset: target, now: now)
      // `handleSeek` checkpoints from `.paused`, so this step emits only its `.seeking` event.
      // The `.play` effect is enough to preserve intent; `.playing` is emitted by `resolveReady`
      // when the engine confirms the seek, avoiding a synchronous phase event that is premature.
      return PlayerStepResult(
        effects: restoreEffects + seekResult.effects + [.play],
        progressEvents: seekResult.progressEvents)
    case .buffering, .seeking:
      state.pausedAt = nil
      // The engine is between states on a real stream, but the intent must reach it now. An
      // AVPlayer told to play mid-buffer or mid-seek starts the moment it can, whereas a merely
      // recorded intent leaves it paused until `resolveReady` runs (a dead tap on device).
      // `resolveReady` still re-asserts on resolution.
      return PlayerStepResult(effects: restoreEffects + [.play])
    default:
      state.pausedAt = nil
      // Preparing or already playing: record the intent only. The pending load's `.ready`
      // resolution picks it up via `resolveReady`.
      return PlayerStepResult(effects: restoreEffects)
    }
  }

  mutating func handlePause(now: Double) -> PlayerStepResult {
    guard isLegalForPlaybackIntents else { return .none }
    let wasPlaybackIntended = state.isPlaybackIntended
    state.isPlaybackIntended = false
    switch state.phase {
    case .playing:
      guard let event = checkpoint(now: now, newPhase: .paused) else { return .none }
      if wasPlaybackIntended { state.pausedAt = now }
      return PlayerStepResult(effects: [.pause], progressEvents: [event])
    case .preparing, .ready, .buffering:
      // A real stream can still be preparing or reporting ready while AVPlayer has already
      // accepted a play request (buffering and seeking can likewise have audio in flight), so
      // always cancel the pending or active engine request when the intent changes to paused.
      // Waiting for a later `.ready` would let audio and ticks run under a play icon.
      if wasPlaybackIntended { state.pausedAt = now }
      return PlayerStepResult(effects: [.pause])
    case .seeking where wasPlaybackIntended:
      state.pausedAt = now
      return PlayerStepResult(effects: [.pause])
    default:
      return .none
    }
  }

  private var isLegalForPlaybackIntents: Bool {
    guard state.item != nil else { return false }
    switch state.phase {
    case .stalled:
      // A stalled stream cannot be revived by a bare playback intent. PlaybackModel owns the
      // fresh preparation that establishes a new server session.
      return false
    case .failed, .ended, .idle: return false
    default: return true
    }
  }
}
