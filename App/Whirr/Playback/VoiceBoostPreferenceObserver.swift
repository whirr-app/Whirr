import AppModel
import Foundation
import Observation
import Persistence

/// Forwards Voice Boost to the player engine: the value the loaded show resolves to, from the
/// app-wide preference and the show's own setting. Applies at start-up, then on every change of
/// the preference (including one from another device via `ICloudSettingsSync`), the show
/// settings, or the loaded show. The DSP is a real-time tap that never reads `UserDefaults`, so a
/// change while playing needs no reload. Nothing loaded, an audiobook, or no account follows the
/// preference alone. `UserDefaults.didChangeNotification` names no key, so only a real change in
/// the resolved value is forwarded, as `AppAppearanceStore` does.
@MainActor
final class VoiceBoostPreferenceObserver {
  private let defaults: UserDefaults
  private let apply: @MainActor (Bool) -> Void
  private var preference: Bool
  private var loadedShow: String?
  private var overrides: [String: VoiceBoostShowOverride] = [:]
  private var current: Bool
  private var observer: NSObjectProtocol?
  private var showTasks: [Task<Void, Never>] = []

  init(defaults: UserDefaults, apply: @escaping @MainActor (Bool) -> Void) {
    self.defaults = defaults
    self.apply = apply
    preference = UserDefaultsPlaybackPreferences(defaults: defaults).loadVoiceBoostEnabled()
    current = preference
    apply(current)
    observer = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshPreference()
      }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    for task in showTasks { task.cancel() }
  }

  /// Follows one account's show settings and loaded show, replacing what it followed before.
  /// `loadedShow` returns the playing podcast's item id, or nil for an audiobook or nothing.
  func followShows(
    overrides: AsyncStream<[String: VoiceBoostShowOverride]>,
    loadedShow: @escaping @MainActor @Sendable () -> String?
  ) {
    stopFollowingShows()
    let shows = Observations(loadedShow)
    showTasks = [
      Task { [weak self] in
        for await values in overrides {
          guard Task.isCancelled == false, let self else { return }
          self.overrides = values
          self.resolve()
        }
      },
      Task { [weak self] in
        for await show in shows {
          guard Task.isCancelled == false, let self else { return }
          self.loadedShow = show
          self.resolve()
        }
      },
    ]
  }

  /// Back to the preference alone, as at logout.
  func stopFollowingShows() {
    for task in showTasks { task.cancel() }
    showTasks = []
    overrides = [:]
    loadedShow = nil
    resolve()
  }

  private func refreshPreference() {
    preference = UserDefaultsPlaybackPreferences(defaults: defaults).loadVoiceBoostEnabled()
    resolve()
  }

  private func resolve() {
    let next =
      loadedShow.map {
        VoiceBoostResolution.isOn(default: preference, showOverride: overrides[$0] ?? .inherit)
      } ?? preference
    guard next != current else { return }
    current = next
    apply(next)
  }
}

/// The app-wide Voice Boost preference as the per-show model reads it: the default for every show
/// without its own setting.
nonisolated struct UserDefaultsVoiceBoostDefault: VoiceBoostDefaultSource {
  // `UserDefaults` is thread-safe but not annotated `Sendable`.
  private nonisolated(unsafe) let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var current: Bool {
    UserDefaultsPlaybackPreferences(defaults: defaults).loadVoiceBoostEnabled()
  }

  /// The current value, then each real change.
  func observeDefault() -> AsyncStream<Bool> {
    let source = self
    return PreferenceChanges.stream(
      read: { source.current },
      notificationNames: [UserDefaults.didChangeNotification],
      object: defaults)
  }
}
