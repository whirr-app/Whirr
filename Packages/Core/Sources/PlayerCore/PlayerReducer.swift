/// Pure playback state machine and listening-time clock (see ARCHITECTURE.md). No engine calls and
/// no clock reads: every input, including "now", comes from `PlayerController`, so transitions
/// are deterministic and testable without AVFoundation, `async` or real sleeps.
///
/// Listening time is wall-clock time spent `.playing`, never media-position movement. A tick's
/// `listenedDelta` accrues only when the previous phase was `.playing` and the position fits
/// normal forward playback at the current rate; an unexplained jump still updates
/// `state.globalPosition` but adds zero.
public struct PlayerReducer: Sendable {
  public internal(set) var state: PlayerState
  /// Injected playback policy. Kept outside `PlayerState` so a preference change is an input to
  /// the pure reducer rather than an intent or a clock read.
  public var isSmartRewindEnabled: Bool = true

  var generation = 0
  /// The loaded episode's skip ranges (`PlayerReducer+SkipRanges.swift`).
  var skip = SkipRangeState()
  /// The loaded episode's trim map (`PlayerReducer+Trim.swift`).
  var trim = TrimState()
  /// The stretch of the loaded item to stop at the end of (`PlayerReducer+Segment.swift`).
  var segment: PlayerSegment?
  var hasEverPlayedThisItem = false
  var lastCheckpoint: Double
  var sequence = 0

  /// Wall-clock timestamp the sleep timer last accounted for. Separate from `lastCheckpoint`
  /// (which only advances on events that reach `checkpoint()`) because the timer must keep
  /// counting down across steps that don't touch listening-delta accrual.
  var sleepTimerCheckpoint: Double

  /// How far a reported position may drift from `expected = previousPosition + elapsed * rate`
  /// before it is treated as an engine jump rather than normal playback progress.
  private static let jumpTolerance: Double = 0.01

  /// Where a requested seek is heading, held until the engine confirms it landed. While set,
  /// position ticks are suspect: a stream seek takes real time and ticks in that window still
  /// carry the old clock. Not derived from `state.phase`, as a streaming engine flaps into
  /// `.buffering` between request and completion, just when the stale ticks arrive.
  var outstandingSeekTarget: Double?

  /// The supported playback-rate range. `setRate` clamps into it; a non-finite value (NaN or
  /// infinity) is rejected rather than clamped.
  public static let supportedRateRange: ClosedRange<Double> = 0.5...3.0

  /// How close to the item's end a sleep-timer boundary must sit to count as the end of the item
  /// rather than an interior chapter break. Chapter metadata routinely stops a fraction short of
  /// the declared duration; a whole second is far tighter than any real trailing segment.
  static let itemEndBoundaryTolerance: Double = 1.0

  public init(now: Double) {
    self.state = .idle
    self.lastCheckpoint = now
    self.sleepTimerCheckpoint = now
  }

  // MARK: - Intents

  public mutating func handle(_ intent: PlayerIntent, now: Double) -> PlayerStepResult {
    clearSkipLandingFloor(for: intent)
    let result = handleIntent(intent, now: now)
    noteSkipOrigin(for: intent)
    consumeRangeAtListenerMove(for: intent, result: result)
    clearSegmentAtListenerMove(for: intent, result: result)
    return armingSkipBoundary(result)
  }

