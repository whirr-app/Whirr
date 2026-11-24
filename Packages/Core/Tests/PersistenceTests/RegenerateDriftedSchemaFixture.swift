import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Fixture tool, invoked as an opt-in test so it needs no extra executable target (as
/// `RegenerateReleasedSchemaFixture` does).
///
///     REGENERATE_DRIFTED_SCHEMA_FIXTURE=1 swift test --filter RegenerateDriftedSchemaFixture
///
/// It rewrites `Sources/TestSupport/Fixtures/drifted-schema-field.sqlite` in the source tree from
/// `DriftedSchemaFixture.generateStore(at:shape:)`. Without the environment variable it is inert.
///
/// Unlike the released baseline, this fixture records a deliberately wrong historical `v1` shape
/// absent from the source tree. It should essentially never need regenerating, as today's migrator
/// does not change what a 2026 device store looks like. If regenerating makes a heal test pass,
/// the heal needs fixing.
@Suite struct RegenerateDriftedSchemaFixture {

  @Test func regenerate() throws {
    guard ProcessInfo.processInfo.environment["REGENERATE_DRIFTED_SCHEMA_FIXTURE"] == "1" else {
      return
    }

    let fixturesDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PersistenceTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Core
      .appendingPathComponent("Sources/TestSupport/Fixtures")

    let storeURL = fixturesDirectory.appendingPathComponent(
      "\(DriftedSchemaFixture.storeResourceName).\(DriftedSchemaFixture.storeResourceExtension)")
    for sidecar in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(
        at: storeURL.deletingLastPathComponent()
          .appendingPathComponent(storeURL.lastPathComponent + sidecar))
    }
    try DriftedSchemaFixture.generateStore(at: storeURL, shape: .fieldObserved)

    print("Regenerated \(storeURL.lastPathComponent)")
  }
}
