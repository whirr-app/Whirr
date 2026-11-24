import Foundation

/// Where a confirmed creative's audio plays in an episode: the reach of a listener's mark beyond
/// the episode it was made in. A match is served like a mark, whole and over what analysis found,
/// with no window, transcript or arbiter involved: the listener has already said it is an ad.
///
/// The episode is matched against the confirmed prints alone, never the whole library. In the
/// library query an every-episode plug loses its votes to the episode's other references (only
/// `AudioRecurrence.offsetsPerChunk` offsets are kept per chunk) and its hashes to the
/// `AudioRecurrence.commonOccurrences` cap.
public enum ConfirmedReach {
  /// The least a match, and so a taught span, may be. Shorter audio aligns too rarely to be found
  /// (measured in the ad-skip harness).
  public static let minimumSeconds: Double = 4
  /// The least share of its print a match must cover.
  public static let coverage: Double = 0.75

  /// A confirmed creative's audio playing in the episode.
  public struct Match: Equatable, Sendable {
    public let creativeId: Int64
    public let span: TimeSpan

    public init(creativeId: Int64, span: TimeSpan) {
      self.creativeId = creativeId
      self.span = span
    }
  }

  /// Every stretch of `episode` that plays one of `creatives`, sorted by start. Overlapping
  /// matches, such as one plug marked in two episodes, are joined under the lowest creative id.
  public static func matches(
    in episode: AudioPrint, creatives: [(id: Int64, print: AudioPrint)]
  ) -> [Match] {
    let usable = creatives.filter { $0.print.isEmpty == false }
    guard episode.isEmpty == false, usable.isEmpty == false else { return [] }
    // Distinct keys: nothing in this library is a linked copy of anything else.
    let library =
      [AudioRecurrence.Reference(print: episode, keys: [EpisodeKey("episode")])]
      + usable.enumerated().map {
        AudioRecurrence.Reference(print: $0.element.print, keys: [EpisodeKey("creative-\($0.offset)")])
      }
    let found = AudioRecurrence.alignments(of: 0, in: library).compactMap { alignment -> Match? in
      let creative = usable[alignment.reference - 1]
      let seconds = alignment.span.end - alignment.span.start
      let printSeconds = Double(creative.print.count) * AudioPrint.hopSeconds
      guard seconds >= minimumSeconds, seconds >= coverage * printSeconds else { return nil }
      return Match(creativeId: creative.id, span: alignment.span)
    }
    var joined: [Match] = []
    for match in found.sorted(by: { ($0.span.start, $0.span.end) < ($1.span.start, $1.span.end) }) {
      // Touching matches join too, as `ListenerMarks.laying` joins touching marks.
      if let last = joined.last, match.span.start <= last.span.end {
        joined[joined.count - 1] = Match(
          creativeId: min(last.creativeId, match.creativeId),
          span: TimeSpan(start: last.span.start, end: max(last.span.end, match.span.end)))
      } else {
        joined.append(match)
      }
    }
    return joined
  }

  /// A piece served once matches are laid over the episode's ranges: `ListenerMarks.Piece` with
  /// the creative of a match's piece.
  public struct Piece: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var endsItem: Bool
    /// The index of the range this is all or part of; nil for a match.
    public var source: Int?
    /// The match's creative; nil for a range's piece.
    public var creativeId: Int64?
  }

  /// `ListenerMarks.laying` with `matches` as the marks: each is served whole and cuts what it
  /// overlaps.
  public static func laying(
    _ matches: [Match], over ranges: [(start: Double, end: Double, endsItem: Bool)]
  ) -> [Piece] {
    ListenerMarks.laying(matches.map(\.span), over: ranges).map { piece in
      // Matches never overlap, so each match piece is exactly one match.
      let creativeId =
        piece.source == nil
        ? matches.first { $0.span.start == piece.start }?.creativeId : nil
      return Piece(
        start: piece.start, end: piece.end, endsItem: piece.endsItem, source: piece.source,
        creativeId: creativeId)
    }
  }

  /// What of `kept` is left to learn once `matches` are taken out: a confirmed ad is already in
  /// the store, and an unconfirmed copy of it would only be merged, expired or replaced. A remnant
  /// shorter than `RepetitionStage.minimumRunSeconds`, which no run could match, is dropped.
  public static func unmatched(_ kept: [KeptRange], by matches: [Match]) -> [KeptRange] {
    guard matches.isEmpty == false else { return kept }
    return kept.flatMap { range -> [KeptRange] in
      var start = range.start
      var remnants: [TimeSpan] = []
      for match in matches.sorted(by: { $0.span.start < $1.span.start })
      where match.span.start < range.end && range.start < match.span.end {
        if match.span.start > start { remnants.append(TimeSpan(start: start, end: match.span.start)) }
        start = max(start, match.span.end)
      }
      if start < range.end { remnants.append(TimeSpan(start: start, end: range.end)) }
      if remnants == [TimeSpan(start: range.start, end: range.end)] { return [range] }
      return remnants.filter { $0.end - $0.start >= RepetitionStage.minimumRunSeconds }.map {
        KeptRange(
          start: $0.start, end: $0.end, meanAdProbability: range.meanAdProbability,
          endsItem: $0.end == range.end && range.endsItem)
      }
    }
  }
}
