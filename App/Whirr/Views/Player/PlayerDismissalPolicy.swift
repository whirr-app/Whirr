import CoreGraphics
import Foundation

/// Pure decision layer for the expanded player's UIKit-owned interactive dismissal.
///
/// Every value is a plain function of gesture inputs, so finish/cancel behaviour is testable
/// without a view controller, a transition or the player view.
enum PlayerDismissalPolicy {

  // MARK: - Tuning

  /// Travelled progress at or beyond which a release finishes the dismissal on distance alone.
  static let finishProgressThreshold: CGFloat = 0.2

  /// Downward release speed that finishes the dismissal regardless of travelled distance.
  static let flickVelocityThreshold: CGFloat = 800

  /// How far ahead a release velocity is projected when deciding finish vs cancel.
  static let projectionInterval: CGFloat = 0.2

  /// The vertical speed must exceed horizontal speed by this factor to claim the pan.
  static let verticalDominanceRatio: CGFloat = 1.0

  /// Slack allowed when deciding whether a scroll view is at its top boundary.
  static let scrollTopTolerance: CGFloat = 1.0

  /// The shortest permitted non-interactive remainder, preventing an abrupt snap.
  static let minimumCompletionDuration: TimeInterval = 0.2

  /// The longest permitted non-interactive remainder, preventing a sluggish finish or cancel.
  /// Long enough for a slow release near the top to be seen to travel the whole screen; the
  /// release spring is fitted to this, so the tail decelerates rather than stops.
  static let maximumCompletionDuration: TimeInterval = 0.55

  /// The largest `releaseVelocity` handed to the release spring, in remaining travels per second.
  /// The critically damped spring still overshoots at a large enough initial velocity, lifting a
  /// cancelled page above the top edge. The ratio spikes on a fast flick near the end of travel,
  /// where the remainder is too short for the clamp to be felt.
  static let releaseVelocityCeiling: CGFloat = 10

  /// The minimum speed used for timing when the release is stationary or nearly stationary.
  /// A 100-point-per-second floor keeps a long remainder responsive without producing infinity.
  static let completionVelocityFloor: CGFloat = 100

  /// The fastest release speed allowed to set the pace of the remaining travel. Raw flick timing
  /// would cross most of the screen before the start is noticed, reading as a cut. A faster flick
  /// still decides the dismissal instantly; only the leaving time is capped.
  static let completionVelocityCeiling: CGFloat = 2200

  // MARK: - Decisions

  enum Completion: Equatable {
    case finish
    case cancel
  }

  /// Whether the dismissal pan recognizer may begin at all: downward, vertically dominant motion.
  static func shouldBegin(velocity: CGPoint) -> Bool {
    guard velocity.x.isFinite, velocity.y.isFinite else { return false }
    return velocity.y > 0 && velocity.y > abs(velocity.x) * verticalDominanceRatio
  }

  /// Whether the player's scroll view is at (or within tolerance of) its top boundary.
  /// `contentOffsetY` is `scrollView.contentOffset.y`; `adjustedContentInsetTop` is
  /// `scrollView.adjustedContentInset.top`.
  static func isAtScrollTop(
    contentOffsetY: CGFloat, adjustedContentInsetTop: CGFloat
  ) -> Bool {
    guard contentOffsetY.isFinite, adjustedContentInsetTop.isFinite else { return false }
    return contentOffsetY <= -adjustedContentInsetTop + scrollTopTolerance
  }

  /// Normalized transition progress, with upward movement unable to reverse the dismissal.
  static func progress(translationY: CGFloat, containerHeight: CGFloat) -> CGFloat {
    guard translationY.isFinite, containerHeight.isFinite, containerHeight > 0 else { return 0 }

    let normalized = max(0, translationY) / containerHeight
    return min(max(normalized, 0), 1)
  }

  /// Finish or cancel from travelled progress projected forward by the release velocity.
  static func completion(
    progress: CGFloat, velocityY: CGFloat, containerHeight: CGFloat
  ) -> Completion {
    guard progress.isFinite, velocityY.isFinite, containerHeight.isFinite, containerHeight > 0
    else { return .cancel }

    let projected = progress + max(0, velocityY) * projectionInterval / containerHeight
    guard projected.isFinite else { return .cancel }

    if progress >= finishProgressThreshold
      || velocityY >= flickVelocityThreshold
      || projected >= finishProgressThreshold
    {
      return .finish
    }
    return .cancel
  }

  /// Bounded duration for the remaining non-interactive finish or cancel travel.
  static func completionDuration(
    progress: CGFloat, velocityY: CGFloat, containerHeight: CGFloat, completion: Completion
  ) -> TimeInterval {
    guard progress.isFinite, velocityY.isFinite, containerHeight.isFinite, containerHeight > 0
    else { return minimumCompletionDuration }

    let remainingProgress: CGFloat
    switch completion {
    case .finish:
      remainingProgress = 1 - progress
    case .cancel:
      remainingProgress = progress
    }

    let remainingTravel = remainingProgress * containerHeight
    let speed = min(
      max(abs(velocityY), completionVelocityFloor),
      completionVelocityCeiling)
    let candidate = TimeInterval(remainingTravel / speed)
    guard candidate.isFinite else {
      return remainingTravel > 0 ? maximumCompletionDuration : minimumCompletionDuration
    }

    return min(
      max(candidate, minimumCompletionDuration),
      maximumCompletionDuration)
  }

  /// The release speed as `UISpringTimingParameters` wants it: remaining travels per second,
  /// positive toward the end state. A finish continues downward, so a downward release is
  /// positive; a cancel returns upward, so the same release is negative and the spring turns the
  /// page round instead of cutting back to rest. Upward speed is read by sign too: the drag
  /// couldn't scrub upward, but the finger can still be moving that way on lift.
  static func releaseVelocity(
    progress: CGFloat, velocityY: CGFloat, containerHeight: CGFloat, completion: Completion
  ) -> CGFloat {
    guard progress.isFinite, velocityY.isFinite, containerHeight.isFinite, containerHeight > 0
    else { return 0 }

    let remainingProgress: CGFloat
    let direction: CGFloat
    switch completion {
    case .finish:
      remainingProgress = 1 - progress
      direction = 1
    case .cancel:
      remainingProgress = progress
      direction = -1
    }

    let remainingTravel = remainingProgress * containerHeight
    guard remainingTravel > 0 else { return 0 }

    let normalized = direction * velocityY / remainingTravel
    guard normalized.isFinite else { return 0 }
    return min(max(normalized, -releaseVelocityCeiling), releaseVelocityCeiling)
  }
}