  private mutating func handleIntent(_ intent: PlayerIntent, now: Double) -> PlayerStepResult {
    // Captured before any handler runs: the sleep timer credits the segment that just ended, so
    // the phase that matters is the one in force during it, not the one this intent installs.
    // Reading it inside `applySleepTimerTick` would drop the final playing segment on `.pause`.
    let wasPlaying = state.phase == .playing
    switch intent {
    case .load(let item, let initialGlobalPosition, let rate, let trimMap):
      resetSkipRanges()
      resetTrim(for: item, map: trimMap)
      segment = segmentSurvivingReload(of: item, at: initialGlobalPosition)
      let result = handleLoad(item: item, initialGlobalPosition: initialGlobalPosition, rate: rate, now: now)
      // A displaced item's sleep timer must not carry over to its replacement.
      state.sleepTimer = .off
      sleepTimerCheckpoint = now
      return PlayerStepResult(
        effects: result.effects + [.setVolume(1.0)], progressEvents: result.progressEvents)
    case .stop:
      let result = handleStop(now: now)
      segment = nil
      state.sleepTimer = .off
      sleepTimerCheckpoint = now
      return PlayerStepResult(
        effects: result.effects + [.setVolume(1.0)], progressEvents: result.progressEvents)
    case .play:
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handlePlay(now: now))
    case .pause:
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handlePause(now: now))
    case .toggle:
      return applySleepTimerTick(
        now: now, wasPlaying: wasPlaying,
        to: state.isPlaybackIntended ? handlePause(now: now) : handlePlay(now: now))
    case .seek(let target):
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handleSeek(toGlobalOffset: target, now: now))
    case .skip(let delta):
      return applySleepTimerTick(
        now: now, wasPlaying: wasPlaying,
        to: skipToSegmentEnd(by: delta, now: now) ?? handleSkip(by: delta, now: now))
    case .retry:
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handleRetry(now: now))
    case .setRate(let rate):
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handleSetRate(rate, now: now))
    case .selectChapter(let chapter):
      return applySleepTimerTick(
        now: now, wasPlaying: wasPlaying, to: handleSeek(toGlobalOffset: chapter.start, now: now))
    case .previousChapter:
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handlePreviousChapter(now: now))
    case .nextChapter:
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handleNextChapter(now: now))
    case .setSleepTimer(let duration):
      return handleSetSleepTimer(duration, now: now)
    case .extendSleepTimer(let seconds):
      let tick = applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: .none)
      let extensionResult = handleExtendSleepTimer(by: seconds, now: now)
      // The tick can emit the current fade before the extension restores full volume. The later
      // restore wins when the caller applies the effects in order.
      return PlayerStepResult(
        effects: tick.effects + extensionResult.effects,
        progressEvents: tick.progressEvents + extensionResult.progressEvents)
    case .setSkipRanges(let itemID, let episodeID, let ranges):
      return applySleepTimerTick(
        now: now, wasPlaying: wasPlaying,
        to: handleSetSkipRanges(itemID: itemID, episodeID: episodeID, ranges: ranges, now: now))
    case .undoSkip(let range):
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: handleUndoSkip(range, now: now))
    case .setTrimMap(let itemID, let episodeID, let map):
      return applySleepTimerTick(
        now: now, wasPlaying: wasPlaying,
        to: handleSetTrimMap(itemID: itemID, episodeID: episodeID, map: map, now: now))
    case .setSegment(let start, let end):
      handleSetSegment(start: start, end: end)
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: .none)
    case .clearSegment:
      segment = nil
      return applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: .none)
    }
  }

  private mutating func handleSetRate(_ rate: Double, now: Double) -> PlayerStepResult {
    guard rate.isFinite else { return .none }
    let clamped = min(max(rate, Self.supportedRateRange.lowerBound), Self.supportedRateRange.upperBound)
    var progressEvents: [PlaybackProgressEvent] = []
    if let event = checkpoint(now: now) { progressEvents.append(event) }
    state.rate = clamped
    return PlayerStepResult(effects: [.setRate(clamped)], progressEvents: progressEvents)
  }

  private mutating func handleLoad(item: PlayerItem, initialGlobalPosition: Double, rate: Double, now: Double)
    -> PlayerStepResult
  {
    // Flush any credit still accruing under whatever was active before this load displaces it.
    var events: [PlaybackProgressEvent] = []
    if let flush = checkpoint(now: now) { events.append(flush) }

    generation += 1
    hasEverPlayedThisItem = false

    let clamped = trimSnapped(min(max(initialGlobalPosition, 0), item.timeline.totalDuration), in: item)
    // A load positions the engine by seeking, as `handleSeek` does (the offset rides on
    // `.loadEngine` and the adapter resolves it asynchronously), so its ticks are suspect for the
    // same window. The periodic observer reports the item's pre-seek clock of zero as soon as
    // playback is requested, and adopting that tick would move the playhead to zero and sync a
    // zero progress tick. A load that starts at the beginning has nothing to wait for.
    outstandingSeekTarget = clamped > 0 ? clamped : nil
    let (track, localOffset) = item.timeline.trackAndLocalOffset(atGlobalOffset: clamped)
    state = PlayerState(
      phase: .preparing, item: item, currentTrackIndex: track.index, globalPosition: clamped, rate: rate)
    lastCheckpoint = now
    sequence += 1
    events.append(
      PlaybackProgressEvent(
        sequence: sequence, itemId: item.id, episodeID: item.episodeID, phase: .preparing,
        currentTime: clamped, listenedDelta: 0))

    return PlayerStepResult(
      effects: [
        .loadEngine(
          track: track, localOffset: localOffset, rate: rate, generation: generation, trim: trimMap(for: item))
      ],
      progressEvents: events)
  }

  private mutating func handleStop(now: Double) -> PlayerStepResult {
    guard let item = state.item else { return .none }
    let elapsed = max(0, now - lastCheckpoint)
    let credited = state.phase == .playing ? elapsed : 0

    generation += 1
    hasEverPlayedThisItem = false
    outstandingSeekTarget = nil
    let finalPosition = state.globalPosition
    sequence += 1
    let event = PlaybackProgressEvent(
      sequence: sequence, itemId: item.id, episodeID: item.episodeID, phase: .idle,
      currentTime: finalPosition, listenedDelta: credited, speedSavedDelta: speedSaved(over: credited))

    state = .idle
    lastCheckpoint = now
    return PlayerStepResult(effects: [.stop], progressEvents: [event])
  }

  /// Retry is legal only from `.failed`: it reloads the existing engine
  /// resource, which cannot re-establish a server session after a stream stall. A stalled item
  /// needs a fresh preparation owned by `PlaybackModel` instead.
  private mutating func handleRetry(now: Double) -> PlayerStepResult {
    guard case .failed(let failure) = state.phase, failure.isRecoverable else { return .none }
    guard let item = state.item else { return .none }

    let (track, localOffset) = item.timeline.trackAndLocalOffset(atGlobalOffset: state.globalPosition)
    generation += 1
    state.currentTrackIndex = track.index
    outstandingSeekTarget = nil
    guard let event = checkpoint(now: now, newPhase: .preparing) else { return .none }
    return PlayerStepResult(
      effects: [
        .loadEngine(
          track: track, localOffset: localOffset, rate: state.rate, generation: generation, trim: activeTrimMap)
      ],
      progressEvents: [event])
  }

  // MARK: - Shared helpers

  /// Credits elapsed wall time to `listenedDelta` only when the phase before this checkpoint was
  /// `.playing` and any supplied position fits normal forward playback at the current rate
  /// (`Self.jumpTolerance`). `newPhase` and `positionUpdate` apply afterwards, so credit reflects
  /// the interval that just ended. Returns nil when no item is loaded to attribute the tick to.
  ///
  /// With a trim map the expected position is predicted through it: playing across a cut also
  /// moves source time by the cut, which is normal playback, not a jump. A credited tick reports
  /// the cut seconds crossed, as wall time, in `trimmedDelta`. The reported position is
  /// `reportedPosition`, not the playhead.
  @discardableResult
  mutating func checkpoint(now: Double, newPhase: PlayerPhase? = nil, positionUpdate: Double? = nil)
    -> PlaybackProgressEvent?
  {
    guard let item = state.item else { return nil }
    let elapsed = max(0, now - lastCheckpoint)
    var credited: Double = 0
    var trimmed: Double = 0
    var trimmedSource: Double = 0
    if state.phase == .playing {
      if let positionUpdate {
        let advance = elapsed * state.rate
        let map = activeTrimMap
        let expected =
          map?.sourceTime(advancing: advance, from: state.globalPosition) ?? state.globalPosition + advance
        let isNormalPlayback = abs(positionUpdate - expected) <= Self.jumpTolerance
        credited = isNormalPlayback ? elapsed : 0
        if isNormalPlayback, let map, state.rate > 0 {
          trimmedSource = map.trimmedSeconds(from: state.globalPosition, to: positionUpdate)
          trimmed = trimmedSource / state.rate
        }
      } else {
        credited = elapsed
      }
    }

    if let positionUpdate { state.globalPosition = positionUpdate }
    if let newPhase { state.phase = newPhase }
    lastCheckpoint = now
    sequence += 1

    return PlaybackProgressEvent(
      sequence: sequence, itemId: item.id, episodeID: item.episodeID, phase: state.phase,
      currentTime: reportedPosition, listenedDelta: credited, trimmedDelta: trimmed,
      speedSavedDelta: speedSaved(over: credited), trimmedSourceDelta: trimmedSource)
  }

  /// What `credited` wall seconds at the current rate saved against 1×. `.load` adopts its rate
  /// unclamped, so the rate is held to the supported range here; slower than 1× saves nothing.
  func speedSaved(over credited: Double) -> Double {
    let rate = min(max(state.rate, Self.supportedRateRange.lowerBound), Self.supportedRateRange.upperBound)
    return credited * max(0, rate - 1)
  }
}
