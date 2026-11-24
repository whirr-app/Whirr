import AdSkip
import Persistence

/// The analysis worker: one pass at a time, choosing the next unit and what follows it.
extension AdSkipCoordinator {

  // MARK: - Worker

  func wake() async {
    await queue.wake()
  }

  func reconcile() async throws {
    guard let isEnabled, let localEpisodes else { return }
    // With the setting off, what was learned is kept but nothing is analysed or
    // recomputed; removal, the sweep and Forget still run so data never outlives its download.
    try await applyPendingStoreChanges()
    // An undo reaches every episode's ranges straight away, ahead of any transcription. Pending
    // first, so one that is stopped still runs later.
    if try await applyPendingUndosIfNeeded(isEnabled: isEnabled) {
      try await recompute()
    }

    var stored = try await dependencies.episodes.allEpisodes()
    try await removeStaleRows(&stored, localEpisodes: localEpisodes)
    invalidatePlansIfShowsChanged()
    try await sweepFilesIfNeeded()

    guard isEnabled else { return }

    await applyPendingInputs()
    markRecomputeIfOwed(stored: stored)
    // Held for charging, Check Now still runs its one episode, and nothing else.
    let priorityOnly = isAllowed == false && isGrantActive
    guard isAllowed || priorityOnly, isDeferred == false,
      let work = try await measuredNextWork(stored: stored, priorityOnly: priorityOnly)
    else {
      // Held, the recompute stays owed: it reads every stored transcript, which is the work the
      // conditions hold back.
      if isRecomputePending, mayRecompute { try await recompute() }
      return
    }
    // Ranges for what is already analysed are kept current before a long transcription starts. A
    // decode does not wait: each one changes every plan, so a recompute between decodes is wasted,
    // and decodes alone are no reason to recompute before transcribing either.
    if work.isTranscription && isRecomputePending && isRecomputeOwedOnlyToDecodes == false
      && analysesSinceRecompute == 0
    {
      try await recompute()
    }
    try await performQueuedWork(work, stored: stored, priorityOnly: priorityOnly)
  }

  /// Forget Learned Ads and a restored signature store each forget every plan and owe the
  /// listener's recompute. Cleared only once done, so a failed delete is tried again on the next
  /// pass.
  private func applyPendingStoreChanges() async throws {
    if isForgetPending {
      try await dependencies.signatures.deleteAll()
      isForgetPending = false
      plans.invalidateAudioPlans()
      isRecomputePending = true
      isListenerRecomputeOwed = true
    }
    if isRestoreNoticePending {
      isRestoreNoticePending = false
      plans.invalidateAudioPlans()
      isRecomputePending = true
      isListenerRecomputeOwed = true
    }
  }

  /// Applies the player's pending undos and says whether one landed, so its recompute runs ahead
  /// of any transcription. `isEnabled` is the value `reconcile` read on entry, not the stored
  /// property: the pending-change step before this can suspend, and a reentrant toggle must not
  /// change this pass's decision.
  private func applyPendingUndosIfNeeded(isEnabled: Bool) async throws -> Bool {
    guard isEnabled, try await applyPendingUndos() else { return false }
    isRecomputePending = true
    isListenerRecomputeOwed = true
    return true
  }

  /// Removes rows whose file is gone, whose fingerprint changed, or whose episode is no longer
  /// analysable, and forgets their stage-2 state.
  private func removeStaleRows(
    _ stored: inout [AdSkipEpisodeRecord],
    localEpisodes: [AdSkipEpisodeIdentity: AdSkipLocalEpisode]
  ) async throws {
    let removals = stored.filter { row in
      guard let local = localEpisodes[row.identity], Self.isAnalysable(local) else { return true }
      // A file whose fingerprint changed is analysed again from scratch; a missing file is left
      // until the download tables say it is gone.
      guard let current = dependencies.fingerprinting.fingerprint(ofFileAt: local.fileURL) else {
        return false
      }
      return current != row.fingerprint
    }.map(\.identity)
    guard removals.isEmpty == false else { return }
    let names = try await dependencies.episodes.deleteEpisodes(removals)
    dependencies.transcripts.delete(fileNames: names)
    let removed = Set(removals)
    stored.removeAll { removed.contains($0.identity) }
    plans.forget(removed)
    plans.invalidateAudioPlans()
    isRecomputePending = true
  }

  /// A show joined or split since the library was built changes which alignments are another
  /// show's, though no print changed.
  private func invalidatePlansIfShowsChanged() {
    guard let library = plans.audioLibrary else { return }
    let shows = AdSkipPlanBook.shows(of: Array(currentLocalEpisodes.values))
    if library.showByEpisode.contains(where: { shows[$0.key] != $0.value }) {
      plans.invalidateAudioPlans()
      isRecomputePending = true
    }
  }

