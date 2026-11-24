import AdSkip
import CoreSupport
import Foundation
import Persistence

/// Analyses downloaded podcast episodes for inserted ads and keeps their skip ranges current
///
/// One worker does every database and file mutation, so analysis, removal, recompute and cleanup
/// never interleave. Inputs (the setting, whether analysis is allowed, the local episode files)
/// only record state and wake the worker; one that invalidates the episode being transcribed
/// cancels it. Removal follows the local-episode set, derived from the download tables, so every
/// purge path, account removal and the launch integrity sweeps reach it without a hook.
public actor AdSkipCoordinator {
  public struct Dependencies: Sendable {
    public var episodes: AdSkipEpisodeStore
    public var signatures: AdSignatureStore
    public var transcripts: AdSkipTranscriptFileStore
    public var transcriber: any EpisodeTranscribing
    public var audioPrinter: any AudioPrinting
    public var scorer: any AdStepScoring
    public var fingerprinting: any AdSkipFileFingerprinting
    /// The app's transcriber adapter version, speech asset version and OS build. A change
    /// retries failed episodes; it does not invalidate stored transcripts.
    public var transcriberRevision: String
    /// Debug builds' whole-file mode: every episode is transcribed in full, as before audio gating,
    /// so the two can be measured on one phone. Never set in release builds.
    public var transcribesWholeFiles: Bool
    /// Debug builds' matching measurement. Nil in release builds.
    public var matchingMeasurement: (any AdSkipMatchingMeasuring)?
    /// Whether a change that only adds prints re-queries just the episodes whose audio recurs in
    /// what was added, keeping every other plan. Off, every change to the prints replans the
    /// whole library.
    public var replansIncrementally: Bool
    /// The listener's own transcripts, for host-read spots. Nil where there are none to read.
    public var listenerTranscripts: (any CompleteEpisodeTranscriptReading)?
    public var now: @Sendable () -> Date

    public init(
      episodes: AdSkipEpisodeStore, signatures: AdSignatureStore,
      transcripts: AdSkipTranscriptFileStore, transcriber: any EpisodeTranscribing,
      audioPrinter: any AudioPrinting, scorer: any AdStepScoring,
      fingerprinting: any AdSkipFileFingerprinting = FileSystemAdSkipFingerprinting(),
      transcriberRevision: String, transcribesWholeFiles: Bool = false,
      matchingMeasurement: (any AdSkipMatchingMeasuring)? = nil, replansIncrementally: Bool = true,
      listenerTranscripts: (any CompleteEpisodeTranscriptReading)? = nil,
      now: @escaping @Sendable () -> Date = Date.init
    ) {
      self.episodes = episodes
      self.signatures = signatures
      self.transcripts = transcripts
      self.transcriber = transcriber
      self.audioPrinter = audioPrinter
      self.scorer = scorer
      self.fingerprinting = fingerprinting
      self.transcriberRevision = transcriberRevision
      self.transcribesWholeFiles = transcribesWholeFiles
      self.matchingMeasurement = matchingMeasurement
      self.replansIncrementally = replansIncrementally
      self.listenerTranscripts = listenerTranscripts
      self.now = now
    }
  }

  /// Transcriptions between library recomputes while a backlog drains. A recompute reads every
  /// stored transcript, so running one per episode would make a large first backlog quadratic.
  static let analysesPerRecompute = 5

  static let log = CoreLogging.logger(category: "AdSkip")

  let dependencies: Dependencies

  /// The audio-gated plan state, reached only from this actor. See `AdSkipPlanBook`.
  let plans: AdSkipPlanBook

  private(set) var isEnabled: Bool? {
    didSet { noteActivityChange() }
  }
  private(set) var isAllowed = false {
    didSet { noteActivityChange() }
  }
  /// `isAllowed` starts false before its stream has spoken; this tells the two apart.
  private(set) var hasAllowedSignal = false {
    didSet { noteActivityChange() }
  }
  /// Set when the transcriber reported that analysis cannot run yet; cleared when the allowed
  /// signal next turns on.
  var isDeferred = false {
    didSet { noteActivityChange() }
  }
  /// The episode whose unit last ran, kept through the replan and recompute that follow it until
  /// another episode's unit starts, analysis is held, or the worker goes idle.
  var underAnalysis: AdSkipEpisodeIdentity? {
    didSet { noteActivityChange() }
  }
  /// The analysis conditions with the charging rule left out: Low Power Mode and heat still hold.
  private(set) var priorityConditionsAllowed = false {
    didSet { noteActivityChange() }
  }
  /// The listener's Check Now for the loaded episode: analyse it alone
  /// while analysis is otherwise held for charging. Cleared when the priority changes or the
  /// episode is analysed.
  var grantedPriority: AdSkipEpisodeIdentity? {
    didSet { noteActivityChange() }
  }
  /// The settle between the live state and what the glyph and the status read, reached only from
  /// this actor. See `AdSkipActivityPublisher`.
  let activity: AdSkipActivityPublisher
  /// The two streams the settled state is published to, kept here because the `nonisolated`
  /// accessors reading them cannot reach the publisher.
  let activityChanges: LatestValueBroadcaster<AdSkipAnalysisActivity>
  let statusChanges: SkipRangeChangeBroadcaster
  /// Whether the queue last held work, decodes or windows on any row. Kept while analysis is held
  /// back, when the queue is not read, so the wait is shown as a pause rather than as done.
  var hasQueuedWork = false
  private(set) var localEpisodes: [AdSkipEpisodeIdentity: AdSkipLocalEpisode]?
  private(set) var priority: AdSkipEpisodeIdentity? {
    didSet { noteActivityChange() }
  }
  /// Episodes whose file, or whose transcript straight after it was rewritten, could not be read;
  /// cleared when the local set changes.
  var unreadableFiles: Set<AdSkipEpisodeIdentity> = []
  /// Episodes re-analysed because their transcript could not be read. A second failure waits for
  /// the local set to change rather than transcribing again and again.
  var rereadTranscripts: Set<AdSkipEpisodeIdentity> = []

  var inFlight: (identity: AdSkipEpisodeIdentity, task: Task<WorkOutcome, Error>)?
  var hasSweptFiles = false
  /// Whether this process has taught the marks an earlier teaching revision left (`reteachMarks`).
  var hasRetaughtMarks = false
  var isForgetPending = false
  var isRestoreNoticePending = false
  /// Undos from the player, applied by the worker before anything else.
  var pendingUndos: [PendingUndo] = []
  /// Listener marks waiting for the worker (`markAd`).
  var pendingMarks: [PendingMark] = []
  /// Marks removed so far, so a recompute that was running meanwhile can tell its ranges are stale.
  var listenerMarkRemovals = 0
  /// The episode groups the last recompute formed, which a mark teaches as its teachers. A rerun
  /// grouped by its words is known only from a recompute.
  var lastEpisodeGroups: EpisodeGroups?
  let rangeChanges = SkipRangeChangeBroadcaster()
  let progressChanges = LatestValueBroadcaster<AdSkipProgress>()
  var isRecomputePending = false {
    // Any other reason a recompute is owed, set anywhere, makes it more than decodes.
    didSet { isRecomputeOwedOnlyToDecodes = false }
  }
  /// True while the pending recompute is owed only to decodes stored since the last one. Ranges
  /// for already-analysed rows cannot have changed then, so a transcription need not wait for it.
  var isRecomputeOwedOnlyToDecodes = false
  /// True while the pending recompute is one the listener asked for, an Undo or Forget Learned
  /// Ads: it runs whatever the power state, where any other waits until analysis is allowed.
  var isListenerRecomputeOwed = false
  var analysesSinceRecompute = 0
  /// P(ad) by step index, keyed by transcript file name. Steps come from the covered view, which a
  /// file fixes: new words or coverage are always a new file, and a file name is never reused. The
  /// model is fixed per rules revision, so an entry stays valid until its transcript is gone.
  var scoreCache: [String: [Int: Double]] = [:]
  /// See `HostReadScores`: by episode, replaced when its listener transcript's file changes.
  var hostReadScores: [AdSkipEpisodeIdentity: HostReadScores] = [:]
  /// Episodes whose listener transcript completed or went away since their host reads were set.
  var pendingHostReads: Set<AdSkipEpisodeIdentity> = []

  private var inputWaiters: [CheckedContinuation<Void, Never>] = []

  /// Progress is published after every pass and the carried-plan check runs once the queue is
  /// otherwise empty, which is why those two are hooks here rather than parts of `reconcile`.
  lazy var queue = SerialAnalysisQueue(
    hooks: .init(
      pass: { [weak self] in try await self?.reconcile() },
      passDidRun: { [weak self] in await self?.publishProgress() },
      idle: { [weak self] in await self?.checkCarriedPlans() },
      willIdle: { [weak self] in await self?.placementEnded() }),
    reporting: .init(
      cancelled: {
        // The setting went off or analysis was held mid-recompute; it stays pending until the
        // setting is back on and analysis is allowed.
        Self.log.debug("Ad-skip pass cancelled")
      },
      failed: {
        // A database or file error: nothing is retried until the next input, so a persistent
        // fault cannot spin. Only the error's type is logged; never a name or content.
        Self.log.error("Ad-skip pass failed: \(String(describing: type(of: $0)), privacy: .public)")
      }))

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
    // Through locals, because the two broadcasters must exist before the publisher, and a `self`
    // property cannot be read until every stored property has a value.
    let activityChanges = LatestValueBroadcaster<AdSkipAnalysisActivity>()
    let statusChanges = SkipRangeChangeBroadcaster()
    self.activityChanges = activityChanges
    self.statusChanges = statusChanges
    activity = AdSkipActivityPublisher(
      activityChanges: activityChanges, statusChanges: statusChanges)
    plans = AdSkipPlanBook(
      dependencies: .init(
        episodes: dependencies.episodes, transcripts: dependencies.transcripts,
        signatures: dependencies.signatures,
        transcribesWholeFiles: dependencies.transcribesWholeFiles,
        replansIncrementally: dependencies.replansIncrementally,
        isAnalysable: Self.isAnalysable))
  }

  /// The worker has nothing left: no episode is shown as under analysis.
  private func placementEnded() {
    underAnalysis = nil
  }

  // MARK: - Inputs

  /// Feeds the inputs from their streams until `stop()`. Idempotent. `priorityConditions` is the
  /// analysis conditions without the charging rule, which Check Now runs under.
  public func start(
    localEpisodes: AsyncStream<[AdSkipLocalEpisode]>, isEnabled: AsyncStream<Bool>,
    isAllowed: AsyncStream<Bool>, priorityConditions: AsyncStream<Bool>? = nil
  ) async {
    let reader = dependencies.listenerTranscripts
    _ = await queue.installFeeders {
      var feeders: [Task<Void, Never>] = []
      if let priorityConditions {
        feeders.append(
          Task { [weak self] in
            for await allowed in priorityConditions {
              await self?.setPriorityConditionsAllowed(allowed)
            }
          })
      }
      if let reader {
        feeders.append(
          Task { [weak self] in
            for await identity in await reader.completeTranscriptChanges() {
              await self?.noteCompleteTranscriptChange(identity)
            }
          })
      }
      feeders += [
        Task { [weak self] in
          for await episodes in localEpisodes { await self?.setLocalEpisodes(episodes) }
        },
        Task { [weak self] in
          for await enabled in isEnabled { await self?.setEnabled(enabled) }
        },
        Task { [weak self] in
          for await allowed in isAllowed { await self?.setAllowed(allowed) }
        },
      ]
      return feeders
    }
  }

  /// Ends the coordinator for good: inputs are still recorded, but no pass runs again.
  public func stop() async {
    await queue.stop()
    inFlight?.task.cancel()
    grantedPriority = nil
    underAnalysis = nil
    await resumeInputWaitersIfReady()
  }

  public func setEnabled(_ enabled: Bool) async {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    await resumeInputWaitersIfReady()
    if enabled == false {
      inFlight?.task.cancel()
      grantedPriority = nil
      underAnalysis = nil
      pendingMarks = []
    }
    // The player asks again: none while off, the kept ranges once back on.
    rangeChanges.signal()
    await wake()
  }

  /// False on battery (unless the listener allows it), under Low Power Mode, serious thermal
  /// state, or before the speech asset is installed.
  public func setAllowed(_ allowed: Bool) async {
    if allowed { isDeferred = false }
    if hasAllowedSignal == false {
      hasAllowedSignal = true
      await resumeInputWaitersIfReady()
    }
    guard allowed != isAllowed else {
      await wake()
      return
    }
    isAllowed = allowed
    // A move to battery leaves a Check Now running: that is what the listener asked for.
    if allowed == false, let inFlight, isGrantedUnit(inFlight.identity) == false {
      inFlight.task.cancel()
      underAnalysis = nil
    }
    await wake()
  }

  /// The conditions with the charging rule left out. Turning false stops a
  /// Check Now that analysis is not otherwise allowed to run.
  public func setPriorityConditionsAllowed(_ allowed: Bool) async {
    guard allowed != priorityConditionsAllowed else { return }
    priorityConditionsAllowed = allowed
    if allowed == false, isAllowed == false, let inFlight {
      inFlight.task.cancel()
      underAnalysis = nil
    }
    await wake()
  }

  /// The overnight task's time is up: stop everything, Check Now included, so the process is not
  /// suspended mid-transcription, where an interrupted episode could be recorded as failed.
  public func suspendForExpiry() async {
    grantedPriority = nil
    // A recompute the listener asked for stops as well, and waits as any other does.
    isListenerRecomputeOwed = false
    await setAllowed(false)
    inFlight?.task.cancel()
    underAnalysis = nil
  }

  /// Whether Check Now lets the priority episode run while analysis is otherwise held.
  var isGrantActive: Bool {
    priorityConditionsAllowed && grantedPriority != nil && grantedPriority == priority
  }

  private func isGrantedUnit(_ identity: AdSkipEpisodeIdentity) -> Bool {
    isGrantActive && identity == grantedPriority
  }

  public func setLocalEpisodes(_ episodes: [AdSkipLocalEpisode]) async {
    let byIdentity = Dictionary(episodes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    guard byIdentity != localEpisodes else { return }
    localEpisodes = byIdentity
    await resumeInputWaitersIfReady()
    unreadableFiles = []
    if let inFlight, Self.isAnalysable(byIdentity[inFlight.identity]) == false {
      inFlight.task.cancel()
    }
    if let underAnalysis, Self.isAnalysable(byIdentity[underAnalysis]) == false {
      self.underAnalysis = nil
    }
    // A changed link set changes which tiles the activity names.
    noteActivityChange()
    // The player asks again: an ask before the episodes arrived, as at launch, when the setting
    // is read at once and the downloads come later from the database, was answered empty.
    rangeChanges.signal()
    await wake()
  }

  /// The episode loaded in the player is analysed first when it has not been yet.
  public func prioritize(_ identity: AdSkipEpisodeIdentity?) async {
    guard identity != priority else { return }
    priority = identity
    if grantedPriority != identity { grantedPriority = nil }
    await wake()
  }

  /// Clears the signature store ("Forget learned ads"), then recomputes so ranges that
  /// came only from it go.
  public func forgetLearnedAds() async {
    isForgetPending = true
    await wake()
  }

  /// A backup restore added learned ads to the signature store behind the coordinator's back. The
  /// store's audio prints are held in memory, so they are read again, and the recompute applies
  /// the new ads, the expiry and the cap.
  public func learnedAdsRestored() async {
    isRestoreNoticePending = true
    await wake()
  }

  /// Returns once all three inputs have arrived and the worker has nothing left to do: the
  /// backlog is analysed, or analysis is blocked (setting off, not allowed, deferred, stopped).
  /// For the overnight processing task, which can launch the process cold before any input has
  /// been delivered, when an idle worker would otherwise mean nothing has started yet.
  public func drainBacklog() async {
    let hasStopped = await queue.hasStopped
    if hasAllInputs == false && hasStopped == false {
      await withCheckedContinuation { inputWaiters.append($0) }
    }
    guard hasStopped == false else { return }
    await wake()
    await waitUntilIdle()
  }

  private var hasAllInputs: Bool {
    isEnabled != nil && localEpisodes != nil && hasAllowedSignal
  }

  private func resumeInputWaitersIfReady() async {
    let hasStopped = await queue.hasStopped
    guard hasAllInputs || hasStopped else { return }
    let waiters = inputWaiters
    inputWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// Returns once the worker has nothing left to do. For tests.
  func waitUntilIdle() async {
    await queue.waitUntilIdle()
  }

  /// Runs one more recompute with nothing new, to find the fixed point a drained library settles
  /// on. For tests.
  func forceRecompute() async {
    isRecomputePending = true
    await wake()
  }
}
