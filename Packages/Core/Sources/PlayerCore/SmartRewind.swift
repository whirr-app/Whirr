import Foundation

public enum SmartRewind {
  /// Below this, a pause is a transport fumble rather than a break, and rewinding would fight the
  /// listener.
  public static let minimumPauseSeconds: Double = 15
  /// The ceiling. Past roughly half an hour the listener has lost the thread either way, and more
  /// rewind stops being re-orientation and starts being re-listening they did not ask for.
  public static let maximumRewindSeconds: Double = 10
  /// Seconds of rewind earned per doubling of pause length past `minimumPauseSeconds`. Chosen so
  /// the curve arrives at `maximumRewindSeconds` right around a thirty-minute pause.
  public static let secondsPerDoubling: Double = 1.45

  /// How far to seek back for a pause of `seconds`. Pure, total, monotonic non-decreasing.
  public static func rewindSeconds(pausedFor seconds: Double) -> Double {
    guard seconds.isFinite, seconds >= minimumPauseSeconds else { return 0 }
    return min(
      maximumRewindSeconds,
      secondsPerDoubling * log2(seconds / minimumPauseSeconds))
  }

  /// Where a resume should land: the curve above, floored at `chapterStart`.
  ///
  /// A listener who paused at or just past a chapter start has no thread to pick up, and
  /// rewinding across the boundary would replay the finished chapter's end and flip the
  /// lock-screen title and scrubber back. The curve caps at `maximumRewindSeconds`, so the floor
  /// only bites within that distance of the boundary.
  ///
  /// `chapterStart` is nil when the book has no chapters or the position sits in a gap (no floor).
  /// A non-finite `chapterStart`, or one ahead of `position`, is ignored. The result never
  /// exceeds `position`.
  public static func resumeTarget(
    from position: Double, pausedFor seconds: Double, chapterStart: Double?
  ) -> Double {
    let target = position - rewindSeconds(pausedFor: seconds)
    guard let chapterStart, chapterStart.isFinite, chapterStart <= position else { return target }
    return max(target, chapterStart)
  }
}
