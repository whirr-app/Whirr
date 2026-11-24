import Foundation
import Testing

@testable import AppModel

enum ReleaseAudit {
  enum Rule: String, Equatable, Sendable {
    case acknowledgement
    case backgroundMode
    case bundleVersion
    case entitlement
    case exportCompliance
    case frameRate
    case liveActivities
    case packageInventory
    case transportSecurity
  }

  struct Finding: Equatable, CustomStringConvertible, Sendable {
    let rule: Rule
    let path: String

    var description: String { "\(rule.rawValue) at \(path)" }
  }

  struct PackagePin: Equatable, Sendable {
    let identity: String
    let version: String
    let location: String
    let revision: String

    init(
      identity: String,
      version: String,
      location: String = "fixture",
      revision: String = "fixture"
    ) {
      self.identity = identity
      self.version = version
      self.location = location
      self.revision = revision
    }
  }

  struct PropertyListFile {
    let path: String
    let values: [String: Any]
  }

  static let productionTargetNames: Set<String> = [
    "ABSApi", "PodcastFeeds", "Persistence", "SyncEngine", "PlayerCore", "ReaderCore", "AppModel",
    "DesignSystem",
  ]

  // Locations are copied from the two checked-in lockfiles. Comparison removes only URL scheme
  // and host case, a terminal slash, and a terminal `.git`; owner and repository path case stay
  // significant so a different source cannot satisfy the inventory.
  static let productionPackagePins: [String: PackagePin] = [
    "grdb.swift": PackagePin(
      identity: "grdb.swift", version: "7.11.1",
      location: "https://github.com/groue/GRDB.swift.git",
      revision: "b83108d10f42680d78f23fe4d4d80fc88dab3212"),
    "swift-toolkit": PackagePin(
      identity: "swift-toolkit", version: "3.11.0",
      location: "https://github.com/readium/swift-toolkit.git",
      revision: "d82f44f4f05d87add9e22a8b75abbd61dce745dd"),
    "cryptoswift": PackagePin(
      identity: "cryptoswift", version: "1.10.0",
      location: "https://github.com/krzyzanowskim/CryptoSwift.git",
      revision: "f2a627b84c1ff96f21ac2fcb623ab36142dd5512"),
    "differencekit": PackagePin(
      identity: "differencekit", version: "1.3.0",
      location: "https://github.com/ra1028/DifferenceKit.git",
      revision: "073b9671ce2b9b5b96398611427a1f929927e428"),
    "fuzi": PackagePin(
      identity: "fuzi", version: "4.0.0", location: "https://github.com/readium/Fuzi.git",
      revision: "347aab158ff8894966ff80469b384bb5337928cd"),
    "gcdwebserver": PackagePin(
      identity: "gcdwebserver", version: "4.0.1",
      location: "https://github.com/readium/GCDWebServer.git",
      revision: "584db89a4c3c3be27206cce6afde037b2b6e38d8"),
    "sqlite.swift": PackagePin(
      identity: "sqlite.swift", version: "0.16.0",
      location: "https://github.com/stephencelis/SQLite.swift.git",
      revision: "964c300fb0736699ce945c9edb56ecd62eba27a3"),
    "swiftsoup": PackagePin(
      identity: "swiftsoup", version: "2.13.7",
      location: "https://github.com/scinfu/SwiftSoup.git",
      revision: "8d6ad267714cac3ae747cefdd21f7a6665006e1f"),
    "zip": PackagePin(
      identity: "zip", version: "2.1.2", location: "https://github.com/marmelroy/Zip.git",
      revision: "67fa55813b9e7b3b9acee9c0ae501def28746d76"),
    "zipfoundation": PackagePin(
      identity: "zipfoundation", version: "3.0.1",
      location: "https://github.com/readium/ZIPFoundation.git",
      revision: "adb49c8bfe060cc187370b12fa081012a6440b86"),
  ]

