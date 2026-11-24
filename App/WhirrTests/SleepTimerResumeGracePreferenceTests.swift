import Foundation
import Testing

@testable import Whirr

/// The stored resume window for the sleep timer. Off until the listener picks a window, and read
/// back in seconds.
@Suite("Sleep timer resume grace preference")
struct SleepTimerResumeGracePreferenceTests {

  private func isolatedDefaults() throws -> UserDefaults {
    let name = "SleepTimerResumeGracePreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("off until a window is chosen")
  func offByDefault() throws {
    let preferences = UserDefaultsPlaybackPreferences(defaults: try isolatedDefaults())
    #expect(preferences.loadSleepTimerResumeGraceSeconds() == 0)
  }

  @Test("a chosen window reads back in seconds")
  func chosenWindowReadsBack() throws {
    let defaults = try isolatedDefaults()
    defaults.set(300, forKey: UserDefaultsPlaybackPreferences.sleepTimerResumeGraceKey)
    let preferences = UserDefaultsPlaybackPreferences(defaults: defaults)
    #expect(preferences.loadSleepTimerResumeGraceSeconds() == 300)
  }

  @Test("a negative stored value is off")
  func negativeIsOff() throws {
    let defaults = try isolatedDefaults()
    defaults.set(-60, forKey: UserDefaultsPlaybackPreferences.sleepTimerResumeGraceKey)
    let preferences = UserDefaultsPlaybackPreferences(defaults: defaults)
    #expect(preferences.loadSleepTimerResumeGraceSeconds() == 0)
  }

  @Test("Settings offers Off and the agreed windows")
  func offeredWindows() {
    #expect(UserDefaultsPlaybackPreferences.sleepTimerResumeGraceOptions == [0, 120, 300, 600, 900])
  }
}
