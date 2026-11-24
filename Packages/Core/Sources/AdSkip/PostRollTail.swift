import Foundation

/// The post-roll tail proposer: an inserted post-roll that plays nowhere else matches nothing, so
/// repetition never proposes it. Once the tail trigger fires (`TranscriptionWindows.tailSilence`)
/// and the tail window is transcribed, the stretch from the silence's end to the end of the file is
/// a candidate, kept at a stricter cut than the veto's since its words do not already recur.
public enum PostRollTail {
  /// The mean P(ad) a tail candidate's steps must reach. The veto's 0.06 assumes the
  /// text already recurs.
  public static let keepThreshold = 0.5

  /// The tail candidate: from the trigger's silence to the end of the file, once `coverage` holds
  /// the whole tail window, and unless a range in `kept` already overlaps it, since the pipeline
  /// then owns the tail. Nil when there is none.
  public static func candidate(
    silences: [Silence], duration: Double, sameShow: [TimeSpan], coverage: [TimeSpan],
    kept: [KeptRange]
  ) -> CandidateRange? {
    guard
      let silence = TranscriptionWindows.tailSilence(
        silences: silences, duration: duration, sameShow: sameShow)
    else { return nil }
    let window = TranscriptionWindows.tailWindow(after: silence, duration: duration)
    guard TranscriptionWindows.covers(coverage, from: max(0, window.start), toEndOf: duration),
      kept.allSatisfy({ $0.end <= silence.end || $0.start >= duration })
    else { return nil }
    return CandidateRange(start: silence.end, end: duration)
  }

  /// The tombstone for an undone tail range: the covered view's shingles over it, less any
  /// the index view holds. A tail's words are never in the index, so the Undo holds without
  /// vetoing the show's own audio, such as an outro the range reached back over. Nil when no
  /// shingle is left.
  public static func tombstone(
    covered: PreparedTranscript, index: PreparedTranscript, start: Double, end: Double,
    teachers: Set<EpisodeKey>
  ) -> NewSignatureCreative? {
    guard
      let overlapping = SignatureStore.tombstone(
        from: covered, start: start, end: end, teachers: teachers)
    else { return nil }
    let hashes = overlapping.hashes.subtracting(index.shingles.lazy.map(\.hash))
    return hashes.isEmpty
      ? nil
      : NewSignatureCreative(
        kind: .tombstone, start: start, end: end, teachers: teachers, hashes: hashes)
  }

  /// The tombstones holding any of `candidate`'s covered shingles, which drop it. The shingles
  /// lying wholly inside it are read, so the Undo of a range ending at the silence, whose shingles
  /// run on past it, leaves the tail alone; a tail too short for one reads those overlapping it.
  public static func undoing(
    _ candidate: CandidateRange, in covered: PreparedTranscript, store: SignatureStore
  ) -> Set<Int64> {
    let inside = covered.shingles.filter { candidate.start <= $0.start && $0.end <= candidate.end }
    let shingles =
      inside.isEmpty
      ? covered.shingles.filter { $0.start < candidate.end && $0.end > candidate.start } : inside
    return Set(shingles.flatMap { store.tombstones(holding: $0.hash) })
  }
}
