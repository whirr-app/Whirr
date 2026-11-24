import CoreGraphics

/// Pure presentation policy for the transient feedback shown while seeking playback.
public enum SeekFeedbackPresentation {
  /// What the bubble is currently describing.
  public enum Content: Sendable, Equatable {
    /// An engaged scrub: the absolute target elapsed time within the scrubber's current scope.
    case scrub(targetSeconds: Double)
    /// A skip episode: the accumulated requested signed delta.
    case skip(deltaSeconds: Double)
  }

  /// Adds consecutive requested skip deltas, preserving an opposing sequence's zero receipt.
  public static func accumulated(existing: Double, adding: Double) -> Double {
    (existing.isFinite ? existing : 0) + (adding.isFinite ? adding : 0)
  }

  /// Gives an engaged scrub precedence over a skip receipt so one bubble describes one gesture.
  public static func resolved(scrub: Double?, skip: Double?) -> Content? {
    if let scrub {
      return .scrub(targetSeconds: scrub)
    }
    if let skip {
      return .skip(deltaSeconds: skip)
    }
    return nil
  }

  /// Returns the leading x-offset for a bubble, keeping its bounds inside the track when possible.
  /// If the bubble is wider than the track, its leading edge is the centred (necessarily negative)
  /// offset; invalid or non-positive geometry returns zero rather than producing NaN.
  public static func bubbleCenter(
    trackWidth: CGFloat, bubbleWidth: CGFloat, fraction: Double
  ) -> CGFloat {
    guard
      trackWidth.isFinite, bubbleWidth.isFinite, fraction.isFinite,
      trackWidth > 0, bubbleWidth > 0
    else { return 0 }

    guard bubbleWidth <= trackWidth else {
      return (trackWidth - bubbleWidth) / 2
    }
    let center = min(max(CGFloat(fraction) * trackWidth, bubbleWidth / 2), trackWidth - bubbleWidth / 2)
    return center - bubbleWidth / 2
  }

  /// Formats a requested skip as a signed compact duration, retaining zero as a visible receipt.
  public static func skipLabel(deltaSeconds: Double) -> String {
    let seconds = wholeSeconds(deltaSeconds)
    let sign: String
    if seconds < 0 {
      sign = "−"
    } else if seconds > 0 {
      sign = "+"
    } else {
      sign = ""
    }

    let magnitude = abs(seconds)
    if magnitude < 60 {
      return "\(sign)\(magnitude) sec"
    }
    return "\(sign)\(clock(magnitude))"
  }

  /// Formats the non-negative absolute elapsed target using the player's scoped clock shape.
  public static func scrubLabel(targetSeconds: Double) -> String {
    WhirrClockFormatting.clock(targetSeconds.isFinite ? max(0, targetSeconds) : 0)
  }

  private static func wholeSeconds(_ seconds: Double) -> Int {
    guard seconds.isFinite else { return 0 }
    let rounded = abs(seconds).rounded(.toNearestOrAwayFromZero)
    return rounded >= Double(Int.max) ? Int.max : Int(rounded) * (seconds < 0 ? -1 : 1)
  }

  private static func clock(_ seconds: Int) -> String {
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    if hours > 0 {
      return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
    }
    return "\(minutes):\(twoDigits(remainder))"
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }
}
