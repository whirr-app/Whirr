import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Database bootstrap only. These tests create ad hoc tables directly via SQL to prove the
/// connection-level contract (foreign keys, WAL, file protection) without any real schema.
///
/// Every on-disk open here passes `.migrateFromEmpty`: this suite's subject is the production
/// bootstrap from an empty directory, which a template clone would skip.
@Suite struct AppDatabaseTests {

  @Test func inMemoryDatabaseOpensAndIsWritable() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
      try db.execute(sql: "INSERT INTO probe (id) VALUES (1)")
    }
    let count = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe") ?? 0
    }
    #expect(count == 1)
  }

  /// `inMemory()` hands out copies of one migrated template rather than replaying the migrations,
  /// so a copy must be indistinguishable from a store that ran them itself.
  @Test func inMemoryDatabaseMatchesAStoreMigratedInPlace() async throws {
    let copied = try await Self.schemaFingerprint(of: AppDatabase.inMemory())
    try await withOnDiskDatabases { scope in
      let migrated = try await Self.schemaFingerprint(
        of: scope.open(fileAttributes: FakeFileAttributeApplying(), seeding: .migrateFromEmpty))
      #expect(!migrated.isEmpty)
      #expect(copied == migrated)
    }
  }

  @Test func inMemoryDatabasesDoNotShareRows() async throws {
    let first = try AppDatabase.inMemory()
    let second = try AppDatabase.inMemory()
    try await first.writeAsync { db in
      try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
    }
    let leaked = try await second.readAsync { db in try db.tableExists("probe") }
    let third = try await AppDatabase.inMemory().readAsync { db in try db.tableExists("probe") }
    #expect(!leaked, "a write to one in-memory store must not reach another")
    #expect(!third, "a write to one in-memory store must not reach the shared template")
  }

  private static func schemaFingerprint(of database: AppDatabase) async throws -> [String] {
    try await database.readAsync { db in
      let objects = try String.fetchAll(
        db,
        sql: """
          SELECT type || ' ' || name || ' ' || tbl_name || ' ' || COALESCE(sql, '')
          FROM sqlite_master ORDER BY type, name
          """)
      let applied = try String.fetchAll(
        db, sql: "SELECT 'migration ' || identifier FROM grdb_migrations ORDER BY identifier")
      return objects + applied
    }
  }

  @Test func asyncAccessSuspendsThroughGRDBAndPreservesTransactionSemantics() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(sql: "CREATE TABLE asyncProbe (id INTEGER PRIMARY KEY)")
      try db.execute(sql: "INSERT INTO asyncProbe (id) VALUES (1)")
    }

    let count = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asyncProbe") ?? 0
    }
    #expect(count == 1)

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        try db.execute(sql: "INSERT INTO asyncProbe (id) VALUES (2)")
        throw AsyncProbeError.expected
      }
    }
    let ids = try await database.readAsync { db in
      try Int.fetchAll(db, sql: "SELECT id FROM asyncProbe ORDER BY id")
    }
    #expect(ids == [1], "the async write must retain GRDB's transaction rollback guarantee")
  }

  /// In-memory, outside the on-disk fixture gate. The subject is the async accessor fan-out:
  /// sixty-four independent writers must all complete without deadlocking each other. An
  /// in-memory `DatabasePool` still owns a writer queue and a reader pool, so the fan-out is
  /// real, but it never touches the on-disk class the gate bounds. Moving it on-disk would open
  /// sixty-four real pools inside one permit and starve the gate.
  @Test(.timeLimit(.minutes(1)))
  func asyncAccessCompletesAcrossManyIndependentWriters() async throws {
    let databases = try (0..<64).map { _ in try AppDatabase.inMemory() }

    let counts = try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
      for (index, database) in databases.enumerated() {
        group.addTask {
          try await database.writeAsync { db in
            try db.execute(sql: "CREATE TABLE parallelProbe (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO parallelProbe (id) VALUES (?)", arguments: [index])
          }
          return try await database.readAsync { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parallelProbe") ?? 0
          }
        }
      }

      var values: [Int] = []
      for try await count in group {
        values.append(count)
      }
      return values
    }

    #expect(counts.count == databases.count)
    #expect(counts.allSatisfy { $0 == 1 })
  }

  @Test func foreignKeysAreEnforced() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(sql: "CREATE TABLE parent (id INTEGER PRIMARY KEY)")
      try db.execute(
        sql: "CREATE TABLE child (id INTEGER PRIMARY KEY, parentId INTEGER REFERENCES parent(id))")
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        try db.execute(sql: "INSERT INTO child (id, parentId) VALUES (1, 999)")
      }
    }

    let childRowCount = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM child") ?? -1
    }
    #expect(childRowCount == 0, "the violating insert must not have committed")
  }

  @Test func onDiskDatabaseOpensAndIsWritable() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying(), seeding: .migrateFromEmpty)
      try await database.writeAsync { db in
        try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO probe (id) VALUES (1)")
      }
      let count = try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe") ?? 0
      }
      #expect(count == 1)
      #expect(FileManager.default.fileExists(atPath: databaseURL.path))
    }
  }

  /// Both writers run on dedicated `Thread`s, not `DispatchQueue.global()`: libdispatch's global
  /// pool stalls after 64 concurrently-blocked blocks, which the full suite reaches on its own (64
  /// parallel `DatabasePool`s in `asyncAccessCompletesAcrossManyIndependentWriters`, plus
  /// `DriftedSchemaHealTests`), so a dispatched writer would never be scheduled.
  @Test func onDiskDatabaseWaitsForAConcurrentWriterInsteadOfImmediatelyFailingBusy() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AppDatabaseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("app.sqlite")

    let firstDatabase = try AppDatabase.onDisk(
      at: databaseURL, fileAttributes: FakeFileAttributeApplying())
    let secondDatabase = try AppDatabase.onDisk(
      at: databaseURL, fileAttributes: FakeFileAttributeApplying())
    defer {
      try? firstDatabase.dbWriter.close()
      try? secondDatabase.dbWriter.close()
    }
    // Synchronous writes are the sole exception: this test pins GRDB's cross-connection
    // busy-lock waiting contract from a synchronous thread harness.
    try firstDatabase.write { db in
      try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
    }

    let firstWriterHasLock = DispatchSemaphore(value: 0)
    let releaseFirstWriter = DispatchSemaphore(value: 0)
    let firstWriterFinished = DispatchSemaphore(value: 0)
    let secondWriterStarted = DispatchSemaphore(value: 0)
    let secondWriterFinished = DispatchSemaphore(value: 0)
    let secondWriterError = Locked<(any Error)?>(nil)

    startDetachedWriter(named: "AppDatabaseTests.firstWriter") {
      defer { firstWriterFinished.signal() }
      try? firstDatabase.write { db in
        firstWriterHasLock.signal()
        releaseFirstWriter.wait()
        try db.execute(sql: "INSERT INTO probe (id) VALUES (1)")
      }
    }
    #expect(firstWriterHasLock.wait(timeout: .now() + livenessTimeout) == .success)

    startDetachedWriter(named: "AppDatabaseTests.secondWriter") {
      defer { secondWriterFinished.signal() }
      secondWriterStarted.signal()
      do {
        try secondDatabase.write { db in
          try db.execute(sql: "INSERT INTO probe (id) VALUES (2)")
        }
      } catch {
        secondWriterError.value = error
      }
    }
    #expect(secondWriterStarted.wait(timeout: .now() + livenessTimeout) == .success)

    // This deadline must stay short: the negative assertion is only meaningful while the first
    // writer still holds the lock. Widening it would let a second writer that threw SQLITE_BUSY
    // immediately still look like one that waited.
    let resultWhileLocked = secondWriterFinished.wait(timeout: .now() + 0.1)
    #expect(
      resultWhileLocked == .timedOut,
      "A transient write lock should make the second connection wait, not throw SQLITE_BUSY")

    releaseFirstWriter.signal()
    #expect(firstWriterFinished.wait(timeout: .now() + livenessTimeout) == .success)
    // The negative check above already consumed the completion signal if the second writer had
    // (wrongly) finished, so only wait again when it was still blocked. Otherwise a failing run
    // would also stall for the whole liveness timeout.
    let secondWriterCompleted =
      resultWhileLocked == .success
      || secondWriterFinished.wait(timeout: .now() + livenessTimeout) == .success
    #expect(secondWriterCompleted)
    #expect(secondWriterError.value == nil)

    let ids = try firstDatabase.read { db in
      try Int.fetchAll(db, sql: "SELECT id FROM probe ORDER BY id")
    }
    #expect(ids == [1, 2])
  }

  @Test func onDiskDatabaseProtectsDirectoryBeforeSQLiteCreatesAnyFile() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let fileAttributes = FakeFileAttributeApplying()

      _ = try scope.open(fileAttributes: fileAttributes, seeding: .migrateFromEmpty)

      #expect(fileAttributes.directoryProtectionCalls == [databaseURL.deletingLastPathComponent()])
      #expect(fileAttributes.directoryWasEmptyOnFirstProtection == true)
    }
  }

  @Test func onDiskDatabaseAppliesAndVerifiesAttributesOnMainFileAndSidecarsAfterAWALWrite() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let fileAttributes = FakeFileAttributeApplying()

      let database = try scope.open(fileAttributes: fileAttributes, seeding: .migrateFromEmpty)
      try await database.writeAsync { db in
        try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO probe (id) VALUES (1)")
      }

      let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
      let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")

      // WAL mode must actually have produced sidecars for this to be a meaningful assertion.
      #expect(
        FileManager.default.fileExists(atPath: walURL.path) || FileManager.default.fileExists(atPath: shmURL.path))

      #expect(fileAttributes.artifactProtectionCalls.contains(databaseURL))
      if FileManager.default.fileExists(atPath: walURL.path) {
        #expect(fileAttributes.artifactProtectionCalls.contains(walURL))
      }
      if FileManager.default.fileExists(atPath: shmURL.path) {
        #expect(fileAttributes.artifactProtectionCalls.contains(shmURL))
      }

      // The database, and every sidecar that exists, must carry real (round-tripped) protection
      // and must remain included in backup (it may hold unsynced progress).
      for candidate in [databaseURL, walURL, shmURL] where FileManager.default.fileExists(atPath: candidate.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        let resourceValues = try candidate.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup != true, "\(candidate.lastPathComponent) must stay backed up")
      }
    }
  }

  /// Re-applying protection is ~5 filesystem calls per artifact (two writes) on files SQLite holds
  /// open. On device (where the attribute half is not compiled out) that costs every transaction a
  /// Data Protection round trip, and a first sync issues one per page plus one per item with server
  /// progress. Once the main file and both sidecars exist and are protected, nothing is left to
  /// discover (later files inherit the directory's class), so the check must retire itself.
  @Test func onDiskDatabaseStopsReapplyingFileAttributesOnceEveryArtifactIsProtected() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let fileAttributes = FakeFileAttributeApplying()

      let database = try scope.open(fileAttributes: fileAttributes, seeding: .migrateFromEmpty)
      try await database.writeAsync { db in
        try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
      }

      let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
      let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
      try #require(FileManager.default.fileExists(atPath: walURL.path))
      try #require(FileManager.default.fileExists(atPath: shmURL.path))
      let callsOnceEveryArtifactExists = fileAttributes.artifactProtectionCalls.count

      for id in 1...25 {
        try await database.writeAsync { db in
          try db.execute(sql: "INSERT INTO probe (id) VALUES (?)", arguments: [id])
        }
      }

      #expect(
        fileAttributes.artifactProtectionCalls.count == callsOnceEveryArtifactExists,
        "protection must not be re-applied per write once every artifact is already protected")
    }
  }
}

/// Liveness gates only, not part of any contract: how long a starved machine may take to schedule
/// a thread or commit a row. Generous because the full 1600-test parallel run leaves little CPU,
/// and a timeout here would read as a busy-wait contract failure.
private let livenessTimeout: DispatchTimeInterval = .seconds(30)

/// A real OS thread, so the writer starts promptly no matter how saturated libdispatch's global
/// pool is. `.userInitiated` keeps it above the background work the rest of the suite generates.
private func startDetachedWriter(named name: String, _ body: @escaping @Sendable () -> Void) {
  let thread = Thread(block: body)
  thread.name = name
  thread.qualityOfService = .userInitiated
  thread.start()
}

private enum AsyncProbeError: Error {
  case expected
}
