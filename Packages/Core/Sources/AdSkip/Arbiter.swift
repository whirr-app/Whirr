import Foundation

/// The classifier veto: 5 s steps with 7.5 s of text context either side (`prep.py`), and a
/// candidate kept when the mean P(ad) of its steps reaches the cut-off (`arbiter.py`).
public enum Arbiter {
  public struct Step: Sendable, Equatable {
    public let start: Double
    public let end: Double
    /// Raw (unnormalised) word text, or `_` when no word falls in the window.
    public let text: String

    public init(start: Double, end: Double, text: String) {
      self.start = start
      self.end = end
      self.text = text
    }
  }

  public static let stepSeconds = 5.0
  public static let contextSeconds = 7.5
  public static let keepThreshold = 0.06

  /// Steps from zero, the last truncated at the transcript's duration.
  public static func steps(for transcript: Transcript) -> [Step] {
    let words = transcript.words
    let middles = words.map { ($0.start + $0.end) / 2 }
    // `prep.py` filters every word for every step. When midpoints are in order (the transcriber's
    // usual output) a sliding window gives the same words in the same order in linear time;
    // otherwise fall back to the filter, which keeps transcript order.
    let ordered = zip(middles, middles.dropFirst()).allSatisfy { $0 <= $1 }
    var steps: [Step] = []
    var start = 0.0
    var low = 0
    while start < transcript.duration {
      let end = min(start + stepSeconds, transcript.duration)
      let from = start - contextSeconds
      let to = end + contextSeconds
      let texts: [String]
      if ordered {
        while low < middles.count && middles[low] < from { low += 1 }
        var high = low
        while high < middles.count && middles[high] < to { high += 1 }
        texts = words[low..<high].map(\.text)
      } else {
        texts = words.indices.filter { from <= middles[$0] && middles[$0] < to }.map {
          words[$0].text
        }
      }
      steps.append(Step(start: start, end: end, text: texts.isEmpty ? "_" : texts.joined(separator: " ")))
      start += stepSeconds
    }
    return steps
  }

  private static func overlapping(_ candidate: CandidateRange, in steps: [Step]) -> [Int] {
    steps.indices.filter { steps[$0].start < candidate.end && steps[$0].end > candidate.start }
  }

  /// Sorted, distinct indices into `steps` of every step some candidate overlaps. Only these
  /// need scoring.
  public static func stepIndices(overlapping candidates: [CandidateRange], in steps: [Step]) -> [Int] {
    Array(Set(candidates.flatMap { overlapping($0, in: steps) })).sorted()
  }

  /// The candidates whose steps' mean P(ad) is at least `threshold`. `probabilities` is keyed
  /// by step index and must cover `stepIndices(overlapping:in:)`. A candidate with no steps is
  /// vetoed.
  public static func keep(
    _ candidates: [CandidateRange], transcript: Transcript, steps: [Step],
    probabilities: [Int: Double], threshold: Double = keepThreshold
  ) -> [KeptRange] {
    var kept: [KeptRange] = []
    for candidate in candidates {
      let indices = overlapping(candidate, in: steps)
      guard !indices.isEmpty else { continue }
      let mean =
        pythonSum(
          indices.map {
            guard let p = probabilities[$0] else {
              preconditionFailure("No P(ad) for step \($0): scores must cover stepIndices(overlapping:in:)")
            }
            return p
          }) / Double(indices.count)
      guard mean >= threshold else { continue }
      let endsItem = !transcript.words.contains { $0.start > candidate.end }
      kept.append(
        KeptRange(
          start: candidate.start, end: candidate.end, meanAdProbability: mean, endsItem: endsItem))
    }
    return kept
  }

  /// Python 3.12+'s built-in `sum` over floats, which compensates rounding (Neumaier). The harness
  /// ran on Python 3.14, so a plain left fold can land one ulp away at the cut-off.
  static func pythonSum(_ values: [Double]) -> Double {
    var total = 0.0
    var compensation = 0.0
    for x in values {
      let t = total + x
      if abs(total) >= abs(x) {
        compensation += (total - t) + x
      } else {
        compensation += (x - t) + total
      }
      total = t
    }
    if compensation != 0 && compensation.isFinite { total += compensation }
    return total
  }
}
