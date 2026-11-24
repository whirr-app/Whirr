import Foundation
import Testing

@testable import AppModel

@Suite("Release audit")
struct ReleaseAuditTests {
  @Test func approvedPackageFixturesPassForCoreAndAppLockfiles() throws {
    let corePins = try ReleaseAudit.pins(at: Self.coreLockfile)
    let appPins = try ReleaseAudit.pins(at: Self.appLockfile)

    let findings = ReleaseAudit.packageFindings(corePins: corePins, appPins: appPins)

    #expect(findings.isEmpty)
  }

  @Test func unapprovedPackageInAppLockfileFixtureFailsThePackageRule() throws {
    let fixture = Data(
      """
      {"pins":[{"identity":"unapproved-sdk","location":"https://example.invalid/unapproved-sdk","state":{"revision":"deadbeef","version":"1.0.0"}}]}
      """.utf8)
    let appPins = try ReleaseAudit.pins(from: fixture)

    let findings = ReleaseAudit.packageFindings(corePins: [], appPins: appPins)

    #expect(findings.contains { $0.rule == .packageInventory })
    #expect(
      findings.contains {
        $0.rule == .packageInventory
          && $0.path == "App/Whirr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
      }
    )
  }

  @Test func samePackageVersionWithDifferentRevisionFailsThePackageRule() throws {
    var pins = try ReleaseAudit.pins(at: Self.coreLockfile)
    let pin = try #require(pins.first { $0.identity == "grdb.swift" })
    pins[pins.firstIndex { $0.identity == pin.identity }!] = ReleaseAudit.PackagePin(
      identity: pin.identity,
      version: pin.version,
      location: pin.location,
      revision: String(repeating: "0", count: pin.revision.count))

    let findings = ReleaseAudit.packageFindings(corePins: pins, appPins: try ReleaseAudit.pins(at: Self.appLockfile))

    #expect(findings.contains { $0.rule == .packageInventory })
  }

  @Test func samePackageVersionWithDifferentLocationFailsThePackageRule() throws {
    var pins = try ReleaseAudit.pins(at: Self.coreLockfile)
    let pin = try #require(pins.first { $0.identity == "grdb.swift" })
    pins[pins.firstIndex { $0.identity == pin.identity }!] = ReleaseAudit.PackagePin(
      identity: pin.identity,
      version: pin.version,
      location: "https://github.com/another-owner/GRDB.swift.git",
      revision: pin.revision)

    let findings = ReleaseAudit.packageFindings(corePins: pins, appPins: try ReleaseAudit.pins(at: Self.appLockfile))

    #expect(findings.contains { $0.rule == .packageInventory })
  }

  @Test func testOnlyPackageOnAProductionTargetFixtureFailsThePackageRule() {
    let target = PackageManifest.Target(
      name: "AppModel", dependencies: ["SnapshotTesting"], isTest: false)

    let findings = ReleaseAudit.testOnlyDependencyFindings(targets: [target])

    #expect(findings.contains { $0.rule == .packageInventory })
  }

  @Test func podcastFeedsCannotImportTestOnlyDependencies() {
    let target = PackageManifest.Target(
      name: "PodcastFeeds", dependencies: ["SnapshotTesting"], isTest: false)
    #expect(
      ReleaseAudit.testOnlyDependencyFindings(targets: [target]).contains {
        $0.rule == .packageInventory
      })
  }

  @Test func emptyEntitlementFileCannotBypassTheAllowlist() {
    let findings = ReleaseAudit.configurationFindings(
      infoPlist: [:],
      entitlements: [
        ReleaseAudit.PropertyListFile(path: "App/Whirr/Whirr.entitlements", values: [:])
      ])
    #expect(findings.contains { $0.rule == .entitlement })
  }

  @Test func productionGraphKeepsTestOnlyProductsOutOfProductionTargets() throws {
    let targets = try PackageManifest.targets()
    let findings = ReleaseAudit.testOnlyDependencyFindings(targets: targets)

    #expect(findings.isEmpty)
    let persistence = try #require(targets.first { $0.name == "Persistence" })
    #expect(persistence.dependencies == Set(["GRDB"]))
    let designSystemTests = try #require(targets.first { $0.name == "DesignSystemTests" })
    #expect(designSystemTests.dependencies.contains("SnapshotTesting"))
  }

  @Test func currentAppConfigurationUsesOnlyApprovedEntitlementsAndBackgroundModes() throws {
    let findings = try ReleaseAudit.configurationFindings(at: Self.repositoryRoot)

    #expect(findings.isEmpty)
  }

  @Test func watchCompanionHasOnlyApprovedAudioBackgroundMode() throws {
    let path = "App/WhirrWatch-Watch-App-Info.plist"
    let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent(path))
    let values = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(values["UIBackgroundModes"] as? [String] == ["audio"])
  }

  /// Each shipped bundle needs its own privacy manifest; the phone app's does not cover the Watch
  /// app or the widget extension, and a missing one is an ITMS-91053 upload finding.
  @Test func watchPrivacyManifestDeclaresExactlyTheReasonsItsSourcesNeed() throws {
    let manifest = try Self.privacyManifest(at: "App/WhirrWatch Watch App/PrivacyInfo.xcprivacy")
    #expect(manifest.tracking == false)
    #expect(manifest.collectsData == false)
    #expect(
      manifest.reasons == [
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
      ])

    // Each declaration must stay true. The undeclared categories (disk space, active input modes)
    // are banned by the `watch-app-uses-no-undeclared-privacy-api` source rule.
    let watchSources = try Self.concatenatedSwift(under: [
      "App/WhirrWatch Watch App", "App/WatchShared",
      "Packages/Core/Sources/WatchPlayback", "Packages/Core/Sources/PlayerCore",
    ])
    for marker in ["systemUptime", "attributesOfItem", "UserDefaults"] {
      #expect(watchSources.contains(marker), "Watch sources no longer use \(marker)")
    }
  }

  @Test func widgetPrivacyManifestDeclaresNoTrackingCollectionOrReasons() throws {
    let manifest = try Self.privacyManifest(at: "App/WhirrWidgets/PrivacyInfo.xcprivacy")
    #expect(manifest.tracking == false)
    #expect(manifest.collectsData == false)
    #expect(manifest.reasons.isEmpty)
    // That the widget's sources reach no required-reason API is the
    // `widget-extension-uses-no-privacy-manifest-api` source rule.
  }

  private struct PrivacyManifestSummary {
    var tracking: Bool?
    var collectsData: Bool
    var reasons: [String: Set<String>]
  }

  private static func privacyManifest(at path: String) throws -> PrivacyManifestSummary {
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
    let plist = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      "\(path) is not a dictionary")
    #expect(plist["NSPrivacyTrackingDomains"] as? [String] == [])
    var reasons: [String: Set<String>] = [:]
    for entry in plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
      let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
      let codes = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
      reasons[category] = Set(codes)
    }
    let collected = try #require(
      plist["NSPrivacyCollectedDataTypes"] as? [Any], "\(path) omits NSPrivacyCollectedDataTypes")
    return PrivacyManifestSummary(
      tracking: plist["NSPrivacyTracking"] as? Bool, collectsData: !collected.isEmpty,
      reasons: reasons)
  }

  private static func concatenatedSwift(under directories: [String]) throws -> String {
    var text = ""
    for directory in directories {
      let root = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
      let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
      var count = 0
      for case let url as URL in enumerator where url.pathExtension == "swift" {
        text += WaiterPatternScan.executableText(try String(contentsOf: url, encoding: .utf8))
        count += 1
      }
      #expect(count > 0, "no Swift sources found under \(directory)")
    }
    return text
  }

  @Test func watchTargetEmptyEntitlementsAreApprovedButAnyCapabilityFailsClosed() {
    let path = "App/WhirrWatch Watch App/WhirrWatch Watch App.entitlements"
    let approved = ReleaseAudit.configurationFindings(
      infoPlist: [:], entitlements: [.init(path: path, values: [:])])
    #expect(!approved.contains { $0.rule == .entitlement })
    let unexpected = ReleaseAudit.configurationFindings(
      infoPlist: [:],
      entitlements: [.init(path: path, values: ["com.apple.security.application-groups": ["group.unapproved"]])])
    #expect(unexpected.contains { $0.rule == .entitlement })
  }

  @Test func entitlementEnumerationExcludesGeneratedRootsButIncludesTrackedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ReleaseAudit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let appRoot = root.appendingPathComponent("App", isDirectory: true)
    let trackedURL = appRoot.appendingPathComponent("Whirr.entitlements")
    let ignoredURLs = [
      appRoot.appendingPathComponent(".build/Derived.entitlements"),
      appRoot.appendingPathComponent("DerivedData/Derived.entitlements"),
      appRoot.appendingPathComponent("SourcePackages/Dependency.entitlements"),
    ]
    let plist = Data(
      "<plist version=\"1.0\"><dict><key>fixture</key><true/></dict></plist>".utf8)

    try FileManager.default.createDirectory(
      at: appRoot, withIntermediateDirectories: true)
    try plist.write(to: trackedURL)
    for url in ignoredURLs {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try plist.write(to: url)
    }

    let files = try ReleaseAudit.entitlementFiles(at: appRoot, repositoryRoot: root)
    let paths = Set(files.map(\.path))

    #expect(paths.count == 1)
    #expect(paths.first?.hasSuffix("App/Whirr.entitlements") == true)
  }

  @Test func unexpectedBackgroundModeFixtureFailsTheBackgroundModeRule() {
    let findings = ReleaseAudit.configurationFindings(
      infoPlist: [
        "UIBackgroundModes": ["audio", "location"],
        "BGTaskSchedulerPermittedIdentifiers": ["com.remoteconcern.whirr.podcast-refresh"],
      ],
      entitlements: [])

    #expect(findings.contains { $0.rule == .backgroundMode })
  }

  /// `processing` and the analysis identifier are approved together for overnight ad-skip
  /// analysis; dropping either one is drift, not a no-op.
  @Test func preAdSkipBackgroundConfigurationFixtureFailsTheBackgroundModeRule() {
    let findings = ReleaseAudit.configurationFindings(
      infoPlist: [
        "UIBackgroundModes": ["audio", "fetch", "remote-notification", "processing"],
        "BGTaskSchedulerPermittedIdentifiers": ["com.remoteconcern.whirr.podcast-refresh"],
      ],
      entitlements: [])

    #expect(findings.contains { $0.rule == .backgroundMode })
  }

  @Test func missingFullFrameRateOptInFailsTheFrameRateRule() {
    let findings = ReleaseAudit.configurationFindings(
      infoPlist: [
        "UIBackgroundModes": ["audio", "fetch", "remote-notification"],
        "BGTaskSchedulerPermittedIdentifiers": ["com.remoteconcern.whirr.podcast-refresh"],
      ],
      entitlements: [])

    #expect(findings.contains { $0.rule == .frameRate })
  }

  @Test func unexpectedEntitlementFixtureFailsTheEntitlementRule() {
    let findings = ReleaseAudit.configurationFindings(
      infoPlist: ["UIBackgroundModes": ["audio", "fetch", "remote-notification"]],
      entitlements: [
        ReleaseAudit.PropertyListFile(
          path: "App/Fixture.entitlements",
          values: ["com.apple.developer.networking.multicast": true])
      ])

    #expect(findings.contains { $0.rule == .entitlement })
  }

  @Test func theKeyValueOnlyReleaseShapeIsNoLongerApproved() {
    // Release carries CloudKit (ADR 0009); a KVS-only shape would silently turn sync off in the
    // builds Rhys installs.
    let findings = ReleaseAudit.configurationFindings(
      infoPlist: [:],
      entitlements: [
        ReleaseAudit.PropertyListFile(
          path: "App/Whirr/Whirr.entitlements",
          values: [
            "com.apple.developer.icloud-container-identifiers": [Any](),
            "com.apple.developer.ubiquity-kvstore-identifier":
              "$(TeamIdentifierPrefix)$(CFBundleIdentifier)",
          ])
      ])

    #expect(findings.contains { $0.rule == .entitlement })
  }

  @Test func iCloudDocumentsRemainAnUnapprovedEntitlement() {
    let findings = ReleaseAudit.configurationFindings(
      infoPlist: [:],
      entitlements: [
        ReleaseAudit.PropertyListFile(
          path: "App/Whirr/Whirr.entitlements",
          values: [
            "com.apple.developer.icloud-container-identifiers": ["iCloud.example"],
            "com.apple.developer.ubiquity-kvstore-identifier":
              "$(TeamIdentifierPrefix)$(CFBundleIdentifier)",
          ])
      ])

    #expect(findings.contains { $0.rule == .entitlement })
  }

  /// Debug stays in the Development environment; Release is what TestFlight ships, so it is in
  /// Production. Each file is refused with the other's values.
  @Test(arguments: [
    ("App/Whirr/WhirrDebug.entitlements", "development", "Development", "production", "Production"),
    ("App/Whirr/Whirr.entitlements", "production", "Production", "development", "Development"),
  ])
  func appAllowsOnlyTheApprovedPrivateContainerServicesPushAndAppGroup(
    path: String, push: String, container: String, wrongPush: String, wrongContainer: String
  ) {
    let approved: [String: Any] = [
      "aps-environment": push,
      "com.apple.developer.carplay-audio": true,
      "com.apple.developer.icloud-container-environment": container,
      "com.apple.developer.icloud-container-identifiers": ["iCloud.com.remoteconcern.whirr"],
      "com.apple.developer.icloud-services": ["CloudKit"],
      "com.apple.developer.ubiquity-kvstore-identifier": "$(TeamIdentifierPrefix)$(CFBundleIdentifier)",
      "com.apple.security.application-groups": ["group.com.remoteconcern.whirr"],
    ]
    func hasEntitlementFinding(_ values: [String: Any]) -> Bool {
      ReleaseAudit.configurationFindings(
        infoPlist: [:], entitlements: [.init(path: path, values: values)]
      ).contains { $0.rule == .entitlement }
    }
    #expect(!hasEntitlementFinding(approved))
    var missingEnvironment = approved
    missingEnvironment.removeValue(forKey: "com.apple.developer.icloud-container-environment")
    #expect(hasEntitlementFinding(missingEnvironment))
    // Without the group the widgets silently draw nothing, so dropping it from one configuration
    // is drift, not a harmless narrowing.
    var missingCarPlay = approved
    missingCarPlay.removeValue(forKey: "com.apple.developer.carplay-audio")
    #expect(hasEntitlementFinding(missingCarPlay))
    var missingGroup = approved
    missingGroup.removeValue(forKey: "com.apple.security.application-groups")
    #expect(hasEntitlementFinding(missingGroup))
    for (key, value) in [
      ("aps-environment", wrongPush as Any),
      ("com.apple.developer.icloud-container-environment", wrongContainer as Any),
      ("com.apple.developer.icloud-container-identifiers", ["iCloud.com.remoteconcern.whirr", "iCloud.other"] as Any),
      ("com.apple.developer.icloud-services", ["CloudKit", "CloudDocuments"] as Any),
      ("com.apple.security.application-groups", ["group.example"] as Any),
      (
        "com.apple.security.application-groups",
        ["group.com.remoteconcern.whirr", "group.example"] as Any
      ),
    ] {
      var changed = approved
      changed[key] = value
      #expect(hasEntitlementFinding(changed))
    }
  }

  @Test func widgetExtensionHoldsOnlyTheSharedAppGroup() {
    let path = "App/WhirrWidgetsExtension.entitlements"
    func hasEntitlementFinding(_ values: [String: Any]) -> Bool {
      ReleaseAudit.configurationFindings(
        infoPlist: [:], entitlements: [.init(path: path, values: values)]
      ).contains { $0.rule == .entitlement }
    }
    let group = "com.apple.security.application-groups"
    #expect(!hasEntitlementFinding([group: ["group.com.remoteconcern.whirr"]]))
    #expect(hasEntitlementFinding([:]))
    #expect(hasEntitlementFinding([group: ["group.example"]]))
    #expect(hasEntitlementFinding([group: ["group.com.remoteconcern.whirr", "group.example"]]))
    // The extension never talks to iCloud: the app's key-value and CloudKit keys fail here.
    #expect(
      hasEntitlementFinding([
        group: ["group.com.remoteconcern.whirr"],
        "com.apple.developer.ubiquity-kvstore-identifier":
          "$(TeamIdentifierPrefix)$(CFBundleIdentifier)",
      ]))
    #expect(
      hasEntitlementFinding([
        group: ["group.com.remoteconcern.whirr"],
        "com.apple.developer.icloud-services": ["CloudKit"],
      ]))
  }

  /// Two app configurations carrying the given Live Activities settings, as the project file lays
  /// them out, plus a configuration for another target that must not count.
  static func liveActivityConfigurations(_ debug: [String], _ release: [String]) -> String {
    [debug, release].map { lines in
      "\t\t\tbuildSettings = {\n\t\t\t\tINFOPLIST_FILE = Whirr/Info.plist;\n"
        + lines.map { "\t\t\t\t\($0);\n" }.joined() + "\t\t\t};"
    }.joined(separator: "\n")
      + "\n\t\t\tbuildSettings = {\n\t\t\t\tINFOPLIST_FILE = WhirrWidgets/Info.plist;\n\t\t\t};\n"
  }

  @Test func liveActivitiesAreEnabledInEveryAppConfigurationWithoutFrequentUpdates() {
    let enabled = "INFOPLIST_KEY_NSSupportsLiveActivities = YES"
    let frequent = "INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates = YES"
    let approved = Self.liveActivityConfigurations([enabled], [enabled])
    func hasFinding(_ projectText: String, infoPlist: [String: Any] = [:]) -> Bool {
      ReleaseAudit.liveActivityFindings(infoPlist: infoPlist, projectText: projectText)
        .contains { $0.rule == .liveActivities }
    }
    #expect(!hasFinding(approved))
    // A copy left in the Info.plist file must agree with the setting.
    #expect(!hasFinding(approved, infoPlist: ["NSSupportsLiveActivities": true]))
    #expect(hasFinding(approved, infoPlist: ["NSSupportsLiveActivities": false]))
    #expect(hasFinding(approved, infoPlist: ["NSSupportsLiveActivitiesFrequentUpdates": true]))
    #expect(hasFinding(Self.liveActivityConfigurations([enabled], [])))
    #expect(
      hasFinding(
        Self.liveActivityConfigurations([enabled], ["INFOPLIST_KEY_NSSupportsLiveActivities = NO"])))
    #expect(hasFinding(Self.liveActivityConfigurations([enabled, frequent], [enabled])))
    #expect(hasFinding(""))
  }

  @Test func embeddedTargetsCarryTheAppsBuildNumberAndVersion() {
    func configuration(_ plist: String, _ build: String?, _ version: String = "1.0") -> String {
      "\t\t\tbuildSettings = {\n"
        + (build.map { "\t\t\t\tCURRENT_PROJECT_VERSION = \($0);\n" } ?? "")
        + "\t\t\t\tINFOPLIST_FILE = \(plist);\n\t\t\t\tMARKETING_VERSION = \(version);\n\t\t\t};\n"
    }
    let app = "Whirr/Info.plist"
    let widgets = "WhirrWidgets/Info.plist"
    let watch = "\"WhirrWatch-Watch-App-Info.plist\""
    func hasFinding(_ configurations: [String]) -> Bool {
      ReleaseAudit.bundleVersionFindings(projectText: configurations.joined())
        .contains { $0.rule == .bundleVersion }
    }
    let matching = [
      configuration(app, "2"), configuration(app, "2"), configuration(widgets, "2"),
      configuration(watch, "2"), configuration("", "1"),
    ]
    // A configuration for an unrelated target (the tests) may carry anything.
    #expect(!hasFinding(matching))
    // The widget template's own default, which Xcode warns about on every build.
    #expect(hasFinding([configuration(app, "2"), configuration(widgets, "1")]))
    #expect(hasFinding([configuration(app, "3"), configuration(app, "2"), configuration(widgets, "2")]))
    #expect(hasFinding([configuration(app, "2"), configuration(watch, "2", "1.1")]))
    #expect(hasFinding([configuration(app, "2"), configuration(widgets, nil)]))
    #expect(hasFinding([configuration(app, "2")]))
    #expect(hasFinding([]))
  }

  @Test func transportSecurityMatchesTheRecordedDecision() {
    let findings = ReleaseAudit.transportSecurityFindings(
      infoPlist: ["NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true]])

    #expect(findings.isEmpty)
  }

  @Test func aSilentlyAddedExceptionDomainFixtureFailsTheTransportRule() {
    let findings = ReleaseAudit.transportSecurityFindings(
      infoPlist: [
        "NSAppTransportSecurity": [
          "NSAllowsArbitraryLoads": true,
          "NSExceptionDomains": ["example.invalid": ["NSIncludesSubdomains": true]],
        ]
      ])

    #expect(findings.contains { $0.rule == .transportSecurity })
  }

  @Test func droppingTheTransportDecisionFixtureFailsTheTransportRule() {
    #expect(
      ReleaseAudit.transportSecurityFindings(infoPlist: [:])
        .contains { $0.rule == .transportSecurity })
    #expect(
      ReleaseAudit.transportSecurityFindings(
        infoPlist: ["NSAppTransportSecurity": ["NSAllowsArbitraryLoads": false]]
      ).contains { $0.rule == .transportSecurity })
  }

  /// The fixture directories are not the only place a real credential can land. Sources are
  /// scanned for a pasted token literal (SECURITY.md). See `literalTokenMatch` for why the
  /// fixture rule is the wrong instrument here.
  /// The Whirr target's two configurations as the project file lays them out: the setting Xcode
  /// keeps the key in, beside the Info.plist file it merges.
  static func appConfigurations(_ debug: String?, _ release: String?) -> String {
    [debug, release].map { value in
      """
      \t\t\tbuildSettings = {
      \t\t\t\tGENERATE_INFOPLIST_FILE = YES;
      \t\t\t\tINFOPLIST_FILE = Whirr/Info.plist;
      \(value.map { "\t\t\t\tINFOPLIST_KEY_ITSAppUsesNonExemptEncryption = \($0);\n" } ?? "")\
      \t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
      \t\t\t\t\t"$(inherited)",
      \t\t\t\t);
      \t\t\t};
      """
    }.joined(separator: "\n")
      + "\n\t\t\tbuildSettings = {\n\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n\t\t\t};\n"
  }

  @Test func exportComplianceMatchesTheRecordedDecision() {
    #expect(
      ReleaseAudit.exportComplianceFindings(
        infoPlist: [:], projectText: Self.appConfigurations("NO", "NO")
      ).isEmpty)
    // Xcode moves the key out of the file into the setting; while both hold it, they agree.
    #expect(
      ReleaseAudit.exportComplianceFindings(
        infoPlist: ["ITSAppUsesNonExemptEncryption": false],
        projectText: Self.appConfigurations("NO", "NO")
      ).isEmpty)
  }

  @Test func droppingTheExportComplianceKeyFixtureFailsTheRule() {
    // Absent is not neutral: it puts the question back on every upload, where it gets answered
    // from memory rather than from the evidence in the release packet.
    for projectText in [
      Self.appConfigurations("NO", nil), Self.appConfigurations(nil, nil), "",
    ] {
      #expect(
        ReleaseAudit.exportComplianceFindings(infoPlist: [:], projectText: projectText)
          .contains { $0.rule == .exportCompliance })
    }
  }

  @Test func claimingNonExemptEncryptionFixtureFailsTheRule() {
    #expect(
      ReleaseAudit.exportComplianceFindings(
        infoPlist: [:], projectText: Self.appConfigurations("NO", "YES")
      ).contains { $0.rule == .exportCompliance })
    #expect(
      ReleaseAudit.exportComplianceFindings(
        infoPlist: ["ITSAppUsesNonExemptEncryption": true],
        projectText: Self.appConfigurations("NO", "NO")
      ).contains { $0.rule == .exportCompliance })
  }

  @Test func acknowledgementsCoverBothLockfilesAndExcludeTestOnlyPackages() throws {
    let corePins = try ReleaseAudit.pins(at: Self.coreLockfile)
    let appPins = try ReleaseAudit.pins(at: Self.appLockfile)
    let targets = try PackageManifest.targets()
    let coreProductionIdentities = Set(
      targets
        .filter { ReleaseAudit.productionTargetNames.contains($0.name) }
        .flatMap { $0.dependencies.contains("GRDB") ? ["grdb.swift"] : [] })

    let findings = ReleaseAudit.acknowledgementFindings(
      acknowledgements: ReleaseAcknowledgements.entries,
      corePins: corePins,
      appPins: appPins,
      coreProductionIdentities: coreProductionIdentities)

    #expect(findings.isEmpty)
    #expect(
      Set(
        ReleaseAcknowledgements.entries.map(\.packageIdentity).filter {
          ReleaseAudit.testOnlyPackagePins[$0] != nil
        }
      ).isEmpty)
  }

  @Test func missingAcknowledgementFixtureFailsTheAcknowledgementRule() {
    let acknowledgements = [Self.acknowledgement(for: "grdb.swift", version: "7.11.1")]
    let appPins = [
      ReleaseAudit.PackagePin(identity: "grdb.swift", version: "7.11.1"),
      ReleaseAudit.PackagePin(identity: "swift-toolkit", version: "3.11.0"),
    ]

    let findings = ReleaseAudit.acknowledgementFindings(
      acknowledgements: acknowledgements,
      corePins: [],
      appPins: appPins,
      coreProductionIdentities: ["grdb.swift"])

    #expect(findings.contains { $0.rule == .acknowledgement })
  }

  @Test func testOnlyAcknowledgementFixtureFailsTheAcknowledgementRule() {
    let acknowledgements = [
      Self.acknowledgement(for: "swift-snapshot-testing", version: "1.19.3")
    ]
    let appPins = [ReleaseAudit.PackagePin(identity: "grdb.swift", version: "7.11.1")]

    let findings = ReleaseAudit.acknowledgementFindings(
      acknowledgements: acknowledgements,
      corePins: [
        ReleaseAudit.PackagePin(identity: "swift-snapshot-testing", version: "1.19.3")
      ],
      appPins: appPins,
      coreProductionIdentities: ["grdb.swift"])

    #expect(findings.contains { $0.rule == .acknowledgement })
  }

  /// MIT and BSD-3-Clause both require the notice, not a copyright line, to travel with the
  /// binary. An attribution string alone does not satisfy either licence for a distributed build.
  @Test func everyAcknowledgementCarriesItsFullLicenceText() throws {
    for entry in ReleaseAcknowledgements.entries {
      let text = try #require(
        entry.licenseText, "\(entry.packageIdentity) has no bundled licence text")
      #expect(text.count > 400, "\(entry.packageIdentity)'s licence text looks like a summary")
    }
  }

  /// Each text must be the licence the inventory claims it is. A file present but wrong is the
  /// failure an existence check cannot see.
  @Test func bundledLicenceTextMatchesTheRecordedIdentifier() throws {
    let signatures: [String: String] = [
      "MIT": "Permission is hereby granted, free of charge",
      "BSD-3-Clause": "Redistributions of source code must retain",
      "Apache-2.0": "Apache License",
      "LicenseRef-CryptoSwift": "an acknowledgment in the product documentation is required",
    ]

    for entry in ReleaseAcknowledgements.entries {
      let signature = try #require(
        signatures[entry.licenseIdentifier],
        "no signature phrase recorded for \(entry.licenseIdentifier)")
      let text = try #require(entry.licenseText)
      #expect(
        text.contains(signature),
        "\(entry.packageIdentity)'s text does not read as \(entry.licenseIdentifier)")
    }
  }

  /// A licence file for a package we do not ship is stale attribution; the resource set and the
  /// acknowledgement list move together or not at all.
  @Test func bundledLicenceResourcesHaveNoOrphans() throws {
    let bundled = try #require(ReleaseAcknowledgements.bundledLicenceIdentities())

    #expect(bundled == Set(ReleaseAcknowledgements.entries.map(\.packageIdentity)))
  }

  /// The screen renders this order directly, so it is a presentation rule with a test rather than
  /// a sort buried in a view body.
  @Test func acknowledgementsArePresentedAlphabeticallyByDisplayName() {
    let names = ReleaseAcknowledgements.displayOrdered.map(\.displayName)

    #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    #expect(Set(names) == Set(ReleaseAcknowledgements.entries.map(\.displayName)))
  }

  private static let repositoryRoot = PackageManifest.packageRoot
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  private static let coreLockfile =
    repositoryRoot
    .appendingPathComponent("Packages/Core/Package.resolved")
  private static let appLockfile =
    repositoryRoot
    .appendingPathComponent(
      "App/Whirr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")

  private static func acknowledgement(for identity: String, version: String)
    -> ReleaseAcknowledgement
  {
    ReleaseAcknowledgement(
      packageIdentity: identity,
      displayName: identity,
      version: version,
      licenseIdentifier: "MIT",
      attribution: "Attribution",
      repositoryURL: "https://example.invalid/\(identity)")
  }

}
