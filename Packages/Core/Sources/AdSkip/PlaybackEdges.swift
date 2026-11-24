import Foundation

/// Where a kept range stops skipping. Not part of the harness port: it runs after learning, so the
/// signature store and every parity target still see the frozen rules' ranges.
///
/// An ad's closing call to action usually names the show ("nordvpn.com/<show>"), so it recurs less
/// than the rest and the matched run stops a few seconds short. In the harness's predictions,
/// moving the end to the next pause within 5 s recovered more than 2 s of ad in 29 of 415 matched
/// ranges, and clipped more than 1 s of programme in 8 of 473.
public enum PlaybackEdges {
  /// How far past a range's end, over words, the end may move to the start of a pause.
  public static let endExtensionSeconds = 5.0

  /// `range` with its end at the first pause that starts within `endExtensionSeconds` after it.
  /// A pause starting up to 0.5 s before the end, as one the repetition stage has already
  /// extended to does, leaves the end where it is.
  public static func extendingEnd(of range: KeptRange, silences: [Silence]) -> KeptRange {
    guard
      let pause = silences.first(where: {
        range.end - 0.5 <= $0.start && $0.start <= range.end + endExtensionSeconds
      }), pause.start > range.end
    else { return range }
    return KeptRange(
      start: range.start, end: pause.start, meanAdProbability: range.meanAdProbability,
      endsItem: range.endsItem)
  }

  /// How close to the start of the file a range's start may be and still run back to zero.
  public static let itemStartSnapSeconds = 5.0

  /// `start`, or zero when it lies within `itemStartSnapSeconds` of the file's start. A pre-roll's
  /// opening words often name the brand, which the transcriber spells differently in each copy, so
  /// the match begins a few seconds into the ad. On the labelled sets, what precedes an ad that
  /// starts this early is a stitch, a channel ident or a greeting, and losing the opener before a
  /// pre-roll is accepted.
  public static func start(atItemStartFor start: Double) -> Double {
    start <= itemStartSnapSeconds ? 0 : start
  }

  /// How far after a silence ends a range's start may lie, and how far before one begins its end,
  /// for the served range to take in the whole silence. The repetition stage and `extendingEnd`
  /// put an edge on the silence itself; this absorbs rounding. A wider tolerance takes in audible
  /// audio: 0.5 s added up to 1.2 s of it per labelled set.
  public static let bridgeToleranceSeconds = 0.05

  /// `spans`, sorted by start, with each start moved up to the furthest end before it, so they are
  /// disjoint and cover their union. A span another wholly holds comes back empty. Two library
  /// matches can overlap within one break, and `bridgingSilences` would cut the first at the
  /// second's start, losing whatever the first ran past the second's end.
  public static func disjoint(_ spans: [TimeSpan]) -> [TimeSpan] {
    var reached = -Double.infinity
    return spans.map { span in
      let start = max(span.start, reached)
      reached = max(reached, span.end)
      return TimeSpan(start: start, end: max(start, span.end))
    }
  }

  /// The player's join (`PlayerReducer.skipJoinGap`): spans this close already play as one skip.
  public static let joinGapSeconds = 9.0

  /// The longest gap between two spans that is served with them.
  /// Every gap of 60 s or less in the labelled sets and on the owner's phone was ad, credits or
  /// neutral, never programme.
  public static let breakFillSeconds = 60.0

  /// The gaps between consecutive `spans`, which are sorted and disjoint, longer than
  /// `joinGapSeconds` and no longer than `breakFillSeconds`, less those `isRefused` refuses: what
  /// plays between two ads of one break, which no episode shares. Like the sting segment, a fill is
  /// playback-only and never learned.
  public static func breakFills(
    between spans: [TimeSpan], refusing isRefused: (TimeSpan) -> Bool
  ) -> [TimeSpan] {
    zip(spans, spans.dropFirst()).compactMap { before, after in
      let gap = TimeSpan(start: before.end, end: after.start)
      let length = gap.end - gap.start
      guard length > joinGapSeconds, length <= breakFillSeconds, isRefused(gap) == false else {
        return nil
      }
      return gap
    }
  }

  /// `ranges`, sorted and disjoint, each served from the start of the silence before it and to
  /// the end of the silence after it.
  ///
  /// An inserted ad is stitched in with digital silence on each side. The pipeline's edges stop at
  /// the ad's first and last frame, so the listener hears the gap and then whatever of the ad the
  /// output route had already buffered when the skip fired. A silence holds no programme, so taking
  /// it in is free. The nearest silence each side is used; neighbours sharing one meet at its end.
  public static func bridgingSilences(_ ranges: [TimeSpan], silences: [Silence]) -> [TimeSpan] {
    var result: [TimeSpan] = []
    var previousEnd = 0.0
    for (index, range) in ranges.enumerated() {
      let nextStart = index + 1 < ranges.count ? ranges[index + 1].start : Double.infinity
      var start = range.start
      if let before = silences.last(where: {
        $0.start < range.start && $0.end >= range.start - bridgeToleranceSeconds
      }) {
        start = max(previousEnd, min(range.start, before.start))
      }
      var end = range.end
      if let after = silences.first(where: {
        $0.end > range.end && $0.start <= range.end + bridgeToleranceSeconds
      }) {
        end = min(nextStart, max(range.end, after.end))
      }
      result.append(TimeSpan(start: start, end: end))
      previousEnd = end
    }
    return result
  }
}
