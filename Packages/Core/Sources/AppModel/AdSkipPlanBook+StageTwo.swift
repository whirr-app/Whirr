import AdSkip
import Persistence

/// Stage 2: the windows a row's kept ranges and phrase starts ask to hear, and the rounds an
/// episode may queue before it settles on what it has. The queue's pass is the caller's to ask
/// for: the book never touches the queue.
extension AdSkipPlanBook {
  /// Stage-2 rounds an episode may queue before it settles without them.
  static let stageTwoRoundLimit = 2

  /// Records the stage-2 windows the row's kept ranges and anchors ask for. Returns true when the
  /// caller should run another pass, which only the queue may. A nil `stageOne` asks for nothing:
  /// its row is transcribed in full. A row that has queued its rounds settles on what it has.
  func planStageTwo(
    for row: AdSkipEpisodeRecord, stageOne: [TimeSpan]?, views: TranscriptViews,
    keptStarts: [Double], anchors: [Double], stingEnds: [Double]
  ) -> Bool {
    let duration = views.covered.transcript.duration
    guard stageOne != nil else { return false }
    let identity = row.identity
    let stageTwo = TranscriptionWindows.clamped(
      TranscriptionWindows.stageTwo(keptStarts: keptStarts, anchors: anchors, stingEnds: stingEnds),
      duration: duration)
    var wantsPass = false
    if TranscriptionWindows.missing(stageTwo, covered: views.coverage).isEmpty {
      stageTwoWindows[identity] = stageTwo
    } else if stageTwoAwaiting.contains(identity) {
      stageTwoWindows[identity] = stageTwo
    } else if (stageTwoRounds[identity] ?? 0) < Self.stageTwoRoundLimit {
      stageTwoRounds[identity, default: 0] += 1
      stageTwoAwaiting.insert(identity)
      stageTwoWindows[identity] = stageTwo
      wantsPass = true
    } else {
      stageTwoWindows[identity] = []
    }
    return wantsPass
  }

  /// Whether every second the row wants is covered, from the windows `planStageTwo` recorded: the
  /// whole file for a row with no stage-1 plan, else its stage 1 and its stage 2. Read after the
  /// caller's pass request, where the one function used to read it.
  func isSettled(
    for row: AdSkipEpisodeRecord, stageOne: [TimeSpan]?, views: TranscriptViews
  ) -> Bool {
    let duration = views.covered.transcript.duration
    guard let stageOne else {
      return TranscriptionWindows.missing(
        [TimeSpan(start: 0, end: duration)], covered: views.coverage
      ).isEmpty
    }
    let wanted = TranscriptionWindows.clamped(
      stageOne + (stageTwoWindows[row.identity] ?? []), duration: duration)
    return TranscriptionWindows.missing(wanted, covered: views.coverage).isEmpty
  }

  /// Forgets every stage-1 and stage-2 fact about `identities`, whose rows are gone: their last
  /// plan, their stage-2 windows and rounds, and their awaiting flag.
  func forget(_ identities: Set<AdSkipEpisodeIdentity>) {
    for identity in identities {
      stageTwoWindows[identity] = nil
      stageTwoRounds[identity] = nil
      stageTwoAwaiting.remove(identity)
      lastStageOne[identity] = nil
    }
  }
}
