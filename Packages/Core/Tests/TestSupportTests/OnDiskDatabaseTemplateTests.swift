import Foundation
import GRDB
import Persistence
import Testing

@testable import TestSupport

/// The seeded store must be indistinguishable from one that ran its migrations, and seeding must
/// never touch a file that already exists. Skipped when seeding is switched off for a measurement.
@Suite(.enabled(if: OnDiskDatabaseTemplate.isEnabled))
struct OnDiskDatabaseTemplateTests {

  @Test func seededStoreMatchesAStoreMigratedInPlace() async throws {
    try await withOnDiskDatabases { scope in
      let migrated = try scope.open("migrated.sqlite", seeding: .migrateFromEmpty)
      let seeded = try scope.open("seeded.sqlite")

      let migratedContents = try await Self.contents(of: migrated)
      let seededContents = try await Self.contents(of: seeded)
      #expect(migratedContents.schema.isEmpty == false)
      #expect(migratedContents.migrations.isEmpty == false)
      #expect(seededContents.schema == migratedContents.schema)
      #expect(seededContents.migrations == migratedContents.migrations)
      #expect(seededContents.rows == migratedContents.rows)
    }
  }

  @Test func seedingClonesTheTemplateOnlyWhenNoFileExists() async throws {
    try await withOnDiskDatabases { scope in
      let url = scope.url()
      let seededFirst = try OnDiskDatabaseTemplate.seedIfAbsent(at: url)
      let seededAgain = try OnDiskDatabaseTemplate.seedIfAbsent(at: url)
      #expect(seededFirst)
      #expect(seededAgain == false)

      let missingDirectory = scope.directoryURL
        .appendingPathComponent("absent", isDirectory: true)
        .appendingPathComponent("app.sqlite")
      let seededMissing = try OnDiskDatabaseTemplate.seedIfAbsent(at: missingDirectory)
      #expect(seededMissing == false)
    }
  }

  @Test func reopeningASeededStoreKeepsItsRows() async throws {
    try await withOnDiskDatabases { scope in
      let first = try scope.open()
      try await first.writeAsync { db in
        try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO probe (id) VALUES (7)")
      }
      scope.close(first)

      let reopened = try scope.open()
      let ids = try await reopened.readAsync { db in
        try Int.fetchAll(db, sql: "SELECT id FROM probe")
      }
      #expect(ids == [7])
    }
  }

  @Test func optingOutRunsTheMigrationsFromAnEmptyDirectory() async throws {
    try await withOnDiskDatabases { scope in
      let fileAttributes = DirectoryContentsRecorder()
      _ = try scope.open(fileAttributes: fileAttributes, seeding: .migrateFromEmpty)
      #expect(fileAttributes.directoryWasEmptyOnFirstProtection == true)
    }
  }

  @Test func seededOpenFindsTheDatabaseFileAlreadyPresent() async throws {
    try await withOnDiskDatabases { scope in
      let fileAttributes = DirectoryContentsRecorder()
      _ = try scope.open(fileAttributes: fileAttributes)
      #expect(fileAttributes.directoryWasEmptyOnFirstProtection == false)
    }
  }

  @Test func concurrentlySeededStoresAreIndependent() async throws {
    let ids = try await withThrowingTaskGroup(of: [Int].self, returning: [[Int]].self) { group in
      for index in 0..<4 {
        group.addTask {
          try await withOnDiskDatabases(named: "template-independent-\(index)") { scope in
            let database = try scope.open()
            try await database.writeAsync { db in
              try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
              try db.execute(sql: "INSERT INTO probe (id) VALUES (?)", arguments: [index])
            }
            return try await database.readAsync { db in
              try Int.fetchAll(db, sql: "SELECT id FROM probe ORDER BY id")
            }
          }
        }
      }
      var all: [[Int]] = []
      for try await rows in group { all.append(rows) }
      return all
    }
    #expect(ids.sorted { $0.first ?? 0 < $1.first ?? 0 } == [[0], [1], [2], [3]])

    let template = try OnDiskDatabaseTemplate.url()
    let templateQueue = try DatabaseQueue(path: template.path)
    let templateHasProbe = try await templateQueue.read { db in try db.tableExists("probe") }
    try templateQueue.close()
    #expect(templateHasProbe == false, "a write to a clone must not reach the template")
  }

  private struct Contents: Equatable {
    var schema: [String]
    var migrations: [String]
    var rows: [String: [String]]
  }

  private static func contents(of database: AppDatabase) async throws -> Contents {
    try await database.readAsync { db in
      let schema = try String.fetchAll(
        db,
        sql: """
          SELECT type || ' ' || name || ' ' || tbl_name || ' ' || COALESCE(sql, '')
          FROM sqlite_master ORDER BY type, name
          """)
      let migrations = try String.fetchAll(
        db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND sql NOT LIKE 'CREATE VIRTUAL%'
          ORDER BY name
          """)
      var rows: [String: [String]] = [:]
      for table in tables {
        rows[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table.quotedDatabaseIdentifier)")
          .map(\.description).sorted()
      }
      return Contents(schema: schema, migrations: migrations, rows: rows)
    }
  }
}

/// Records whether the database directory held any file when it was first protected: the
/// observable difference between a store migrated from empty and one cloned before opening.
// Kept: observes directory contents at first protection; InertFileAttributes observes nothing.
private final class DirectoryContentsRecorder: FileAttributeApplying, @unchecked Sendable {
  private let lock = NSLock()
  private var firstProtectionSawEmptyDirectory: Bool?

  var directoryWasEmptyOnFirstProtection: Bool? {
    lock.withLock { firstProtectionSawEmptyDirectory }
  }

  func protectDirectory(at directoryURL: URL) throws {
    let contents = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
    lock.withLock {
      if firstProtectionSawEmptyDirectory == nil {
        firstProtectionSawEmptyDirectory = contents.isEmpty
      }
    }
  }

  func protectDatabaseArtifacts(at databaseURL: URL) throws {}
  func protectDownloadsRoot(at directoryURL: URL) throws {}
  func protectDownloadedFile(at fileURL: URL) throws {}
}
