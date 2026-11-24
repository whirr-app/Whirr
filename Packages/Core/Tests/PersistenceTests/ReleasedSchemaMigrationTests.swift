import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The released-schema migration baseline.
///
/// Guards against a later migration changing or breaking the schema already on a device:
///
/// 1. `ReleasedSchemaFixture`'s committed store (created by `v1` to `v3`, with a row in every
///    account-owned table) is opened and migrated, so an edit that invalidates existing data
///    shows up as a foreign-key failure or a lost row.
/// 2. The checksum test compares a freshly migrated store's normalised `sqlite_master` with a
///    committed expected file, so editing a registered migration fails until a new migration plus
///    a regenerated expected file lands.
@Suite struct ReleasedSchemaMigrationTests {

  /// Copies the committed fixture into a scratch directory and opens it. The bundled bytes are
  /// never opened directly, because migrating writes.
  private func withCommittedFixture<T>(
    _ body: (AppDatabase) throws -> T
  ) async throws -> T {
    try await withOnDiskDatabases { scope in
      let url = try ReleasedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      let database = try scope.open(at: url)
      return try body(database)
    }
  }

  private func withCommittedDriftedFixture<T>(
    _ body: (AppDatabase) throws -> T
  ) async throws -> T {
    try await withOnDiskDatabases { scope in
      let url = try DriftedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      let database = try scope.open(at: url)
      return try body(database)
    }
  }

