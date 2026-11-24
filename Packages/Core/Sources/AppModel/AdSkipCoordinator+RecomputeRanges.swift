import AdSkip
import Foundation
import Persistence

/// The per-episode range pipeline `scoreEpisode` runs: what the arbiter keeps, the phrase and
/// audio evidence that moves each edge, and the spans served and saved, with the scorer cache
/// the evidence reads through.
extension AdSkipCoordinator {
  /// The candidates the arbiter keeps, from the extra steps it scores first.
  func arbitratedRanges(
    _ ranges: [CandidateRange], prepared: PreparedTranscript, steps: [Arbiter.Step], fileName: String
  ) async throws -> [KeptRange] {
    let probabilities = try await scores(
      fileName: fileName, steps: steps,
      indices: Arbiter.stepIndices(overlapping: ranges, in: steps))
    return Arbiter.keep(
      ranges, transcript: prepared.transcript, steps: steps, probabilities: probabilities)
  }

  /// The ranges the arbiter keeps, another show's audio readmits, and the post-roll tail adds.
  func keptRanges(
    ranges: [CandidateRange], arbiterKept: [KeptRange], crossShow: [CrossShowAlignment],
    analysedKeys: Set<EpisodeKey>, groups: EpisodeGroups, key: EpisodeKey,
    row: AdSkipEpisodeRecord, prepared: PreparedTranscript, coverage: [TimeSpan],
    steps: [Arbiter.Step], sameShow: [TimeSpan], store: SignatureStore, now: Date,
    seen: inout [Int64: Date]
  ) async throws -> (
    kept: [KeptRange], tail: KeptRange?, unvetoed: [Int: [TimeSpan]]
  ) {
    // Another show's audio passes the veto. A rerun in this episode's
    // group is not another show's, and an episode not analysed yet cannot be told from one.
    let evidenceKeys = analysedKeys.subtracting(groups.members(of: key))
    let alignments = crossShow.filter { evidenceKeys.contains($0.episode) }.map(\.span)
    var readmitted: [KeptRange] = []
    for candidate in CrossShowEvidence.readmitted(ranges, kept: arbiterKept, alignments: alignments) {
      readmitted.append(
        KeptRange(
          start: candidate.start, end: candidate.end,
          meanAdProbability: try await meanAdProbability(
            of: TimeSpan(start: candidate.start, end: candidate.end), steps: steps,
            fileName: row.transcriptFileName ?? ""),
          endsItem: prepared.transcript.words.contains { $0.start > candidate.end } == false))
    }
    let repeated =
      readmitted.isEmpty
      ? arbiterKept : (arbiterKept + readmitted).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    // A one-off post-roll after the trigger's silence, kept at its own cut. Like another show's
    // audio, it is never learned. An undone one stays undone, and its tombstone is refreshed
    // while the post-roll airs.
    let (tail, undoneBy) = try await postRollTail(
      row: row, prepared: prepared, coverage: coverage, steps: steps,
      sameShow: sameShow, kept: repeated, store: store)
    for tombstone in undoneBy { seen[tombstone] = now }
    let kept =
      tail.map { (repeated + [$0]).sorted { ($0.start, $0.end) < ($1.start, $1.end) } } ?? repeated
    // Each readmitted range's index, with the alignments its edges may move over unvetoed.
    var unvetoed: [Int: [TimeSpan]] = [:]
    for (index, range) in kept.enumerated()
    where readmitted.contains(where: { $0.start == range.start && $0.end == range.end }) {
      unvetoed[index] = alignments
    }
    return (kept, tail, unvetoed)
  }

