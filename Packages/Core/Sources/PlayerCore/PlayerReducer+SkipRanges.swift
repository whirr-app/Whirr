/// One stretch of the loaded item to skip in global item time.
/// PlayerCore knows nothing of how it was found; AppModel supplies these only for an analysed
/// local file whose fingerprint still matches.
public struct PlayerSkipRange: Sendable, Equatable, Hashable {
  public let start: Double
  public let end: Double
  /// No speech follows the range, so skipping it finishes the item. Decided by the analysis rather
  /// than by comparing `end` with `totalDuration`, which is an estimate that can grow.
  public let endsItem: Bool

  public init(start: Double, end: Double, endsItem: Bool) {
    self.start = start
    self.end = end
    self.endsItem = endsItem
  }

  func overlaps(_ other: PlayerSkipRange) -> Bool {
    start < other.end && other.start < end
  }
}

/// The reducer's skip-range bookkeeping for the loaded episode.
struct SkipRangeState: Sendable {
  var itemID: String?
  var episodeID: String?
  var ranges: [PlayerSkipRange] = []
  /// Ranges skipped or played this pass, until a listener's move lands before one's start.
  /// Matched by overlap rather than equality: a recompute can nudge a range's edges, and that must
  /// not make it skippable again.
  var consumed: [PlayerSkipRange] = []
  /// Ranges undone during this load. Unlike `consumed`, no move back releases them.
  var undone: [PlayerSkipRange] = []
  /// The boundary last handed to the engine, with the generation it was armed under.
  var armed: (generation: Int, localOffset: Double)?
  /// Set while the seek past a range is in flight: a tick behind this is one the engine queued
  /// before the seek, from inside the range, however close it sits to the seek target.
  var landingFloor: Double?
  /// Where this load's uninterrupted playback began: where it loaded, or the listener's last move
  /// landed. Ranges come from a possibly busy actor, so playback can already be inside one on
  /// arrival; the rule judges entry from here. Kept until the load's first delivery is judged, so
  /// later replacements never reach back.
  var origin: (position: Double, isListenerMove: Bool)?

  func isConsumed(_ range: PlayerSkipRange) -> Bool {
    consumed.contains { $0.overlaps(range) } || undone.contains { $0.overlaps(range) }
  }
}

extension PlayerReducer {
  /// How far short of a skip's target a landing may still be. Seeks are issued with zero
  /// tolerance, so this only absorbs `CMTime` rounding; a stale tick from inside the range is
  /// seconds short.
  static let skipLandingMargin: Double = 0.5
  /// Ranges this close are skipped as one. One break often holds several creatives detected
  /// separately; in the harness's predictions, gaps up to 9 s held almost no programme, while longer
  /// ones began to.
  static let skipJoinGap: Double = 9

  var skipRanges: [PlayerSkipRange] { skip.ranges }
  var armedSkipBoundary: Double? { skip.armed?.localOffset }

  // MARK: - Intents

  mutating func handleSetSkipRanges(
    itemID: String, episodeID: String?, ranges: [PlayerSkipRange], now: Double
  ) -> PlayerStepResult {
    guard let item = state.item, item.id == itemID, item.episodeID == episodeID else { return .none }
    // Only the load's first delivery may catch up. A recompute that finds an ad where the listener
    // already is must not pull them out of what they have been hearing.
    if skip.itemID != nil { skip.origin = nil }
    skip.itemID = itemID
    skip.episodeID = episodeID
    skip.ranges = ranges.filter { $0.start.isFinite && $0.end.isFinite && $0.start < $0.end }
      .sorted { $0.start < $1.start }
    // Not playing, there is nothing to seek away from yet; the next playing tick judges it.
    guard state.phase == .playing, state.isPlaybackIntended, let range = rangeEnteredFromOrigin()
    else { return .none }
    return skippingPast(joining(from: range), now: now)
  }

  /// A fresh load is a fresh pass, and possibly a different episode.
  mutating func resetSkipRanges() {
    skip = SkipRangeState()
  }

  /// Run once the load has positioned the playhead.
  mutating func noteSkipOrigin(for intent: PlayerIntent) {
    guard case .load = intent, state.item != nil else { return }
    skip.origin = (state.globalPosition, false)
  }

  /// The range playback is in because it ran there uninterrupted from `skip.origin`, which is
  /// spent by the asking. A listener's move to exactly a range's start asked to hear it, as it does
  /// when the ranges are on time; a load there has not.
  private mutating func rangeEnteredFromOrigin() -> PlayerSkipRange? {
    guard let origin = skip.origin else { return nil }
    skip.origin = nil
    let position = state.globalPosition
    return skip.ranges.first {
      (origin.isListenerMove ? origin.position < $0.start : origin.position <= $0.start)
        && $0.start <= position && position < $0.end && skip.isConsumed($0) == false
    }
  }

