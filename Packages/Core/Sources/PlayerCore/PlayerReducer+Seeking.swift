extension PlayerReducer {
  /// How far into a chapter counts as "just started it" for `.previousChapter`. Past this point
  /// the current chapter restarts; otherwise the previous one starts.
  private static let previousChapterRestartThreshold: Double = 3.0

  /// Restarts the current chapter when more than `previousChapterRestartThreshold` seconds into
  /// it; otherwise moves to the previous chapter's start. With no previous chapter it restarts the
  /// current one, and with no chapter data it does nothing.
  mutating func handlePreviousChapter(now: Double) -> PlayerStepResult {
    guard let item = state.item else { return .none }
    let position = state.globalPosition
    guard let current = item.chapters.currentChapter(at: position) else {
      guard let previous = item.chapters.previousChapter(before: position) else { return .none }
      return handleSeek(toGlobalOffset: previous.start, now: now)
    }
    if position - current.start > Self.previousChapterRestartThreshold {
      return handleSeek(toGlobalOffset: current.start, now: now)
    }
    guard let previous = item.chapters.previousChapter(before: position) else {
      return handleSeek(toGlobalOffset: current.start, now: now)
    }
    return handleSeek(toGlobalOffset: previous.start, now: now)
  }

  mutating func handleNextChapter(now: Double) -> PlayerStepResult {
    guard let item = state.item, let next = item.chapters.nextChapter(after: state.globalPosition)
    else { return .none }
    return handleSeek(toGlobalOffset: next.start, now: now)
  }

  /// Whether the playhead may be moved at all. A stalled stream cannot be revived by moving it, so
  /// the terminal state is kept until a higher layer prepares afresh; `.failed` follows the same
  /// rule. `.ended` and `.idle` are refused because the engine may still hold mid-item audio after
  /// a completion. A seek there would move the phase to `.seeking`, so `isCurrent` would admit
  /// engine events again and play would be legal against an item the model has unloaded.
  var isLegalForPlayheadMovement: Bool {
    guard state.item != nil else { return false }
    switch state.phase {
    case .failed, .stalled, .ended, .idle: return false
    default: return true
    }
  }

  mutating func handleSeek(toGlobalOffset target: Double, now: Double) -> PlayerStepResult {
    guard let item = state.item, let currentIndex = state.currentTrackIndex else { return .none }
    guard isLegalForPlayheadMovement else { return .none }

    // A target inside a cut is where the engine cannot land; it lands at the cut's end, so the
    // target says so too and the landing guard recognises it however long the cut.
    let clamped = trimSnapped(min(max(target, 0), item.timeline.totalDuration), in: item)
    let (track, localOffset) = item.timeline.trackAndLocalOffset(atGlobalOffset: clamped)
    // Adopt the target immediately. A real engine confirms a seek only through later periodic
    // ticks, and a paused player never ticks, so waiting leaves state (and the UI and the
    // seek-completed sync) at the stale position. Set before `checkpoint` rather than passed as its
    // `positionUpdate`, so the jump detector does not zero the wall-clock credit for the interval
    // just ended.
    state.globalPosition = clamped
    outstandingSeekTarget = clamped
    guard let event = checkpoint(now: now, newPhase: .seeking) else { return .none }

    if track.index == currentIndex {
      return PlayerStepResult(effects: [.seekEngine(localOffset: localOffset)], progressEvents: [event])
    }
    generation += 1
    state.currentTrackIndex = track.index
    return PlayerStepResult(
      effects: [
        .loadEngine(
          track: track, localOffset: localOffset, rate: state.rate, generation: generation, trim: activeTrimMap)
      ],
      progressEvents: [event])
  }

  /// Relative movement, and the only path that may complete the item: skipping past the end means
  /// the listener is done, so it completes instead of parking on the last frame. An absolute
  /// `seek` does not (see `PlayerIntent`).
  ///
  /// Completion is synthesised here because the engine cannot produce it: `trackFinished` needs
  /// audio to reach the end, so a skip while paused would finish nothing, and the sleep-timer
  /// boundary is gated on having been `.playing`.
  mutating func handleSkip(by delta: Double, now: Double) -> PlayerStepResult {
    guard let item = state.item else { return .none }
    guard isLegalForPlayheadMovement else { return .none }
    guard delta.isFinite, delta != 0 else { return .none }

    let target = state.globalPosition + delta
    guard target > item.timeline.totalDuration + Self.itemEndBoundaryTolerance else {
      if delta > 0, let carried = forwardSkipCarry(landingAt: target) {
        return skippingPast(carried, now: now)
      }
      return handleSeek(toGlobalOffset: target, now: now)
    }
    return completeItem(now: now, endBehavior: endBehaviorAtItemEnd())
  }
}
