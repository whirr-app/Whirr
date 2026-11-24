import AdSkip
import Foundation
import Persistence

extension AdSkipCoordinator {

  /// Re-runs the pipeline over every on-device episode whose stage-1 windows are transcribed,
  /// against the others and the signature store, scores candidates, writes every episode's ranges,
  /// learns kept ranges and asks for stage 2.
  ///
  /// Memory stays bounded by one episode plus the compact occurrence table: transcripts are read
  /// twice (shingles, then matching), not held together. The pending flag clears only once every
  /// episode's ranges are saved, so a pass that throws is retried.
  func recompute() async throws {
    let removals = listenerMarkRemovals
    do {
      try await runRecompute()
    } catch {
      // A mark removed while the pipeline ran leaves its ranges stale, so the replay is owed
      // whether the pass finished or threw.
      await recomputeAgainIfMarksRemoved(since: removals)
      throw error
    }
    await recomputeAgainIfMarksRemoved(since: removals)
  }

  /// The pipeline itself, split from `recompute` so a mark-removal replay can be queued after it
  /// on both exits: a `defer` cannot await.
  private func runRecompute() async throws {
    guard let measurement = dependencies.matchingMeasurement else {
      _ = try await recomputeLibrary()
      return
    }
    let (queries, pairChecks) = (plans.stageOneQueries, plans.stageOnePairChecks)
    await measurement.willStart(.recompute)
    do {
      let counts = try await recomputeLibrary()
      await measurement.didFinish(
        .recompute,
        AdSkipMatchingDetail(
          queries: plans.stageOneQueries - queries, librarySize: plans.audioLibrary?.references.count,
          episodesRead: counts.read, episodesSaved: counts.saved,
          pairChecks: plans.stageOnePairChecks - pairChecks, storeMatchAges: counts.storeMatchAges))
    } catch {
      await measurement.didFinish(
        .recompute,
        AdSkipMatchingDetail(
          queries: plans.stageOneQueries - queries, pairChecks: plans.stageOnePairChecks - pairChecks,
          succeeded: false))
      throw error
    }
  }

  /// `recompute()`'s pass. Returns the candidates it read, the rows it saved and the matched
  /// creatives' ages (`AdSkipMatchingDetail.storeMatchAges`).
  ///
  /// Five phases share state through locals here: load the inputs, index the index views, match
  /// and score, persist what was learned, then persist the ranges.
  private func recomputeLibrary() async throws -> (
    read: Int, saved: Int, storeMatchAges: [Double]
  ) {
    let now = dependencies.now()
    let local = currentLocalEpisodes
    // Loaded first: an unreadable print deletes its row, which must not be saved again below.
    let audio = try await loadedAudioLibrary()
    // A row without an audio print was transcribed in full before audio gating; it keeps its older
    // ranges until decoded.
    let candidates = try await recomputeCandidates(local: local)

    // Pass 1: shingles of the index views, for grouping and the library index.
    var builder = ShingleOccurrences.Builder()
    var rows: [AdSkipEpisodeRecord] = []
    var stageOnes: [AdSkipEpisodeIdentity: [TimeSpan]?] = [:]
    var evidence: [AdSkipEpisodeIdentity: [TimeSpan]] = [:]
    var crossShows: [AdSkipEpisodeIdentity: [CrossShowAlignment]] = [:]
    var sameShows: [AdSkipEpisodeIdentity: [TimeSpan]] = [:]
    var unreadable: Set<AdSkipEpisodeIdentity> = []
    try await indexEpisodes(
      candidates, builder: &builder, rows: &rows, stageOnes: &stageOnes, evidence: &evidence,
      crossShows: &crossShows, sameShows: &sameShows, unreadable: &unreadable)
    pruneCaches(rows: rows, local: local)

    let occurrences = builder.build()
    let groups = episodeGroups(
      rows: rows, stageOnes: stageOnes, local: local, audio: audio, occurrences: occurrences)
    lastEpisodeGroups = groups
    let library = LibraryIndex(occurrences: occurrences)
    let analysedKeys = Set(rows.map(\.identity.episodeKey))

    let loadedStored = try await dependencies.signatures.allCreatives()
    let loaded = SignatureStore(creatives: loadedStored.map(SignatureCreative.init))
    // Copies of one ad are merged before anything is matched, so this pass's ranges name the ads
    // that will be there once its one store change is applied.
    var draft = LearnedAdDraft(
      loaded: loaded.creatives, expired: Set(loaded.expired(asOf: now)), prints: try await learnedPrints())
    let store = SignatureStore(creatives: draft.collapsed)

    // Pass 2: match, score, keep and learn, one episode at a time.
    let scored = try await scoreEpisodes(
      rows: rows, stageOnes: stageOnes, evidence: evidence, crossShows: crossShows,
      sameShows: sameShows, unreadable: &unreadable, local: local, now: now, audio: audio,
      groups: groups, library: library, analysedKeys: analysedKeys, store: store, draft: &draft)

    let storeIds = try await persistLearnedSignatures(
      draft: draft, seen: scored.seen, audio: audio, now: now)

    if unreadable.isEmpty == false {
      // Analysed again on the next pass, once.
      try await discardUnreadable(Array(unreadable))
    }
    let saved = try await saveScoredRanges(
      rows: rows, unreadable: unreadable, settled: scored.settled,
      rangesByRow: scored.rangesByRow, surviving: storeIds.surviving, successors: storeIds.successors)
    Self.logTallies(scored.phraseTally, scored.edgeTally)
    isRecomputePending = false
    isListenerRecomputeOwed = false
    plans.hasPlannedStageTwo = true
    analysesSinceRecompute = 0
    rangeChanges.signal()
    let storeMatchAges = store.creatives.filter { scored.matched.contains($0.id) }
      .map { now.timeIntervalSince($0.lastSeen) }.sorted()
    return (candidates.count, saved, storeMatchAges)
  }