  /// Once per process, drops transcript files no row references. Serialized with every write: a
  /// file `write` produced is referenced before this worker runs again, so `now` is a safe cutoff.
  private func sweepFilesIfNeeded() async throws {
    guard hasSweptFiles == false else { return }
    let referenced = try await dependencies.episodes.referencedFileNames()
    _ = try dependencies.transcripts.sweep(keeping: referenced, modifiedBefore: dependencies.now())
    hasSweptFiles = true
  }

  /// Applies the marks, teaching and host reads a pass owes before it picks work.
  private func applyPendingInputs() async {
    await applyPendingMarks()
    if hasRetaughtMarks == false {
      // Cleared only once done, so a failed read is tried again on the next pass.
      hasRetaughtMarks = await reteachMarks()
    }
    await applyPendingHostReads()
  }

  /// Marks the recompute a launch or a rules revision owes, and ends Check Now once its episode is
  /// analysed.
  private func markRecomputeIfOwed(stored: [AdSkipEpisodeRecord]) {
    // Stage 2 is planned only in memory, so a new process asks again for what an earlier one
    // queued but never heard, once analysis may run. That costs one recompute per launch on charge.
    if plans.hasPlannedStageTwo == false, isAllowed, stored.contains(where: { $0.state == .analysed }) {
      isRecomputePending = true
    }

    // Rows without an audio print keep their older ranges until decoded.
    if stored.contains(where: {
      $0.state == .analysed && $0.audioPrintFileName != nil
        && $0.rulesRevision != AdSkipRules.revision
    }) {
      isRecomputePending = true
    }

    // Check Now ends once its episode is analysed.
    if let granted = grantedPriority, stored.contains(where: { $0.identity == granted && $0.state == .analysed }) {
      grantedPriority = nil
    }
  }

  /// Runs one chosen unit, then decides what follows it: another pass, or a recompute.
  private func performQueuedWork(
    _ work: Work, stored: [AdSkipEpisodeRecord], priorityOnly: Bool
  ) async throws {
    publishProgress(stored: stored)
    let wasPriority = work.episode.identity == priority
    let wasStored = try await perform(work)
    // Another pass follows whatever happened: the next unit, a recompute that is due, or both. A
    // deferral or an unreadable file cannot spin, since neither is chosen again this pass.
    await queue.requestPass()
    guard wasStored else { return }
    let isOwedOnlyToDecodes =
      work.isTranscription == false && (isRecomputePending == false || isRecomputeOwedOnlyToDecodes)
    isRecomputePending = true
    isRecomputeOwedOnlyToDecodes = isOwedOnlyToDecodes
    guard work.isTranscription else {
      // A priority episode whose audio recurs nowhere has no windows: its decode was its only
      // unit, and only a recompute settles it. Waiting for the batch would leave the listener's
      // episode behind every other decode.
      if wasPriority, let row = try await dependencies.episodes.episode(for: work.episode.identity),
        row.state == .decoded, try await missingWindows(of: row).isEmpty
      {
        try await recompute()
      }
      return
    }
    analysesSinceRecompute += 1
    try await recomputeAfterTranscription(wasPriority: wasPriority, priorityOnly: priorityOnly)
  }

  /// A transcription recomputes once its batch is due: the priority episode, the end of the
  /// backlog, or `analysesPerRecompute` transcriptions, whichever comes first.
  private func recomputeAfterTranscription(wasPriority: Bool, priorityOnly: Bool) async throws {
    let backlogRemains =
      try await measuredNextWork(
        stored: try await dependencies.episodes.allEpisodes(), priorityOnly: priorityOnly) != nil
    if wasPriority || backlogRemains == false
      || analysesSinceRecompute >= Self.analysesPerRecompute
    {
      try await recompute()
    }
  }

  static func byIdentity(_ stored: [AdSkipEpisodeRecord]) -> [AdSkipEpisodeIdentity: AdSkipEpisodeRecord] {
    Dictionary(stored.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
  }

  static func isAnalysable(_ episode: AdSkipLocalEpisode?) -> Bool {
    guard let episode else { return false }
    return ShowLanguagePolicy.isAnalysable(languageTag: episode.languageTag)
  }

  /// The current local set, for the recompute.
  var currentLocalEpisodes: [AdSkipEpisodeIdentity: AdSkipLocalEpisode] {
    localEpisodes ?? [:]
  }

  /// Whether the conditions let a recompute run: analysis is allowed, Check Now's episode is
  /// running, whose recomputes plan its stage 2, or the listener asked.
  private var mayRecompute: Bool {
    isAllowed || isGrantActive || isListenerRecomputeOwed
  }

  /// Recompute stops early once the setting goes off or analysis is held (it stays pending and
  /// resumes when both allow it again) or the coordinator stops.
  var shouldContinueRecompute: Bool {
    get async {
      guard isEnabled == true, mayRecompute else { return false }
      return await queue.hasStopped == false
    }
  }
}