  static let testOnlyPackagePins: [String: PackagePin] = [
    "swift-snapshot-testing": PackagePin(
      identity: "swift-snapshot-testing", version: "1.19.3",
      location: "https://github.com/pointfreeco/swift-snapshot-testing.git",
      revision: "1bc16f430d8410e7f087d4c787767b26fd32fe30"),
    "swift-custom-dump": PackagePin(
      identity: "swift-custom-dump", version: "1.6.1",
      location: "https://github.com/pointfreeco/swift-custom-dump",
      revision: "a8cd6c976f335ed361dcecddb0dc39ebda51bc3e"),
    "swift-syntax": PackagePin(
      identity: "swift-syntax", version: "603.0.2",
      location: "https://github.com/swiftlang/swift-syntax",
      revision: "79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1"),
    "xctest-dynamic-overlay": PackagePin(
      identity: "xctest-dynamic-overlay", version: "1.11.0",
      location: "https://github.com/pointfreeco/xctest-dynamic-overlay",
      revision: "8f6abcf4c8950e2679d5b2fee4ca284fd7c34886"),
  ]

  static func pins(at url: URL) throws -> [PackagePin] {
    try pins(from: Data(contentsOf: url))
  }

  static func pins(from data: Data) throws -> [PackagePin] {
    let object = try JSONSerialization.jsonObject(with: data)
    let root = try #require(object as? [String: Any])
    let rawPins = try #require(root["pins"] as? [[String: Any]])
    return try rawPins.map { rawPin in
      let identity = try #require(rawPin["identity"] as? String)
      let location = try #require(rawPin["location"] as? String)
      let state = try #require(rawPin["state"] as? [String: Any])
      let version = try #require(state["version"] as? String)
      let revision = try #require(state["revision"] as? String)
      return PackagePin(identity: identity, version: version, location: location, revision: revision)
    }
  }

  static func packageFindings(corePins: [PackagePin], appPins: [PackagePin]) -> [Finding] {
    var coreExpected = ["grdb.swift": productionPackagePins["grdb.swift"]!]
    coreExpected.merge(testOnlyPackagePins) { _, testOnly in testOnly }
    return packageFindings(
      pins: corePins,
      expected: coreExpected,
      path: "Packages/Core/Package.resolved"
    )
      + packageFindings(
        pins: appPins,
        expected: productionPackagePins,
        path: "App/Whirr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
      )
  }

  static func testOnlyDependencyFindings(targets: [PackageManifest.Target]) -> [Finding] {
    let testOnlyProducts = Set(["SnapshotTesting", "CustomDump", "SwiftSyntax", "XCTestDynamicOverlay"])
    return
      targets
      .filter { productionTargetNames.contains($0.name) }
      .flatMap { target in
        target.dependencies.intersection(testOnlyProducts).isEmpty
          ? []
          : [Finding(rule: .packageInventory, path: "Package.swift:\(target.name)")]
      }
  }

  static func configurationFindings(at repositoryRoot: URL) throws -> [Finding] {
    let infoURL = repositoryRoot.appendingPathComponent("App/Whirr/Info.plist")
    let infoPlist = try propertyList(at: infoURL)
    let appRoot = repositoryRoot.appendingPathComponent("App")
    let entitlements = try entitlementFiles(at: appRoot, repositoryRoot: repositoryRoot)
    guard entitlements.isEmpty == false else {
      throw EnumerationFailure.noEntitlementFiles(appRoot.path)
    }
    let projectText = try String(
      contentsOf: repositoryRoot.appendingPathComponent(projectPath), encoding: .utf8)
    return configurationFindings(infoPlist: infoPlist, entitlements: entitlements)
      + exportComplianceFindings(infoPlist: infoPlist, projectText: projectText)
      + liveActivityFindings(infoPlist: infoPlist, projectText: projectText)
      + bundleVersionFindings(projectText: projectText)
  }

  static let projectPath = "App/Whirr.xcodeproj/project.pbxproj"

  /// The App Group the app and the widget extension share.
  static let appGroup = "group.com.remoteconcern.whirr"
  static let widgetExtensionEntitlementsPath = "App/WhirrWidgetsExtension.entitlements"

  static func entitlementFiles(at appRoot: URL, repositoryRoot: URL) throws -> [PropertyListFile] {
    var files: [PropertyListFile] = []
    // A missing root must not read as "no entitlements, nothing to approve".
    guard
      let enumerator = FileManager.default.enumerator(
        at: appRoot, includingPropertiesForKeys: [.isDirectoryKey])
    else { throw EnumerationFailure.rootUnreachable(appRoot.path) }

    for case let url as URL in enumerator {
      let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
      if resourceValues.isDirectory == true,
        ignoredConfigurationDirectoryNames.contains(url.lastPathComponent.lowercased())
      {
        enumerator.skipDescendants()
        continue
      }
      guard url.pathExtension == "entitlements" else { continue }
      files.append(
        PropertyListFile(
          path: relativePath(url, to: repositoryRoot), values: try propertyList(at: url)))
    }
    return files
  }