  /// Back to the start of a skipped range, which then plays: it is undone for the rest of the
  /// load, so the rule does not fire again on the way through or after a move back before it.
  /// Tombstoning the ad is AppModel's half.
  mutating func handleUndoSkip(_ range: PlayerSkipRange, now: Double) -> PlayerStepResult {
    guard appliesToLoadedItem, skip.ranges.contains(range) || skip.consumed.contains(range)
    else { return .none }
    skip.undone.append(range)
    skip.landingFloor = nil
    return handleSeek(toGlobalOffset: range.start, now: now)
  }

  /// Any intent that moves the playhead supersedes a skip's seek, so its landing guard goes too.
  mutating func clearSkipLandingFloor(for intent: PlayerIntent) {
    switch intent {
    // A trim reload keeps the listener's place, so a skip's seek in flight is still in flight.
    case .play, .pause, .toggle, .setRate, .setSleepTimer, .extendSleepTimer, .setSkipRanges, .setTrimMap,
      .setSegment, .clearSegment:
      return
    default:
      skip.landingFloor = nil
    }
  }

  /// A listener's move into a range plays it, so the range is consumed for this pass, and a skip
  /// forward never lands in one still to be skipped (`forwardSkipCarry`). A move that lands before
  /// a consumed range's start begins a new pass for it. The position before the next tick cannot
  /// say so: a tick queued before the seek can be adopted as its landing, and a resume's smart
  /// rewind can land before the start.
  mutating func consumeRangeAtListenerMove(for intent: PlayerIntent, result: PlayerStepResult) {
    switch intent {
    case .seek, .skip, .selectChapter, .previousChapter, .nextChapter:
      break
    default:
      return
    }
    guard result.effects.isEmpty == false else { return }
    let position = state.globalPosition
    if skip.origin != nil { skip.origin = (position, true) }
    guard appliesToLoadedItem else { return }
    skip.consumed.removeAll { position < $0.start }
    for range in skip.ranges
    where range.start <= position && position < range.end && skip.isConsumed(range) == false {
      skip.consumed.append(range)
    }
  }

  // MARK: - Engine events

  /// Whether `event` is a tick queued before a skip's seek, reporting from inside the range. Such
  /// a tick is dropped outright; the landing guard ends with the first tick at the target, with
  /// `.ready` from the seek's completion, or with any later playhead intent.
  mutating func isStaleSkipLanding(_ event: AudioEngineEvent) -> Bool {
    guard let floor = skip.landingFloor else { return false }
    switch event {
    case .ready:
      skip.landingFloor = nil
      return false
    case .positionUpdated(let gen, let localOffset):
      guard gen == generation, let item = state.item, let trackIndex = state.currentTrackIndex,
        let global = item.timeline.globalOffset(forTrackIndex: trackIndex, localOffset: localOffset)
      else { return false }
      guard global < floor else {
        skip.landingFloor = nil
        return false
      }
      return true
    default:
      return false
    }
  }

  /// The rule: playback that has just moved from at or before a range's start into it, while the
  /// listener intends to play, skips it once. The pre-step `position` makes a scrub or resume
  /// inside a range play it, as neither starts before its start. "At" admits a pre-roll (playback
  /// starts at 0); a listener's seek to exactly a range's start has already consumed it. The
  /// first playing tick after a load's ranges arrive also admits entry from `skip.origin`, for
  /// ranges that arrived late while playback was not `.playing`.
  mutating func applySkipRule(
    to result: PlayerStepResult, event: AudioEngineEvent, from previousPosition: Double, now: Double
  ) -> PlayerStepResult {
    guard case .positionUpdated = event, state.phase == .playing, state.isPlaybackIntended,
      appliesToLoadedItem
    else { return result }
    let position = state.globalPosition
    let late = rangeEnteredFromOrigin()
    guard
      let range = skip.ranges.first(where: {
        previousPosition <= $0.start && $0.start <= position && position < $0.end
          && skip.isConsumed($0) == false
      }) ?? late
    else { return result }
    let step = skippingPast(joining(from: range), now: now)
    return PlayerStepResult(
      effects: result.effects + step.effects, progressEvents: result.progressEvents + step.progressEvents)
  }

  /// The range a forward skip landing at `target` should carry on past, or `nil` to land there. A
  /// skip forward says "get me past this", so landing inside a range still to be skipped this pass
  /// skips it: skipping a missed ad just before a kept one must not land in the kept one. A scrub
  /// or a skip back into a range still plays it.
  func forwardSkipCarry(landingAt target: Double) -> PlayerSkipRange? {
    guard appliesToLoadedItem,
      let range = skip.ranges.first(where: {
        $0.start <= target && target < $0.end && skip.isConsumed($0) == false
      })
    else { return nil }
    return joining(from: range)
  }

