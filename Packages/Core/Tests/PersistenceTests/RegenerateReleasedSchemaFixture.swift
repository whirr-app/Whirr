import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Fixture tool, invoked as an opt-in test so it needs no extra executable target.
///
///     REGENERATE_RELEASED_SCHEMA_FIXTURE=1 swift test --filter RegenerateReleasedSchemaFixture
///
/// It rewrites only `Sources/TestSupport/Fixtures/released-schema-baseline.schema` from the current
/// migrator; the `.sqlite` fixture is the immutable v1-v3 released baseline, and regenerating it
/// would erase the migration-from-release path this suite tests. Without the environment variable
/// this is inert.
///
/// Regenerate only when a new migration has been appended. If the recorded schema of an
/// already-registered migration changes, that edit is the bug and
/// `ReleasedSchemaMigrationTests` is right to fail.
@Suite struct RegenerateReleasedSchemaFixture {

  @Test func regenerate() throws {
    guard ProcessInfo.processInfo.environment["REGENERATE_RELEASED_SCHEMA_FIXTURE"] == "1" else {
      return
    }

    let fixturesDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PersistenceTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Core
      .appendingPathComponent("Sources/TestSupport/Fixtures")

    let database = try AppDatabase.inMemory()
    let schema = try database.read { db in
      try ReleasedSchemaFixture.normalizedSchema(of: db)
    }
    let schemaURL = fixturesDirectory.appendingPathComponent(
      "\(ReleasedSchemaFixture.schemaResourceName).\(ReleasedSchemaFixture.schemaResourceExtension)")
    try schema.write(to: schemaURL, atomically: true, encoding: .utf8)

    print("Regenerated \(schemaURL.lastPathComponent); preserved the frozen v1-v3 SQLite fixture")
  }
}
