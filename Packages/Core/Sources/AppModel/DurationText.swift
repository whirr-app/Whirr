/// One owner for the app's duration and remainder wording. Each style names the fact it states, so
/// surfaces stating the same fact share one rounding rule instead of drifting apart.
///
/// The player's `h:mm:ss` clock is not here: it belongs to `WhirrClockFormatting` in DesignSystem, a
/// leaf the player and chapter list share, and DesignSystem cannot depend on AppModel.
public enum DurationText {
  /// "1 hr 5 min", "2 hr", "12 min". A positive duration under a minute reads "1 min"; truncating,
  /// so a 90-second chapter never reads as two minutes while an episode length reads one.
  public static func long(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0 min" }
    let totalMinutes = Int(min(max(seconds, 0), 1e9)) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0, minutes > 0 { return "\(hours) hr \(minutes) min" }
    if hours > 0 { return "\(hours) hr" }
    guard seconds > 0 else { return "0 min" }
    return "\(max(1, minutes)) min"
  }

  /// "1h 5m", "2h", "12m", "<1m"; zero reads "0m". Rounded to the nearest minute, so every
  /// compact remainder agrees with the player's.
  public static func compact(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0m" }
    guard seconds >= 60 else { return "<1m" }
    let totalMinutes = Int((min(seconds, 1e9) / 60).rounded())
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes)m" }
    if minutes == 0 { return "\(hours)h" }
    return "\(hours)h \(minutes)m"
  }

  /// `compact`'s rounded clock with " left", keeping the zero minutes for an exact number of
  /// hours: "80h 0m left". A caption reading "80h left" would hide that the figure is rounded.
  public static func remaining(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0m left" }
    guard seconds >= 60 else { return "<1m left" }
    let totalMinutes = Int((min(seconds, 1e9) / 60).rounded())
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 { return "\(hours)h \(minutes)m left" }
    return "\(minutes)m left"
  }
}