  enum EnumerationFailure: Error, CustomStringConvertible {
    case rootUnreachable(String)
    case noEntitlementFiles(String)

    var description: String {
      switch self {
      case .rootUnreachable(let path): return "release audit root is unreachable at \(path)"
      case .noEntitlementFiles(let path):
        return "release audit found no .entitlements file under \(path); the app has several"
      }
    }
  }

  static func configurationFindings(
    infoPlist: [String: Any], entitlements: [PropertyListFile]
  ) -> [Finding] {
    var findings: [Finding] = []
    let backgroundModes = Set(infoPlist["UIBackgroundModes"] as? [String] ?? [])
    if backgroundModes != Set(["audio", "fetch", "remote-notification", "processing"]) {
      findings.append(Finding(rule: .backgroundMode, path: "App/Whirr/Info.plist"))
    }
    let taskIdentifiers = Set(
      infoPlist["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? [])
    if taskIdentifiers
      != Set([
        "com.remoteconcern.whirr.podcast-refresh", "com.remoteconcern.whirr.adskip-analysis",
      ])
    {
      findings.append(Finding(rule: .backgroundMode, path: "App/Whirr/Info.plist"))
    }
    if infoPlist["CADisableMinimumFrameDurationOnPhone"] as? Bool != true {
      findings.append(Finding(rule: .frameRate, path: "App/Whirr/Info.plist"))
    }
    for file in entitlements {
      if entitlementIsApproved(file) == false {
        findings.append(Finding(rule: .entitlement, path: file.path))
      }
    }
    findings.append(contentsOf: transportSecurityFindings(infoPlist: infoPlist))
    return findings
  }

  private static func entitlementIsApproved(_ file: PropertyListFile) -> Bool {
    if file.path == "App/WhirrWatch Watch App/WhirrWatch Watch App.entitlements" {
      return file.values.isEmpty
    }
    // The widget extension holds the shared group and nothing else: no iCloud, no push. Checked
    // before the key-value requirement below, which applies only to the app.
    if file.path == widgetExtensionEntitlementsPath {
      return Set(file.values.keys) == ["com.apple.security.application-groups"]
        && file.values["com.apple.security.application-groups"] as? [String] == [appGroup]
    }
    let kvs = "$(TeamIdentifierPrefix)$(CFBundleIdentifier)"
    guard file.values["com.apple.developer.ubiquity-kvstore-identifier"] as? String == kvs else {
      return false
    }
    // Debug and Release carry the same private container. Debug uses the Development environment;
    // Release is the TestFlight build and uses Production (ADR 0009).
    let push: String
    let environment: String
    switch file.path {
    case "App/Whirr/WhirrDebug.entitlements": (push, environment) = ("development", "Development")
    case "App/Whirr/Whirr.entitlements": (push, environment) = ("production", "Production")
    default: return false
    }
    // CarPlay audio is in both configurations.
    return Set(file.values.keys) == [
      "aps-environment", "com.apple.developer.carplay-audio",
      "com.apple.developer.icloud-container-identifiers",
      "com.apple.developer.icloud-container-environment",
      "com.apple.developer.icloud-services", "com.apple.developer.ubiquity-kvstore-identifier",
      "com.apple.security.application-groups",
    ]
      && file.values["aps-environment"] as? String == push
      && file.values["com.apple.developer.carplay-audio"] as? Bool == true
      && file.values["com.apple.developer.icloud-container-environment"] as? String == environment
      && file.values["com.apple.developer.icloud-container-identifiers"] as? [String]
        == ["iCloud.com.remoteconcern.whirr"]
      && file.values["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"]
      && file.values["com.apple.security.application-groups"] as? [String] == [appGroup]
  }

  /// The app opts in to Live Activities for the sleep-timer activity, updated only from the app.
  /// Xcode holds the key as an `INFOPLIST_KEY_` build setting, so every app configuration must
  /// carry it. Frequent updates are for push-driven activities, which Whirr does not have; that
  /// key must not appear in either place.
  static func liveActivityFindings(infoPlist: [String: Any], projectText: String) -> [Finding] {
    var findings: [Finding] = []
    if infoPlist["NSSupportsLiveActivitiesFrequentUpdates"] != nil
      || infoPlist["NSSupportsLiveActivities"].map({ $0 as? Bool != true }) == true
    {
      findings.append(Finding(rule: .liveActivities, path: "App/Whirr/Info.plist"))
    }
    let settings = appBuildSettings(in: projectText)
    if settings.isEmpty
      || settings.contains(where: {
        $0["INFOPLIST_KEY_NSSupportsLiveActivities"] != "YES"
          || $0["INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates"] != nil
      })
    {
      findings.append(Finding(rule: .liveActivities, path: projectPath))
    }
    return findings
  }

  /// `NSAllowsArbitraryLoads` is set on purpose: SECURITY.md supports plain-HTTP private servers
  /// with an informational note and no blocking gate. The rule pins the shape rather than objecting
  /// to the flag, so adding an exception domain or dropping the flag fails and gets re-reviewed.
  static func transportSecurityFindings(infoPlist: [String: Any]) -> [Finding] {
    let path = "App/Whirr/Info.plist"
    guard let transport = infoPlist["NSAppTransportSecurity"] as? [String: Any] else {
      return [Finding(rule: .transportSecurity, path: path)]
    }
    guard Set(transport.keys) == ["NSAllowsArbitraryLoads"],
      transport["NSAllowsArbitraryLoads"] as? Bool == true
    else {
      return [Finding(rule: .transportSecurity, path: path)]
    }
    return []
  }

  /// A configuration-drift guard for the recorded bundle value, not proof the classification is
  /// correct; the release packet is the owner gate. ReadiumStreamer reaches CryptoSwift's
  /// SHA-1/XOR EPUB font deobfuscation even though ReadiumLCP is not linked, so the owner must
  /// classify that use before upload. This only stops the boolean changing or vanishing silently.
  ///
  /// Xcode keeps the key as the `INFOPLIST_KEY_` build setting and drops it from Info.plist when it
  /// rewrites that file, so every app configuration must hold the setting. A copy left in the
  /// file must agree with it.
  static func exportComplianceFindings(infoPlist: [String: Any], projectText: String) -> [Finding] {
    var findings: [Finding] = []
    if let value = infoPlist["ITSAppUsesNonExemptEncryption"], value as? Bool != false {
      findings.append(Finding(rule: .exportCompliance, path: "App/Whirr/Info.plist"))
    }
    let values = appBuildSettings(in: projectText).map {
      $0["INFOPLIST_KEY_ITSAppUsesNonExemptEncryption"]
    }
    if values.isEmpty || values.contains(where: { $0 != "NO" }) {
      findings.append(Finding(rule: .exportCompliance, path: projectPath))
    }
    return findings
  }

  /// The settings of each configuration whose Info.plist is the Whirr app's, as `KEY = VALUE;`
  /// lines; list values are skipped.
  static func appBuildSettings(in projectText: String) -> [[String: String]] {
    buildSettings(in: projectText).filter { $0["INFOPLIST_FILE"] == "Whirr/Info.plist" }
  }

  /// The Info.plist settings of the targets the app embeds: the widget extension and the Watch app.
  static let embeddedInfoPlistFiles: Set<String> = [
    "WhirrWidgets/Info.plist", "\"WhirrWatch-Watch-App-Info.plist\"",
  ]

  /// An embedded bundle whose build number or version differs from the app's is refused at upload
  /// (and Xcode warns on every build). Each target holds its own copy of both settings, so a bump
  /// to the app alone would ship a mismatch; this pins every embedded configuration to the app's.
  static func bundleVersionFindings(projectText: String) -> [Finding] {
    let keys = ["CURRENT_PROJECT_VERSION", "MARKETING_VERSION"]
    let app = Set(appBuildSettings(in: projectText).map { settings in keys.map { settings[$0] } })
    let embedded = buildSettings(in: projectText).filter {
      embeddedInfoPlistFiles.contains($0["INFOPLIST_FILE"] ?? "")
    }
    guard app.count == 1, let versions = app.first, versions.allSatisfy({ $0 != nil }),
      embedded.isEmpty == false,
      embedded.allSatisfy({ settings in keys.map { settings[$0] } == versions })
    else { return [Finding(rule: .bundleVersion, path: projectPath)] }
    return []
  }

  /// Every configuration's settings as `KEY = VALUE;` lines; list values are skipped.
  static func buildSettings(in projectText: String) -> [[String: String]] {
    projectText.components(separatedBy: "buildSettings = {").dropFirst().compactMap { chunk in
      guard let end = chunk.range(of: "};") else { return nil }
      var settings: [String: String] = [:]
      for line in chunk[..<end.lowerBound].split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(
          separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[1].hasSuffix(";") else { continue }
        settings[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].dropLast()
          .trimmingCharacters(in: .whitespaces)
      }
      return settings
    }
  }

  static func acknowledgementFindings(
    acknowledgements: [ReleaseAcknowledgement],
    corePins: [PackagePin],
    appPins: [PackagePin],
    coreProductionIdentities: Set<String>
  ) -> [Finding] {
    var findings: [Finding] = []
    var byIdentity: [String: ReleaseAcknowledgement] = [:]
    for acknowledgement in acknowledgements {
      if byIdentity.updateValue(acknowledgement, forKey: acknowledgement.packageIdentity) != nil {
        findings.append(Finding(rule: .acknowledgement, path: "AppModel acknowledgements"))
      }
      if acknowledgement.displayName.isEmpty || acknowledgement.version.isEmpty
        || acknowledgement.licenseIdentifier.isEmpty || acknowledgement.attribution.isEmpty
        || acknowledgement.repositoryURL.isEmpty
      {
        findings.append(Finding(rule: .acknowledgement, path: "AppModel acknowledgements"))
      }
    }

    let appVersions = Dictionary(uniqueKeysWithValues: appPins.map { ($0.identity, $0.version) })
    let coreVersions = Dictionary(uniqueKeysWithValues: corePins.map { ($0.identity, $0.version) })
    let shipped = Set(appPins.map(\.identity)).union(coreProductionIdentities)
    for identity in shipped {
      guard let acknowledgement = byIdentity[identity] else {
        findings.append(Finding(rule: .acknowledgement, path: "AppModel acknowledgements"))
        continue
      }
      let lockfileVersions = [appVersions[identity], coreVersions[identity]].compactMap { $0 }
      if lockfileVersions.contains(where: { $0 != acknowledgement.version })
        || Set(lockfileVersions).count > 1
      {
        findings.append(Finding(rule: .acknowledgement, path: "AppModel acknowledgements"))
      }
    }
    for acknowledgement in acknowledgements {
      if shipped.contains(acknowledgement.packageIdentity) == false
        || testOnlyPackagePins[acknowledgement.packageIdentity] != nil
      {
        findings.append(Finding(rule: .acknowledgement, path: "AppModel acknowledgements"))
      }
    }
    return findings
  }

  private static let ignoredConfigurationDirectoryNames: Set<String> = [
    ".build", "build", "deriveddata", "sourcepackages", ".swiftpm", "pods", "carthage",
    "xcuserdata", "index.noindex", ".git",
  ]

  private static func packageFindings(
    pins: [PackagePin], expected: [String: PackagePin], path: String
  ) -> [Finding] {
    var findings: [Finding] = []
    let actual = Dictionary(grouping: pins, by: \.identity)
    if actual.count != pins.count {
      findings.append(Finding(rule: .packageInventory, path: path))
    }
    for pin in pins {
      guard let expectedPin = expected[pin.identity] else {
        findings.append(Finding(rule: .packageInventory, path: path))
        continue
      }
      if expectedPin.version != pin.version
        || canonicalLocation(expectedPin.location) != canonicalLocation(pin.location)
        || expectedPin.revision != pin.revision
      {
        findings.append(Finding(rule: .packageInventory, path: path))
      }
    }
    for identity in expected.keys where actual[identity] == nil {
      findings.append(Finding(rule: .packageInventory, path: path))
    }
    return findings
  }

  private static func canonicalLocation(_ location: String) -> String {
    guard var components = URLComponents(string: location) else { return location }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix(".git") { path.removeLast(4) }
    components.path = path
    return components.string ?? location
  }

  private static func propertyList(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(object as? [String: Any])
  }

  private static func relativePath(_ url: URL, to root: URL) -> String {
    url.path.replacingOccurrences(of: root.path + "/", with: "")
  }
}
