import Foundation

/// Stretches of an episode whose shingles recur elsewhere (`repeatall.py` `predictions`).
public enum RepetitionStage {
  /// Runs closer than this, with no word between them, merge.
  public static let mergeSeconds = 5.0
  /// Shorter runs are dropped.
  public static let minimumRunSeconds = 15.0
  /// How far an edge may extend over wordless audio to a silence.
  public static let extensionSeconds = 15.0

  /// Candidate ranges for `transcript`, where `isHit` says whether a shingle hash counts as
  /// recurring for this episode.
  public static func candidates(
    in transcript: PreparedTranscript, isHit: (UInt64) -> Bool
  ) -> [CandidateRange] {
    // Runs of consecutive hit shingles, per segment.
    var runs: [(start: Double, end: Double)] = []
    var current: (start: Double, end: Double)?
    var currentSegment = -1
    for shingle in transcript.shingles {
      if shingle.segment != currentSegment {
        if let open = current { runs.append(open) }
        current = nil
        currentSegment = shingle.segment
      }
      guard isHit(shingle.hash) else { continue }
      if var open = current, shingle.start <= open.end + 0.05 {
        open.end = max(open.end, shingle.end)
        current = open
      } else {
        if let open = current { runs.append(open) }
        current = (shingle.start, shingle.end)
      }
    }
    if let open = current { runs.append(open) }

    // Python's sort is stable; Swift's is not, so break ties by position.
    let ordered = runs.enumerated().sorted {
      $0.element.start != $1.element.start
        ? $0.element.start < $1.element.start : $0.offset < $1.offset
    }.map(\.element)

    let words = transcript.words
    var merged: [(start: Double, end: Double)] = []
    for run in ordered {
      if var previous = merged.last, run.start - previous.end < mergeSeconds,
        !words.contains(where: { previous.end < $0.start && $0.start < run.start })
      {
        previous.end = max(previous.end, run.end)
        merged[merged.count - 1] = previous
      } else {
        merged.append(run)
      }
    }

    let silences = transcript.silences
    var output: [CandidateRange] = []
    for run in merged {
      let start = run.start
      let end = run.end
      if end - start < minimumRunSeconds { continue }
      let before = silences.filter { $0.end <= start + 0.5 && start - $0.end <= extensionSeconds }
      let after = silences.filter { $0.start >= end - 0.5 && $0.start - end <= extensionSeconds }
      var newStart = start
      var newEnd = end
      if let silence = before.last,
        !words.contains(where: { silence.end < $0.end && $0.start < start - 0.05 })
      {
        newStart = silence.end
      }
      if let silence = after.first,
        !words.contains(where: { $0.start < silence.start && $0.end > end + 0.05 })
      {
        newEnd = silence.start
      }
      output.append(CandidateRange(start: newStart, end: newEnd))
    }
    return output
  }
}
