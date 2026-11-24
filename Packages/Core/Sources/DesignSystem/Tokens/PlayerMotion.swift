import SwiftUI

/// Reduce-Motion-aware animation tokens for the expanded player.
public enum PlayerMotion {
  /// Timeline readouts keep the same fade timing when their conditional content swaps.
  public static func timelineReadoutAnimation(reduceMotion: Bool) -> Animation? {
    guard reduceMotion == false else { return nil }
    return .easeOut(duration: 0.15)
  }

  /// Short ease-out for timeline emphasis while a scrub begins or ends.
  public static func timelineScrubbingAnimation(reduceMotion: Bool) -> Animation? {
    guard reduceMotion == false else { return nil }
    return .easeOut(duration: 0.15)
  }

  /// Short opacity/scale feedback for the transient seek bubble; Reduce Motion removes it.
  public static func seekFeedbackAnimation(reduceMotion: Bool) -> Animation? {
    guard reduceMotion == false else { return nil }
    return .easeOut(duration: 0.15)
  }

  /// The ambient canvas crossfade for a palette that arrived after the page had already committed
  /// to a neutral for the incoming item. Matches the 200ms ease of a cover's cold completion, as
  /// both are work that finished after the first frame. Reduce Motion applies it immediately.
  ///
  /// Only the page's background interpolates; the ink and metadata ladder travel as environment
  /// values and land on the transaction boundary. That is fine: app appearance owns the canvas's
  /// light/dark mode, so a late adoption never flips polarity and the ink stays inside the same
  /// AA-clamped band.
  public static func ambientAdoptionAnimation(reduceMotion: Bool) -> Animation? {
    guard reduceMotion == false else { return nil }
    return .easeInOut(duration: 0.2)
  }
}
