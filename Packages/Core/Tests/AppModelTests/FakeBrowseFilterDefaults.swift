import Foundation

@testable import AppModel

/// An in-memory `BrowseFilterDefaults`, per test.
///
/// A `UserDefaults(suiteName:)` per test would write a real plist into `~/Library/Preferences` and
/// register each suite with `cfprefsd`: disk I/O and shared daemon state in a pure value check.
/// `UserDefaults.standard` is worse, since the filter persists and tests would share state.
final class FakeBrowseFilterDefaults: BrowseFilterDefaults {
  private var values: [String: String] = [:]

  init(_ initialValues: [String: String] = [:]) {
    values = initialValues
  }

  func filterString(forKey key: String) -> String? { values[key] }

  func setFilterString(_ value: String?, forKey key: String) {
    if let value {
      values[key] = value
    } else {
      values.removeValue(forKey: key)
    }
  }

  /// Test-only: whether anything is stored at all, for asserting that clearing removes the key
  /// rather than storing an empty value.
  var isEmpty: Bool { values.isEmpty }
}