  /// Skips `joined`, a range already extended through its break: consumes it, then seeks to its end
  /// or completes the item, reporting it on the last progress event for the receipt.
  mutating func skippingPast(_ joined: PlayerSkipRange, now: Double) -> PlayerStepResult {
    // Matched by overlap, the joined range consumes every range it covers.
    skip.consumed.append(joined)
    let step: PlayerStepResult
    if joined.endsItem {
      step = completeItem(now: now, endBehavior: endBehaviorAtItemEnd())
    } else {
      step = handleSeek(toGlobalOffset: joined.end, now: now)
      if step.effects.isEmpty == false { skip.landingFloor = joined.end - Self.skipLandingMargin }
    }
    var events = step.progressEvents
    if let last = events.indices.last { events[last] = events[last].reporting(joined) }
    return PlayerStepResult(effects: step.effects, progressEvents: events)
  }

  /// `range` extended through each following range that starts within `skipJoinGap` of it, up to
  /// one already consumed this pass.
  private func joining(from range: PlayerSkipRange) -> PlayerSkipRange {
    var end = range.end
    var endsItem = range.endsItem
    for next in skip.ranges where next.start > range.start && next.end > end {
      guard next.start - end <= Self.skipJoinGap, skip.isConsumed(next) == false else { break }
      end = next.end
      endsItem = next.endsItem
    }
    return PlayerSkipRange(start: range.start, end: end, endsItem: endsItem)
  }

  // MARK: - Smart rewind

  /// A resume after a skip must not land back inside the ad: the rewind stops at the end of any
  /// consumed range it would cross, as it stops at a chapter start.
  func flooredAtConsumedRanges(_ target: Double, from position: Double) -> Double {
    guard appliesToLoadedItem else { return target }
    return skip.consumed.reduce(target) { floor, range in
      range.end <= position && range.end > floor ? range.end : floor
    }
  }

  // MARK: - Boundary

  /// Appends the effect arming the next position the engine must report the moment it reaches (a
  /// range start or the segment end), when it differs from what is armed or the engine has just
  /// been repositioned. Periodic ticks are 2 s apart in the background, so without the boundary up
  /// to 2 s of an ad, or of the chapter after the segment, would play.
  mutating func armingSkipBoundary(_ result: PlayerStepResult) -> PlayerStepResult {
    let desired = desiredBoundary
    let repositioned = result.effects.contains {
      switch $0 {
      case .loadEngine, .seekEngine: true
      default: false
      }
    }
    let unchanged = desired == skip.armed?.localOffset && (desired == nil || skip.armed?.generation == generation)
    guard unchanged == false || (repositioned && desired != nil) else { return result }
    skip.armed = desired.map { (generation, $0) }
    return PlayerStepResult(
      effects: result.effects + [.setBoundary(localOffset: desired)], progressEvents: result.progressEvents)
  }

  /// The earlier of the next range start and the segment end, as a local offset in the loaded
  /// track. One in a later track is not armed: the range start waits for that track's load, and a
  /// segment that ends where a track does is stopped by `.trackFinished`.
  private var desiredBoundary: Double? {
    guard let item = state.item, let trackIndex = state.currentTrackIndex else { return nil }
    switch state.phase {
    case .idle, .ended, .failed, .stalled: return nil
    default: break
    }
    let position = state.globalPosition
    var candidates: [Double] = []
    if appliesToLoadedItem,
      let next = skip.ranges.first(where: { $0.start > position && skip.isConsumed($0) == false })
    {
      candidates.append(next.start)
    }
    if let segment, segment.end > position { candidates.append(segment.end) }
    guard let earliest = candidates.min() else { return nil }
    let (track, localOffset) = item.timeline.trackAndLocalOffset(atGlobalOffset: earliest)
    return track.index == trackIndex ? localOffset : nil
  }

  var appliesToLoadedItem: Bool {
    guard let item = state.item, let itemID = skip.itemID else { return false }
    return item.id == itemID && item.episodeID == skip.episodeID
  }
}

extension PlaybackProgressEvent {
  /// The same event, reporting the range it skipped.
  func reporting(_ range: PlayerSkipRange) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: sequence, itemId: itemId, episodeID: episodeID, phase: phase,
      currentTime: currentTime, listenedDelta: listenedDelta, trimmedDelta: trimmedDelta,
      speedSavedDelta: speedSavedDelta, trimmedSourceDelta: trimmedSourceDelta, endBehavior: endBehavior,
      sleepTimerExpiry: sleepTimerExpiry, skippedRange: range, segmentEnd: segmentEnd)
  }
}
