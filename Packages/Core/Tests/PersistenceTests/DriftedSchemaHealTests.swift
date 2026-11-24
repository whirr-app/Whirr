import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `v4`, the general heal for every `v1` amendment that never got one.
///
/// `v1` was widened in place many times, and GRDB never revisits an applied migration, so an
/// amendment only reached stores that did not exist yet. A device store can report `v1,v2,v3`
/// applied while missing four tables, six `download` columns and two indexes (seen as
/// `no such table: accountRemovalJournal`).
///
/// The oracle is not a list of what `v4` should add: a healed store's normalized `sqlite_master`
/// must equal a freshly migrated store's, byte for byte, using the baseline fixture's normalizer.
/// That catches known drift, unknown drift and any future in-place amendment.
///
/// Nearly every case opens a real on-disk `DatabasePool`, as a drifted store cannot be built in
/// memory, through the shared on-disk fixture gate that bounds the process-wide pool population.
@Suite struct DriftedSchemaHealTests {

  // MARK: - Harness

  private func withFixtureScope<T>(
    _ body: (OnDiskDatabaseScope) async throws -> T
  ) async throws -> T {
    try await withOnDiskDatabases { scope in
      try await body(scope)
    }
  }

  /// Generates `shape` into a scratch directory and returns its URL, unopened and unmigrated.
  private func generated(_ shape: DriftedSchemaFixture.Shape, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("\(shape.rawValue).sqlite")
    try DriftedSchemaFixture.generateStore(at: url, shape: shape)
    return url
  }

  /// Opens (and therefore heals) the store at `url`, then closes it. Close explicitly rather
  /// than leaving it to ARC: a `DatabasePool` holds a writer queue plus reader queues, and this
  /// suite opens dozens, enough to starve the process's dispatch threads and time out an
  /// unrelated concurrency test elsewhere in the run.
  private func withHealedStore<T>(
    in scope: OnDiskDatabaseScope,
    at url: URL,
    _ body: (AppDatabase) throws -> T
  ) throws -> T {
    let database = try scope.open(at: url)
    defer { scope.close(database) }
    return try body(database)
  }

  private func freshSchema() throws -> String {
    let database = try AppDatabase.inMemory()
    defer { try? database.dbWriter.close() }
    return try database.read { db in try ReleasedSchemaFixture.normalizedSchema(of: db) }
  }

  private func schema(ofOpened database: AppDatabase) throws -> String {
    try database.read { db in try ReleasedSchemaFixture.normalizedSchema(of: db) }
  }

  // MARK: - The committed fixture is genuinely a drifted field store

