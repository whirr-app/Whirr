import Foundation

/// The one freshness budget for a phone↔Watch session. The setup handshake and command admission
/// draw on the same window; each call site keeps its own edge, so an age or remaining lifetime of
/// exactly `window` is still admitted where the range is closed and expires where it is half-open.
public enum WatchSetupLimits {
  public static let window: TimeInterval = 120
}