  /// The sponsor-phrase starts and sting segments for `kept`: two rounds of phrase starts, then the
  /// segment each sting ends. `anchors` is every phrase start the rounds found.
  func phraseSegments(
    kept: [KeptRange], prepared: PreparedTranscript, steps: [Arbiter.Step], fileName: String,
    evidence: [TimeSpan], showTitle: String?, store: SignatureStore,
    tally: inout SponsorPhraseTally
  ) async throws -> (
    starts: [Int: Double], firstStarts: [Int: Double], anchors: [Double], stings: [TimeSpan],
    segments: [StingSegment.Segment], segmentStarts: [Int: Double]
  ) {
    let firstPhraseStarts = try await sponsorPhraseStarts(
      kept: kept, prepared: prepared, steps: steps, fileName: fileName, showTitle: showTitle,
      store: store, tally: &tally)
    // One more round from each phrase-moved start: a presenting partner can open the break
    // before the sponsor whose phrase moved it, too far before the matched range to anchor.
    let movedKept = kept.enumerated().map { index, range in
      firstPhraseStarts[index].map {
        KeptRange(
          start: $0, end: range.end, meanAdProbability: range.meanAdProbability,
          endsItem: range.endsItem)
      } ?? range
    }
    let secondPhraseStarts = try await sponsorPhraseStarts(
      kept: movedKept, prepared: prepared, steps: steps, fileName: fileName, showTitle: showTitle,
      store: store, only: Set(firstPhraseStarts.keys), tally: &tally
    ).filter { index, start in firstPhraseStarts[index].map { start < $0 } ?? false }
    let phraseStarts = firstPhraseStarts.merging(secondPhraseStarts) { $1 }
    // A sponsored segment after a break sting runs into the next range as moved by the phrase.
    let stings = StingSegment.stings(audioEdges: evidence)
    let segments = StingSegment.segments(
      stings: stings,
      kept: kept.enumerated().map { index, range in
        KeptRange(
          start: phraseStarts[index] ?? range.start, end: range.end,
          meanAdProbability: range.meanAdProbability, endsItem: range.endsItem)
      }, in: prepared, showTitle: showTitle, isTombstoned: store.isTombstoned)
    var segmentStarts: [Int: Double] = [:]
    for segment in segments {
      if let index = segment.keptIndex {
        segmentStarts[index] = min(segmentStarts[index] ?? .infinity, segment.start)
      }
    }
    let anchors = (Array(firstPhraseStarts.values) + secondPhraseStarts.values).sorted()
    return (phraseStarts, firstPhraseStarts, anchors, stings, segments, segmentStarts)
  }

  /// The spans served after the phrase, edge and segment moves. A range another wholly holds is
  /// dropped, though its creatives still count as seen.
  func servedSpans(
    confirmed: [KeptRange], phraseStarts: [Int: Double], segmentStarts: [Int: Double],
    segments: [StingSegment.Segment], audioEdges: [AudioEdges.Edges], covered: PreparedTranscript,
    store: SignatureStore, candidates: [LibraryMatching.Candidate], now: Date,
    seen: inout [Int64: Date], matched: inout Set<Int64>
  ) -> [(range: KeptRange?, span: TimeSpan)] {
    // Joined to creatives on the kept range; the playback edges apply only to what is saved.
    // Each edge is the widest of its candidates, then the served range
    // takes in the silence on either side.
    let edged = confirmed.enumerated().map { index, range in
      let played = PlaybackEdges.extendingEnd(of: range, silences: covered.silences)
      let start = [phraseStarts[index], audioEdges[index].start, segmentStarts[index]]
        .compactMap { $0 }.min()
      return TimeSpan(start: start ?? played.start, end: max(played.end, audioEdges[index].end ?? 0))
    }
    // A segment a sting ends stands alone, cut short of whatever range follows it.
    var spans = zip(edged, confirmed.map(Optional.some)).map { ($0, $1) }
    for segment in segments where segment.keptIndex == nil {
      spans.append((TimeSpan(start: segment.start, end: segment.end), nil))
    }
    spans.sort { $0.0.start < $1.0.start }
    for index in spans.indices.dropLast() where spans[index].1 == nil {
      let end = min(spans[index].0.end, spans[index + 1].0.start)
      spans[index].0 = TimeSpan(start: spans[index].0.start, end: end)
    }
    // A range another wholly holds is not served, though its creatives still count as seen.
    let disjoint = zip(PlaybackEdges.disjoint(spans.map(\.0)), spans.map(\.1)).map { ($0, $1) }
    var remaining = disjoint.filter { $0.0.end > $0.0.start }
    for case (_, let range?) in disjoint.filter({ $0.0.end <= $0.0.start }) {
      let creatives = storeCreatives(for: range, in: candidates)
      for id in creatives { seen[id] = now }
      matched.formUnion(creatives)
    }
    // A short gap inside a break is its own span, as a segment a sting ends is. A gap holding a
    // tombstoned shingle is not filled; an Undo of the joined skip tombstones the neighbours, so
    // with them gone the fill is not rebuilt either.
    let fills = PlaybackEdges.breakFills(between: remaining.map(\.0)) { gap in
      covered.shingles.contains {
        $0.start < gap.end && $0.end > gap.start && store.isTombstoned($0.hash)
      }
    }
    remaining = (remaining + fills.map { ($0, nil) }).sorted { $0.0.start < $1.0.start }
    let served = PlaybackEdges.bridgingSilences(remaining.map(\.0), silences: covered.silences)
    return Array(zip(remaining.map(\.1), served))
  }

