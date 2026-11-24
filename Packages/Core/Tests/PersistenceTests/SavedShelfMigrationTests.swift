import Foundation
import GRDB
import Testing

@testable import Persistence

/// The Saved for Later table, its account-scoped uniqueness rules, cascades, and denormalised
/// display-title migration.
@Suite struct SavedShelfMigrationTests {

  @Test func freshMigrationCreatesSavedShelfTableAndIndexes() throws {
    let database = try AppDatabase.inMemory()

    try database.read { db in
      #expect(try db.tableExists("savedShelfEntry"))
      #expect(
        try db.columns(in: "savedShelfEntry").map(\.name)
          == [
            "id", "accountId", "itemId", "podcastEpisodeId", "savedAt",
            "subjectTitle", "contextTitle",
          ])

      let indexes = try db.indexes(on: "savedShelfEntry")
      #expect(
        Set(indexes.map(\.name)) == [
          "index_savedShelfEntry_on_account_item",
          "index_savedShelfEntry_on_account_episode",
          "index_savedShelfEntry_on_account_savedAt",
          // GRDB creates this FK-support index for `belongsTo("account")`.
          "savedShelfEntry_on_accountId",
        ])

      let itemIndex = try #require(
        indexes.first { $0.name == "index_savedShelfEntry_on_account_item" })
      #expect(itemIndex.columns == ["accountId", "itemId"])
      #expect(itemIndex.isUnique)

      let episodeIndex = try #require(
        indexes.first { $0.name == "index_savedShelfEntry_on_account_episode" })
      #expect(episodeIndex.columns == ["accountId", "podcastEpisodeId"])
      #expect(episodeIndex.isUnique)

      let savedAtIndex = try #require(
        indexes.first { $0.name == "index_savedShelfEntry_on_account_savedAt" })
      #expect(savedAtIndex.columns == ["accountId", "savedAt"])
      #expect(savedAtIndex.isUnique == false)
    }
  }

  @Test("v53 preserves an existing ABS saved identity and timestamp")
  func v53PreservesExistingABSRows() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let database = try DatabaseQueue(configuration: configuration)
    // Seeded at v53's predecessor so `ItemRecord` matches the fixture's column set.
    try SchemaV1.migrator().migrate(database, upTo: "v52")

    let savedAt = Date(timeIntervalSince1970: 1_700_000_123)
    let accountId = try database.write { db -> Int64 in
      let accountID = try Self.insertLegacyAccount(
        db, clientUUID: "v53-client", serverBaseURL: "v53-server", serverUserId: "v53-user",
        serverVersion: "2.52.0")
      let libraryId = try Self.insertLegacyLibrary(
        db, accountID: accountID, serverLibraryId: "v53-library", mediaType: "book")
      // Seed with only the columns that existed at v52. `ItemRecord` tracks the head schema and
      // would write v57's podcast feed fingerprint before the migration under test.
      let itemID = try Self.insertLegacyItem(
        db, accountID: accountID, libraryID: libraryId, serverItemID: "v53-item",
        mediaKind: "book", title: "V53 Book", sortTitle: "v53 book")
      try db.execute(
        sql: "INSERT INTO savedShelfEntry(accountId, itemId, savedAt, subjectTitle) VALUES (?, ?, ?, ?)",
        arguments: [accountID, itemID, savedAt, "V53 Book"])
      return accountID
    }

    try SchemaV1.migrator().migrate(database, upTo: "v53")

    try database.read { db in
      let fetched = try Row.fetchOne(
        db,
        sql: """
          SELECT saved.itemId, item.serverItemId, saved.savedAt, saved.rssEpisodeId
          FROM savedShelfEntry AS saved
          JOIN item ON item.id = saved.itemId
          WHERE saved.accountId = ?
          """,
        arguments: [accountId])
      let row = try #require(fetched)
      #expect(row["itemId"] as Int64? != nil)
      #expect(row["serverItemId"] as String? == "v53-item")
      #expect(row["savedAt"] as Date? == savedAt)
      #expect(row["rssEpisodeId"] as Int64? == nil)
    }
  }

  @Test func v53CopyCountGuardReportsMismatches() {
    #expect(
      throws: SchemaV1.SavedShelfMigrationError.copyCountMismatch(expected: 2, actual: 1)
    ) {
      try SchemaV1.validateSavedShelfCopyCount(expected: 2, actual: 1)
    }
  }

  @Test("v35 backfills denormalized titles for pre-existing whole-item and episode saves")
  func v35BackfillsExistingSavedTitles() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let database = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(database, upTo: "v34")

    let fixture = try database.write { db -> (accountId: Int64, itemId: Int64, episodeId: Int64) in
      let accountID = try Self.insertLegacyAccount(
        db, clientUUID: "migration-client", serverBaseURL: "migration-server",
        serverUserId: "migration-user", serverVersion: "2.35.1")

      // Pinned below the head migration, so the row is written with the columns that existed at
      // `v34` rather than through `LibraryRecord`, which always carries today's.
      let libraryID = try Self.insertLegacyLibrary(
        db, accountID: accountID, serverLibraryId: "migration-library", mediaType: "book")

      let itemID = try Self.insertLegacyItem(
        db, accountID: accountID, libraryID: libraryID, serverItemID: "migration-item",
        mediaKind: "podcast", title: "Migration Show", sortTitle: "migration show")

      var episode = PodcastEpisodeRecord(
        accountId: accountID, itemId: itemID, serverEpisodeId: "migration-episode",
        title: "Migration Episode", lastSeenGeneration: 1)
      try episode.insert(db)

      try db.execute(
        sql: """
          INSERT INTO savedShelfEntry(accountId, itemId, savedAt)
          VALUES (?, ?, ?)
          """,
        arguments: [accountID, itemID, Date(timeIntervalSince1970: 1_700_000_000)])
      try db.execute(
        sql: """
          INSERT INTO savedShelfEntry(accountId, itemId, podcastEpisodeId, savedAt)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          accountID, itemID, episode.id!, Date(timeIntervalSince1970: 1_700_000_001),
        ])
      return (accountID, itemID, episode.id!)
    }

    try SchemaV1.migrator().migrate(database, upTo: "v35")

    try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT podcastEpisodeId, subjectTitle, contextTitle
          FROM savedShelfEntry
          WHERE accountId = ? AND itemId = ?
          ORDER BY id
          """,
        arguments: [fixture.accountId, fixture.itemId])
      #expect(rows.count == 2)
      #expect(rows[0]["podcastEpisodeId"] as Int64? == nil)
      #expect(rows[0]["subjectTitle"] as String? == "Migration Show")
      #expect(rows[0]["contextTitle"] as String? == nil)
      #expect(rows[1]["podcastEpisodeId"] as Int64? == fixture.episodeId)
      #expect(rows[1]["subjectTitle"] as String? == "Migration Episode")
      #expect(rows[1]["contextTitle"] as String? == "Migration Show")
    }
  }

  @Test func partialUniqueIndexRejectsDuplicateWholeItemSaves() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)

    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 1)
    await #expect(throws: (any Error).self) {
      _ = try await Self.insertEntry(
        database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 2)
    }
  }

  @Test func partialUniqueIndexRejectsDuplicateEpisodeSaves() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let episodeId = try #require(fixture.episodeId)

    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId,
      podcastEpisodeId: episodeId, savedAt: 1)
    await #expect(throws: (any Error).self) {
      _ = try await Self.insertEntry(
        database, accountId: fixture.accountId, itemId: fixture.itemId,
        podcastEpisodeId: episodeId, savedAt: 2)
    }
  }

  @Test func sameServerItemInDifferentAccountsCanBeSaved() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await Self.seedAccountLibraryItemAndEpisode(
      database, suffix: "first", serverItemID: "shared-item")
    let second = try await Self.seedAccountLibraryItemAndEpisode(
      database, suffix: "second", serverItemID: "shared-item")

    _ = try await Self.insertEntry(
      database, accountId: first.accountId, itemId: first.itemId, savedAt: 1)
    _ = try await Self.insertEntry(
      database, accountId: second.accountId, itemId: second.itemId, savedAt: 2)

    let count = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry")
    }
    #expect(count == 2)
  }

  @Test func wholeItemAndEpisodeSavesForTheSameItemCanCoexist() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let episodeId = try #require(fixture.episodeId)

    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 1)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId,
      podcastEpisodeId: episodeId, savedAt: 2)

    let count = try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM savedShelfEntry WHERE accountId = ? AND itemId = ?",
        arguments: [fixture.accountId, fixture.itemId])
    }
    #expect(count == 2)
  }

  @Test func deletingAccountCascadesSavedShelfEntries() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 1)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [fixture.accountId])
    }

    let count = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry")
    }
    #expect(count == 0)
  }

  @Test func deletingItemCascadesItsSavedShelfEntries() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 1)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [fixture.itemId])
    }

    let count = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry")
    }
    #expect(count == 0)
  }

  @Test func deletingEpisodeCascadesItsSavedShelfEntry() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let episodeId = try #require(fixture.episodeId)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId,
      podcastEpisodeId: episodeId, savedAt: 1)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM podcastEpisode WHERE id = ?", arguments: [episodeId])
    }

    let count = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry")
    }
    #expect(count == 0)
  }

  @Test("positive audio progress removes only the matching saved identity")
  func positiveAudioProgressRemovesMatchingSavedIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let episodeId = try #require(fixture.episodeId)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 1)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId,
      podcastEpisodeId: episodeId, savedAt: 2)

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.itemId,
        podcastEpisodeId: episodeId, currentTime: 12, isFinished: false,
        localSequence: 1, origin: .local, originKey: "test")
      try progress.insert(db)
    }

    let remainingEpisodeIDs = try database.read { db in
      try Int64?.fetchAll(
        db,
        sql: "SELECT podcastEpisodeId FROM savedShelfEntry WHERE accountId = ? ORDER BY id",
        arguments: [fixture.accountId])
    }
    #expect(remainingEpisodeIDs == [nil])
  }

  @Test("positive ebook progress removes a saved whole item on update")
  func positiveEbookProgressRemovesSavedWholeItemOnUpdate() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 1)

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.itemId, currentTime: 0,
        isFinished: false, localSequence: 1, origin: .local, originKey: "test")
      try progress.insert(db)
      progress.ebookProgress = 0.25
      try progress.update(db)
    }

    let count = try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM savedShelfEntry WHERE accountId = ?",
        arguments: [fixture.accountId])
    }
    #expect(count == 0)
  }

  @Test("v36 uses activity chronology to reconcile existing positive progress")
  func v36ReconcilesExistingProgress() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let database = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(database, upTo: "v35")

    try database.write { db in
      let accountID = try Self.insertLegacyAccount(
        db, clientUUID: "reconcile-client", serverBaseURL: "reconcile-server",
        serverUserId: "reconcile-user", serverVersion: "2.35.1")
      let libraryID = try Self.insertLegacyLibrary(
        db, accountID: accountID, serverLibraryId: "reconcile-library", mediaType: "book")
      let itemID = try Self.insertLegacyItem(
        db, accountID: accountID, libraryID: libraryID, serverItemID: "reconcile-item",
        mediaKind: "book", title: "Book", sortTitle: "book")
      let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
      // Same reason as the mediaProgress insert below: this fixture stops at v35, and
      // SavedShelfEntryRecord carries an rssEpisodeId column that does not exist there.
      try db.execute(
        sql: """
          INSERT INTO savedShelfEntry(accountId, itemId, savedAt, subjectTitle)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [accountID, itemID, savedAt, "Book"])
      // This database stops at v35. Insert its historical row shape directly so newer
      // MediaProgressRecord columns do not leak backwards into the migration fixture.
      try db.execute(
        sql: """
          INSERT INTO mediaProgress
            (accountId, itemId, currentTime, isFinished, localSequence, origin, originKey,
             lastActivityAt)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          accountID, itemID, 30, false, 1, ProgressOrigin.local.rawValue, "test",
          savedAt.addingTimeInterval(1),
        ])

      // Saved after it had already been started, so the migration must preserve it until progress
      // changes again.
      let resumedLaterID = try Self.insertLegacyItem(
        db, accountID: accountID, libraryID: libraryID,
        serverItemID: "saved-after-progress", mediaKind: "book", title: "Saved After Progress",
        sortTitle: "saved after progress")
      try db.execute(
        sql: """
          INSERT INTO mediaProgress
            (accountId, itemId, currentTime, isFinished, localSequence, origin, originKey,
             lastActivityAt)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          accountID, resumedLaterID, 45, false, 1, ProgressOrigin.local.rawValue, "test",
          savedAt.addingTimeInterval(-2),
        ])
      try db.execute(
        sql: """
          INSERT INTO savedShelfEntry(accountId, itemId, savedAt, subjectTitle)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          accountID, resumedLaterID, savedAt.addingTimeInterval(-1), "Saved After Progress",
        ])
    }

    try SchemaV1.migrator().migrate(database, upTo: "v36")

    let remainingItemIDs = try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT item.serverItemId
          FROM savedShelfEntry AS saved
          JOIN item ON item.id = saved.itemId
          ORDER BY item.serverItemId
          """)
    }
    #expect(remainingItemIDs == ["saved-after-progress"])
  }

  // MARK: - Finish resolves a save (v56)

  @Test("a zero-position finish removes only the matching saved identity")
  func zeroPositionFinishRemovesMatchingSavedIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let episodeId = try #require(fixture.episodeId)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId, savedAt: 1)
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId,
      podcastEpisodeId: episodeId, savedAt: 2)

    // "Mark as Finished" with no known duration inserts a finished row at position zero.
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.itemId,
        podcastEpisodeId: episodeId, currentTime: 0, isFinished: true,
        localSequence: 1, origin: .local, originKey: "test")
      try progress.insert(db)
    }
    #expect(try Self.savedEpisodeIDs(database, accountId: fixture.accountId) == [nil])

    // The whole-item identity: an unfinished zero row changes nothing, its finish transition does.
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.itemId, currentTime: 0,
        isFinished: false, localSequence: 1, origin: .local, originKey: "test")
      try progress.insert(db)
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM savedShelfEntry WHERE accountId = ?",
          arguments: [fixture.accountId]) == 1)
      progress.isFinished = true
      try progress.update(db)
    }
    #expect(try Self.savedEpisodeIDs(database, accountId: fixture.accountId).isEmpty)
  }

  @Test("a repeated finished write leaves a save made after completion alone")
  func repeatedFinishedWriteKeepsALaterExplicitSave() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let episodeId = try #require(fixture.episodeId)
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.itemId,
        podcastEpisodeId: episodeId, currentTime: 0, isFinished: true,
        localSequence: 1, origin: .local, originKey: "test")
      try progress.insert(db)
    }
    _ = try await Self.insertEntry(
      database, accountId: fixture.accountId, itemId: fixture.itemId,
      podcastEpisodeId: episodeId, savedAt: 5)

    func rewrite(isFinished: Bool) async throws {
      try await database.writeAsync { db in
        try db.execute(
          sql: """
            UPDATE mediaProgress SET currentTime = currentTime, isFinished = ?
            WHERE accountId = ? AND podcastEpisodeId = ?
            """,
          arguments: [isFinished, fixture.accountId, episodeId])
      }
    }

    // Hydrating or re-marking an already-finished row is not a new completion.
    try await rewrite(isFinished: true)
    #expect(try Self.savedEpisodeIDs(database, accountId: fixture.accountId) == [episodeId])
    // Marking it unplayed again neither removes nor re-adds anything.
    try await rewrite(isFinished: false)
    #expect(try Self.savedEpisodeIDs(database, accountId: fixture.accountId) == [episodeId])
    // A fresh not-finished → finished transition is the genuine finish that resolves the save.
    try await rewrite(isFinished: true)
    #expect(try Self.savedEpisodeIDs(database, accountId: fixture.accountId).isEmpty)
  }

  @Test("a native finish removes the exact saved RSS episode without any position change")
  func nativeFinishRemovesTheExactSavedEpisode() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let native = try await Self.seedNativeEpisodes(database, keys: ["episode-a", "episode-b"])
    let episodeA = try #require(native["episode-a"])
    let episodeB = try #require(native["episode-b"])
    _ = try await Self.insertNativeEntry(
      database, accountId: fixture.accountId, rssEpisodeId: episodeA, savedAt: 1)
    _ = try await Self.insertNativeEntry(
      database, accountId: fixture.accountId, rssEpisodeId: episodeB, savedAt: 2)

    let stateStore = RSSEpisodeStateStore(database: database)

    // A device-owned "Mark as Finished" on a fresh row inserts finished at position zero.
    _ = try await stateStore.setFinished(
      episodeId: episodeA, finished: true, now: Date(timeIntervalSince1970: 10))
    #expect(try Self.savedNativeEpisodeIDs(database, accountId: fixture.accountId) == [episodeB])

    // A row that already exists unfinished at zero resolves on the finish transition alone.
    _ = try await stateStore.recordTick(
      episodeId: episodeB, position: 0, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 10))
    #expect(
      try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssSavedShelfEntry")
      } == 1)
    _ = try await stateStore.setFinished(
      episodeId: episodeB, finished: true, now: Date(timeIntervalSince1970: 20))
    #expect(try Self.savedNativeEpisodeIDs(database, accountId: fixture.accountId).isEmpty)
  }

  @Test("a repeated native finished write leaves a save made after completion alone")
  func repeatedNativeFinishedWriteKeepsALaterExplicitSave() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedAccountLibraryItemAndEpisode(database)
    let native = try await Self.seedNativeEpisodes(database, keys: ["episode-a"])
    let episodeA = try #require(native["episode-a"])
    let stateStore = RSSEpisodeStateStore(database: database)
    _ = try await stateStore.setFinished(
      episodeId: episodeA, finished: true, now: Date(timeIntervalSince1970: 10))
    _ = try await Self.insertNativeEntry(
      database, accountId: fixture.accountId, rssEpisodeId: episodeA, savedAt: 20)

    func rewrite(finished: Bool, sequence: Int64) async throws {
      _ = try await stateStore.setFinished(
        episodeId: episodeA, finished: finished,
        now: Date(timeIntervalSince1970: 30 + Double(sequence)))
    }

    try await rewrite(finished: true, sequence: 2)
    #expect(try Self.savedNativeEpisodeIDs(database, accountId: fixture.accountId) == [episodeA])
    try await rewrite(finished: false, sequence: 3)
    #expect(try Self.savedNativeEpisodeIDs(database, accountId: fixture.accountId) == [episodeA])
    try await rewrite(finished: true, sequence: 4)
    #expect(try Self.savedNativeEpisodeIDs(database, accountId: fixture.accountId).isEmpty)
  }

  @Test("v56 reconciles finished saves by activity chronology on both sources")
  func v56ReconcilesFinishedSavesByChronology() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let database = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(database, upTo: "v55")

    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let (accountID, preservedRSSEpisodeID) = try database.write { db -> (Int64, Int64) in
      let accountID = try Self.insertLegacyAccount(
        db, clientUUID: "v56-client", serverBaseURL: "v56-server", serverUserId: "v56-user",
        serverVersion: "2.35.1")
      let libraryID = try Self.insertLegacyLibrary(
        db, accountID: accountID, serverLibraryId: "v56-library", mediaType: "podcast")
      let showID = try Self.insertLegacyItem(
        db, accountID: accountID, libraryID: libraryID, serverItemID: "v56-show",
        mediaKind: "podcast", title: "Show", sortTitle: "show")

      func episode(_ serverEpisodeID: String) throws -> Int64 {
        try db.execute(
          sql: """
            INSERT INTO podcastEpisode (accountId, itemId, serverEpisodeId, title, lastSeenGeneration)
            VALUES (?, ?, ?, ?, 1)
            """,
          arguments: [accountID, showID, serverEpisodeID, serverEpisodeID])
        return db.lastInsertedRowID
      }
      func progress(episodeID: Int64?, itemID: Int64 = showID, isFinished: Bool, stamp: Date?)
        throws
      {
        try db.execute(
          sql: """
            INSERT INTO mediaProgress
              (accountId, itemId, podcastEpisodeId, currentTime, isFinished, localSequence,
               origin, originKey, lastActivityAt)
            VALUES (?, ?, ?, 0, ?, 1, ?, 'test', ?)
            """,
          arguments: [
            accountID, itemID, episodeID, isFinished, ProgressOrigin.local.rawValue, stamp,
          ])
      }
      func save(episodeID: Int64?, itemID: Int64 = showID, at: Date) throws {
        try db.execute(
          sql: """
            INSERT INTO savedShelfEntry (accountId, itemId, podcastEpisodeId, savedAt, subjectTitle)
            VALUES (?, ?, ?, ?, '')
            """,
          arguments: [accountID, itemID, episodeID, at])
      }

      // Finished (at position zero) after it was saved: the released trigger missed this.
      let finishedAfterSave = try episode("finished-after-save")
      try save(episodeID: finishedAfterSave, at: savedAt)
      try progress(episodeID: finishedAfterSave, isFinished: true, stamp: savedAt.addingTimeInterval(1))
      // Saved after it was already finished: an explicit intent the migration must keep.
      let savedAfterFinish = try episode("saved-after-finish")
      try progress(episodeID: savedAfterFinish, isFinished: true, stamp: savedAt.addingTimeInterval(-2))
      try save(episodeID: savedAfterFinish, at: savedAt.addingTimeInterval(-1))
      // Finished with no activity stamp at all: no chronology, so nothing is guessed.
      let finishedUnstamped = try episode("finished-unstamped")
      try save(episodeID: finishedUnstamped, at: savedAt)
      try progress(episodeID: finishedUnstamped, isFinished: false, stamp: nil)
      try db.execute(
        sql: "UPDATE mediaProgress SET isFinished = 1 WHERE podcastEpisodeId = ?",
        arguments: [finishedUnstamped])
      // Not finished at all: v36's positive-position rule already governs this row, not v56.
      let unfinished = try episode("unfinished")
      try save(episodeID: unfinished, at: savedAt)
      try progress(episodeID: unfinished, isFinished: false, stamp: savedAt.addingTimeInterval(1))

      try db.execute(
        sql: "INSERT INTO rssFeed (feedURL, subscribedAt) VALUES (?, ?)",
        arguments: ["https://example.com/v56.xml", savedAt])
      let feedID = db.lastInsertedRowID
      func rssEpisode(_ key: String) throws -> Int64 {
        try db.execute(
          sql: """
            INSERT INTO rssEpisode (feedId, identityKey, enclosureURL, lastSeenGeneration)
            VALUES (?, ?, 'https://example.com/audio.mp3', 1)
            """,
          arguments: [feedID, key])
        return db.lastInsertedRowID
      }
      func rssState(episodeID: Int64, position: Double, finished: Bool, at: Date) throws {
        try db.execute(
          sql: """
            INSERT INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
            VALUES (?, ?, ?, 1, ?)
            """,
          arguments: [episodeID, position, finished, at])
      }
      func rssSave(episodeID: Int64, at: Date) throws {
        try db.execute(
          sql: """
            INSERT INTO savedShelfEntry (accountId, rssEpisodeId, savedAt, subjectTitle)
            VALUES (?, ?, ?, '')
            """,
          arguments: [accountID, episodeID, at])
      }

      let rssFinishedAfterSave = try rssEpisode("rss-finished-after-save")
      try rssSave(episodeID: rssFinishedAfterSave, at: savedAt)
      try rssState(
        episodeID: rssFinishedAfterSave, position: 0, finished: true,
        at: savedAt.addingTimeInterval(1))
      let rssSavedAfterFinish = try rssEpisode("rss-saved-after-finish")
      try rssState(
        episodeID: rssSavedAfterFinish, position: 0, finished: true,
        at: savedAt.addingTimeInterval(-2))
      try rssSave(episodeID: rssSavedAfterFinish, at: savedAt.addingTimeInterval(-1))
      // Positive but unfinished progress written after a re-save is a same-position rewrite the
      // released trigger already ignored; v56 reconciles finishes only.
      let rssResumedLater = try rssEpisode("rss-unfinished")
      try rssState(
        episodeID: rssResumedLater, position: 30, finished: false,
        at: savedAt.addingTimeInterval(1))
      try rssSave(episodeID: rssResumedLater, at: savedAt)

      return (accountID, rssSavedAfterFinish)
    }

    try SchemaV1.migrator().migrate(database, upTo: "v56")

    let remainingEpisodeIDs = try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT episode.serverEpisodeId
          FROM savedShelfEntry AS saved
          JOIN podcastEpisode AS episode ON episode.id = saved.podcastEpisodeId
          WHERE saved.accountId = ?
          ORDER BY episode.serverEpisodeId
          """,
        arguments: [accountID])
    }
    #expect(remainingEpisodeIDs == ["finished-unstamped", "saved-after-finish", "unfinished"])
    let remainingNativeKeys = try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT episode.identityKey
          FROM savedShelfEntry AS saved
          JOIN rssEpisode AS episode ON episode.id = saved.rssEpisodeId
          WHERE saved.accountId = ?
          ORDER BY episode.identityKey
          """,
        arguments: [accountID])
    }
    #expect(remainingNativeKeys == ["rss-saved-after-finish", "rss-unfinished"])

    // The recreated triggers own the rule from here: an unchanged finished rewrite keeps the
    // preserved save, and a fresh finish transition resolves it.
    try database.write { db in
      try db.execute(
        sql: "UPDATE rssEpisodeState SET finished = 1, updatedAt = ? WHERE episodeId = ?",
        arguments: [savedAt.addingTimeInterval(5), preservedRSSEpisodeID])
    }
    #expect(
      try database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM savedShelfEntry WHERE rssEpisodeId = ?",
          arguments: [preservedRSSEpisodeID])
      } == 1)
    try database.write { db in
      try db.execute(
        sql: "UPDATE rssEpisodeState SET finished = 0 WHERE episodeId = ?",
        arguments: [preservedRSSEpisodeID])
      try db.execute(
        sql: "UPDATE rssEpisodeState SET finished = 1 WHERE episodeId = ?",
        arguments: [preservedRSSEpisodeID])
    }
    #expect(
      try database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM savedShelfEntry WHERE rssEpisodeId = ?",
          arguments: [preservedRSSEpisodeID])
      } == 0)
    let triggers = try database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'savedShelf%' ORDER BY name")
    }
    #expect(
      triggers == [
        "savedShelfProgress_ai", "savedShelfProgress_au",
        "savedShelfRSSProgress_ai", "savedShelfRSSProgress_au",
      ])
  }

  private static func savedEpisodeIDs(_ database: AppDatabase, accountId: Int64) throws -> [Int64?] {
    try database.read { db in
      try Int64?.fetchAll(
        db,
        sql: "SELECT podcastEpisodeId FROM savedShelfEntry WHERE accountId = ? ORDER BY id",
        arguments: [accountId])
    }
  }

  private static func savedNativeEpisodeIDs(_ database: AppDatabase, accountId: Int64) throws -> [Int64] {
    try database.read { db in
      try Int64.fetchAll(db, sql: "SELECT rssEpisodeId FROM rssSavedShelfEntry ORDER BY rssEpisodeId")
    }
  }

  /// One device-owned feed carrying `keys`, returned as identity key → row id.
  private static func seedNativeEpisodes(
    _ database: AppDatabase, keys: [String]
  ) async throws -> [String: Int64] {
    try await database.writeAsync { db in
      var feed = RSSFeedRecord(
        feedURL: "https://example.com/native-\(UUID().uuidString).xml", title: "Feed",
        subscribedAt: Date(timeIntervalSince1970: 1))
      try feed.insert(db)
      var ids: [String: Int64] = [:]
      for key in keys {
        var episode = RSSEpisodeRecord(
          feedId: feed.id!, identityKey: key, title: key,
          enclosureURL: "https://example.com/\(key).mp3", lastSeenGeneration: 1)
        try episode.insert(db)
        ids[key] = episode.id!
      }
      return ids
    }
  }

  private static func insertNativeEntry(
    _ database: AppDatabase, accountId: Int64, rssEpisodeId: Int64, savedAt: TimeInterval
  ) async throws -> RSSSavedShelfEntryRecord {
    try await database.writeAsync { db in
      try RSSSavedShelfEntryRecord(
        rssEpisodeId: rssEpisodeId,
        savedAt: Date(timeIntervalSince1970: savedAt)
      ).inserted(db)
    }
  }

  private struct Fixture: Sendable {
    let accountId: Int64
    let itemId: Int64
    let episodeId: Int64?
  }

  private static func seedAccountLibraryItemAndEpisode(
    _ database: AppDatabase,
    suffix: String = "one",
    serverItemID: String = "item-1"
  ) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-\(suffix)", mediaType: "podcast",
        name: "Library")
      try library.insert(db)

      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: serverItemID,
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)

      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: item.id!, serverEpisodeId: "episode-\(suffix)",
        title: "Episode", lastSeenGeneration: 1)
      try episode.insert(db)

      return Fixture(accountId: account.id!, itemId: item.id!, episodeId: episode.id!)
    }
  }

  /// Inserts an `account` row using only the columns present before `v63`.
  private static func insertLegacyAccount(
    _ db: Database,
    clientUUID: String,
    serverBaseURL: String,
    serverUserId: String,
    serverVersion: String
  ) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [clientUUID, serverBaseURL, serverUserId, serverVersion])
    return db.lastInsertedRowID
  }

  private static func insertEntry(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    savedAt: TimeInterval
  ) async throws -> SavedShelfEntryRecord {
    try await database.writeAsync { db in
      try SavedShelfEntryRecord(
        accountId: accountId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        savedAt: Date(timeIntervalSince1970: savedAt)
      ).inserted(db)
    }
  }

  /// Inserts a `library` row using only the columns present before `v40`. These tests migrate to a
  /// pinned version, so a record type that has since gained a column cannot be used to seed them.
  private static func insertLegacyLibrary(
    _ db: Database, accountID: Int64, serverLibraryId: String, mediaType: String
  ) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO library
          (accountId, serverLibraryId, mediaType, name, lastSeenGeneration, softDeleted, isIncluded)
        VALUES (?, ?, ?, 'Library', 0, 0, 1)
        """,
      arguments: [accountID, serverLibraryId, mediaType])
    return db.lastInsertedRowID
  }

  /// Like `insertLegacyLibrary`, but constrained to the item columns the oldest fixtures in
  /// this file can rely on, so later column additions do not leak backwards into them.
  private static func insertLegacyItem(
    _ db: Database,
    accountID: Int64,
    libraryID: Int64,
    serverItemID: String,
    mediaKind: String,
    title: String,
    sortTitle: String
  ) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO item
          (accountId, libraryId, serverItemId, mediaKind, title, sortTitle, lastSeenGeneration,
           softDeleted)
        VALUES (?, ?, ?, ?, ?, ?, 1, 0)
        """,
      arguments: [accountID, libraryID, serverItemID, mediaKind, title, sortTitle])
    return db.lastInsertedRowID
  }

}