  /// The rows whose stage-1 words the pass may read.
  private func recomputeCandidates(
    local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode]
  ) async throws -> [AdSkipEpisodeRecord] {
    try await dependencies.episodes.allEpisodes().filter {
      ($0.state == .analysed || $0.state == .decoded) && $0.transcriptFileName != nil
        && $0.audioPrintFileName != nil && local[$0.identity] != nil
    }
  }

  /// Pass 1: adds each readable row's index view to `builder` and records the plan facts pass 2
  /// reads. A row whose transcript cannot be read is left to be discarded.
  private func indexEpisodes(
    _ candidates: [AdSkipEpisodeRecord], builder: inout ShingleOccurrences.Builder,
    rows: inout [AdSkipEpisodeRecord], stageOnes: inout [AdSkipEpisodeIdentity: [TimeSpan]?],
    evidence: inout [AdSkipEpisodeIdentity: [TimeSpan]],
    crossShows: inout [AdSkipEpisodeIdentity: [CrossShowAlignment]],
    sameShows: inout [AdSkipEpisodeIdentity: [TimeSpan]],
    unreadable: inout Set<AdSkipEpisodeIdentity>
  ) async throws {
    for row in candidates {
      guard await shouldContinueRecompute else { throw CancellationError() }
      let plan = try await stageOnePlan(of: row)
      let stageOne = plan?.windows
      guard let views = views(of: row, stageOne: stageOne) else {
        unreadable.insert(row.identity)
        continue
      }
      // A decoded episode joins once its stage-1 words are in.
      let duration = views.covered.transcript.duration
      let firstWanted =
        stageOne.map { TranscriptionWindows.clamped($0, duration: duration) }
        ?? [TimeSpan(start: 0, end: duration)]
      if row.state == .decoded,
        TranscriptionWindows.missing(firstWanted, covered: views.coverage).isEmpty == false
      {
        continue
      }
      builder.add(row.identity.episodeKey, hashes: views.index.shingleHashes)
      rows.append(row)
      stageOnes[row.identity] = stageOne
      evidence[row.identity] = plan?.audioEdges ?? []
      crossShows[row.identity] = plan?.crossShow ?? []
      sameShows[row.identity] = plan?.sameShowEdges ?? []
    }
  }

  /// Drops cache entries whose transcript or episode is gone.
  private func pruneCaches(
    rows: [AdSkipEpisodeRecord], local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode]
  ) {
    let names = Set(rows.compactMap(\.transcriptFileName))
    scoreCache = scoreCache.filter { names.contains($0.key) }
    plans.transcriptCoverages = plans.transcriptCoverages.filter { names.contains($0.key) }
    hostReadScores = hostReadScores.filter { local[$0.key] != nil }
  }

  /// The pass's episode groups. Under audio gating a Jaccard link is confirmed by the shared audio
  /// check, which reads the prints of the rows that keep an index view.
  private func episodeGroups(
    rows: [AdSkipEpisodeRecord], stageOnes: [AdSkipEpisodeIdentity: [TimeSpan]?],
    local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode], audio: AudioLibrary,
    occurrences: ShingleOccurrences
  ) -> EpisodeGroups {
    var gatedPrints: [EpisodeKey: AudioPrint] = [:]
    for row in rows where (stageOnes[row.identity] ?? nil) != nil {
      gatedPrints[row.identity.episodeKey] = audio.audioPrint(of: row.identity)
    }
    return EpisodeGrouping.groups(
      occurrences: occurrences, identityLinks: AdSkipPlanBook.identityLinks(rows: rows, local: local),
      confirmsJaccardLink: Self.sharedAudioCheck(gatedPrints))
  }

  /// Pass 2, one episode at a time, accumulating every row's served ranges and the creatives they
  /// name.
  private func scoreEpisodes(
    rows: [AdSkipEpisodeRecord], stageOnes: [AdSkipEpisodeIdentity: [TimeSpan]?],
    evidence: [AdSkipEpisodeIdentity: [TimeSpan]],
    crossShows: [AdSkipEpisodeIdentity: [CrossShowAlignment]],
    sameShows: [AdSkipEpisodeIdentity: [TimeSpan]],
    unreadable: inout Set<AdSkipEpisodeIdentity>,
    local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode], now: Date, audio: AudioLibrary,
    groups: EpisodeGroups, library: LibraryIndex, analysedKeys: Set<EpisodeKey>,
    store: SignatureStore, draft: inout LearnedAdDraft
  ) async throws -> (
    rangesByRow: [Int64: [AdSkipRange]], settled: Set<AdSkipEpisodeIdentity>,
    seen: [Int64: Date], matched: Set<Int64>,
    phraseTally: SponsorPhraseTally, edgeTally: AudioEdgeTally
  ) {
    var seen: [Int64: Date] = [:]
    var matched: Set<Int64> = []
    var rangesByRow: [Int64: [AdSkipRange]] = [:]
    var settled: Set<AdSkipEpisodeIdentity> = []
    var phraseTally = SponsorPhraseTally()
    var edgeTally = AudioEdgeTally()
    for row in rows {
      guard await shouldContinueRecompute else { throw CancellationError() }
      guard let rowId = row.id else { continue }
      let stageOne = stageOnes[row.identity] ?? nil
      guard let views = views(of: row, stageOne: stageOne) else {
        unreadable.insert(row.identity)
        continue
      }
      let scored = try await scoreEpisode(
        row: row, rowId: rowId, stageOne: stageOne, views: views,
        evidence: evidence[row.identity] ?? [], crossShow: crossShows[row.identity] ?? [],
        sameShow: sameShows[row.identity] ?? [], local: local, now: now, audio: audio,
        groups: groups, library: library, analysedKeys: analysedKeys, store: store, draft: &draft,
        seen: &seen, matched: &matched, phraseTally: &phraseTally, edgeTally: &edgeTally)
      rangesByRow[rowId] = scored.ranges
      if scored.settled { settled.insert(row.identity) }
    }
    return (rangesByRow, settled, seen, matched, phraseTally, edgeTally)
  }

  /// One row through pass 2: match, arbitrate, readmit and weigh, then serve the ranges and teach
  /// what only this episode's own audio kept.
  private func scoreEpisode(
    row: AdSkipEpisodeRecord, rowId: Int64, stageOne: [TimeSpan]?, views: TranscriptViews,
    evidence: [TimeSpan], crossShow: [CrossShowAlignment], sameShow: [TimeSpan],
    local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode], now: Date, audio: AudioLibrary,
    groups: EpisodeGroups, library: LibraryIndex, analysedKeys: Set<EpisodeKey>,
    store: SignatureStore, draft: inout LearnedAdDraft, seen: inout [Int64: Date],
    matched: inout Set<Int64>, phraseTally: inout SponsorPhraseTally,
    edgeTally: inout AudioEdgeTally
  ) async throws -> (ranges: [AdSkipRange], settled: Bool) {
    let key = row.identity.episodeKey
    let fileName = row.transcriptFileName ?? ""
    let match = LibraryMatching.candidates(
      for: key, transcript: views.index, groups: groups, library: library, store: store)
    for tombstone in match.matchedTombstones { seen[tombstone] = now }

    // The arbiter and the phrase start read every covered word, as the harness gave them the
    // whole transcript.
    let covered = views.covered
    let steps = Arbiter.steps(for: covered.transcript)
    let arbiterKept = try await arbitratedRanges(
      match.candidates.map(\.range), prepared: covered, steps: steps, fileName: fileName)

    let weighed = try await keptRanges(
      ranges: match.candidates.map(\.range), arbiterKept: arbiterKept, crossShow: crossShow,
      analysedKeys: analysedKeys, groups: groups, key: key, row: row, prepared: covered,
      coverage: views.coverage, steps: steps, sameShow: sameShow, store: store, now: now,
      seen: &seen)
    let kept = weighed.kept

    let phrases = try await phraseSegments(
      kept: kept, prepared: covered, steps: steps, fileName: fileName, evidence: evidence,
      showTitle: local[row.identity]?.showTitle, store: store, tally: &phraseTally)
    let confirmed = views.confirmingEndsItem(kept)
    let edges = try await audioEdges(
      of: confirmed, evidence: evidence, unvetoed: weighed.unvetoed, prepared: covered, steps: steps,
      fileName: fileName, tally: &edgeTally)
    let served = servedSpans(
      confirmed: confirmed, phraseStarts: phrases.starts, segmentStarts: phrases.segmentStarts,
      segments: phrases.segments, audioEdges: edges, covered: covered, store: store,
      candidates: match.candidates, now: now, seen: &seen, matched: &matched)

    var saved = try await savedRanges(
      served, candidates: match.candidates, steps: steps, fileName: fileName,
      tail: weighed.tail, now: now, seen: &seen, matched: &matched)
    // A confirmed ad's audio is served whole, over what the steps above found.
    let reach = try await confirmedMatches(for: row, rowId: rowId, audio: audio)
    saved = Self.laying(reach, over: saved)

    let result = try await settleRanges(
      saved, for: row, rowId: rowId, stageOne: stageOne, views: views, kept: kept,
      tail: weighed.tail, firstPhraseStarts: phrases.firstStarts, anchors: phrases.anchors,
      stingEnds: phrases.stings.map(\.end), showTitle: local[row.identity]?.showTitle,
      store: store, now: now, seen: &seen)

    learnSignatures(
      for: row, views: views, kept: arbiterKept, reach: reach, groups: groups,
      analysedKeys: analysedKeys, audio: audio, draft: &draft, now: now)
    return result
  }

  /// Plans the row's stage 2, then lays its host reads and the listener's marks over the ranges
  /// matched so far. Returns the served ranges and whether every wanted second is covered.
  /// Stage 2 looks back from the first phrase round's starts only; the second round's earlier
  /// starts are anchors, not look-back origins.
  private func settleRanges(
    _ saved: [AdSkipRange], for row: AdSkipEpisodeRecord, rowId: Int64, stageOne: [TimeSpan]?,
    views: TranscriptViews, kept: [KeptRange], tail: KeptRange?, firstPhraseStarts: [Int: Double],
    anchors: [Double], stingEnds: [Double], showTitle: String?, store: SignatureStore, now: Date,
    seen: inout [Int64: Date]
  ) async throws -> (ranges: [AdSkipRange], settled: Bool) {
    // A phrase-moved start looks back for the second round as a kept start does for the first.
    // A tail range does not: its window already holds the context its steps read.
    let lookingBack = kept.indices.filter {
      tail?.start != kept[$0].start || tail?.end != kept[$0].end
    }
    let wantsPass = plans.planStageTwo(
      for: row, stageOne: stageOne, views: views,
      keptStarts: lookingBack.map { kept[$0].start }
        + lookingBack.compactMap { firstPhraseStarts[$0] }.sorted(),
      anchors: anchors, stingEnds: stingEnds)
    if wantsPass { await queue.requestPass() }
    let settled = plans.isSettled(for: row, stageOne: stageOne, views: views)

    // Laid over the ranges above, which are final: a host read moves none of them.
    let hostReads = try await hostReadRanges(
      for: row, isAnalysed: row.state == .analysed || settled,
      shipped: saved, silences: views.covered.silences, showTitle: showTitle,
      store: store, duringRecompute: true)
    for tombstone in hostReads.undoneBy { seen[tombstone] = now }
    // The listener's marks go last: they are served whole, and the ranges above lose what they
    // cover.
    let ranges = try await layingListenerMarks(
      over: (saved + hostReads.ranges).sorted { $0.startTime < $1.startTime }, episodeId: rowId)
    return (ranges, settled)
  }

  /// The creatives a kept range was matched through.
  func storeCreatives(
    for range: KeptRange, in candidates: [LibraryMatching.Candidate]
  ) -> Set<Int64> {
    candidates.first { $0.range.start == range.start && $0.range.end == range.end }?
      .storeCreatives ?? []
  }

  /// One teaching episode per group, its smallest analysed key, so copies of one episode do not
  /// each learn the same ad and then keep replacing one another.
  private func learnSignatures(
    for row: AdSkipEpisodeRecord, views: TranscriptViews, kept: [KeptRange],
    reach: [ConfirmedReach.Match], groups: EpisodeGroups, analysedKeys: Set<EpisodeKey>,
    audio: AudioLibrary, draft: inout LearnedAdDraft, now: Date
  ) {
    let key = row.identity.episodeKey
    let members = groups.members(of: key)
    guard members.intersection(analysedKeys).min() == key else { return }
    let episodePrint = audio.audioPrint(of: row.identity)
    // What only another show's audio kept is never learned.
    for learned in SignatureStore.learning(
      from: views.index, kept: ConfirmedReach.unmatched(kept, by: reach), teachers: members)
    {
      // The range's audio print opens windows in later episodes that carry the same ad, even
      // once this episode is gone.
      let learnedPrint = episodePrint?.slice(
        from: AudioPrint.frame(atTime: learned.start), to: AudioPrint.frame(atTime: learned.end))
      draft.learn(learned, print: learnedPrint, now: now)
    }
  }

  /// Applies this pass's one store change, then its evictions, and answers the creatives that
  /// survive and the successors an evicted or merged one maps to.
  private func persistLearnedSignatures(
    draft: LearnedAdDraft, seen: [Int64: Date], audio: AudioLibrary, now: Date
  ) async throws -> (surviving: Set<Int64>, successors: [Int64: Int64]) {
    let inserted = try await dependencies.signatures.apply(draft.change(matched: seen, now: now))
    let appliedStored = try await dependencies.signatures.allCreatives()
    let applied = SignatureStore(creatives: appliedStored.map(SignatureCreative.init))
    let evicted = Set(applied.evictions())
    if evicted.isEmpty == false {
      _ = try await dependencies.signatures.apply(AdSignatureStoreChange(deletions: evicted))
    }
    let surviving = Set(applied.creatives.map(\.id)).subtracting(evicted)
    let successorIds = draft.successors(inserted: inserted, surviving: surviving)
    // Ids alone would miss an ad merged in place, which keeps its id and changes its keys.
    let keysAfter = Self.audioKeys(
      of: appliedStored.filter { !evicted.contains($0.id) }, groups: audio.groups)
    if keysAfter != audio.creativeKeys { plans.invalidateAudioPlans() }
    return (surviving, successorIds)
  }

  /// Saves every readable row's ranges, remapping a creative that was merged or evicted, and
  /// answers how many rows were saved.
  private func saveScoredRanges(
    rows: [AdSkipEpisodeRecord], unreadable: Set<AdSkipEpisodeIdentity>,
    settled: Set<AdSkipEpisodeIdentity>, rangesByRow: [Int64: [AdSkipRange]],
    surviving: Set<Int64>, successors: [Int64: Int64]
  ) async throws -> Int {
    var saved = 0
    for row in rows where unreadable.contains(row.identity) == false {
      guard await shouldContinueRecompute else { throw CancellationError() }
      guard let rowId = row.id else { continue }
      var updated = row
      updated.rulesRevision = AdSkipRules.revision
      if settled.contains(row.identity) { updated.state = .analysed }
      let ranges = (rangesByRow[rowId] ?? []).map { range -> AdSkipRange in
        var range = range
        // A range matched only through a creative since evicted no longer counts as the store's.
        range.creativeId = range.creativeId.flatMap {
          surviving.contains($0) ? $0 : successors[$0]
        }
        range.fromStore = range.creativeId != nil
        return range
      }
      _ = try await dependencies.episodes.save(updated, ranges: ranges)
      saved += 1
    }
    return saved
  }

  /// The per-recompute diagnostic lines: counts only, never seconds or text.
  private static func logTallies(
    _ phraseTally: SponsorPhraseTally, _ edgeTally: AudioEdgeTally
  ) {
    Self.log.debug(
      "Ad-skip sponsor-phrase starts: \(phraseTally.accepted, privacy: .public) accepted, \(phraseTally.vetoed, privacy: .public) vetoed"
    )
    Self.log.debug(
      "Ad-skip audio edges: \(edgeTally.starts, privacy: .public) starts and \(edgeTally.ends, privacy: .public) ends moved, \(edgeTally.vetoed, privacy: .public) vetoed"
    )
  }

  /// Under audio gating a Jaccard link joins two episodes only when their prints share
  /// `EpisodeGrouping.sharedAudioThreshold` of each: index views hold mostly the
  /// recurring audio, so episodes carrying the same ads reach the Jaccard threshold. A pair with an
  /// episode transcribed in full, or without a print, is grouped by Jaccard alone.
  static func sharedAudioCheck(
    _ gatedPrints: [EpisodeKey: AudioPrint]
  ) -> (EpisodeKey, EpisodeKey) -> Bool {
    { first, second in
      guard let a = gatedPrints[first], let b = gatedPrints[second] else { return true }
      return AudioRecurrence.sharedFraction(of: a, and: b) >= EpisodeGrouping.sharedAudioThreshold
    }
  }
}
