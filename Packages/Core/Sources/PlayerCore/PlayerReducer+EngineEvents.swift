extension PlayerReducer {
  /// How far an engine-reported position may sit from a seek target and still read as that seek
  /// landing, not the pre-seek clock still ticking. Wider than `AVPlayer`'s seek imprecision (it
  /// settles on a nearby sync sample) and far narrower than a scrubber drag, which is how far off
  /// a stale tick is. A short seek misread against a stale tick self-corrects next tick; a long
  /// one cannot.
  private static let seekLandingTolerance: Double = 15

  /// How far behind a seek target a landing may sit and still read as landing where aimed, not
  /// as drift. `CMTime`'s 1/600s timescale rounds a target to the nearest tick, usually just
  /// below it, and AVFoundation reports that immediately. At a chapter start (`PlaybackChapterMap`
  /// gives the shared boundary to the later chapter) a landing a third of a millisecond short
  /// reads as the previous chapter, with its scrubber full, until the next tick. An order of
  /// magnitude wider than the rounding, far narrower than perceptible drift.
  private static let seekLandingEpsilon: Double = 0.05

  public mutating func handle(_ event: AudioEngineEvent, now: Double) -> PlayerStepResult {
    let wasPlaying = state.phase == .playing
    guard isStaleSkipLanding(event) == false else {
      return armingSkipBoundary(applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: .none))
    }
    let previousPosition = state.globalPosition
    let result = applySkipRule(
      to: handleEngineEvent(event, now: now), event: event, from: previousPosition, now: now)
    return armingSkipBoundary(applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: result))
  }

  /// Turns an expired wait (preparing, buffering, or seeking) into a terminal reducer input.
  /// Entering `.stalled` clears playback intent and pauses the engine, so recovery stays an
  /// explicit action. The sleep timer is advanced through this input too, crediting the playback
  /// that preceded the stall, but a stall then freezes it like any other exit from `.playing`.
  public mutating func handleStallTimeout(now: Double) -> PlayerStepResult {
    let wasPlaying = state.phase == .playing
    let result: PlayerStepResult
    // The controller arms only a streamed item being waited on; the reducer keeps the invariant
    // at its input so a late timeout never marks a local or paused item as a network stall.
    // Mirrors `PlayerController.awaitingAudioPhase`: `.preparing` and `.seeking` count with
    // `.buffering` because an item that never reports readiness never reaches `.buffering`, the
    // freeze this deadline breaks.
    let isWaitingOnAudio: Bool
    switch state.phase {
    case .preparing, .buffering, .seeking: isWaitingOnAudio = true
    default: isWaitingOnAudio = false
    }
    if isWaitingOnAudio, state.isPlaybackIntended, state.item?.isStreaming == true,
      let event = checkpoint(now: now, newPhase: .stalled)
    {
      state.isPlaybackIntended = false
      result = PlayerStepResult(effects: [.pause], progressEvents: [event])
    } else {
      result = .none
    }
    return armingSkipBoundary(applySleepTimerTick(now: now, wasPlaying: wasPlaying, to: result))
  }

  /// The sleep timer must keep advancing on every engine event that reaches this reducer while
  /// audio plays, including in the background: periodic `positionUpdated` ticks from the running
  /// engine are what let it expire without a wall-clock timer of PlayerCore's own.
  /// `handle(_:AudioEngineEvent:now:)` above wraps every branch below, including the early `.none`
  /// returns for stale or unrecognised events, which still represent real elapsed playback.
  private mutating func handleEngineEvent(_ event: AudioEngineEvent, now: Double) -> PlayerStepResult {
    switch event {
    case .ready(let gen):
      guard isCurrent(gen) else { return .none }
      return resolveReady(now: now)

    case .buffering(let gen):
      guard isCurrent(gen) else { return .none }
      // A late buffering notification cannot overwrite a terminal stall: the adapter may emit
      // callbacks already enqueued when the deadline fired. Only `.ready` proves recovery.
      guard state.phase != .stalled else { return .none }
      guard let event = checkpoint(now: now, newPhase: .buffering) else { return .none }
      return PlayerStepResult(progressEvents: [event])

    case .durationObserved(let gen, let localDuration):
      guard isCurrent(gen) else { return .none }
      applyObservedExtent(localDuration)
      return .none

    case .positionUpdated(let gen, let localOffset):
      guard isCurrent(gen), state.currentTrackIndex != nil else { return .none }
      // Before the timeline can clamp it away. An offset past the declared duration means the
      // audio is longer than the manifest claimed.
      applyObservedExtent(localOffset)
      guard let item = state.item, let trackIndex = state.currentTrackIndex,
        let global = item.timeline.globalOffset(forTrackIndex: trackIndex, localOffset: localOffset)
      else { return .none }
      // A seek in flight makes every tick suspect, whatever phase the engine has flapped into:
      // only a tick that has reached the target can be reporting from after the seek. The rest
      // are the position the listener dragged away from, and adopting one would put it straight
      // back. A seek the ticks never confirm is still ended by `.ready` from the adapter's
      // seek-completion handler, so nothing waits on this forever.
      var reported = global
      if let target = outstandingSeekTarget {
        guard abs(reported - target) <= Self.seekLandingTolerance else { return .none }
        outstandingSeekTarget = nil
        // The seek landed; keep the position it was aimed at rather than the engine's rounding of
        // it (`Self.seekLandingEpsilon`). Only an undershoot is corrected: an overshoot belongs
        // to whatever the target belongs to, and a landing further back than the epsilon is real
        // drift the listener has to be shown.
        if reported < target, target - reported <= Self.seekLandingEpsilon { reported = target }
      }
      if state.phase == .seeking {
        return resolveReady(now: now, positionUpdate: reported)
      }
      // Position observers can tick with a frozen value while the engine is still waiting. That
      // is not evidence of recovery, so checkpointing leaves `.stalled` unchanged; only `.ready`
      // below may clear it.
      guard let progress = checkpoint(now: now, positionUpdate: reported) else { return .none }
      // A tick while the reducer considers itself paused means the engine is still delivering
      // periodic callbacks after playback stopped (the on-device runaway that pegged a core, with
      // `phase=paused` ticks streaming at a frozen position). The reducer is the authority on
      // intent, so re-assert `.pause` to stop the ticking at the source. The first corrective
      // tick clears the adapter's `isPlaybackRequested`, so the flood ends rather than sustains.
      let corrective: [PlayerEffect] = state.phase == .paused ? [.pause] : []
      return PlayerStepResult(effects: corrective, progressEvents: [progress])

    case .trackFinished(let gen):
      guard isCurrent(gen), let item = state.item, let trackIndex = state.currentTrackIndex else { return .none }
      guard isEndOfTrackStale(item: item, trackIndex: trackIndex) == false else { return .none }
      if let nextIndex = nextTrackIndex(after: trackIndex, in: item.timeline),
        let nextTrack = item.timeline.tracks.first(where: { $0.index == nextIndex })
      {
        // A chapter that is its own file ends here. Loading the next file would play the next
        // chapter until its first tick.
        if segmentEnds(atStartOfTrack: nextIndex, in: item) { return reachSegmentEnd(now: now) }
        guard let flush = checkpoint(now: now) else { return .none }
        generation += 1
        state.currentTrackIndex = nextIndex
        state.phase = .preparing
        lastCheckpoint = now
        sequence += 1
        let loadEvent = PlaybackProgressEvent(
          sequence: sequence, itemId: item.id, episodeID: item.episodeID, phase: .preparing,
          currentTime: state.globalPosition, listenedDelta: 0)
        return PlayerStepResult(
          effects: [
            .loadEngine(
              track: nextTrack, localOffset: 0, rate: state.rate, generation: generation, trim: activeTrimMap)
          ],
          progressEvents: [flush, loadEvent])
      }
      state.isPlaybackIntended = false
      // The timeline, not the final engine callback, is authoritative at natural end. Snap state
      // before checkpointing so the event carries the true end position, but don't pass it as
      // `positionUpdate`: it is a known completion boundary, not an engine jump, and checkpoint
      // must credit the final elapsed interval normally.
      state.globalPosition = item.timeline.totalDuration
      guard let event = checkpoint(now: now, newPhase: .ended) else { return .none }
      return PlayerStepResult(progressEvents: [event])

    case .failed(let gen, let failure):
      guard isCurrent(gen) else { return .none }
      guard let event = checkpoint(now: now, newPhase: .failed(failure)) else { return .none }
      return PlayerStepResult(progressEvents: [event])

    case .trimDeclined(let gen):
      guard isCurrent(gen) else { return .none }
      return handleTrimDeclined()
    }
  }

  private func isCurrent(_ gen: Int) -> Bool {
    gen == generation && state.phase != .ended
  }

  private mutating func resolveReady(now: Double, positionUpdate: Double? = nil) -> PlayerStepResult {
    // `.ready` is the engine's positive recovery signal, including after `.stalled`; resolving it
    // through the ordinary intent-aware path leaves a recovered stalled item paused until a fresh
    // preparation accepts a new play intent.
    // The engine has confirmed where it is, so no seek is outstanding: the adapter emits `.ready`
    // from its seek-completion handler to say so.
    outstandingSeekTarget = nil
    let intended = state.isPlaybackIntended
    let newPhase: PlayerPhase = intended ? .playing : (hasEverPlayedThisItem ? .paused : .ready)
    guard let event = checkpoint(now: now, newPhase: newPhase, positionUpdate: positionUpdate) else {
      return .none
    }
    // Re-assert the current intent against the engine either way (once the item has played): a
    // pause taken during buffering/seeking must land again here, because the engine may have been
    // mid-play when it arrived and some players resume on their own after a stall.
    let effects: [PlayerEffect] = intended ? [.play] : (hasEverPlayedThisItem ? [.pause] : [])
    return PlayerStepResult(effects: effects, progressEvents: [event])
  }

  /// An end-of-track report is stale when a seek into the same track is outstanding: the engine
  /// reached the end before being told to move. A same-track seek keeps the generation, so
  /// `isCurrent` cannot catch it. It happens when a finished item is restarted (`load` places it at
  /// its end) and a position is picked before the end-of-item callback arrives; completing then
  /// would leave the reducer `.ended` and deaf to events while the engine played on. Seeks use
  /// zero tolerance, so a target short of the end never legitimately finishes the track.
  private func isEndOfTrackStale(item: PlayerItem, trackIndex: Int) -> Bool {
    // `globalOffset` clamps the local offset to the track's own duration, so this is its end.
    guard let target = outstandingSeekTarget,
      let trackEnd = item.timeline.globalOffset(forTrackIndex: trackIndex, localOffset: .infinity)
    else { return false }
    return target < trackEnd - Self.itemEndBoundaryTolerance
  }

  private func nextTrackIndex(after currentIndex: Int, in timeline: PlaybackTimeline) -> Int? {
    guard let position = timeline.tracks.firstIndex(where: { $0.index == currentIndex }) else { return nil }
    let nextPosition = position + 1
    guard nextPosition < timeline.tracks.count else { return nil }
    return timeline.tracks[nextPosition].index
  }

  /// Extends the loaded track when the engine reports the audio running past its declared duration.
  ///
  /// An under-running declared duration is routine for podcast feed metadata. `PlaybackTimeline`
  /// clamps reported positions to it, so without this the playhead freezes at a false end,
  /// remaining time reads zero while audio plays, and a skip forward lands back at the surplus
  /// audio's start, restarting an injected advert.
  ///
  /// When an observation counts is `PlaybackTimeline.grown(toObservedLocalExtent:)`, shared with
  /// `WatchAudioEngine`. Only the reducer knows that an `.ended` item takes no further correction
  /// and that a sleep-timer boundary pinned at the old end must follow the new one.
  private mutating func applyObservedExtent(_ localDuration: Double) {
    guard let item = state.item, state.phase != .ended else { return }
    guard let grown = item.timeline.grown(toObservedLocalExtent: localDuration) else { return }

    let previousEnd = item.timeline.totalDuration
    state.item = PlayerItem(
      id: item.id, episodeID: item.episodeID, timeline: grown, chapters: item.chapters,
      isStreaming: item.isStreaming)
    repinSleepTimerAtItemEnd(movedFrom: previousEnd, to: grown.totalDuration)
  }
}