  /// `served` as the ranges saved for the row, crediting each matched creative as seen.
  func savedRanges(
    _ served: [(range: KeptRange?, span: TimeSpan)],
    candidates: [LibraryMatching.Candidate], steps: [Arbiter.Step], fileName: String,
    tail: KeptRange?, now: Date, seen: inout [Int64: Date], matched: inout Set<Int64>
  ) async throws -> [AdSkipRange] {
    var saved: [AdSkipRange] = []
    for (range, span) in served {
      guard let range else {
        saved.append(
          AdSkipRange(
            startTime: span.start, endTime: span.end,
            meanAdProbability: try await meanAdProbability(
              of: span, steps: steps, fileName: fileName),
            rulesRevision: AdSkipRules.revision, fromStore: false, endsItem: false,
            creativeId: nil))
        continue
      }
      let creatives = storeCreatives(for: range, in: candidates)
      for id in creatives { seen[id] = now }
      matched.formUnion(creatives)
      saved.append(
        AdSkipRange(
          startTime: span.start, endTime: span.end,
          meanAdProbability: range.meanAdProbability,
          rulesRevision: AdSkipRules.revision, fromStore: creatives.isEmpty == false,
          endsItem: range.endsItem, creativeId: creatives.min(),
          fromTail: tail?.start == range.start && tail?.end == range.end))
    }
    return saved
  }

  /// Counts for the per-recompute diagnostic line: never seconds or text.
  struct SponsorPhraseTally {
    var accepted = 0
    var vetoed = 0
  }

  /// Counts for the per-recompute audio-edge line: never seconds or text.
  struct AudioEdgeTally {
    var starts = 0
    var ends = 0
    var vetoed = 0
  }

  /// `AudioEdges` for each range of `kept`, each moved edge kept only when the arbiter keeps the
  /// range it extends, as a phrase start is. A range only another show's audio keeps, by index in
  /// `unvetoed`, moves an edge without the arbiter where one of its alignments covers the move:
  /// the arbiter dropped the range, so it vetoes every move.
  func audioEdges(
    of kept: [KeptRange], evidence: [TimeSpan], unvetoed: [Int: [TimeSpan]],
    prepared: PreparedTranscript, steps: [Arbiter.Step], fileName: String,
    tally: inout AudioEdgeTally
  ) async throws -> [AudioEdges.Edges] {
    var result: [AudioEdges.Edges] = []
    for (index, (range, proposed)) in zip(kept, AudioEdges.edges(for: kept, evidence: evidence))
      .enumerated()
    {
      func kept(_ extended: CandidateRange, moving move: TimeSpan) async throws -> Bool {
        if CrossShowEvidence.covers(move, alignments: unvetoed[index] ?? []) { return true }
        let probabilities = try await scores(
          fileName: fileName, steps: steps,
          indices: Arbiter.stepIndices(overlapping: [extended], in: steps))
        let keeps =
          Arbiter.keep(
            [extended], transcript: prepared.transcript, steps: steps, probabilities: probabilities
          ).isEmpty == false
        if keeps == false { tally.vetoed += 1 }
        return keeps
      }
      var start = proposed.start
      if let moved = start {
        if try await kept(
          CandidateRange(start: moved, end: range.end), moving: TimeSpan(start: moved, end: range.start))
        {
          tally.starts += 1
        } else {
          start = nil
        }
      }
      var end = proposed.end
      if let moved = end {
        if try await kept(
          CandidateRange(start: range.start, end: moved), moving: TimeSpan(start: range.end, end: moved))
        {
          tally.ends += 1
        } else {
          end = nil
        }
      }
      result.append(AudioEdges.Edges(start: start, end: end))
    }
    return result
  }

