import AdSkip
import Persistence

/// The audio-gated planner's plan state: the two libraries of prints and plans, the stage-one
/// cache, the stage-two windows a recompute asked for, and the matching counters.
///
/// One object per coordinator, created in its `init` and touched only from the actor, so it is not
/// `Sendable`: one worker's state, never shared.
///
/// Every plan is derived from the set of audio prints, and `invalidateAudioPlans` drops them
/// together: a partial drop would serve stale ranges under a new library.
final class AdSkipPlanBook {
  /// The stores a plan is read from and written to, and the two switches that decide when a plan
  /// may be reused. The stores are the coordinator's own instances.
  struct Dependencies {
    let episodes: AdSkipEpisodeStore
    let transcripts: AdSkipTranscriptFileStore
    let signatures: AdSignatureStore
    /// Debug builds' whole-file mode: every episode is transcribed in full. Never set in release
    /// builds.
    let transcribesWholeFiles: Bool
    /// Whether a change that only adds prints keeps the plans its audio cannot have changed.
    let replansIncrementally: Bool
    /// Whether an episode's language is analysed at all, so the library holds only those prints.
    let isAnalysable: (AdSkipLocalEpisode?) -> Bool
  }

  let dependencies: Dependencies

  /// See `TranscriptCoverage`.
  var transcriptCoverages: [String: TranscriptCoverage] = [:]
  /// See `AudioLibrary`; nil until needed after a change to the set of prints.
  var audioLibrary: AudioLibrary?
  /// Each episode's confirmed matches (`confirmedMatches`), with the print and creatives they
  /// were found against.
  var confirmedReachCache: [AdSkipEpisodeIdentity: ConfirmedReachEntry] = [:]
  /// Stage-1 plans by episode, for the current library.
  var stageOnePlans: [AdSkipEpisodeIdentity: StageOnePlan] = [:]
  /// The last library's plans, kept when its prints changed until the next library is loaded.
  var retainedPlans: RetainedPlans?
  /// Plans the current library kept from the last one, each taken into `stageOnePlans` when its
  /// episode is next planned.
  var carriedStageOnePlans: [AdSkipEpisodeIdentity: StageOnePlan] = [:]
  /// Episodes whose current plan was carried and not yet checked against a full query.
  var uncheckedCarriedPlans: Set<AdSkipEpisodeIdentity> = []
  /// The stage-1 windows each episode last had, to tell a changed plan from a reloaded one.
  var lastStageOne: [AdSkipEpisodeIdentity: [TimeSpan]] = [:]
  /// Stage-2 windows the last recompute asked for, by episode.
  var stageTwoWindows: [AdSkipEpisodeIdentity: [TimeSpan]] = [:]
  /// Stage-2 rounds queued since the episode's stage-1 plan last changed.
  var stageTwoRounds: [AdSkipEpisodeIdentity: Int] = [:]
  /// Episodes whose queued stage-2 round has not reached the transcriber yet. A recompute that
  /// finds such a round still missing leaves it queued without using another: a backlog runs
  /// through several recomputes before the queue reaches its last episodes.
  var stageTwoAwaiting: Set<AdSkipEpisodeIdentity> = []
  /// Whether a recompute has run in this process, and so planned stage 2 for what is stored.
  var hasPlannedStageTwo = false
  /// Stage-1 audio queries run so far, for `AdSkipMatchingMeasuring`.
  var stageOneQueries = 0
  /// Pairwise checks of a kept episode against an added print run so far, likewise.
  var stageOnePairChecks = 0

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }
}
