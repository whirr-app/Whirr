import Foundation
import Testing

/// The first-party privacy manifest is a declaration to Apple, and it stays true only while the
/// code it describes stays the same. These tests pin what the shipped bundle claims. A required-
/// reason API used without a matching declaration is an upload rejection (ITMS-91053). A
/// declaration for an API the app does not use is a false statement. The source half, that no
/// first-party code uses an undeclared API, is the `no-undeclared-required-reason-api` rule in
/// `Scripts/source-rules/privacy.toml`.
@Suite("Privacy manifest contract")
struct PrivacyManifestContractTests {

  /// Exactly what `App/Whirr/PrivacyInfo.xcprivacy` may declare. Changing this set needs fresh
  /// evidence for each new entry.
  private static let approvedReasons: [String: Set<String>] = [
    // `volumeAvailableCapacityForImportantUsageKey`: read by the download scheduler before it
    // writes, and shown as remaining capacity in Settings.
    "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1"],
    // `ProcessInfo.systemUptime`: monotonic reference for playback position, reading-session
    // duration, and background-download pacing. Elapsed time only, never sent off device.
    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
    // File modification dates: the ad-skip transcript sweep's grace window and the analysed-episode
    // fingerprint. Only files inside the app container, never shown or sent off device.
    "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
    // `UserDefaults`: the app's own preferences, mirrored only to the same app's iCloud key-value
    // store. The widget App Group carries files only, so a `UserDefaults(suiteName:)` on the group
    // would need its own reason here and in the extension.
    "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
  ]

  private func manifest() throws -> [String: Any] {
    let url = try #require(
      Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
      "the app bundle ships no first-party privacy manifest")
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(plist as? [String: Any], "privacy manifest is not a dictionary")
  }

  @Test("the manifest ships in the app bundle and declares no tracking or collection")
  func manifestDeclaresNoTracking() throws {
    let manifest = try manifest()
    #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    #expect(manifest["NSPrivacyTrackingDomains"] as? [String] == [])
    // Listening state goes only to the server the person configured and controls. That is not
    // collection by the developer, who has no access to it, and the archive has no analytics or
    // crash-reporting SDK. An entry appearing here means one of those changed.
    #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
  }

  @Test("the declared required-reason APIs are exactly the approved set")
  func declaredReasonsMatchTheApprovedSet() throws {
    let entries = try #require(
      try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
      "manifest declares no NSPrivacyAccessedAPITypes array")

    var declared: [String: Set<String>] = [:]
    for entry in entries {
      let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
      let reasons = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
      #expect(declared[category] == nil, "category \(category) is declared twice")
      declared[category] = Set(reasons)
    }
    #expect(declared == Self.approvedReasons)
  }
}
