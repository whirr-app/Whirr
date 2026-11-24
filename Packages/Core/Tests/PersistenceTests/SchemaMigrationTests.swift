import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The schema migrations. `AppDatabase.inMemory()` already applies the migrator at construction,
/// so most assertions here inspect the resulting schema directly via SQLite's schema-introspection
/// pragmas rather than re-deriving it by hand.
@Suite struct SchemaMigrationTests {

  /// Every table the schema requires, in the order the migration creates them.
  private static let allTables = [
    "account", "library", "item", "podcastEpisode", "mediaProgress", "outboxOperation",
    "playbackSession", "download", "syncRun", "syncPage", "diagnosticsEvent",
    // The single-row-per-account "what was last played" bookmark.
    "playbackBookmark", "hiddenContinueSeries", "accountEndpoint",
  ]

  /// Account-owned tables: every one of these must carry an `accountId` FK with
  /// `ON DELETE CASCADE` so a future schema-driven removal sweep can find them all.
  private static let accountOwnedTables = [
    "library", "item", "podcastEpisode", "mediaProgress", "outboxOperation", "playbackSession",
    "download", "syncRun", "syncPage", "diagnosticsEvent", "playbackBookmark",
    "hiddenContinueSeries", "accountEndpoint",
  ]

  @Test func v1MigratesFromEmpty() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      for table in Self.allTables {
        let exists = try db.tableExists(table)
        #expect(exists, "\(table) should exist after v1 migrates")
      }
    }
  }

  @Test func reRunningTheMigratorIsANoOp() throws {
    let database = try AppDatabase.inMemory()
    // The migrator already ran once inside `AppDatabase.inMemory()`. Running a freshly
    // constructed migrator with the same registrations against the same writer must not throw
    // and must not change the set of applied migrations.
    try SchemaV1.migrator().migrate(database.dbWriter)
    let appliedIdentifiers = try database.read { db in
      try SchemaV1.migrator().appliedMigrations(db)
    }
    #expect(
      appliedIdentifiers == [
        "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14",
        "v15", "v16", "v17", "v18", "v19",
        "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31",
        "v32", "v33", "v34", "v35", "v36", "v37", "v38", "v39", "v40", "v41", "v42",
        "v43", "v44", "v45", "v46", "v47", "v48", "v49", "v50", "v51", "v52", "v53", "v54",
        "v55", "v56", "v57", "v58", "v59", "v60", "v61", "v62", "v63", "v64", "v65", "v66",
        "v67", "v68", "v69", "v70", "v71", "v72", "v73", "v74", "v75", "v76", "v77",
        "v78", "v79", "v80", "v81", "v82", "v83", "v84", "v85", "v86", "v87", "v88",
        "v89", "v90", "v91", "v92", "v93", "v94", "v95", "v96", "v97", "v98",
        "v99", "v100", "v101", "v102", "v103", "v104", "v105", "v106", "v107",
      ])
  }

  /// No existing account signed in through OpenID, so every row upgrades to false.
  @Test func v89RecordsExistingAccountsAsNotSigningInWithOpenID() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v88")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (clientUUID, credentialNamespace, serverBaseURL, serverUserId, serverVersion)
          VALUES ('client-v89', 'account:client-v89', 'https://example.com', 'user-v89', '2.37.2')
          """)
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let account = try #require(try AccountRecord.fetchOne(db))
      #expect(account.signsInWithOpenID == false)
      #expect(account.serverUserId == "user-v89")
    }
  }

  @Test func v63BackfillsOneEndpointAndNamespacePerAccount() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v62")
    let clientUUID = "client-v63"
    let serverURL = "https://example.com"
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [clientUUID, serverURL, "user-v63", "1"])
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let account = try #require(try AccountRecord.fetchOne(db))
      #expect(account.credentialNamespace == "account:\(clientUUID)")
      let endpoint = try #require(try AccountEndpointRecord.fetchOne(db))
      #expect(endpoint.accountId == account.id)
      #expect(endpoint.normalizedURL == serverURL)
      #expect(endpoint.isPreferred)
      #expect(endpoint.sortOrder == 0)
    }
  }

  /// The v65 backfill is the one step that can corrupt deletion inference. The generations it
  /// copies are what the next traversal compares against: invent a value and the first run after
  /// upgrade either resurrects genuinely deleted rows or sweeps live ones.
  @Test func v65MovesEachItemsGenerationIntoTheSeenSet() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v64")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (id, clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES (1, 'client-v65', 'https://example.com', 'user-v65', '1')
          """)
      try db.execute(
        sql: """
          INSERT INTO library (id, accountId, serverLibraryId, mediaType, name)
          VALUES (1, 1, 'lib-1', 'book', 'Library')
          """)
      for (rowId, generation) in [(1, 7), (2, 3), (3, 0)] {
        try db.execute(
          sql: """
            INSERT INTO item (id, accountId, libraryId, serverItemId, mediaKind, title, sortTitle,
              lastSeenGeneration, softDeleted)
            VALUES (?, 1, 1, ?, 'book', 'Title', 'title', ?, 0)
            """,
          arguments: [rowId, "item-\(rowId)", generation])
      }
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      #expect(try db.columns(in: "item").contains { $0.name == "lastSeenGeneration" } == false)
      let seen = try ItemSeenRecord.fetchAll(db).sorted { $0.itemId < $1.itemId }
      #expect(
        seen == [
          ItemSeenRecord(itemId: 1, generation: 7),
          ItemSeenRecord(itemId: 2, generation: 3),
          ItemSeenRecord(itemId: 3, generation: 0),
        ])
    }
  }

  @Test func v63ReplacesTheAccountUniqueIndex() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let indexes = try db.indexes(on: "account")
      #expect(indexes.contains { $0.name == "index_account_on_serverUserId" && $0.isUnique })
      #expect(indexes.contains { $0.name == "index_account_on_serverBaseURL_serverUserId" } == false)
    }

    let accountDAO = AccountDAO(database: database)
    _ = try accountDAO.save(
      AccountRecord(
        clientUUID: "client-one", serverBaseURL: "https://one.example", serverUserId: "same-user",
        serverVersion: "1"))
    #expect(throws: (any Error).self) {
      _ = try accountDAO.save(
        AccountRecord(
          clientUUID: "client-two", serverBaseURL: "https://two.example", serverUserId: "same-user",
          serverVersion: "1"))
    }
  }

  @Test func v63AddsNullableJournalColumns() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let columns = try db.columns(in: "accountRemovalJournal")
      #expect(columns.first { $0.name == "credentialNamespace" }?.isNotNull == false)
      #expect(columns.first { $0.name == "endpointURLs" }?.isNotNull == false)
    }
  }

  @Test func v52InvalidatesOnlyLiveBookCoverageAndPreservesExpandedMetadata() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v51")

    let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [UUID().uuidString, "https://example.com", "user-1", "2.35.1"])
      let accountId = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM account"))
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "library-1", mediaType: "book", name: "Books")
      try library.insert(db)

      for (serverItemID, mediaKind, softDeleted) in [
        ("live-book", "book", false),
        ("podcast", "podcast", false),
        ("deleted-book", "book", true),
      ] {
        try db.execute(
          sql: """
            INSERT INTO item
              (accountId, libraryId, serverItemId, mediaKind, title, sortTitle, itemDescription,
               seriesName, narratorName, expandedMetadataFetchedAt, lastSeenGeneration, softDeleted)
            VALUES (?, ?, ?, ?, ?, ?, 'Description', 'Series', 'Narrator', ?, 1, ?)
            """,
          arguments: [
            accountId, library.id!, serverItemID, mediaKind, serverItemID, serverItemID,
            fetchedAt, softDeleted,
          ])
      }
    }

    try SchemaV1.migrator().migrate(queue)

    let rows = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM item ORDER BY serverItemId")
    }
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["serverItemId"] as String, $0) })
    #expect((byID["live-book"]?["expandedMetadataFetchedAt"] as Date?) == nil)
    #expect((byID["podcast"]?["expandedMetadataFetchedAt"] as Date?) == fetchedAt)
    #expect((byID["deleted-book"]?["expandedMetadataFetchedAt"] as Date?) == fetchedAt)
    for row in rows {
      #expect((row["itemDescription"] as String?) == "Description")
      #expect((row["seriesName"] as String?) == "Series")
      #expect((row["narratorName"] as String?) == "Narrator")
      #expect((row["audioDownloadExpectedBytes"] as Int64?) == nil)
      #expect((row["ebookDownloadExpectedBytes"] as Int64?) == nil)
    }
  }

  @Test func v43SoftDeletesServerRowsUsingTheReservedRSSNamespace() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)

    try await database.writeAsync { db in
      for serverItemId in ["rss:7", "RSS:8", "xrss:9"] {
        var item = ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
          mediaKind: "podcast", title: serverItemId, sortTitle: serverItemId)
        try item.insert(db)
      }
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v43'")
    }

    try SchemaV1.migrator().migrate(database.dbWriter)

    let deletionByIdentifier = try database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT serverItemId, softDeleted FROM item ORDER BY serverItemId"
      ).reduce(into: [String: Bool]()) { result, row in
        result[row["serverItemId"]] = row["softDeleted"]
      }
    }
    #expect(deletionByIdentifier["rss:7"] == true)
    #expect(deletionByIdentifier["RSS:8"] == true)
    #expect(deletionByIdentifier["xrss:9"] == false)
  }

  @Test func v41CreatesHiddenContinueSeriesTable() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let tableExists = try db.tableExists("hiddenContinueSeries")
      let columns = try db.columns(in: "hiddenContinueSeries").map(\.name)
      let primaryKey = try db.primaryKey("hiddenContinueSeries").columns
      let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(hiddenContinueSeries)")
      let hasCascadingAccountForeignKey = foreignKeys.contains {
        ($0["table"] as String) == "account"
          && ($0["on_delete"] as String).uppercased() == "CASCADE"
      }
      #expect(tableExists)
      #expect(columns == ["accountId", "serverSeriesId"])
      #expect(primaryKey == ["accountId", "serverSeriesId"])
      #expect(hasCascadingAccountForeignKey)
    }
  }

  @Test func continueSeriesSettingIsNonNullAndDefaultsToServerOff() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let setting = try #require(
        try db.columns(in: "library").first {
          $0.name == "onlyShowLaterBooksInContinueSeries"
        })
      #expect(setting.isNotNull)
      let defaultValue: String? = try String.fetchOne(
        db,
        sql: "SELECT dflt_value FROM pragma_table_info('library') WHERE name = 'onlyShowLaterBooksInContinueSeries'")
      #expect(defaultValue == "0")
    }
  }

  @Test func mediaProgressCarriesContinueListeningVisibility() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let column = try #require(
        try db.columns(in: "mediaProgress").first { $0.name == "hideFromContinueListening" })
      #expect(column.isNotNull)
      #expect(column.defaultValueSQL == "0")
    }
  }

  @Test func librarySelectionColumnsHaveUpgradeSafeDefaultsAndIndex() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let accountMode = try #require(
        try db.columns(in: "account").first { $0.name == "librarySelectionMode" })
      #expect(accountMode.isNotNull)
      let accountDefault: String? = try String.fetchOne(
        db,
        sql: "SELECT dflt_value FROM pragma_table_info('account') WHERE name = 'librarySelectionMode'")
      #expect(accountDefault == "'all'")

      let libraryIncluded = try #require(
        try db.columns(in: "library").first { $0.name == "isIncluded" })
      #expect(libraryIncluded.isNotNull)
      let libraryDefault: String? = try String.fetchOne(
        db, sql: "SELECT dflt_value FROM pragma_table_info('library') WHERE name = 'isIncluded'")
      #expect(libraryDefault == "1")

      let index = try #require(
        try db.indexes(on: "library").first { $0.name == "index_library_on_account_visibility_media" })
      #expect(index.columns == ["accountId", "softDeleted", "isIncluded", "mediaType"])
      #expect(index.isUnique == false)
    }
  }

  @Test func preV32RowsUpgradeToIncludedLibraryDefaults() async throws {
    try await withOnDiskDatabases { scope in
      let url = try ReleasedSchemaFixture.copyOfCommittedStore(into: scope.directoryURL)
      #expect(try ReleasedSchemaFixture.appliedMigrations(inStoreAt: url).contains("v32") == false)

      let database = try scope.open(at: url)
      try await database.readAsync { db in
        let accounts = try AccountRecord.fetchAll(db)
        #expect(accounts.isEmpty == false)
        #expect(accounts.allSatisfy { $0.librarySelectionMode == .all })

        let libraries = try LibraryRecord.fetchAll(db)
        #expect(libraries.isEmpty == false)
        #expect(libraries.allSatisfy { $0.isIncluded })
      }
    }
  }

  @Test func itemArtworkAvailabilityIsNullableForOlderServerPayloads() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let column = try #require(
        try db.columns(in: "item").first { $0.name == "hasServerArtwork" })
      #expect(column.isNotNull == false)
    }
  }

  @Test func filterDataSnapshotDistinguishesSuccessfulEmptyLibraries() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let hasSnapshot = try db.tableExists("libraryFilterDataSnapshot")
      let hasIndex = try db.tableExists("libraryEntityIndex")
      let primaryKey = try db.primaryKey("libraryFilterDataSnapshot").columns
      let indexes = try db.indexes(on: "libraryEntityIndex")
      #expect(hasSnapshot)
      #expect(hasIndex)
      #expect(primaryKey == ["libraryId"])
      #expect(
        indexes.contains {
          $0.name == "index_libraryEntityIndex_on_library_kind_entity" && $0.isUnique
        })
    }
  }

  /// v28: a local session's own start position. The server derives a `startTime` only on the
  /// online `/play` path, so an offline session's uploaded start is whatever this column holds.
  /// Nullable, because a session opened before the column existed has no recoverable start and a
  /// `0` would claim it began at the start of the book.
  @Test func playbackSessionCarriesItsStartPosition() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let column = try #require(try db.columns(in: "playbackSession").first { $0.name == "startPosition" })
      #expect(column.isNotNull == false)
    }
  }

  /// v33: the ledger a lost `/sync` response is reconciled against. Non-null with a zero default,
  /// so a session already open at upgrade time reads as "nothing acknowledged yet" rather than
  /// null, since an unknown would be unreconcilable on every later attempt.
  @Test func playbackSessionCarriesItsAcknowledgedListenedTotal() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let column = try #require(
        try db.columns(in: "playbackSession").first { $0.name == "acknowledgedListenedSeconds" })
      #expect(column.isNotNull)
      #expect(column.defaultValueSQL == "0")
    }
  }

  /// v26: local listening/reading recency. `serverUpdatedAt` only ever moves when a server
  /// observation wins a merge, so it cannot order "what did I play last"; existing rows are
  /// seeded from it so an upgraded store starts from the best approximation it has.
  @Test func mediaProgressCarriesALocalActivityStamp() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      #expect(try db.columns(in: "mediaProgress").contains { $0.name == "lastActivityAt" })

      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib1", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "item-1", mediaKind: "book",
        title: "Title", sortTitle: "Title")
      try item.insert(db)

      // A pre-v26 row, written the only way an unmigrated store could: no activity stamp.
      try db.execute(
        sql: """
          INSERT INTO mediaProgress
            (accountId, itemId, currentTime, isFinished, serverUpdatedAt, localSequence, origin,
             originKey)
          VALUES (?, ?, 120, 0, ?, 3, 'server', 'server')
          """,
        arguments: [account.id!, item.id!, Date(timeIntervalSince1970: 1_000)])
      try SchemaV1.backfillActivityStamps(db)

      let stamp = try Date.fetchOne(db, sql: "SELECT lastActivityAt FROM mediaProgress")
      #expect(stamp == Date(timeIntervalSince1970: 1_000))
    }
  }

  @Test func ebookTOCEntryIsItemScopedAndOrdered() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      #expect(try db.tableExists("ebookTOCEntry"))
      #expect(
        Set(try db.columns(in: "ebookTOCEntry").map(\.name))
          == [
            "id", "accountId", "itemId", "position", "title", "href", "depth", "startProgression",
          ])
      let indexes = try db.indexes(on: "ebookTOCEntry")
      let unique = try #require(indexes.first { $0.isUnique })
      #expect(unique.columns == ["accountId", "itemId", "position"])
      let foreignKeys = try db.foreignKeys(on: "ebookTOCEntry")
      #expect(foreignKeys.count == 1)
      #expect(foreignKeys.first?.originColumns.count == 2)
    }
  }

  @Test func readerPreferencesIsOneAccountScopedJSONRow() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      #expect(try db.tableExists("readerPreferences"))
      #expect(
        Set(try db.columns(in: "readerPreferences").map(\.name))
          == ["accountId", "preferencesJSON"])
      #expect(try db.primaryKey("readerPreferences").columns == ["accountId"])
      let accountForeignKey = try db.foreignKeys(on: "readerPreferences").first {
        $0.destinationTable == "account"
      }
      #expect(accountForeignKey != nil)
      #expect(
        try db.columns(in: "readerPreferences").first { $0.name == "preferencesJSON" }?.isNotNull
          == true)
    }
  }

  @Test func ebookDownloadMediaKindMigrationIsNonNullAndDefaultsToAudio() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let mediaKind = try #require(
        db.columns(in: "download").first(where: { $0.name == "mediaKind" }))
      #expect(mediaKind.isNotNull)
      let defaultValue: String? = try String.fetchOne(
        db,
        sql: "SELECT dflt_value FROM pragma_table_info('download') WHERE name = 'mediaKind'")
      #expect(defaultValue == "'audio'")
    }
  }

  @Test func ebookProgressAndFileIdentityColumnsAreNullableAndDisjoint() throws {
    let database = try AppDatabase.inMemory()

    try database.read { db in
      let progressColumns = try db.columns(in: "mediaProgress").map(\.name)
      #expect(
        Set(progressColumns).isSuperset(of: [
          "readingPositionJSON", "ebookProgress", "ebookLocation",
        ]))
      #expect(progressColumns.filter { $0 == "isFinished" }.count == 1)
      #expect(progressColumns.contains { $0.localizedCaseInsensitiveContains("locator") } == false)

      let itemColumns = try db.columns(in: "item").map(\.name)
      #expect(Set(itemColumns).isSuperset(of: ["ebookFileIno", "ebookFileExt"]))

      // The new fields are nullable: existing rows can be read without a backfill, and a direct
      // NULL write is accepted by SQLite rather than inventing an ebook state.
      let nullable = try Row.fetchOne(
        db,
        sql: "SELECT readingPositionJSON, ebookProgress, ebookLocation FROM mediaProgress LIMIT 1")
      #expect(nullable == nil, "a fresh store has no progress row to backfill")
    }
  }

  @Test func ebookOutboxPayloadColumnsAreNullableInV21() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let columns = try db.columns(in: "outboxOperation")
      let ebookProgress = try #require(columns.first { $0.name == "payloadEbookProgress" })
      let ebookLocation = try #require(columns.first { $0.name == "payloadEbookLocation" })
      #expect(ebookProgress.isNotNull == false)
      #expect(ebookLocation.isNotNull == false)
    }
  }

  // MARK: - v15/v47: universal mixed-source listening queue

  /// `listeningQueueEntry` replaces v6's podcast-only `podcastQueueEntry` (v15). The account and
  /// episode FKs mirror v6's own shape exactly; the new `itemId` FK and the two partial unique
  /// indexes are what widen the table to also carry a whole-audiobook row.
  @Test func listeningQueueTablesHaveSeparateSourceOwnership() throws {
    let database = try AppDatabase.inMemory()
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
      #expect(
        try db.foreignKeys(on: "listeningQueueEntry")
          .contains(where: { $0.destinationTable == "account" }))

      let itemForeignKey = try db.foreignKeys(on: "listeningQueueEntry")
        .filter { $0.destinationTable == "item" }
      #expect(itemForeignKey.count == 1)
      #expect(Set(itemForeignKey.first?.originColumns ?? []) == ["accountId", "itemId"])

      let episodeForeignKey = try db.foreignKeys(on: "listeningQueueEntry")
        .filter { $0.destinationTable == "podcastEpisode" }
      #expect(episodeForeignKey.count == 1)
      #expect(Set(episodeForeignKey.first?.originColumns ?? []) == ["accountId", "podcastEpisodeId"])

      let rssEpisodeForeignKey = try db.foreignKeys(on: "rssListeningQueueEntry")
        .filter { $0.destinationTable == "rssEpisode" }
      #expect(rssEpisodeForeignKey.count == 1)
      #expect(Set(rssEpisodeForeignKey.first?.originColumns ?? []) == ["rssEpisodeId"])

      // No three-column FK, and the two parent unique indexes already existed
      // (v6's `index_podcastEpisode_on_account_id`, v14's `index_item_on_account_id`) so this
      // migration must not have tried to recreate either.
      #expect(episodeForeignKey.first?.originColumns.count == 2)
    }
  }

  // MARK: - v16: listening queue revision counter

  /// `listeningQueueRevision` is one optional row per account, `accountId` itself the primary
  /// key, mirroring `podcastShowOrder`'s shape rather than `belongsTo`'s separate
  /// auto-incremented id.
  @Test func listeningQueueRevisionIsOneRowPerAccountKeyedOnAccountId() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let exists = try db.tableExists("listeningQueueRevision")
      #expect(exists)
      let columns = try db.columns(in: "listeningQueueRevision").map(\.name)
      #expect(Set(columns) == ["accountId", "revision"])
      let primaryKeyColumns = try db.primaryKey("listeningQueueRevision").columns
      #expect(primaryKeyColumns == ["accountId"])
      let foreignKeys = try db.foreignKeys(on: "listeningQueueRevision")
      #expect(foreignKeys.contains(where: { $0.destinationTable == "account" }))
    }
  }

  // MARK: - v14: custom podcast show ordering

  /// Both `podcastShowOrder` and `podcastShowOrderEntry` must cascade away when the owning
  /// account is deleted, exactly like `podcastQueueEntry`'s own account FK above.
  @Test func podcastShowOrderRowsCascadeWithAccount() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)

    try await database.writeAsync { db in
      let order = PodcastShowOrderRecord(accountId: accountId, mode: "custom")
      try order.insert(db)
      var entry = PodcastShowOrderEntryRecord(accountId: accountId, itemId: showId, position: 0)
      try entry.insert(db)
    }

    let orderCascadesFromAccount = try database.read { db in
      try db.foreignKeys(on: "podcastShowOrder").contains { $0.destinationTable == "account" }
    }
    let entryCascadesFromAccount = try database.read { db in
      try db.foreignKeys(on: "podcastShowOrderEntry").contains { $0.destinationTable == "account" }
    }
    #expect(orderCascadesFromAccount)
    #expect(entryCascadesFromAccount)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
    }

    let remainingOrder = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowOrder") ?? -1
    }
    let remainingEntries = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowOrderEntry") ?? -1
    }
    #expect(remainingOrder == 0, "deleting the account must cascade the order row away")
    #expect(remainingEntries == 0, "deleting the account must cascade the order entry away")
  }

  /// `podcastShowOrderEntry` carries a composite `(accountId, itemId)` FK to `item`'s
  /// `(accountId, id)` unique index, so deleting just the show (not the whole
  /// account) must cascade its position row away on its own.
  @Test func podcastShowOrderRowsCascadeWithItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)

    try await database.writeAsync { db in
      var entry = PodcastShowOrderEntryRecord(accountId: accountId, itemId: showId, position: 0)
      try entry.insert(db)
    }

    let itemForeignKey = try database.read { db in
      try db.foreignKeys(on: "podcastShowOrderEntry")
        .filter { $0.destinationTable == "item" }
    }
    #expect(itemForeignKey.count == 1)
    #expect(Set(itemForeignKey.first?.originColumns ?? []) == ["accountId", "itemId"])

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [showId])
    }
    let remaining = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowOrderEntry") ?? -1
    }
    #expect(remaining == 0, "deleting the show must cascade its order entry away")
  }

  /// The `(accountId, position)` unique index (Data design table): no two shows in the same
  /// account may share a linear position.
  @Test func podcastShowOrderRejectsDuplicateAccountPosition() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let firstShowId = try await insertPodcastShowWithServerId(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-order-1")
    let secondShowId = try await insertPodcastShowWithServerId(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-order-2")

    try await database.writeAsync { db in
      var first = PodcastShowOrderEntryRecord(accountId: accountId, itemId: firstShowId, position: 0)
      try first.insert(db)
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        var duplicate = PodcastShowOrderEntryRecord(
          accountId: accountId, itemId: secondShowId, position: 0)
        try duplicate.insert(db)
      }
    }
  }

  /// The `(accountId, itemId)` unique index (Data design table): a show may hold at most one
  /// position row per account.
  @Test func podcastShowOrderRejectsDuplicateAccountItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)

    try await database.writeAsync { db in
      var first = PodcastShowOrderEntryRecord(accountId: accountId, itemId: showId, position: 0)
      try first.insert(db)
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        var duplicate = PodcastShowOrderEntryRecord(accountId: accountId, itemId: showId, position: 1)
        try duplicate.insert(db)
      }
    }
  }

  // MARK: - v13: podcast device auto-download settings

  /// `podcastSettings.accountId` is itself the primary key, so deleting the owning account must
  /// cascade the settings row away exactly like every other account-owned table.
  @Test func podcastSettingsTablesCascadeWithAccount() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)

    try await database.writeAsync { db in
      let settings = PodcastSettingsRecord(
        accountId: accountId, autoDownloadEnabled: true, keepLatestCount: 5)
      try settings.insert(db)
    }

    let accountForeignKeyCascades = try database.read { db in
      try db.foreignKeys(on: "podcastSettings")
        .contains { $0.destinationTable == "account" }
    }
    #expect(accountForeignKeyCascades)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
    }
    let remaining = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastSettings") ?? -1
    }
    #expect(remaining == 0, "deleting the account must cascade the settings row away")
  }

  /// `podcastShowSettings.itemId` is the primary key and cascades from `item`; the
  /// `(accountId, itemId)` unique index is a second, separate guarantee (never more than one
  /// override row per show even if a future caller inserts by `accountId`/`itemId` rather than
  /// the primary key directly).
  @Test func podcastShowSettingsCascadesWithItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)

    try await database.writeAsync { db in
      let settings = PodcastShowSettingsRecord(
        itemId: showId, accountId: accountId, autoDownloadOverride: .enabled)
      try settings.insert(db)
    }

    let indexes = Set(try database.read { db in try db.indexes(on: "podcastShowSettings") }.map(\.name))
    #expect(indexes.contains("index_podcastShowSettings_on_account_item"))

    let itemForeignKeyCascades = try database.read { db in
      try db.foreignKeys(on: "podcastShowSettings")
        .contains { $0.destinationTable == "item" }
    }
    #expect(itemForeignKeyCascades)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [showId])
    }
    let remaining = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowSettings") ?? -1
    }
    #expect(remaining == 0, "deleting the show must cascade its settings row away")
  }

  /// The bookmark table's own identity (at most one row per account), plus the item and
  /// optional episode FKs the projection joins through. The cascading `accountId` FK itself is
  /// covered by `everyAccountOwnedTableHasACascadingAccountForeignKey` above.
  @Test func playbackBookmarkIsUniquePerAccountAndCascadesFromItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let firstItemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)

    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO playbackBookmark (accountId, itemId, updatedAt) VALUES (?, ?, ?)",
        arguments: [accountId, firstItemId, Date(timeIntervalSince1970: 1_700_000_000)])
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        try db.execute(
          sql: "INSERT INTO playbackBookmark (accountId, itemId, updatedAt) VALUES (?, ?, ?)",
          arguments: [accountId, firstItemId, Date(timeIntervalSince1970: 1_700_000_100)])
      }
    }

    let itemForeignKeyCascades = try database.read { db in
      try db.foreignKeys(on: "playbackBookmark")
        .contains { $0.destinationTable == "item" }
    }
    #expect(itemForeignKeyCascades)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [firstItemId])
    }
    let remaining = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playbackBookmark") ?? -1
    }
    #expect(remaining == 0, "deleting the item must cascade the bookmark away")
  }

  /// The regression class the `ebookFormat` bug fell into, for this task's own table: a store that
  /// already exists has `v1` recorded as applied, so adding `playbackBookmark` to `v1` is invisible
  /// to it. `v3` heals it with a guarded `CREATE TABLE IF NOT EXISTS`. A fresh-install test cannot
  /// catch this.
  @Test func v3AddsThePlaybackBookmarkTableToAStoreThatPredatesIt() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      try await Self.degradeToPreBookmarkSchema(database)
      let existsBefore = try await database.readAsync { db in try db.tableExists("playbackBookmark") }
      #expect(existsBefore == false)
      scope.close(database)

      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let (existsAfter, accountForeignKey) = try await reopened.readAsync { db in
        (
          try db.tableExists("playbackBookmark"),
          try db.foreignKeys(on: "playbackBookmark").contains { $0.destinationTable == "account" }
        )
      }
      #expect(existsAfter)
      #expect(accountForeignKey)
    }
  }

  @Test func everyAccountOwnedTableHasACascadingAccountForeignKey() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      for table in Self.accountOwnedTables {
        let foreignKeyRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
        let cascadingAccountFK = foreignKeyRows.contains { row in
          (row["table"] as String) == "account"
            && (row["on_delete"] as String).uppercased() == "CASCADE"
        }
        #expect(cascadingAccountFK, "\(table) must have an accountId FK with ON DELETE CASCADE")
      }
    }
  }

  @Test func accountCarriesAStableClientUUIDThatSurvivesReconstruction() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let clientUUID = UUID().uuidString
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: clientUUID, serverBaseURL: "https://example.com", serverUserId: "user-1",
          serverVersion: "2.10.0")
        try account.insert(db)
      }
      scope.close(database)

      // A fresh `AppDatabase` construction against the same file simulates relaunch.
      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let account = try await reopened.readAsync { db in try AccountRecord.fetchOne(db) }
      #expect(account?.clientUUID == clientUUID)
    }
  }

  @Test func itemIdentityIsUniqueOnLibraryAndServerItemId() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)

    try await database.writeAsync { db in
      var first = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "A", sortTitle: "a")
      try first.insert(db)
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        var duplicate = ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
          title: "A again", sortTitle: "a again")
        try duplicate.insert(db)
      }
    }
  }

  /// `item` gains the recency/media-signal
  /// columns Home needs, plus a recency index.
  @Test func itemCarriesTheHomeScreenRecencyAndMediaSignalColumns() throws {
    let database = try AppDatabase.inMemory()
    let columnNames: Set<String> = try database.read { db in
      Set(try db.columns(in: "item").map(\.name))
    }
    #expect(columnNames.isSuperset(of: ["addedAt", "numAudioFiles", "ebookFormat"]))
  }

  @Test func itemHasARecentlyAddedIndex() throws {
    let database = try AppDatabase.inMemory()
    let indexNames: Set<String> = try database.read { db in
      Set(try db.indexes(on: "item").map(\.name))
    }
    #expect(indexNames.contains("index_item_recently_added"))
  }

  /// Regression: `ebookFormat` was renamed inside the already-applied `v1` migration, so a store
  /// created earlier kept the old `ebookFileFormat` column while Home queries asked for the new
  /// name: "no such column: item.ebookFormat" on device, an empty Home, and a silently mis-derived
  /// Library category (the missing column decodes as nil for `ItemRecord`'s optional property).
  /// Amending v1 in place only helps stores not yet created; `v2` heals the rest.
  @Test func v2RenamesALegacyEbookFileFormatColumnAndPreservesItsValues() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      let (accountId, libraryId) = try await insertAccountAndLibrary(database)
      try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "ebook-1", mediaKind: "book",
          title: "Title", sortTitle: "title", numAudioFiles: 0, ebookFormat: "epub")
        try item.insert(db)
      }
      try await Self.degradeToPreRenameSchema(database)

      // The store now looks exactly like one that ran the pre-rename v1 and nothing since.
      let legacyColumns: Set<String> = try await database.readAsync { db in
        Set(try db.columns(in: "item").map(\.name))
      }
      #expect(legacyColumns.contains("ebookFileFormat"))
      #expect(legacyColumns.contains("ebookFormat") == false)
      scope.close(database)

      // A fresh construction against the same file simulates relaunching the updated app.
      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let columnNames: Set<String> = try await reopened.readAsync { db in
        Set(try db.columns(in: "item").map(\.name))
      }
      #expect(columnNames.contains("ebookFormat"))
      #expect(columnNames.contains("ebookFileFormat") == false)

      let item = try await reopened.readAsync { db in try ItemRecord.fetchOne(db) }
      #expect(item?.ebookFormat == "epub", "the rename must carry the existing values across")
    }
  }

  /// The same heal, for a store old enough to predate the recency columns altogether: it has
  /// neither spelling of the column, nor `addedAt`/`numAudioFiles`, nor the recency index.
  @Test func v2AddsTheHomeColumnsToAStoreThatPredatesTheAmendment() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      try await Self.degradeToPreAmendmentSchema(database)
      let legacyColumns: Set<String> = try await database.readAsync { db in
        Set(try db.columns(in: "item").map(\.name))
      }
      #expect(legacyColumns.isDisjoint(with: ["addedAt", "numAudioFiles", "ebookFormat"]))
      scope.close(database)

      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      try await reopened.readAsync { db in
        let columnNames = Set(try db.columns(in: "item").map(\.name))
        #expect(columnNames.isSuperset(of: ["addedAt", "numAudioFiles", "ebookFormat"]))
        let indexNames = Set(try db.indexes(on: "item").map(\.name))
        #expect(indexNames.contains("index_item_recently_added"))
      }
    }
  }

  @Test func episodeIdentityIsUniqueOnItemAndServerEpisodeId() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "podcast-1", mediaKind: "podcast",
        title: "Show", sortTitle: "show")
      try item.insert(db)
      return item.id!
    }

    try await database.writeAsync { db in
      var first = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "ep-1", title: "Episode 1",
        lastSeenGeneration: 1)
      try first.insert(db)
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        var duplicate = PodcastEpisodeRecord(
          accountId: accountId, itemId: itemId, serverEpisodeId: "ep-1", title: "Episode 1 again",
          lastSeenGeneration: 1)
        try duplicate.insert(db)
      }
    }
  }

  @Test func progressCarriesServerTimestampLocalSequenceOriginAndOriginKey() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)

    let serverUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let stored = try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountId, itemId: itemId, currentTime: 42, isFinished: false,
        serverUpdatedAt: serverUpdatedAt, localSequence: 7, origin: .server,
        originKey: ProgressOrigin.serverOriginKey)
      try progress.insert(db)
      return progress
    }

    #expect(stored.serverUpdatedAt == serverUpdatedAt)
    #expect(stored.localSequence == 7)
    #expect(stored.origin == .server)
    #expect(stored.originKey == "server")
  }

  @Test func outboxCarriesClientUUIDCoalescingKeyPayloadVersionSequenceAttemptsNextAttemptState()
    async throws
  {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let clientOperationId = UUID().uuidString
    let nextAttemptAt = Date(timeIntervalSince1970: 1_700_000_100)

    let stored = try await database.writeAsync { db in
      var operation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: clientOperationId, entityKey: "item:1",
        podcastEpisodeId: nil,
        operationKind: "progressUpdate", coalescingKey: "item:1:progress", payloadVersion: 1,
        localSequence: 3, attempts: 2, nextAttemptAt: nextAttemptAt, state: .retryWaiting)
      try operation.insert(db)
      return operation
    }

    #expect(stored.clientOperationId == clientOperationId)
    #expect(stored.coalescingKey == "item:1:progress")
    #expect(stored.payloadVersion == 1)
    #expect(stored.localSequence == 3)
    #expect(stored.attempts == 2)
    #expect(stored.nextAttemptAt == nextAttemptAt)
    #expect(stored.state == .retryWaiting)
  }

  @Test func syncRunAndSyncPageRowsExist() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)

    let run = try await database.writeAsync { db in
      var run = SyncRunRecord(
        accountId: accountId, libraryId: libraryId, reason: "foreground", generation: 1,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try run.insert(db)
      return run
    }

    try await database.writeAsync { db in
      var page = SyncPageRecord(
        accountId: accountId, syncRunId: run.id!, pageNumber: 1, itemCount: 100,
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_010))
      try page.insert(db)
    }

    let pageCount = try database.read { db in
      try SyncPageRecord.filter(Column("syncRunId") == run.id!).fetchCount(db)
    }
    #expect(pageCount == 1)
  }

  // MARK: - v10: FTS5 search index

  @Test func v10CreatesTheFTS5TablesAndAllSixTriggers() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      #expect(try db.tableExists("itemSearch"))
      #expect(try db.tableExists("episodeSearch"))
      let triggerNames = Set(
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
      #expect(
        triggerNames.isSuperset(
          of: [
            "itemSearch_ai", "itemSearch_ad", "itemSearch_au",
            "episodeSearch_ai", "episodeSearch_ad", "episodeSearch_au",
          ]))
    }
  }

  /// The `searchFold` registration `AppDatabase` adds to every connection must fold the same way
  /// as `SearchQueryNormalizer.normalize`, or the index and a later query would silently
  /// disagree.
  @Test func searchFoldSQLFunctionMatchesSearchQueryNormalizer() throws {
    let database = try AppDatabase.inMemory()
    let samples = ["Émile", "GAIMAN, Neil", "  spaced   out  ", "İstanbul", "Straße"]
    try database.read { db in
      for sample in samples {
        let folded = try String.fetchOne(db, sql: "SELECT searchFold(?)", arguments: [sample])
        #expect(folded == SearchQueryNormalizer.normalize(sample), "mismatch for \(sample)")
      }
    }
  }

  @Test func searchCanonicalSQLFunctionMatchesSearchQueryNormalizer() throws {
    let database = try AppDatabase.inMemory()
    let samples = ["James S.A. Corey", "James S. A. Corey", "O'Brien", "Jean-Luc"]
    try database.read { db in
      for sample in samples {
        let canonical = try String.fetchOne(
          db, sql: "SELECT searchCanonical(?)", arguments: [sample])
        #expect(canonical == SearchQueryNormalizer.canonicalize(sample), "mismatch for \(sample)")
      }
    }
  }

  @Test func insertingAnItemAddsItToTheIndex() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "i1", mediaKind: "book",
        title: "The Ocean at the End of the Lane", sortTitle: "ocean")
      try item.insert(db)
      return item.id!
    }
    #expect(try matchesItemSearch(database, "ocean") == [itemId])
  }

  @Test func updatingAnItemReplacesItsIndexEntryRatherThanAddingToIt() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "i1", mediaKind: "book",
        title: "Ocean", sortTitle: "ocean")
      try item.insert(db)
      return item.id!
    }
    #expect(try matchesItemSearch(database, "ocean") == [itemId])

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET title = ? WHERE id = ?", arguments: ["Neverwhere", itemId])
    }
    #expect(try matchesItemSearch(database, "ocean").isEmpty)
    #expect(try matchesItemSearch(database, "neverwhere") == [itemId])
  }

  @Test func deletingAnItemRemovesItFromTheIndex() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "i1", mediaKind: "book",
        title: "Ocean", sortTitle: "ocean")
      try item.insert(db)
      return item.id!
    }
    #expect(try matchesItemSearch(database, "ocean") == [itemId])

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [itemId])
    }
    #expect(try matchesItemSearch(database, "ocean").isEmpty)
  }

  @Test func softDeletingAnItemRemovesItFromTheIndexAndUnSoftDeletingRestoresIt() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "i1", mediaKind: "book",
        title: "Ocean", sortTitle: "ocean")
      try item.insert(db)
      return item.id!
    }
    #expect(try matchesItemSearch(database, "ocean") == [itemId])

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [itemId])
    }
    #expect(try matchesItemSearch(database, "ocean").isEmpty)

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 0 WHERE id = ?", arguments: [itemId])
    }
    #expect(try matchesItemSearch(database, "ocean") == [itemId])
  }

  @Test func insertingAnEpisodeAddsItToTheIndex() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)
    let episodeId = try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: showId, serverEpisodeId: "e1", title: "A Meditation",
        subtitle: "on silence", episodeDescription: "<p>long form</p>", lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
    #expect(try matchesEpisodeSearch(database, "meditation") == [episodeId])
    #expect(try matchesEpisodeSearch(database, "silence") == [episodeId])
  }

  @Test func updatingAnEpisodeReplacesItsIndexEntryRatherThanAddingToIt() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)
    let episodeId = try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: showId, serverEpisodeId: "e1", title: "Meditation",
        lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
    #expect(try matchesEpisodeSearch(database, "meditation") == [episodeId])

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET title = ? WHERE id = ?", arguments: ["Retrospective", episodeId])
    }
    #expect(try matchesEpisodeSearch(database, "meditation").isEmpty)
    #expect(try matchesEpisodeSearch(database, "retrospective") == [episodeId])
  }

  @Test func deletingAnEpisodeRemovesItFromTheIndex() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)
    let episodeId = try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: showId, serverEpisodeId: "e1", title: "Meditation",
        lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
    #expect(try matchesEpisodeSearch(database, "meditation") == [episodeId])

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM podcastEpisode WHERE id = ?", arguments: [episodeId])
    }
    #expect(try matchesEpisodeSearch(database, "meditation").isEmpty)
  }

  @Test func softDeletingAnEpisodeRemovesItFromTheIndexAndUnSoftDeletingRestoresIt() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)
    let episodeId = try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: showId, serverEpisodeId: "e1", title: "Meditation",
        lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
    #expect(try matchesEpisodeSearch(database, "meditation") == [episodeId])

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [episodeId])
    }
    #expect(try matchesEpisodeSearch(database, "meditation").isEmpty)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 0 WHERE id = ?", arguments: [episodeId])
    }
    #expect(try matchesEpisodeSearch(database, "meditation") == [episodeId])
  }

  /// The regression class `v2`/`v3` above already cover for other tables: `v10`'s index is
  /// created empty by a fresh install (nothing to populate), but a store that already carries
  /// `item`/`podcastEpisode` rows from before `v10` shipped must have its index built for them,
  /// by a one-off population inside the migration itself (not a launch-time sweep). Rewinding a
  /// real schema beats hand-building a partial one.
  @Test func v10PopulatesTheIndexForRowsThatPredateTheMigration() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      try await Self.degradeToPreSearchIndexSchema(database)
      let (accountId, libraryId) = try await insertAccountAndLibrary(database)
      let showId = try await insertPodcastShow(database, accountId: accountId, libraryId: libraryId)
      let episodeId = try await database.writeAsync { db in
        var episode = PodcastEpisodeRecord(
          accountId: accountId, itemId: showId, serverEpisodeId: "pre-v10-episode",
          title: "Preexisting Episode", lastSeenGeneration: 1)
        try episode.insert(db)
        return episode.id!
      }
      let itemId = try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "pre-v10-item",
          mediaKind: "book", title: "Preexisting Item", sortTitle: "preexisting item")
        try item.insert(db)
        return item.id!
      }
      let existsBefore = try await database.readAsync { db in try db.tableExists("itemSearch") }
      #expect(existsBefore == false)
      scope.close(database)

      // A fresh construction against the same file simulates relaunching the updated app, which
      // applies the still-pending `v10`.
      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let itemMatches = try await reopened.readAsync { db in
        try Int64.fetchAll(
          db, sql: "SELECT rowid FROM itemSearch WHERE itemSearch MATCH ? ORDER BY rowid",
          arguments: [SearchQueryNormalizer.normalize("preexisting item")])
      }
      let episodeMatches = try await reopened.readAsync { db in
        try Int64.fetchAll(
          db, sql: "SELECT rowid FROM episodeSearch WHERE episodeSearch MATCH ? ORDER BY rowid",
          arguments: [SearchQueryNormalizer.normalize("preexisting episode")])
      }
      #expect(itemMatches == [itemId])
      #expect(episodeMatches == [episodeId])
    }
  }

  // MARK: - Helpers

  /// Rewinds a current store to the shape a device carried after the *pre-rename* v1: the ebook
  /// column under its old name, and no record of `v2` ever having run. Rewinding a real schema
  /// beats hand-building a partial one: the result is a faithful legacy store.
  private static func degradeToPreRenameSchema(_ database: AppDatabase) async throws {
    try await database.writeAsync { db in
      try db.alter(table: "item") { t in
        t.rename(column: "ebookFormat", to: "ebookFileFormat")
      }
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2'")
    }
  }

  /// Rewinds further still: to a store that predates the recency columns.
  private static func degradeToPreAmendmentSchema(_ database: AppDatabase) async throws {
    try await database.writeAsync { db in
      // The index covers `addedAt`, so it has to go before the column it references.
      try db.drop(index: "index_item_recently_added")
      try db.alter(table: "item") { t in
        t.drop(column: "addedAt")
        t.drop(column: "numAudioFiles")
        t.drop(column: "ebookFormat")
      }
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2'")
    }
  }

  /// Rewinds a current store to the shape a device carried before `playbackBookmark` existed: no
  /// such table, and no record of `v3` ever having run.
  private static func degradeToPreBookmarkSchema(_ database: AppDatabase) async throws {
    try await database.writeAsync { db in
      try db.drop(table: "playbackBookmark")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3'")
    }
  }

  /// Rewinds a current store to the shape a device carried before `v10`'s FTS5 index existed:
  /// the triggers and virtual tables gone, and no record of `v10` ever having run.
  private static func degradeToPreSearchIndexSchema(_ database: AppDatabase) async throws {
    try await database.writeAsync { db in
      for trigger in [
        "itemSearch_ai", "itemSearch_ad", "itemSearch_au",
        "episodeSearch_ai", "episodeSearch_ad", "episodeSearch_au",
      ] {
        try db.execute(sql: "DROP TRIGGER \(trigger)")
      }
      try db.execute(sql: "DROP TABLE itemSearch")
      try db.execute(sql: "DROP TABLE episodeSearch")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v10'")
    }
  }

  /// The rowids `itemSearch` reports as matching `term` (folded through the same
  /// `SearchQueryNormalizer` the write-path triggers use), queried by `MATCH`. A plain `SELECT`
  /// against an external-content FTS5 table reads column values straight through to the source
  /// table by rowid rather than the index, so it cannot answer "is this row actually indexed".
  private func matchesItemSearch(_ database: AppDatabase, _ term: String) throws -> [Int64] {
    try database.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM itemSearch WHERE itemSearch MATCH ? ORDER BY rowid",
        arguments: [SearchQueryNormalizer.normalize(term)])
    }
  }

  /// The `episodeSearch` counterpart of `matchesItemSearch`.
  private func matchesEpisodeSearch(_ database: AppDatabase, _ term: String) throws -> [Int64] {
    try database.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM episodeSearch WHERE episodeSearch MATCH ? ORDER BY rowid",
        arguments: [SearchQueryNormalizer.normalize(term)])
    }
  }

  /// A minimal podcast show `item` row for episode tests, which need a parent to satisfy
  /// `podcastEpisode`'s `itemId` foreign key.
  private func insertPodcastShow(_ database: AppDatabase, accountId: Int64, libraryId: Int64)
    async throws -> Int64
  {
    try await insertPodcastShowWithServerId(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1")
  }

  /// `insertPodcastShow` fixed to a single `serverItemId`; the v14 order-uniqueness tests need
  /// two distinct shows in the same account, which `item`'s own `(libraryId, serverItemId)`
  /// identity requires to be distinct strings.
  private func insertPodcastShowWithServerId(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, serverItemId: String
  )
    async throws -> Int64
  {
    try await database.writeAsync { db in
      var show = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)
      return show.id!
    }
  }

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let libraryId = try await database.writeAsync { db in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    return (accountId, libraryId)
  }

}
