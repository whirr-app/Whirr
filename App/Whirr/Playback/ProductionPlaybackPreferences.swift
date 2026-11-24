import Foundation
import PlayerCore

/// Production `PlaybackPreferences`: persists the user's preferred playback rate to
/// `UserDefaults`. It never syncs to ABS or touches the account database; the app's explicit
/// non-sensitive preference allowlist may mirror it through iCloud key-value storage.
struct UserDefaultsPlaybackPreferences: PlaybackPreferences {
  static let rateKey = "com.remoteconcern.whirr.playbackRate"
  static let smartRewindKey = "player.smartRewind.enabled"
  static let sleepTimerResumeGraceKey = "player.sleepTimer.resumeGraceSeconds"
  /// Voice Boost. Read by `VoiceBoostPreferenceObserver`, not `PlayerCore`.
  static let voiceBoostKey = "player.voiceBoost.enabled"
  /// What Settings offers for the sleep timer's resume window, in seconds. 0 is Off, the default.
  static let sleepTimerResumeGraceOptions = [0, 120, 300, 600, 900]

  // `UserDefaults` is documented thread-safe but predates `Sendable`, so `nonisolated(unsafe)`
  // records that it crosses actors safely unverified. `AudioInterruptionRouteAdapter` and
  // `ScenePhaseAppLifecycle` do the same for `NotificationCenter`.
  private nonisolated(unsafe) let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `UserDefaults.double(forKey:)` returns `0` for a missing key, and `0` is never a legal
  /// playback rate, so it is an unambiguous "never saved" sentinel.
  func loadRate() -> Double? {
    let value = defaults.double(forKey: Self.rateKey)
    return value == 0 ? nil : value
  }

  func saveRate(_ rate: Double) {
    defaults.set(rate, forKey: Self.rateKey)
  }

  /// Absent means never set, which is on. `UserDefaults.bool(forKey:)` alone would read a fresh
  /// install as disabled.
  func loadSmartRewindEnabled() -> Bool {
    guard defaults.object(forKey: Self.smartRewindKey) != nil else { return true }
    return defaults.bool(forKey: Self.smartRewindKey)
  }

  /// Absent means off: Voice Boost is opt-in, the opposite of Smart Rewind.
  func loadVoiceBoostEnabled() -> Bool {
    defaults.bool(forKey: Self.voiceBoostKey)
  }

  /// Absent reads as 0, which is Off. A value synced from another device is honoured as long as it
  /// is a usable window; anything else is Off rather than a guess.
  func loadSleepTimerResumeGraceSeconds() -> Double {
    let seconds = defaults.integer(forKey: Self.sleepTimerResumeGraceKey)
    return seconds > 0 ? Double(seconds) : 0
  }
}
