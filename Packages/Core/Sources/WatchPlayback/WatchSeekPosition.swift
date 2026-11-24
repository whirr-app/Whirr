/// The range a seek surface offers for the title loaded on the Watch and the position a chosen
/// value becomes. Pure, so the player's controls and the tests share one rule.
///
/// A received RSS episode has no phone to scrub it and skip buttons move only seconds at a time, so
/// the Watch needs a control for the whole timeline. The engine's duration can still be zero before
/// the item reports one and indefinite for a live stream; neither is a range to seek across.
public enum WatchSeekPosition {
  /// The surface's bounds. A title without a usable duration still gets a one-second range so a
  /// control stays valid; `isSeekable` is what tells the screen to offer nothing.
  public static func bounds(duration: Double?) -> ClosedRange<Double> {
    guard let duration, isSeekable(duration: duration) else { return 0...1 }
    return 0...duration
  }

  /// A finite position inside the title. A non-finite or out-of-range value lands on a bound rather
  /// than letting the control move the playhead past the end of the audio.
  public static func clamped(_ position: Double, duration: Double?) -> Double {
    let bounds = bounds(duration: duration)
    guard position.isFinite else { return bounds.lowerBound }
    return min(max(position, bounds.lowerBound), bounds.upperBound)
  }

  public static func isSeekable(duration: Double?) -> Bool {
    guard let duration else { return false }
    return duration.isFinite && duration > 0
  }

  /// Seconds of audio per Digital Crown detent. About 240 detents cross the whole title: few
  /// enough that an hour is about a forward turn, and never less than a second so a short episode
  /// still moves in useful steps.
  public static func crownStride(duration: Double?) -> Double {
    guard let duration, isSeekable(duration: duration) else { return 1 }
    return max(1, (duration / 240).rounded())
  }
}
