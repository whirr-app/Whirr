import AdSkip
import Foundation
import Persistence

/// Host-read sponsor spots, from the listener's own transcript of an episode
/// (`HostReadSpans`). Ad skip's transcript covers only the audio that recurs, so a read recorded
/// once is in none of its words; a complete listener transcript holds it.
///
/// The pass only adds ranges. Nothing here reaches the index, learning or stage-2 planning, and
/// the shipped ranges are final before a host-read span is laid over them.
extension AdSkipCoordinator {
  /// P(ad) for the leading steps of one listener transcript, all of them once scoring finishes.
  struct HostReadScores: Sendable {
    let fileName: String
    var probabilities: [Double]
  }

  /// Steps scored per call to the scorer, so a pass that is stopped loses at most one chunk.
  static let hostReadScoringChunk = 120

  /// The episode's host-read ranges, to save beside `shipped`, with the tombstones that dropped a
  /// candidate. Empty unless `row` is analysed and the listener has a complete transcript of the
  /// file as it is now. `silences` are ad skip's own: the listener's file holds none.
  func hostReadRanges(
    for row: AdSkipEpisodeRecord, isAnalysed: Bool, shipped: [AdSkipRange], silences: [Silence],
    showTitle: String?, store: SignatureStore, duringRecompute: Bool
  ) async throws -> (ranges: [AdSkipRange], undoneBy: Set<Int64>) {
    guard isAnalysed, let reader = dependencies.listenerTranscripts,
      let complete = await reader.completeTranscript(for: row.identity)
    else {
      hostReadScores[row.identity] = nil
      return ([], [])
    }
    let prepared = PreparedTranscript(transcript: complete.transcript, silences: silences)
    let steps = Arbiter.steps(for: prepared.transcript)
    let probabilities = try await hostReadProbabilities(
      of: row.identity, fileName: complete.fileName, steps: steps, duringRecompute: duringRecompute)

    var undoneBy: Set<Int64> = []
    let candidates = HostReadSpans.candidates(
      in: prepared, steps: steps, probabilities: probabilities, showTitle: showTitle
    ).filter { candidate in
      let tombstones = PostRollTail.undoing(candidate, in: prepared, store: store)
      undoneBy.formUnion(tombstones)
      return tombstones.isEmpty
    }
    let kept = Arbiter.keep(
      candidates, transcript: prepared.transcript, steps: steps,
      probabilities: Dictionary(uniqueKeysWithValues: probabilities.enumerated().map { ($0, $1) }))
    let spans = shipped.filter { $0.fromHostRead == false }
      .map { TimeSpan(start: $0.startTime, end: $0.endTime) }.sorted { $0.start < $1.start }
    let ranges = HostReadSpans.layingOver(kept.sorted { $0.start < $1.start }, shipped: spans).map {
      AdSkipRange(
        startTime: $0.start, endTime: $0.end, meanAdProbability: $0.meanAdProbability,
        rulesRevision: AdSkipRules.revision, fromStore: false, endsItem: $0.endsItem,
        creativeId: nil, fromHostRead: true)
    }
    return (ranges, undoneBy)
  }

  /// P(ad) for every step of a listener transcript, scored once per file and process.
  private func hostReadProbabilities(
    of identity: AdSkipEpisodeIdentity, fileName: String, steps: [Arbiter.Step],
    duringRecompute: Bool
  ) async throws -> [Double] {
    var known = hostReadScores[identity].flatMap { $0.fileName == fileName ? $0.probabilities : nil } ?? []
    while known.count < steps.count {
      guard duringRecompute ? await shouldContinueRecompute : isEnabled == true else {
        throw CancellationError()
      }
      let chunk = steps[known.count..<min(steps.count, known.count + Self.hostReadScoringChunk)]
      let scored = try await dependencies.scorer.adProbabilities(forStepTexts: chunk.map(\.text))
      guard scored.count == chunk.count else { throw HostReadScorerMismatch() }
      known += scored
      hostReadScores[identity] = HostReadScores(fileName: fileName, probabilities: known)
    }
    return Array(known.prefix(steps.count))
  }

  private struct HostReadScorerMismatch: Error {}

  /// A listener transcript completed or went away: its episode's host reads are brought up to
  /// date alone, without the recompute.
  func noteCompleteTranscriptChange(_ identity: AdSkipEpisodeIdentity) async {
    pendingHostReads.insert(identity)
    await wake()
  }

  /// Rewrites the host-read ranges of each episode whose listener transcript changed, leaving
  /// every other range as it is. It does not wait for charging: the listener has just asked for
  /// the transcript, or just removed it. A failure keeps the episodes pending and is not thrown,
  /// so it holds up nothing else.
  func applyPendingHostReads() async {
    guard pendingHostReads.isEmpty == false else { return }
    let pending = pendingHostReads
    pendingHostReads = []
    var changed = false
    do {
      var store: SignatureStore?
      for identity in pending {
        guard let local = currentLocalEpisodes[identity],
          let row = try await dependencies.episodes.episode(for: identity), let rowId = row.id,
          let name = row.transcriptFileName,
          let stored = try? dependencies.transcripts.read(fileName: name)
        else { continue }
        if store == nil {
          store = SignatureStore(
            creatives: try await dependencies.signatures.allCreatives().map(SignatureCreative.init))
        }
        guard let store else { continue }
        let existing = try await dependencies.episodes.ranges(forEpisodeId: rowId)
        // Laid over by the marks read now, last, as a recompute does: a host read loses what a
        // mark covers, and the marks' own ranges are not this pass's to write.
        let hostReads = try await layingListenerMarks(
          over: try await hostReadRanges(
            for: row, isAnalysed: row.state == .analysed, shipped: existing,
            silences: stored.pipelineSilences, showTitle: local.showTitle, store: store,
            duringRecompute: false
          ).ranges, episodeId: rowId
        ).filter(\.fromHostRead)
        guard hostReads != existing.filter(\.fromHostRead) else { continue }
        try await dependencies.episodes.replaceHostReadRanges(hostReads, episodeId: rowId)
        changed = true
      }
    } catch {
      pendingHostReads.formUnion(pending)
      // Only the error's type: never a name or content.
      Self.log.error("Ad-skip host-read pass failed: \(String(describing: type(of: error)), privacy: .public)")
    }
    if changed { rangeChanges.signal() }
  }

  /// The tombstone for an undone host read: the listener transcript's shingles over the undone
  /// span, less any the index view holds, so the Undo never vetoes audio the library can match.
  /// Nil when the listener's transcript is gone, as the range then is too.
  func hostReadTombstone(
    for row: AdSkipEpisodeRecord, silences: [Silence], index: PreparedTranscript, start: Double,
    end: Double
  ) async -> NewSignatureCreative? {
    guard let complete = await dependencies.listenerTranscripts?.completeTranscript(for: row.identity)
    else { return nil }
    return PostRollTail.tombstone(
      covered: PreparedTranscript(transcript: complete.transcript, silences: silences), index: index,
      start: start, end: end, teachers: [row.identity.episodeKey])
  }
}
