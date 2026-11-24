import Foundation

/// Where a kept range's audio starts and stops lining up with another episode's. Like
/// `PlaybackEdges`, not part of the harness port: it runs after learning, on the saved ranges.
///
/// A kept range comes from words, which copies transcribe differently near an ad's first and last
/// seconds, so it often starts and ends a few seconds inside the ad; the same ad in another
/// episode lines up from its first frame. A show's own episodes share its theme and credits, so an
/// edge may run a few seconds into them; the owner accepts that. On hold-out 4 this rule added
/// 58.8 s of scored ad and 29 words of one show's theme; on the training set 598 s.
public enum AudioEdges {
  /// A move shorter than this is no move.
  public static let minimumMoveSeconds = 0.5
  /// How far into the range an alignment must reach, or all of it when shorter.
  public static let anchorSeconds = 2.0
  /// How far an edge may move.
  public static let capSeconds = 15.0

  /// A kept range's moved edges; nil leaves an edge where it is.
  public struct Edges: Equatable, Sendable {
    public let start: Double?
    public let end: Double?

    public init(start: Double?, end: Double?) {
      self.start = start
      self.end = end
    }
  }

  /// One `Edges` per range of `kept`, which is sorted and disjoint. `evidence` is where the
  /// episode's audio aligns with other episodes.
  ///
  /// The start moves to the latest start among alignments that begin before the range and reach
  /// into it; the end to the earliest end among those that run past it, so the tighter edge wins
  /// when only one episode plays a sting. A start never moves before the previous range's moved
  /// end, an end never past the next range's start.
  public static func edges(for kept: [KeptRange], evidence: [TimeSpan]) -> [Edges] {
    var result: [Edges] = []
    var previousEnd = 0.0
    for (index, range) in kept.enumerated() {
      let nextStart = index + 1 < kept.count ? kept[index + 1].start : Double.infinity
      var start = range.start
      let starts = evidence.filter {
        $0.start < range.start - minimumMoveSeconds
          && $0.end >= min(range.end, range.start + anchorSeconds)
      }.map(\.start)
      if let latest = starts.max() {
        start = min(range.start, max(latest, range.start - capSeconds, previousEnd))
      }
      var end = range.end
      let ends = evidence.filter {
        $0.end > range.end + minimumMoveSeconds
          && $0.start <= max(range.start, range.end - anchorSeconds)
      }.map(\.end)
      if let earliest = ends.min() {
        end = max(range.end, min(earliest, range.end + capSeconds, nextStart))
      }
      result.append(
        Edges(start: start < range.start ? start : nil, end: end > range.end ? end : nil))
      previousEnd = end
    }
    return result
  }
}
