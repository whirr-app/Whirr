/// One stretch of the loaded item to stop at the end of, in global item time: a chapter queued in
/// Up Next. PlayerCore knows nothing of the queue; AppModel sends the stretch after each load.
struct PlayerSegment: Sendable, Equatable {
  let start: Double
  let end: Double
}

extension PlayerReducer {
  /// How far before the segment's start a listener's move may land and still be inside it. A
  /// restart of the chapter lands a rounding short of its start, and a skip back from its first
  /// seconds should not cost the stop.
  static let segmentStartSlack: Double = 1.0
  /// How far short of the segment's end a playing position still counts as reaching it. The
  /// engine's boundary report is the end rounded to `CMTime`'s timescale, usually just below it;
  /// waiting for the next tick would play up to 2 s of the following chapter in the background.
  static let segmentEndEpsilon: Double = 0.05

  // MARK: - Intents

  /// A stretch that ends where the item does is not armed, so the ordinary item end runs: the book
  /// is marked finished and Up Next advances. "Where the item does" is the timeline's end or the
  /// last chapter's: a duration correction moves the first past the second, and a last chapter
  /// armed against the grown timeline would stop short and leave the book unfinished.
  mutating func handleSetSegment(start: Double, end: Double) {
    segment = nil
    guard let item = state.item, isLegalForPlayheadMovement else { return }
    guard start.isFinite, end.isFinite, start >= 0, end > start else { return }
    let itemEnd = min(item.timeline.totalDuration, item.chapters.chapters.last?.end ?? .infinity)
    guard end < itemEnd - Self.itemEndBoundaryTolerance else { return }
    segment = PlayerSegment(start: start, end: end)
  }

  /// The segment a load keeps: the same item loaded again at a position inside it. A stream
  /// recovery, or a stream promoted to its finished download, reloads the playing title where it
  /// stood, and the listener has not left the chapter. Any other load drops the stop.
  func segmentSurvivingReload(of item: PlayerItem, at position: Double) -> PlayerSegment? {
    guard let segment, let loaded = state.item,
      loaded.id == item.id, loaded.episodeID == item.episodeID,
      position >= segment.start - Self.segmentStartSlack, position < segment.end
    else { return nil }
    return segment
  }

  /// A forward skip that would cross the segment's end lands on it and counts as reaching it, or
  /// nil for every other skip. One past the item's end is left to `handleSkip`, which completes
  /// the item.
  mutating func skipToSegmentEnd(by delta: Double, now: Double) -> PlayerStepResult? {
    guard let segment, let item = state.item, isLegalForPlayheadMovement else { return nil }
    guard delta.isFinite, delta > 0, state.globalPosition < segment.end else { return nil }
    let target = state.globalPosition + delta
    guard target >= segment.end, target <= item.timeline.totalDuration + Self.itemEndBoundaryTolerance
    else { return nil }
    self.segment = nil
    let seek = handleSeek(toGlobalOffset: segment.end, now: now)
    guard seek.effects.isEmpty == false else { return seek }
    // The seek leaves the phase at `.seeking`; with the intent cleared, the engine's confirmation
    // resolves it to `.paused`.
    if state.isPlaybackIntended { state.pausedAt = now }
    state.isPlaybackIntended = false
    return PlayerStepResult(
      effects: seek.effects + [.pause], progressEvents: markingSegmentEnd(seek.progressEvents))
  }

  /// A listener's move out of the segment drops the stop, and the book plays on. A relative skip
  /// is not one: back past the start it keeps the stop, and forward past the end it is
  /// `skipToSegmentEnd`.
  mutating func clearSegmentAtListenerMove(for intent: PlayerIntent, result: PlayerStepResult) {
    switch intent {
    case .seek, .selectChapter, .previousChapter, .nextChapter:
      break
    default:
      return
    }
    guard let segment, result.effects.isEmpty == false else { return }
    let position = state.globalPosition
    if position < segment.start - Self.segmentStartSlack || position >= segment.end {
      self.segment = nil
    }
  }

  // MARK: - Reaching the end

  var hasPlayedToSegmentEnd: Bool {
    guard let segment, state.phase == .playing else { return false }
    return state.globalPosition >= segment.end - Self.segmentEndEpsilon
  }

  /// Whether the armed segment ends where the track at `trackIndex` starts.
  func segmentEnds(atStartOfTrack trackIndex: Int, in item: PlayerItem) -> Bool {
    guard let segment,
      let trackStart = item.timeline.globalOffset(forTrackIndex: trackIndex, localOffset: 0)
    else { return false }
    return segment.end <= trackStart + Self.itemEndBoundaryTolerance
  }

  /// Stops at the segment's end: the position is the end itself, not the tick up to 2 s past it,
  /// the pause is the listener's own pause path, and its event carries `segmentEnd: .reached`.
  /// The item is not ended and the segment is spent.
  mutating func reachSegmentEnd(now: Double) -> PlayerStepResult {
    guard let segment else { return .none }
    self.segment = nil
    state.globalPosition = segment.end
    let pause = handlePause(now: now)
    if pause.progressEvents.isEmpty == false {
      return PlayerStepResult(
        effects: pause.effects, progressEvents: markingSegmentEnd(pause.progressEvents))
    }
    // Not `.playing` (a file that finished while buffering): `handlePause` reports nothing, and
    // the stop still has to be said.
    state.isPlaybackIntended = false
    guard let event = checkpoint(now: now, newPhase: .paused) else { return pause }
    return PlayerStepResult(
      effects: pause.effects.isEmpty ? [.pause] : pause.effects,
      progressEvents: markingSegmentEnd([event]))
  }

  /// `result` with no event saying the segment's end was reached, and the segment dropped if one
  /// did or playback has reached it.
  mutating func droppingSegmentEnd(reachedIn result: PlayerStepResult) -> PlayerStepResult {
    if hasPlayedToSegmentEnd { segment = nil }
    guard result.progressEvents.contains(where: { $0.segmentEnd == .reached }) else { return result }
    return PlayerStepResult(
      effects: result.effects,
      progressEvents: result.progressEvents.map { $0.with(segmentEnd: .none) })
  }

  private func markingSegmentEnd(_ events: [PlaybackProgressEvent]) -> [PlaybackProgressEvent] {
    var events = events
    if let last = events.indices.last { events[last] = events[last].with(segmentEnd: .reached) }
    return events
  }
}

extension PlaybackProgressEvent {
  fileprivate func with(segmentEnd: SegmentEnd) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: sequence, itemId: itemId, episodeID: episodeID, phase: phase,
      currentTime: currentTime, listenedDelta: listenedDelta, trimmedDelta: trimmedDelta,
      speedSavedDelta: speedSavedDelta, trimmedSourceDelta: trimmedSourceDelta, endBehavior: endBehavior,
      sleepTimerExpiry: sleepTimerExpiry, skippedRange: skippedRange, segmentEnd: segmentEnd)
  }
}
