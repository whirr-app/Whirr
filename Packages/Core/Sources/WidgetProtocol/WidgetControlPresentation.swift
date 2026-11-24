import Foundation

/// What the Control Center, Lock Screen and Action button controls draw, decided from the widget
/// snapshot. Pure so the extension, which has no test target, can stay a thin view layer.
public enum WidgetControlPresentation: Sendable {
  /// Used when the snapshot has no interval, or one the app never offers.
  public static let fallbackSkipBackSeconds = 15

  /// The Play or Pause toggle's value. Unavailable, signed-out and idle all read as off.
  public static func isPlaying(_ snapshot: WidgetSnapshot?) -> Bool {
    snapshot?.nowPlaying?.isPlaying ?? false
  }

  /// The interval the Skip Back control shows. Anything outside `WidgetSnapshotLimits.skipIntervals`
  /// becomes the fallback, so the symbol name below always names a symbol that exists.
  public static func skipBackSeconds(_ seconds: Int?) -> Int {
    guard let seconds, WidgetSnapshotLimits.skipIntervals.contains(seconds) else {
      return fallbackSkipBackSeconds
    }
    return seconds
  }

  public static func skipBackSeconds(_ snapshot: WidgetSnapshot?) -> Int {
    skipBackSeconds(snapshot?.skipBackSeconds)
  }

  public static func skipBackSymbolName(seconds: Int) -> String {
    "gobackward.\(skipBackSeconds(seconds))"
  }

  public static func skipBackLabel(seconds: Int) -> String {
    "Back \(skipBackSeconds(seconds)) s"
  }

  public static func playPauseSymbolName(isPlaying: Bool) -> String {
    isPlaying ? "pause.fill" : "play.fill"
  }

  public static func playPauseValueText(isPlaying: Bool) -> String {
    isPlaying ? "Playing" : "Paused"
  }
}
