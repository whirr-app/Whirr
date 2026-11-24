import Foundation

/// Device-local choices of how far the skip-back and skip-forward controls move the playhead.
/// Each direction is persisted independently so a listener can use a short rewind to catch missed
/// dialogue and a longer jump for moving through intros or adverts.
nonisolated enum SkipIntervalConfiguration {
  static let forwardStorageKey = "player.skipInterval.forward.seconds"
  static let backwardStorageKey = "player.skipInterval.backward.seconds"
  static let defaultForwardSeconds = 30
  static let defaultBackwardSeconds = 15
  static let presets = [10, 15, 30, 45, 60, 75, 90]

  /// A missing key reads as `0` through `UserDefaults`, and a stale or hand-edited value can sit
  /// outside the menu. Either resolves to the directional default, so every stored state has a
  /// selected menu item. That is what lets `SkipIntervalStore`, `RemoteCommandAdapter` and
  /// `WatchCataloguePublisher` read these keys with a bare `integer(forKey:)`.
  static func resolvedSeconds(_ stored: Int, forward: Bool) -> Int {
    guard presets.contains(stored) else {
      return forward ? defaultForwardSeconds : defaultBackwardSeconds
    }
    return stored
  }

  static func systemImage(seconds: Int, forward: Bool) -> String {
    let base = forward ? "goforward" : "gobackward"
    let resolved = resolvedSeconds(seconds, forward: forward)
    return "\(base).\(resolved)"
  }

  static func accessibilityLabel(seconds: Int, forward: Bool) -> String {
    let resolved = resolvedSeconds(seconds, forward: forward)
    return "Skip \(forward ? "forward" : "back") \(displayName(seconds: resolved))"
  }

  static func accessibilityHint(seconds: Int, forward: Bool) -> String {
    let resolved = resolvedSeconds(seconds, forward: forward)
    return "Moves playback \(displayName(seconds: resolved)) \(forward ? "later" : "earlier")."
  }

  static func displayName(seconds: Int) -> String {
    seconds == 1 ? "1 second" : "\(seconds) seconds"
  }
}
