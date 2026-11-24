import Foundation
import Testing

@testable import Whirr

/// The Reduce Ads setting's storage: off by default, and every write, whichever path made it,
/// reaches the coordinator's stream.
@Suite("Ad skip preference")
struct AdSkipPreferenceTests {

  private func isolatedDefaults() throws -> UserDefaults {
    let name = "AdSkipPreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("off until turned on")
  func offByDefault() throws {
    #expect(AdSkipPreference.isEnabled(in: try isolatedDefaults()) == false)
  }

  @Test("the stream starts with the current value and follows writes")
  func streamFollowsWrites() async throws {
    let defaults = try isolatedDefaults()
    var values = AdSkipPreference.changes(in: defaults).makeAsyncIterator()
    #expect(await values.next() == false)

    defaults.set(true, forKey: AdSkipPreference.key)
    #expect(await values.next() == true)
  }
}
