/// Pure `h:mm:ss`/`mm:ss` formatting shared by App's player presentation and its chapter list.
/// Unusable media durations become `00:00` rather than reaching integer conversion.
public enum WhirrClockFormatting {
  public struct ClockParts: Equatable {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int

    public init(hours: Int, minutes: Int, seconds: Int) {
      self.hours = hours
      self.minutes = minutes
      self.seconds = seconds
    }
  }

  public static func clock(_ seconds: Double) -> String {
    let parts = clockParts(seconds)
    if parts.hours > 0 {
      return "\(parts.hours):\(twoDigits(parts.minutes)):\(twoDigits(parts.seconds))"
    }
    return "\(twoDigits(parts.minutes)):\(twoDigits(parts.seconds))"
  }

  public static func clockParts(_ seconds: Double) -> ClockParts {
    guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else {
      return ClockParts(hours: 0, minutes: 0, seconds: 0)
    }
    let wholeSeconds = Int(seconds.rounded(.down))
    return ClockParts(
      hours: wholeSeconds / 3_600,
      minutes: (wholeSeconds % 3_600) / 60,
      seconds: wholeSeconds % 60)
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }
}