  /// Playback starts, by index into `kept`, for ranges a sponsor phrase opens:
  /// the earliest candidate whose extended range the arbiter keeps. The extra steps are scored
  /// first, since `Arbiter.keep` traps on a step with no probability. `only`, when given, limits
  /// the ranges considered.
  private func sponsorPhraseStarts(
    kept: [KeptRange], prepared: PreparedTranscript, steps: [Arbiter.Step], fileName: String,
    showTitle: String?, store: SignatureStore, only: Set<Int>? = nil, tally: inout SponsorPhraseTally
  ) async throws -> [Int: Double] {
    var starts: [Int: Double] = [:]
    for proposal in SponsorPhraseStart.proposals(
      for: kept, in: prepared, showTitle: showTitle, isTombstoned: store.isTombstoned)
    where only?.contains(proposal.keptIndex) ?? true {
      let end = kept[proposal.keptIndex].end
      for start in proposal.starts {
        let extended = CandidateRange(start: start, end: end)
        let probabilities = try await scores(
          fileName: fileName, steps: steps,
          indices: Arbiter.stepIndices(overlapping: [extended], in: steps))
        guard
          Arbiter.keep(
            [extended], transcript: prepared.transcript, steps: steps, probabilities: probabilities
          ).isEmpty == false
        else {
          tally.vetoed += 1
          continue
        }
        starts[proposal.keptIndex] = start
        tally.accepted += 1
        break
      }
    }
    return starts
  }

  /// The episode's post-roll tail range, when `PostRollTail` proposes one, no tombstone holds it
  /// and its steps reach `PostRollTail.keepThreshold`; with the tombstones that dropped it.
  private func postRollTail(
    row: AdSkipEpisodeRecord, prepared: PreparedTranscript, coverage: [TimeSpan],
    steps: [Arbiter.Step], sameShow: [TimeSpan], kept: [KeptRange], store: SignatureStore
  ) async throws -> (KeptRange?, undoneBy: Set<Int64>) {
    guard
      let candidate = PostRollTail.candidate(
        silences: prepared.silences, duration: prepared.transcript.duration, sameShow: sameShow,
        coverage: coverage, kept: kept)
    else { return (nil, []) }
    let undoneBy = PostRollTail.undoing(candidate, in: prepared, store: store)
    guard undoneBy.isEmpty else { return (nil, undoneBy) }
    let probabilities = try await scores(
      fileName: row.transcriptFileName ?? "", steps: steps,
      indices: Arbiter.stepIndices(overlapping: [candidate], in: steps))
    let range = Arbiter.keep(
      [candidate], transcript: prepared.transcript, steps: steps, probabilities: probabilities,
      threshold: PostRollTail.keepThreshold
    ).first
    return (range, [])
  }

  /// Mean P(ad) over the steps a span overlaps, or zero with none: recorded with a sting segment
  /// for diagnosis, never used to veto it.
  private func meanAdProbability(
    of span: TimeSpan, steps: [Arbiter.Step], fileName: String
  ) async throws -> Double {
    let indices = Arbiter.stepIndices(
      overlapping: [CandidateRange(start: span.start, end: span.end)], in: steps)
    guard indices.isEmpty == false else { return 0 }
    let probabilities = try await scores(fileName: fileName, steps: steps, indices: indices)
    return indices.compactMap { probabilities[$0] }.reduce(0, +) / Double(indices.count)
  }

  func scores(
    fileName: String, steps: [Arbiter.Step], indices: [Int]
  ) async throws -> [Int: Double] {
    var known = scoreCache[fileName] ?? [:]
    let missing = indices.filter { known[$0] == nil }
    if missing.isEmpty == false {
      let probabilities = try await dependencies.scorer.adProbabilities(
        forStepTexts: missing.map { steps[$0].text })
      guard probabilities.count == missing.count else { throw ScorerMismatch() }
      for (index, probability) in zip(missing, probabilities) { known[index] = probability }
      scoreCache[fileName] = known
    }
    return known
  }

  private struct ScorerMismatch: Error {}
}
