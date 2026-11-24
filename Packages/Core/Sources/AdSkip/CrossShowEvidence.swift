import Foundation

/// Another show's audio passes the arbiter's veto. A cross-promo or host-voiced sponsor read scores
/// as programme and is dropped, but the same audio in another show's episode is not this show's
/// programme. Like `StingSegment`, playback-only: the store learns only what the arbiter keeps, so
/// a bad range cannot spread.
///
/// The caller gives only alignments with an episode of another show that is not a copy or rerun
/// of this one (its `EpisodeGroups` group), never a learned creative's, which carries no show.
public enum CrossShowEvidence {
  /// How much of a candidate one alignment must cover. One alignment, not a union across
  /// references, keeps a network's short idents out: they align with many shows, each briefly.
  public static let minimumAlignmentSeconds = RepetitionStage.minimumRunSeconds

  /// The candidates `kept` does not hold that one alignment covers at least
  /// `minimumAlignmentSeconds` of, in order.
  public static func readmitted(
    _ candidates: [CandidateRange], kept: [KeptRange], alignments: [TimeSpan]
  ) -> [CandidateRange] {
    candidates.filter { candidate in
      kept.contains { $0.start == candidate.start && $0.end == candidate.end } == false
        && alignments.contains {
          min($0.end, candidate.end) - max($0.start, candidate.start) >= minimumAlignmentSeconds
        }
    }
  }

  /// Whether one alignment holds all of `span`: an edge of a readmitted range moves there without
  /// the arbiter, which would veto every move of a range it dropped.
  public static func covers(_ span: TimeSpan, alignments: [TimeSpan]) -> Bool {
    alignments.contains { $0.start <= span.start && span.end <= $0.end }
  }
}
