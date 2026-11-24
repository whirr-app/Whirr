import AppModel
import Foundation

/// The app-wide Trim Silences setting, which syncs through `ICloudSettingsSync`. The time it
/// saves is counted by `UserDefaultsTimeSaved`.
nonisolated struct UserDefaultsTrimSilencesPreferences: TrimSilencesDefaultSource {
  static let enabledKey = "player.trimSilences.enabled"
  static let strengthKey = "player.trimSilences.strength"

  // `UserDefaults` is thread-safe but not annotated `Sendable`.
  private nonisolated(unsafe) let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Absent means off at Moderate. An unknown strength, from a newer build on another device,
  /// reads as Moderate rather than switching the feature off. A Focus filter's trim rides along
  /// from its device-local key, so a Focus change emits on `observeDefault()` like any other.
  var current: TrimSilencesDefault {
    TrimSilencesDefault(
      isEnabled: defaults.bool(forKey: Self.enabledKey),
      strength: defaults.string(forKey: Self.strengthKey).flatMap(TrimStrength.init(rawValue:))
        ?? .moderate,
      focus: FocusPlaybackSpeedState.focusTrim(in: defaults))
  }

  func setEnabled(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: Self.enabledKey)
  }

  func setStrength(_ strength: TrimStrength) {
    defaults.set(strength.rawValue, forKey: Self.strengthKey)
  }

  /// The current value, then each change. `didChangeNotification` fires for every write in the
  /// process, so only a real change is forwarded.
  func observeDefault() -> AsyncStream<TrimSilencesDefault> {
    let source = self
    return PreferenceChanges.stream(
      read: { source.current },
      notificationNames: [UserDefaults.didChangeNotification],
      object: defaults)
  }
}