  private func withReleasedFixtureContainingModernDiagnostics(
    _ body: (AppDatabase) throws -> Void
  ) async throws {
    try await withOnDiskDatabases { scope in
      let url = try ReleasedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      let firstMigration = try scope.open(at: url)
      try await firstMigration.writeAsync { db in
        try db.execute(
          sql: """
            INSERT INTO diagnosticsEvent
              (id, accountId, category, statusClass, durationMilliseconds, endpointTemplate, occurredAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            2, ReleasedSchemaFixture.RowID.account, "outboxTransition", "success", 456.0, nil,
            Date(timeIntervalSince1970: 1_600_000_000),
          ])
        try db.execute(
          sql: "UPDATE diagnosticsEvent SET category = ?, statusClass = ? WHERE id = ?",
          arguments: ["sync", "2xx", ReleasedSchemaFixture.RowID.account])
        try db.execute(
          sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v22"])
      }
      scope.close(firstMigration)

      let database = try scope.open(at: url)
      try body(database)
    }
  }

  private func expectMigratedDiagnosticsRow(in database: AppDatabase, accountId: Int64) throws {
    let store = DiagnosticsStore(database: database)
    let rows = try store.fetchAll(accountId: accountId)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.category == .syncRun)
    #expect(row.statusClass == .success)
    #expect(row.durationMilliseconds == 123.0)
    #expect(row.endpointTemplate?.path == "/api/libraries/{id}/items")
  }

  private func expectMigratedDiagnosticsExport(in database: AppDatabase, accountId: Int64) throws {
    let export = try DiagnosticsStore(database: database).export(accountId: accountId)
    #expect(export.contains("\tsyncRun\tsuccess\t123ms\t/api/libraries/{id}/items"))
  }

  /// Read from the committed bytes without opening them through `AppDatabase`, which migrates:
  /// opening the baseline applies `v4` (to nothing, see
  /// `DriftedSchemaHealTests.healingAStoreThatWasNeverDriftedChangesNothing`), so what the fixture
  /// carries and what an opened copy reports differ. This asks the first.
  @Test func committedFixtureCarriesOnlyTheFrozenMigrations() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("released-schema-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = try ReleasedSchemaFixture.copyOfCommittedStore(into: directory)
    #expect(
      try ReleasedSchemaFixture.appliedMigrations(inStoreAt: url)
        == ReleasedSchemaFixture.frozenMigrations)
  }

  @Test func committedFixtureHasIntactForeignKeys() async throws {
    try await withCommittedFixture { database in
      let violations = try database.read { db in
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
      }
      #expect(violations.isEmpty, "fixture has \(violations.count) foreign-key violation(s)")
    }
  }

  @Test func everyRepresentativeRowSurvivesMigration() async throws {
    try await withCommittedFixture { database in
      for (table, expected) in ReleasedSchemaFixture.expectedRowCounts {
        let count = try database.read { db in
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
        #expect(count == expected, "\(table) should still hold \(expected) row(s), found \(count)")
      }
    }
  }

  /// Counts alone would survive a migration that mangled values, so spot-check the semantics read
  /// back later: the item/episode progress split, session identity, and the episode-scoped
  /// bookmark.
  @Test func representativeRowsKeepTheirMeaning() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let itemProgress = try Row.fetchOne(
          db, sql: "SELECT * FROM mediaProgress WHERE id = ?",
          arguments: [ReleasedSchemaFixture.RowID.itemProgress])
        #expect(itemProgress?["podcastEpisodeId"] == nil)
        #expect(itemProgress?["currentTime"] as Double? == 1234.5)

        let episodeProgress = try Row.fetchOne(
          db, sql: "SELECT * FROM mediaProgress WHERE id = ?",
          arguments: [ReleasedSchemaFixture.RowID.episodeProgress])
        #expect(
          episodeProgress?["podcastEpisodeId"] as Int64? == ReleasedSchemaFixture.RowID.episode)
        #expect(episodeProgress?["currentTime"] as Double? == 67.25)

        let bookmark = try Row.fetchOne(
          db, sql: "SELECT * FROM playbackBookmark WHERE accountId = ?",
          arguments: [ReleasedSchemaFixture.RowID.account])
        #expect(bookmark?["podcastEpisodeId"] as Int64? == ReleasedSchemaFixture.RowID.episode)

        let session = try Row.fetchOne(
          db, sql: "SELECT * FROM playbackSession WHERE id = ?",
          arguments: [ReleasedSchemaFixture.RowID.session])
        #expect(session?["clientSessionId"] as String? == "fixture-client-session-1")
        #expect(session?["listenedDeltaSeconds"] as Double? == 300.0)
      }
    }
  }

  @Test func legacyDiagnosticsRowsDecodeThroughTheRecordLayerAfterMigration() async throws {
    try await withCommittedFixture { database in
      try expectMigratedDiagnosticsRow(in: database, accountId: ReleasedSchemaFixture.RowID.account)
    }

    try await withCommittedDriftedFixture { database in
      try expectMigratedDiagnosticsRow(in: database, accountId: DriftedSchemaFixture.RowID.account)
    }
  }

  @Test func legacyDiagnosticsRowsExportThroughTheRecordLayerAfterMigration() async throws {
    try await withCommittedFixture { database in
      try expectMigratedDiagnosticsExport(in: database, accountId: ReleasedSchemaFixture.RowID.account)
    }

    try await withCommittedDriftedFixture { database in
      try expectMigratedDiagnosticsExport(in: database, accountId: DriftedSchemaFixture.RowID.account)
    }
  }

  @Test func modernDiagnosticsRowsRemainUntouchedByLegacyNormalization() async throws {
    try await withReleasedFixtureContainingModernDiagnostics { database in
      let rows = try DiagnosticsStore(database: database).fetchAll(
        accountId: ReleasedSchemaFixture.RowID.account)
      #expect(rows.count == 2)
      let legacy = try #require(rows.first)
      let modern = try #require(rows.dropFirst().first)
      #expect(legacy.category == .syncRun)
      #expect(legacy.statusClass == .success)
      #expect(modern.category == .outboxTransition)
      #expect(modern.statusClass == .success)
      #expect(modern.durationMilliseconds == 456.0)
      #expect(modern.endpointTemplate == nil)
    }
  }

  @Test func podcastMigrationAddsNullableMetadataAndEpisodeConflictIdentity() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let itemColumns = Set(try db.columns(in: "item").map(\.name))
        #expect(itemColumns.contains("podcastAutoDownloadEpisodes"))
        #expect(itemColumns.contains("podcastLastEpisodeCheck"))

        let episodeColumns = Set(try db.columns(in: "podcastEpisode").map(\.name))
        #expect(
          episodeColumns.isSuperset(of: [
            "subtitle",
            "episodeDescription",
            "seasonNumber",
            "episodeType",
            "mimeType",
            "durationSeconds",
            "sizeBytes",
            "publishedAt",
            "storedAudioIno",
            "storedAudioExpectedSize",
            "storedAudioMimeType",
            "storedAudioDurationSeconds",
          ]))
        #expect(episodeColumns.contains("contentUrl") == false)

        let conflictColumns = Set(try db.columns(in: "progressConflict").map(\.name))
        #expect(conflictColumns.contains("podcastEpisodeId"))
        let outboxColumns = Set(try db.columns(in: "outboxOperation").map(\.name))
        #expect(outboxColumns.contains("podcastEpisodeId"))

        let episodeIndexes = Set(try db.indexes(on: "podcastEpisode").map(\.name))
        #expect(episodeIndexes.contains("index_podcastEpisode_browse"))

        let conflictIndexes = Set(try db.indexes(on: "progressConflict").map(\.name))
        #expect(conflictIndexes.contains("index_progressConflict_on_account_item"))
        #expect(conflictIndexes.contains("index_progressConflict_on_account_episode"))
        let outboxIndexes = Set(try db.indexes(on: "outboxOperation").map(\.name))
        #expect(outboxIndexes.contains("index_outboxOperation_on_podcastEpisode"))

        let episode = try Row.fetchOne(
          db, sql: "SELECT * FROM podcastEpisode WHERE id = ?",
          arguments: [ReleasedSchemaFixture.RowID.episode])
        #expect(episode?["title"] as String? == "Fixture Episode One")
        #expect(episode?["subtitle"] == nil)
        #expect(episode?["storedAudioIno"] == nil)
      }
    }
  }

  @Test func v23AddsPodcastServerSettingsWithoutChangingReleasedRows() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let appliedMigrations = Set(
          try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        let itemColumns = Set(try db.columns(in: "item").map(\.name))
        #expect(appliedMigrations.contains("v22"))
        #expect(appliedMigrations.contains("v23"))
        #expect(
          itemColumns.isSuperset(of: [
            "podcastAutoDownloadSchedule",
            "podcastMaxEpisodesToKeep",
            "podcastMaxNewEpisodesToDownload",
          ]))

        let podcast = try Row.fetchOne(
          db, sql: "SELECT * FROM item WHERE id = ?",
          arguments: [ReleasedSchemaFixture.RowID.podcastItem])
        #expect(podcast?["serverItemId"] as String? == "fixture-item-podcast")
        #expect(podcast?["title"] as String? == "Fixture Show")
        #expect(podcast?["podcastAutoDownloadSchedule"] == nil)
        #expect(podcast?["podcastMaxEpisodesToKeep"] == nil)
        #expect(podcast?["podcastMaxNewEpisodesToDownload"] == nil)
      }
    }
  }

  /// v6 created the podcast-only `podcastQueueEntry`; v15 replaces it with the universal
  /// `listeningQueueEntry`. The fixture has no queue row, so this only proves the table migrates
  /// cleanly. Row preservation is `ListeningQueueMigrationTests`' job.
  @Test func queueMigrationAppendsDurableAccountScopedOrdering() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        #expect(try db.tableExists("podcastQueueEntry") == false)
        #expect(try db.tableExists("listeningQueueEntry"))
        #expect(
          Set(try db.columns(in: "listeningQueueEntry").map(\.name)) == [
            "id", "accountId", "itemId", "podcastEpisodeId", "position",
            "chapterStart", "chapterEnd", "chapterTitle", "downloadDeclinedAt",
          ])
        let indexes = Set(try db.indexes(on: "listeningQueueEntry").map(\.name))
        #expect(indexes.contains("listeningQueueEntry_on_accountId"))
        #expect(indexes.contains("listeningQueueEntry_v47_on_accountId") == false)
        #expect(indexes.contains("index_listeningQueueEntry_on_account_position"))
        #expect(indexes.contains("index_listeningQueueEntry_on_account_item"))
        #expect(indexes.contains("index_listeningQueueEntry_on_account_episode"))
        #expect(indexes.contains("index_listeningQueueEntry_on_account_rss_episode") == false)
        #expect(try db.tableExists("rssListeningQueueEntry"))
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") == 0)
      }
    }
  }

  @Test func displayMetadataMigrationAppendsNullableItemColumns() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let columns = Set(try db.columns(in: "item").map(\.name))
        #expect(
          columns.isSuperset(of: [
            "seriesName", "narratorName", "expandedMetadataFetchedAt",
            "audioDownloadExpectedBytes", "ebookDownloadExpectedBytes",
          ]))
      }
    }
  }

  @Test func ebookMigrationAddsNullableProgressAndFileIdentityColumns() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let progressColumns = Set(try db.columns(in: "mediaProgress").map(\.name))
        #expect(
          progressColumns.isSuperset(of: [
            "readingPositionJSON", "ebookProgress", "ebookLocation",
          ]))
        #expect(progressColumns.filter { $0 == "isFinished" }.count == 1)
        #expect(progressColumns.contains { $0.localizedCaseInsensitiveContains("locator") } == false)

        let itemColumns = Set(try db.columns(in: "item").map(\.name))
        #expect(itemColumns.isSuperset(of: ["ebookFileIno", "ebookFileExt"]))

        let progressRows = try Row.fetchAll(
          db,
          sql: "SELECT readingPositionJSON, ebookProgress, ebookLocation FROM mediaProgress")
        #expect(progressRows.count == ReleasedSchemaFixture.expectedRowCounts["mediaProgress"])
        #expect(
          progressRows.allSatisfy {
            ($0["readingPositionJSON"] as String?) == nil
              && ($0["ebookProgress"] as Double?) == nil
              && ($0["ebookLocation"] as String?) == nil
          })

        let itemRows = try Row.fetchAll(db, sql: "SELECT ebookFileIno, ebookFileExt FROM item")
        #expect(itemRows.count == ReleasedSchemaFixture.expectedRowCounts["item"])
        #expect(
          itemRows.allSatisfy {
            ($0["ebookFileIno"] as String?) == nil && ($0["ebookFileExt"] as String?) == nil
          })
      }
    }
  }

  /// The show synopsis is appended as `v12` rather than folded into `v1`, so it reaches stores
  /// already in the field (this fixture is one). Existing rows come through the `ALTER` untouched,
  /// reading the new column as unknown rather than as an empty synopsis.
  @Test func v12MigrationAddsDescriptionToExistingStore() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let columns = Set(try db.columns(in: "item").map(\.name))
        let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item")
        let unknownDescriptions = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM item WHERE itemDescription IS NULL")

        #expect(columns.contains("itemDescription"))
        #expect(rows == ReleasedSchemaFixture.expectedRowCounts["item"])
        #expect(unknownDescriptions == ReleasedSchemaFixture.expectedRowCounts["item"])
      }
    }
  }

  /// Additive-only, so the fixture's existing `download` rows migrate through with `origin`
  /// defaulted to `.manual`, as every pre-existing row came from a manual request.
  @Test func v13AddsPodcastDeviceDownloadSettingsAndDownloadProvenance() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        #expect(try db.tableExists("podcastSettings"))
        #expect(try db.tableExists("podcastShowSettings"))

        let showSettingsIndexes = Set(try db.indexes(on: "podcastShowSettings").map(\.name))
        #expect(showSettingsIndexes.contains("index_podcastShowSettings_on_account_item"))

        let episodeColumns = Set(try db.columns(in: "podcastEpisode").map(\.name))
        #expect(episodeColumns.contains("autoDownloadDecidedAt"))
        let episode = try Row.fetchOne(
          db, sql: "SELECT autoDownloadDecidedAt FROM podcastEpisode WHERE id = ?",
          arguments: [ReleasedSchemaFixture.RowID.episode])
        #expect(episode?["autoDownloadDecidedAt"] == nil)

        let downloadColumns = Set(try db.columns(in: "download").map(\.name))
        #expect(downloadColumns.contains("origin"))
        let origins = try String.fetchAll(db, sql: "SELECT origin FROM download ORDER BY id")
        #expect(
          origins
            == Array(
              repeating: "manual",
              count: ReleasedSchemaFixture.expectedRowCounts["download"] ?? -1))
      }
    }
  }

  @Test func v19DefaultsReleasedDownloadRowsToAudioMediaKind() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let columns = Set(try db.columns(in: "download").map(\.name))
        #expect(columns.contains("mediaKind"))
        let mediaKinds = try String.fetchAll(db, sql: "SELECT mediaKind FROM download ORDER BY id")
        #expect(
          mediaKinds
            == Array(
              repeating: DownloadMediaKind.audio.rawValue,
              count: ReleasedSchemaFixture.expectedRowCounts["download"] ?? -1))
      }
    }
  }

  @Test func v20AddsAccountScopedReaderPreferencesPayload() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        let tableExists = try db.tableExists("readerPreferences")
        let columns = Set(try db.columns(in: "readerPreferences").map(\.name))
        let primaryKeyColumns = try db.primaryKey("readerPreferences").columns
        let hasAccountForeignKey = try db.foreignKeys(on: "readerPreferences").contains {
          $0.destinationTable == "account"
        }
        let rowCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM readerPreferences") ?? -1

        #expect(tableExists)
        #expect(columns == ["accountId", "preferencesJSON"])
        #expect(primaryKeyColumns == ["accountId"])
        #expect(hasAccountForeignKey)
        #expect(rowCount == 0)
      }
    }
  }

  /// Additive-only, so every fixture row the earlier migrations checked migrates through
  /// untouched. An absent `podcastShowOrder` row for a fixture account means alphabetical, and
  /// nothing here inserts one.
  @Test func podcastShowOrderMigrationPreservesReleasedFixture() async throws {
    try await withCommittedFixture { database in
      try database.read { db in
        #expect(try db.tableExists("podcastShowOrder"))
        #expect(try db.tableExists("podcastShowOrderEntry"))

        let orderColumns = Set(try db.columns(in: "podcastShowOrder").map(\.name))
        #expect(orderColumns == ["accountId", "mode"])

        let entryColumns = Set(try db.columns(in: "podcastShowOrderEntry").map(\.name))
        #expect(entryColumns == ["id", "accountId", "itemId", "position"])

        let entryIndexes = Set(try db.indexes(on: "podcastShowOrderEntry").map(\.name))
        #expect(entryIndexes.contains("index_podcastShowOrderEntry_on_account_item"))
        #expect(entryIndexes.contains("index_podcastShowOrderEntry_on_account_position"))

        let itemIndexes = Set(try db.indexes(on: "item").map(\.name))
        #expect(itemIndexes.contains("index_item_on_account_id"))

        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowOrder") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowOrderEntry") == 0)

        // Every item row the fixture already carried must still be present and unmangled.
        let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item")
        #expect(itemCount == ReleasedSchemaFixture.expectedRowCounts["item"])
      }
    }
  }

  /// The schema-driven sweep must find every account-owned table in the released schema,
  /// including ones added late, like `playbackBookmark` and `listeningHistoryEntry`.
  @Test func accountRemovalSweepClearsEveryAccountOwnedRow() async throws {
    try await withCommittedFixture { database in
      let remover = AccountRemover(database: database)
      try remover.removeAccount(accountId: ReleasedSchemaFixture.RowID.account)

      for table in ReleasedSchemaFixture.expectedRowCounts.keys
      where !ReleasedSchemaFixture.tablesSurvivingAccountRemoval.contains(table) {
        // `account` is the row being removed, so it is keyed by `id`; every other account-owned
        // table carries the cascading `accountId` the sweep discovers from the schema.
        let column = table == "account" ? "id" : "accountId"
        let remaining = try database.read { db in
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?",
            arguments: [ReleasedSchemaFixture.RowID.account]) ?? -1
        }
        #expect(remaining == 0, "\(table) still holds \(remaining) row(s) for the removed account")
      }

      // The other account is untouched, and the removal journal outlives the account it describes.
      let survivors = try database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM item WHERE accountId = ?",
          arguments: [ReleasedSchemaFixture.RowID.secondAccount]) ?? -1
      }
      #expect(survivors == 1)
      let journal = try database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accountRemovalJournal") ?? -1
      }
      #expect(journal == 1)
    }
  }

  /// The freeze itself. If this fails, an existing migration was edited: append a new one instead,
  /// then regenerate the expected file in the same commit.
  @Test func freshlyMigratedSchemaMatchesTheCommittedExpectation() throws {
    let database = try AppDatabase.inMemory()
    let actual = try database.read { db in
      try ReleasedSchemaFixture.normalizedSchema(of: db)
    }
    let expected = try ReleasedSchemaFixture.committedSchemaText()
    #expect(actual == expected)
  }

  /// The committed store and the tool that generates it must agree, so the fixture stays
  /// regenerable rather than becoming a mystery blob.
  @Test func fixtureToolReproducesTheCommittedStoreSchema() async throws {
    try await withOnDiskDatabases { scope in
      let generatedURL = scope.url("generated.sqlite")
      try ReleasedSchemaFixture.generateStore(at: generatedURL)
      let generated = try scope.open(at: generatedURL)
      let generatedSchema = try await generated.readAsync { db in
        try ReleasedSchemaFixture.normalizedSchema(of: db)
      }

      let committedSchema = try await withCommittedFixture { database in
        try database.read { db in try ReleasedSchemaFixture.normalizedSchema(of: db) }
      }
      #expect(generatedSchema == committedSchema)

      let generatedCounts = try await generated.readAsync { db -> [String: Int] in
        var counts: [String: Int] = [:]
        for table in ReleasedSchemaFixture.expectedRowCounts.keys {
          counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
        return counts
      }
      #expect(generatedCounts == ReleasedSchemaFixture.expectedRowCounts)
    }
  }

  /// The committed bytes must carry nothing that resembles a real server, account, or credential
  /// (SECURITY.md).
  @Test func committedFixtureContainsNoRealIdentifiers() throws {
    let text = String(decoding: try ReleasedSchemaFixture.committedStoreBytes(), as: UTF8.self)
    // A URL scheme, a bearer token or a JWT header would mean a real capture leaked in. Every
    // synthetic value in the tool is a bare `fixture-…` string.
    for forbidden in ["://", "Bearer ", "eyJ"] {
      #expect(!text.contains(forbidden), "fixture bytes contain \(forbidden)")
    }
  }
}

/// The scratch copies these tests open live in a temporary directory, so there is nothing to
/// protect. Production always uses `POSIXFileAttributeApplier`.
