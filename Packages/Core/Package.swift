// swift-tools-version: 6.2
// .iOS(.v26) requires PackageDescription 6.2 or newer.
import PackageDescription

// Target graph mirrors ARCHITECTURE.md §1 exactly. Imports point downward only;
// the dependency lists below are what enforce it. Changing this graph requires a
// decision-log entry, not a silent edit.
let package = Package(
  name: "WhirrCore",
  platforms: [.iOS(.v26), .macOS(.v15), .watchOS(.v26)],
  products: [
    .library(name: "WatchProtocol", targets: ["WatchProtocol"]),
    .library(name: "WatchPlayback", targets: ["WatchPlayback"]),
    .library(name: "WidgetProtocol", targets: ["WidgetProtocol"]),
    .library(name: "CoreSupport", targets: ["CoreSupport"]),
    .library(name: "ABSApi", targets: ["ABSApi"]),
    .library(name: "PodcastFeeds", targets: ["PodcastFeeds"]),
    .library(name: "Persistence", targets: ["Persistence"]),
    .library(name: "SyncEngine", targets: ["SyncEngine"]),
    .library(name: "PlayerCore", targets: ["PlayerCore"]),
    .library(name: "ReaderCore", targets: ["ReaderCore"]),
    .library(name: "AppModel", targets: ["AppModel"]),
    .library(name: "DesignSystem", targets: ["DesignSystem"]),
    .library(name: "AdSkip", targets: ["AdSkip"]),
    // Test-only: linked by the App's WhirrTests target and nothing else. A source rule
    // (`testsupport-links-only-into-whirrtests`) keeps it out of every shipping target.
    .library(name: "TestSupport", targets: ["TestSupport"]),
  ],
  dependencies: [
    // Both dependencies are exact-pinned.
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    // Test-target-only (DesignSystemTests) — no production target may depend on this.
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", exact: "1.19.3"),
  ],
  targets: [
    // Domain-free concurrency primitives shared by targets that must not depend on each other
    // (ARCHITECTURE.md D34). Foundation only, and it may never gain a dependency — that is what makes it safe
    // for anything above it to import.
    // ADR 0003: dependency-free phone/Watch wire values and safety policy.
    .target(name: "WatchProtocol"),
    .target(name: "WatchPlayback", dependencies: ["ABSApi", "PlayerCore", "WatchProtocol"]),
    // ADR 0014: dependency-free values the app and the widget extension share through the App
    // Group. The extension links this and nothing else from the package.
    .target(name: "WidgetProtocol"),
    .target(name: "CoreSupport"),
    // Foundation only; Security is reached solely inside the Keychain adapter,
    // guarded by canImport(Security) (phase 1, T1.3).
    .target(name: "ABSApi"),
    .target(name: "PodcastFeeds", dependencies: ["CoreSupport", "ABSApi"]),
    // GRDB schema arrives in phase 2 (T2.1).
    .target(
      name: "Persistence",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
    ),
    .target(name: "SyncEngine", dependencies: ["CoreSupport", "ABSApi", "Persistence"]),
    .target(name: "PlayerCore"),
    .target(name: "ReaderCore", dependencies: ["CoreSupport"]),
    .target(
      name: "AppModel",
      dependencies: [
        "CoreSupport", "Persistence", "SyncEngine", "PlayerCore", "ReaderCore", "PodcastFeeds",
        // ARCHITECTURE.md D43: AdSkip's consumers are the ad-skip, transcript and Look Back
        // coordinators.
        "AdSkip",
      ],
      // The shipped packages' licence texts, copied verbatim so the notice MIT and
      // BSD-3-Clause require travels with the binary rather than living only in docs.
      resources: [.copy("Resources/Licenses")]
    ),
    // Leaf-level UI tokens; consumed only by the App target, never by Core.
    .target(name: "DesignSystem"),
    // ARCHITECTURE.md D43: the pure podcast ad-skip pipeline. Foundation only, so the off-repo harness can import
    // it for parity; adapters live in the App, records in Persistence, and AppModel's ad-skip,
    // transcript and Look Back coordinators are its only consumers.
    .target(
      name: "AdSkip",
      // Optimised even in debug builds: the matching kernel is tight integer loops that run several
      // times slower unoptimised, which dominated the coordinator tests and slows on-device
      // analysis in a Debug app. The cost is unreliable breakpoints inside this target.
      swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),

    // Test-only. No production target may depend on this — T0.6 asserts it.
    .target(
      name: "TestSupport",
      dependencies: [
        "ABSApi", "Persistence", "SyncEngine", "PlayerCore", "ReaderCore", "AppModel",
        // `ReleasedSchemaFixture` builds and introspects the baseline store directly.
        // Already a Persistence dependency — no new package.
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [.process("Fixtures")]
    ),

    .testTarget(name: "WatchProtocolTests", dependencies: ["WatchProtocol"]),
    .testTarget(name: "WatchPlaybackTests", dependencies: ["WatchPlayback", "ABSApi", "PlayerCore", "WatchProtocol"]),
    .testTarget(name: "WidgetProtocolTests", dependencies: ["WidgetProtocol"]),
    .testTarget(name: "CoreSupportTests", dependencies: ["CoreSupport"]),
    .testTarget(name: "TestSupportTests", dependencies: ["TestSupport"]),
    .testTarget(name: "ABSApiTests", dependencies: ["ABSApi", "TestSupport"]),
    .testTarget(
      name: "PodcastFeedsTests",
      dependencies: ["PodcastFeeds", "TestSupport"],
      // Synthetic feeds that reproduce real-world markup families (four items each, closing tags
      // intact), so parser conformance is asserted against realistic structure without
      // redistributing third-party feed content.
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "PersistenceTests",
      dependencies: [
        "Persistence", "TestSupport",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "SyncEngineTests",
      // ABSApi/Persistence/GRDB: T2.6/T2.8's tests build a real `ABSClient` over `FakeHTTPClient`
      // and read back persisted `AppDatabase` state directly, the same pattern ABSApiTests/
      // PersistenceTests already use (LayeringTests only governs the production-target table).
      dependencies: [
        "SyncEngine", "TestSupport", "ABSApi", "Persistence",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore", "TestSupport"]),
    .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore", "TestSupport"]),
    .testTarget(name: "AppModelTests", dependencies: ["AppModel", "TestSupport"]),
    .testTarget(name: "AdSkipTests", dependencies: ["AdSkip"]),
    .testTarget(
      name: "DesignSystemTests",
      dependencies: [
        "DesignSystem",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      exclude: ["__Snapshots__"]
    ),
  ]
)
