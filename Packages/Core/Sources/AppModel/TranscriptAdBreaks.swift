/// A stretch of ads the transcript steps between: one or more ad ranges close enough to be one
/// break in the show.
public struct TranscriptAdBreak: Sendable, Equatable {
  public let start: Double
  public let end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }

  public func contains(_ time: Double) -> Bool { start <= time && time <= end }
}

/// The episode's ads grouped into breaks. A break runs several ads back to back, and an ad
/// detection missed usually sits beside the ones it found, so the listener checks and completes a
/// break as one stop rather than ad by ad.
public enum TranscriptAdBreaks {
  /// Ranges this close, end to start, are one break: further apart than two ads sit in a break,
  /// nearer than two breaks sit in a show.
  public static let joinGap: Double = 60

  /// The breaks in time order, every origin counted alike: a listener's mark beside a detected ad
  /// is part of the same break. `before` drops breaks starting at or after it, so a transcript
  /// still being made does not count breaks it has no text for.
  public static func breaks(_ ranges: [TranscriptAdRange], before limit: Double? = nil)
    -> [TranscriptAdBreak]
  {
    var result: [TranscriptAdBreak] = []
    for range in ranges.sorted(by: { $0.start < $1.start }) {
      if let last = result.last, range.start - last.end <= joinGap {
        result[result.count - 1] = TranscriptAdBreak(start: last.start, end: max(last.end, range.end))
      } else {
        result.append(TranscriptAdBreak(start: range.start, end: range.end))
      }
    }
    guard let limit else { return result }
    return result.filter { $0.start < limit }
  }
}
