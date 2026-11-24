import AppModel
import Foundation
import Testing

@testable import Whirr

/// The app-wide setting's defaults and its stream.
@Suite("Trim Silences preferences")
struct TrimSilencesPreferencesTests {

  private func makeDefaults() throws -> UserDefaults {
    let name = "TrimSilencesPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("absent keys read as off at Moderate")
  func absentMeansOffAtModerate() throws {
    let preferences = UserDefaultsTrimSilencesPreferences(defaults: try makeDefaults())
    #expect(preferences.current == .off)
    #expect(preferences.current.strength == .moderate)
  }

  @Test("the stored setting is read back")
  func storedSettingReadsBack() throws {
    let preferences = UserDefaultsTrimSilencesPreferences(defaults: try makeDefaults())
    preferences.setEnabled(true)
    preferences.setStrength(.maximum)
    #expect(preferences.current == TrimSilencesDefault(isEnabled: true, strength: .maximum))
  }

  @Test("an unknown strength from another build reads as Moderate")
  func unknownStrengthIsModerate() throws {
    let defaults = try makeDefaults()
    defaults.set(true, forKey: UserDefaultsTrimSilencesPreferences.enabledKey)
    defaults.set("extreme", forKey: UserDefaultsTrimSilencesPreferences.strengthKey)
    let current = UserDefaultsTrimSilencesPreferences(defaults: defaults).current
    #expect(current == TrimSilencesDefault(isEnabled: true, strength: .moderate))
  }

  @Test("the stream starts with the current value and forwards only real changes")
  func streamForwardsChanges() async throws {
    let defaults = try makeDefaults()
    let preferences = UserDefaultsTrimSilencesPreferences(defaults: defaults)
    var iterator = preferences.observeDefault().makeAsyncIterator()
    #expect(await iterator.next() == .off)

    // An unrelated write posts the same notification and must not emit.
    defaults.set(2, forKey: "unrelated.key")
    preferences.setEnabled(true)
    #expect(await iterator.next() == TrimSilencesDefault(isEnabled: true, strength: .moderate))
    preferences.setStrength(.maximum)
    #expect(await iterator.next() == TrimSilencesDefault(isEnabled: true, strength: .maximum))
  }
}