  @Test func committedDriftedFixtureClaimsTheFrozenMigrationsWhileMissingTheirTables() async throws {
    try await withFixtureScope { scope in
      let url = try DriftedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)

      // The whole bug in one assertion: the store says the released schema is applied…
      #expect(
        try DriftedSchemaFixture.appliedMigrations(inStoreAt: url)
          == DriftedSchemaFixture.appliedMigrations)
      // …and yet it is not the released schema.
      #expect(try DriftedSchemaFixture.unmigratedSchema(ofStoreAt: url) != freshSchema())
    }
  }

  /// The specific drift the heal was diagnosed from, asserted before any healing so the fixture
  /// cannot quietly stop reproducing the field store.
  @Test func committedDriftedFixtureIsMissingTheFourTablesAndTheDownloadTransferColumns() async throws {
    try await withFixtureScope { scope in
      let url = try DriftedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      let dump = try DriftedSchemaFixture.unmigratedSchema(ofStoreAt: url)

      for table in [
        "progressConflict", "observedServerTime", "accountRemovalJournal", "listeningHistoryEntry",
      ] {
        #expect(!dump.contains("table\t\(table)\t"), "\(table) should be absent from a field store")
      }
      let downloadTable = try #require(
        dump.split(separator: "\n").first(where: { $0.hasPrefix("table\tdownload\t") }))
      for column in [
        "serverFileIno", "orderIndex", "expectedMimeType", "fileDurationSeconds", "holdReason",
        "errorCategory",
      ] {
        #expect(
          !downloadTable.contains("\"\(column)\""),
          "download.\(column) should be absent from a field store")
      }
      #expect(
        downloadTable.contains("\"errorReason\" TEXT"),
        "the retired column should still be present")
      #expect(
        downloadTable.contains("\"expectedBytes\" INTEGER,"),
        "expectedBytes should still be nullable")
      #expect(!dump.contains("index_playbackSession_one_active_offline_per_account"))
    }
  }

  // MARK: - The oracle

  @Test func healedFieldStoreSchemaIsIdenticalToAFreshStore() async throws {
    try await withFixtureScope { scope in
      let url = try DriftedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      let fresh = try freshSchema()
      let healed = try withHealedStore(in: scope, at: url) { try schema(ofOpened: $0) }
      #expect(healed == fresh)
    }
  }

  @Test(arguments: DriftedSchemaFixture.Shape.allCases)
  func healedStoreSchemaIsIdenticalToAFreshStoreForEveryDriftedShape(
    shape: DriftedSchemaFixture.Shape
  ) async throws {
    try await withFixtureScope { scope in
      let url = try generated(shape, in: scope.directoryURL)
      let fresh = try freshSchema()
      let drifted = try DriftedSchemaFixture.unmigratedSchema(ofStoreAt: url)
      #expect(drifted != fresh)

      let healed = try withHealedStore(in: scope, at: url) { try schema(ofOpened: $0) }
      #expect(healed == fresh)
    }
  }

  // MARK: - Data survives

  @Test(arguments: DriftedSchemaFixture.Shape.allCases)
  func everyPreExistingRowSurvivesTheHeal(shape: DriftedSchemaFixture.Shape) async throws {
    try await withFixtureScope { scope in
      let url = try generated(shape, in: scope.directoryURL)
      try withHealedStore(in: scope, at: url) { database in
        for (table, expected) in DriftedSchemaFixture.expectedRowCounts(for: shape) {
          let count = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
          }
          #expect(
            count == expected, "\(table) should still hold \(expected) row(s), found \(count)")
        }
        for table in DriftedSchemaFixture.tablesCreatedByTheHeal(for: shape) {
          let count = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
          }
          #expect(count == 0, "\(table) is created empty by the heal, found \(count) row(s)")
        }
      }
    }
  }

  /// Counts alone would survive a rebuild that mangled values, and `download` and `item` are
  /// rebuilt. Spot-check the values on both sides of a rebuilt foreign key.
  @Test(arguments: DriftedSchemaFixture.Shape.allCases)
  func rebuiltRowsKeepTheirIdentityAndValues(shape: DriftedSchemaFixture.Shape) async throws {
    try await withFixtureScope { scope in
      let url = try generated(shape, in: scope.directoryURL)
      try withHealedStore(in: scope, at: url) { database in
        try database.read { db in
          let book = try Row.fetchOne(
            db, sql: "SELECT * FROM item WHERE id = ?",
            arguments: [DriftedSchemaFixture.RowID.bookItem])
          #expect(book?["serverItemId"] as String? == "fixture-item-book")
          #expect(book?["sortTitle"] as String? == "fixture book one")
          #expect(book?["numAudioFiles"] as Int? == 3)
          #expect(book?["ebookFormat"] == nil)

          // The rebuild preserves `id`, which is what keeps every child foreign key valid.
          let episode = try Row.fetchOne(
            db, sql: "SELECT * FROM podcastEpisode WHERE id = ?",
            arguments: [DriftedSchemaFixture.RowID.episode])
          #expect(episode?["itemId"] as Int64? == DriftedSchemaFixture.RowID.podcastItem)

          let session = try Row.fetchOne(
            db, sql: "SELECT * FROM playbackSession WHERE id = ?",
            arguments: [DriftedSchemaFixture.RowID.session])
          #expect(session?["clientSessionId"] as String? == "fixture-client-session-1")
          #expect(session?["listenedDeltaSeconds"] as Double? == 300.0)

          let operation = try Row.fetchOne(db, sql: "SELECT * FROM outboxOperation WHERE id = 2")
          #expect(operation?["clientOperationId"] as String? == "fixture-operation-2")
          #expect(operation?["deadLetterReason"] as String? == "fixture-reason")
          #expect(operation?["state"] as String? == "deadLettered")
        }
      }
    }
  }

  @Test(arguments: DriftedSchemaFixture.Shape.allCases)
  func healedStoreHasCleanForeignKeys(shape: DriftedSchemaFixture.Shape) async throws {
    try await withFixtureScope { scope in
      let url = try generated(shape, in: scope.directoryURL)
      let violations = try withHealedStore(in: scope, at: url) { database in
        try database.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }
      }
      #expect(violations.isEmpty, "healed store has \(violations.count) foreign-key violation(s)")
    }
  }

  // MARK: - The two `download` decisions

  /// The retired free-text `errorReason` is mapped, not dropped. Nothing ever wrote a known
  /// vocabulary into that column, so a non-NULL legacy reason becomes `unknown` (a real
  /// `DownloadErrorCategory` case) and a NULL one stays NULL. The legacy column itself does not
  /// survive, since keeping it would mean a healed store never equals a fresh one.
  @Test func legacyDownloadErrorReasonBecomesAnUnknownErrorCategory() async throws {
    try await withFixtureScope { scope in
      let url = try generated(.fieldObserved, in: scope.directoryURL)
      try withHealedStore(in: scope, at: url) { database in
        try database.read { db in
          #expect(try db.columns(in: "download").map(\.name).contains("errorReason") == false)

          let failed = try DownloadRecord.fetchOne(
            db, key: DriftedSchemaFixture.RowID.legacyItemDownload)
          #expect(failed?.errorCategory == .unknown)
          #expect(failed?.state == .failed)

          let paused = try DownloadRecord.fetchOne(
            db, key: DriftedSchemaFixture.RowID.legacyEpisodeDownload)
          #expect(paused?.errorCategory == nil)
        }
      }
    }
  }

  /// `expectedBytes` goes from nullable to `NOT NULL`, which no `ALTER` can do, so the table is
  /// rebuilt. A legacy NULL becomes `0` ("size unknown") rather than a fabricated count.
  /// `DownloadFileStore` compares the transfer's `Content-Length` and the moved file's size
  /// against this value and quarantines on mismatch, so `0` fails closed: a legacy row can never
  /// complete against an unverified size. Everything else about the row is carried across intact.
  @Test func legacyNullExpectedBytesBecomesAnUntrustedZero() async throws {
    try await withFixtureScope { scope in
      let url = try generated(.fieldObserved, in: scope.directoryURL)
      try withHealedStore(in: scope, at: url) { database in
        try database.read { db in
          let legacy = try DownloadRecord.fetchOne(
            db, key: DriftedSchemaFixture.RowID.legacyItemDownload)
          #expect(legacy?.expectedBytes == 0)
          #expect(legacy?.receivedBytes == 1024)
          #expect(legacy?.destinationRelativePath == "fixture/book/track-1.m4b")
          #expect(legacy?.itemId == DriftedSchemaFixture.RowID.bookItem)
          // Legacy rows have no transfer identity, so the heal mints a deterministic, obviously
          // synthetic one rather than dropping the row or colliding on the new unique indexes.
          #expect(legacy?.serverFileIno == "legacy-1")
          #expect(legacy?.orderIndex == 0)

          let withSize = try DownloadRecord.fetchOne(
            db, key: DriftedSchemaFixture.RowID.legacyEpisodeDownload)
          #expect(withSize?.expectedBytes == 2048)
          #expect(withSize?.serverFileIno == "legacy-2")
        }
      }
    }
  }

  /// The already-current shape must be left completely alone: same `serverFileIno`, same
  /// `expectedBytes`, no synthetic identity anywhere near it.
  @Test func anAlreadyCurrentDownloadTableIsNotRebuilt() async throws {
    try await withFixtureScope { scope in
      let url = try generated(.afterRemovalJournal, in: scope.directoryURL)
      try withHealedStore(in: scope, at: url) { database in
        try database.read { db in
          let first = try DownloadRecord.fetchOne(
            db, key: DriftedSchemaFixture.RowID.legacyItemDownload)
          #expect(first?.serverFileIno == "fixture-ino-1")
          #expect(first?.expectedMimeType == "audio/mp4")
          #expect(first?.fileDurationSeconds == 3600.0)
        }
      }
    }
  }

  // MARK: - Idempotence

  @Test func healingAnAlreadyHealedStoreChangesNothing() async throws {
    try await withFixtureScope { scope in
      let url = try DriftedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)

      let afterFirst = try withHealedStore(in: scope, at: url) { try schema(ofOpened: $0) }
      let countsAfterFirst = try withHealedStore(in: scope, at: url) { try rowCounts($0) }

      // A third `AppDatabase` over the same file runs the whole migrator again, exactly as a
      // relaunch does.
      let afterSecond = try withHealedStore(in: scope, at: url) { try schema(ofOpened: $0) }
      let countsAfterSecond = try withHealedStore(in: scope, at: url) { try rowCounts($0) }
      #expect(afterSecond == afterFirst)
      #expect(countsAfterSecond == countsAfterFirst)
    }
  }

  /// The already-current-for-v4 case: the baseline fixture carries `v1,v2,v3` and v4's target
  /// shape, so the heal itself must not touch a thing. Later additive migrations may legitimately
  /// change the schema after that checkpoint.
  @Test func healingAStoreThatWasNeverDriftedChangesNothing() async throws {
    try await withFixtureScope { scope in
      let url = try ReleasedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      let before = try DriftedSchemaFixture.unmigratedSchema(ofStoreAt: url)

      let throughHeal = try DatabaseQueue(path: url.path)
      try SchemaV1.migrator().migrate(throughHeal, upTo: "v4")
      let afterHeal = try throughHeal.read { db in
        try ReleasedSchemaFixture.normalizedSchema(of: db)
      }
      try throughHeal.close()
      #expect(afterHeal == before)

      let fresh = try freshSchema()
      try withHealedStore(in: scope, at: url) { database in
        let after = try schema(ofOpened: database)
        #expect(after == fresh)
        for (table, expected) in ReleasedSchemaFixture.expectedRowCounts {
          let count = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
          }
          #expect(
            count == expected, "\(table) should still hold \(expected) row(s), found \(count)")
        }
      }
    }
  }

  private func rowCounts(_ database: AppDatabase) throws -> [String: Int] {
    try database.read { db -> [String: Int] in
      var counts: [String: Int] = [:]
      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            AND name <> 'grdb_migrations' ORDER BY name
          """)
      for table in tables {
        counts[table] =
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? -1
      }
      return counts
    }
  }

  // MARK: - The sweep the missing tables broke

  /// The schema-driven removal sweep discovers account-owned tables from `sqlite_master` at
  /// removal time, so a store missing four of them silently swept four fewer. After the heal it
  /// must clear every one.
  @Test(arguments: DriftedSchemaFixture.Shape.allCases)
  func accountRemovalSweepClearsEveryTableOnAHealedStore(shape: DriftedSchemaFixture.Shape) async throws {
    try await withFixtureScope { scope in
      let url = try generated(shape, in: scope.directoryURL)
      try withHealedStore(in: scope, at: url) { database in
        let remover = AccountRemover(database: database)
        try remover.removeAccount(accountId: DriftedSchemaFixture.RowID.account)

        let owned = try database.read { db in try AccountRemover.discoverAccountOwnedTables(db) }
        // Every account-owned table in the current schema, including the ones the drifted store
        // never had.
        for table in ["progressConflict", "observedServerTime", "listeningHistoryEntry"] {
          #expect(owned.contains(table), "the sweep should now discover \(table)")
        }
        #expect(owned.contains("accountRemovalJournal") == false)

        for table in owned {
          let column = table == "account" ? "id" : "accountId"
          let remaining = try database.read { db in
            try Int.fetchOne(
              db,
              sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier) WHERE \(column) = ?",
              arguments: [DriftedSchemaFixture.RowID.account]) ?? -1
          }
          #expect(
            remaining == 0, "\(table) still holds \(remaining) row(s) for the removed account")
        }

        let survivors = try database.read { db in
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM item WHERE accountId = ?",
            arguments: [DriftedSchemaFixture.RowID.secondAccount]) ?? -1
        }
        #expect(survivors == 1)
      }
    }
  }

  // MARK: - The fixture stays regenerable and synthetic

  @Test func fixtureToolReproducesTheCommittedDriftedStore() async throws {
    try await withFixtureScope { scope in
      let committed = try DriftedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      let generatedURL = try generated(.fieldObserved, in: scope.directoryURL)

      #expect(
        try DriftedSchemaFixture.unmigratedSchema(ofStoreAt: generatedURL)
          == DriftedSchemaFixture.unmigratedSchema(ofStoreAt: committed))
      #expect(
        try DriftedSchemaFixture.appliedMigrations(inStoreAt: generatedURL)
          == DriftedSchemaFixture.appliedMigrations(inStoreAt: committed))
    }
  }

  /// SECURITY.md: the committed bytes must carry nothing that resembles a real server, account
  /// or credential (the same canary the baseline fixture carries).
  @Test func committedDriftedFixtureContainsNoRealIdentifiers() throws {
    let text = String(decoding: try DriftedSchemaFixture.committedStoreBytes(), as: UTF8.self)
    for forbidden in ["://", "Bearer ", "eyJ"] {
      #expect(!text.contains(forbidden), "fixture bytes contain \(forbidden)")
    }
  }
}
