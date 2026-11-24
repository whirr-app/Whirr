import Foundation

/// Stretches the listener marked as ads. A mark is the listener's own word, so it is served whole
/// and nothing analysis found can shorten it: it is laid over the other ranges, which lose what it
/// covers. Its edges are the ones chosen, never moved to a pause (`PlaybackEdges` can widen a
/// range by seconds the listener did not select).
public enum ListenerMarks {
  /// The least a mark may be, unless it abuts an ad already served (`isLongEnough`): the least
  /// `HostReadSpans` serves of a piece, and a sliver a skip is not worth on its own.
  public static let minimumSeconds = HostReadSpans.minimumServedSeconds

  /// Whether a mark on `start..<end` may be made. It must have positive length, and be at least
  /// `minimumSeconds` long unless it lies within `PlaybackEdges.joinGapSeconds` of one of `ranges`
  /// (the ads already served for the episode, as shown) or overlaps one: the player joins it to
  /// that ad, so it is skipped with it and not as a sliver of its own, such as a lead-in sentence
  /// detection missed.
  public static func isLongEnough(start: Double, end: Double, beside ranges: [TimeSpan]) -> Bool {
    let length = end - start
    guard length > 0 else { return false }
    if length >= minimumSeconds { return true }
    return ranges.contains {
      $0.start - end <= PlaybackEdges.joinGapSeconds && start - $0.end <= PlaybackEdges.joinGapSeconds
    }
  }

  /// A range as this function sees it: a span, whether skipping it finishes the item, and which of
  /// the caller's ranges it is.
  public struct Piece: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var endsItem: Bool
    /// The index of the range this is all or part of in the caller's list; nil for a mark.
    public var source: Int?

    public init(start: Double, end: Double, endsItem: Bool, source: Int?) {
      self.start = start
      self.end = end
      self.endsItem = endsItem
      self.source = source
    }
  }

  /// What is served once `marks` are laid over `ranges`, sorted by start. Marks that overlap are
  /// served as one. Each range loses what a mark covers; a remnant keeps its `source`, keeps
  /// `endsItem` only while it still reaches the range's own end, and is dropped under
  /// `minimumSeconds`. A mark has no `source`. A range no mark touches is returned as it was.
  public static func laying(
    _ marks: [TimeSpan], over ranges: [(start: Double, end: Double, endsItem: Bool)]
  ) -> [Piece] {
    var merged: [TimeSpan] = []
    for mark in marks.filter({ $0.end > $0.start }).sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
      if let last = merged.last, mark.start <= last.end {
        merged[merged.count - 1] = TimeSpan(start: last.start, end: max(last.end, mark.end))
      } else {
        merged.append(mark)
      }
    }
    var pieces = merged.map { Piece(start: $0.start, end: $0.end, endsItem: false, source: nil) }
    for (index, range) in ranges.enumerated() {
      let touching = merged.filter { $0.start < range.end && range.start < $0.end }
      guard touching.isEmpty == false else {
        pieces.append(Piece(start: range.start, end: range.end, endsItem: range.endsItem, source: index))
        continue
      }
      var start = range.start
      var remnants: [TimeSpan] = []
      for mark in touching {
        if mark.start > start { remnants.append(TimeSpan(start: start, end: mark.start)) }
        start = max(start, mark.end)
      }
      if start < range.end { remnants.append(TimeSpan(start: start, end: range.end)) }
      for remnant in remnants where remnant.end - remnant.start >= minimumSeconds {
        pieces.append(
          Piece(
            start: remnant.start, end: remnant.end, endsItem: remnant.end == range.end && range.endsItem,
            source: index))
      }
    }
    return pieces.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  /// The span a mark at `start..<end` teaches the store, or nil when it teaches nothing. A mark of
  /// `ConfirmedReach.minimumSeconds` or more teaches its own span. A shorter one teaches only
  /// together with the ad it abuts, so its words are learned as part of that ad: the span joining
  /// it to the one of `rows` (the stored spans of ads already served, never the listener's own)
  /// nearest it, within `PlaybackEdges.joinGapSeconds`, the later one on a tie, an overlap being a
  /// gap of nothing. Nil when none is that near or the joined span is still too short to match.
  public static func teachingSpan(start: Double, end: Double, beside rows: [TimeSpan]) -> TimeSpan? {
    guard end > start else { return nil }
    let minimum = ConfirmedReach.minimumSeconds
    if end - start >= minimum { return TimeSpan(start: start, end: end) }
    func gap(_ row: TimeSpan) -> Double { max(row.start - end, start - row.end, 0) }
    guard
      let nearest = rows.filter({ gap($0) <= PlaybackEdges.joinGapSeconds }).min(by: {
        (gap($0), -$0.start) < (gap($1), -$1.start)
      })
    else { return nil }
    let joined = TimeSpan(start: min(start, nearest.start), end: max(end, nearest.end))
    return joined.end - joined.start >= minimum ? joined : nil
  }

  /// The confirmed creative a span teaches the store (see `teachingSpan`): the shingles of
  /// `transcript`, the listener's complete one, lying wholly inside it, as `SignatureStore.learning`
  /// takes them. A short span may hold none: its audio print, which the caller adds, is what
  /// reaches other episodes (`ConfirmedReach`). Nil for a span shorter than
  /// `ConfirmedReach.minimumSeconds`, which cannot be matched.
  public static func creative(
    from transcript: PreparedTranscript, start: Double, end: Double, teachers: Set<EpisodeKey>
  ) -> NewSignatureCreative? {
    guard end - start >= ConfirmedReach.minimumSeconds else { return nil }
    let hashes = Set(transcript.shingles.lazy.filter { start <= $0.start && $0.end <= end }.map(\.hash))
    return NewSignatureCreative(
      kind: .learned, start: start, end: end, teachers: teachers, hashes: hashes, confirmed: true)
  }
}
