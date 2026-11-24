import Foundation
import Testing

/// Mechanical enforcement of the layering in ARCHITECTURE.md.
///
/// SwiftPM does not enforce it: modules in a package share one build directory on the import
/// search path, so a target can `import` a sibling it never declared.
@Suite struct LayeringTests {

  /// The "Exact production-target dependencies" table in ARCHITECTURE.md. This table is the
  /// contract; `Package.swift` must match it, not the other way round. "GRDB" is the
  /// `.product(name:)` value for the external dependency (`Persistence` may depend on
  /// Foundation, GRDB).
  static let expected: [String: Set<String>] = [
    "WatchProtocol": [],
    "WatchPlayback": ["ABSApi", "PlayerCore", "WatchProtocol"],
    "WidgetProtocol": [],
    "CoreSupport": [],
    "ABSApi": [],
    "PodcastFeeds": ["CoreSupport", "ABSApi"],
    "Persistence": ["GRDB"],
    "SyncEngine": ["CoreSupport", "ABSApi", "Persistence"],
    "PlayerCore": [],
    "ReaderCore": ["CoreSupport"],
    "AppModel": [
      "CoreSupport", "Persistence", "SyncEngine", "PlayerCore", "ReaderCore", "PodcastFeeds",
      "AdSkip",
    ],
    "DesignSystem": [],
    "AdSkip": [],
  ]

  @Test func declaredGraphMatchesArchitectureDocument() throws {
    let targets = try PackageManifest.targets()
    for (name, expectedDeps) in Self.expected {
      guard let target = targets.first(where: { $0.name == name }) else {
        Issue.record("Target \(name) is missing from Package.swift")
        continue
      }
      #expect(
        target.dependencies == expectedDeps,
        "\(name) declares \(target.dependencies.sorted()), ARCHITECTURE.md §1 says \(expectedDeps.sorted())"
      )
    }
  }

  /// The check SwiftPM will not do: an actual `import` of a module the target
  /// never declared a dependency on.
  @Test func noProductionSourceImportsAnUndeclaredModule() throws {
    let packageModules = Set(Self.expected.keys).union(["TestSupport"])
    for (name, declared) in Self.expected {
      let imported = try PackageManifest.imports(ofTarget: name)
      let undeclared = imported.intersection(packageModules).subtracting(declared)
      #expect(
        undeclared.isEmpty,
        "\(name) imports \(undeclared.sorted()) without declaring it - imports point downward only (ARCHITECTURE.md §1)"
      )
    }
  }

  @Test func noProductionSourceImportsReadium() throws {
    for name in Self.expected.keys {
      let imported = try PackageManifest.imports(ofTarget: name)
      let forbidden = imported.filter { $0.hasPrefix("Readium") }.sorted()
      #expect(
        forbidden.isEmpty,
        "\(name) imports \(forbidden) - Readium belongs in the App adapter, never in Core"
      )
    }
  }

  /// The table above is checked against `Package.swift`, but only for names it already lists.
  /// A target added to the manifest and not to the table would escape the contract silently,
  /// which is how a new module acquires an undeclared upward import.
  @Test func everyProductionTargetIsCoveredByTheContract() throws {
    let targets = try PackageManifest.targets()
    let uncovered =
      targets
      .filter { $0.isTest == false && $0.name != "TestSupport" }
      .map(\.name)
      .filter { Self.expected[$0] == nil }
      .sorted()
    #expect(
      uncovered.isEmpty,
      "\(uncovered) exist in Package.swift but not in ARCHITECTURE.md §1's dependency table"
    )
  }

  /// CloudKit is a platform/network leaf: `PodcastCloudSyncing` exists so the engine lives in the
  /// App target, so a Core target reaching for `CKSyncEngine` directly would dissolve the
  /// boundary rather than cross it.
  @Test func noProductionSourceImportsCloudKit() throws {
    for name in Self.expected.keys {
      let imported = try PackageManifest.imports(ofTarget: name)
      #expect(
        !imported.contains("CloudKit"),
        "\(name) imports CloudKit - it belongs in the App adapter, never in Core"
      )
    }
  }

  /// TestSupport is test-only; a production target reaching into it would ship fakes.
  @Test func productionTargetsDoNotDependOnTestSupport() throws {
    let targets = try PackageManifest.targets()
    for target in targets where !target.isTest && target.name != "TestSupport" {
      #expect(
        !target.dependencies.contains("TestSupport"),
        "\(target.name) depends on TestSupport"
      )
      let imported = try PackageManifest.imports(ofTarget: target.name)
      #expect(!imported.contains("TestSupport"), "\(target.name) imports TestSupport")
    }
  }

  /// Guards the guard: if the import scanner silently returned nothing, the two tests
  /// above would pass vacuously no matter what the sources contained. AppModel really
  /// does import all four of its dependencies, to compose `AppDependencies`.
  @Test func importScannerActuallyFindsImports() throws {
    let appModelImports = try PackageManifest.imports(ofTarget: "AppModel")
    #expect(appModelImports.contains("Persistence"))
    #expect(appModelImports.contains("SyncEngine"))
    #expect(appModelImports.contains("PlayerCore"))
    #expect(appModelImports.contains("ReaderCore"))
    #expect(appModelImports.contains("PodcastFeeds"))
    #expect(appModelImports.contains("AdSkip"))
  }
}
