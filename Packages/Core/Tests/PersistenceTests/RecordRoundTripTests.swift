import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Each v1 record type inserts, fetches and updates losslessly, including soft-delete flags and
/// generation columns.
///
/// Values crossing a `database.write`/`database.read` closure boundary are `let`: Swift 6 strict
/// concurrency rejects a captured `var` in those `@Sendable` closures. `inserted(_:)`/`saved(_:)`
/// (GRDB's non-mutating counterparts to `insert(_:)`/`save(_:)`) avoid reassigning one.
@Suite struct RecordRoundTripTests {

  @Test func accountRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await database.writeAsync { db in
      try AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0"
      ).inserted(db)
    }
    let fetched = try database.read { db in try AccountRecord.fetchOne(db, key: account.id) }
    #expect(fetched == account)

    var modified = fetched!
    modified.serverVersion = "2.11.0"
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.serverVersion == "2.11.0")
    #expect(updated.clientUUID == account.clientUUID)
  }

  @Test func libraryRoundTripsIncludingGeneration() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let library = try await database.writeAsync { db in
      try LibraryRecord(
        accountId: accountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library",
        lastSeenGeneration: 3
      ).inserted(db)
    }
    let fetched = try database.read { db in try LibraryRecord.fetchOne(db, key: library.id) }
    #expect(fetched == library)

    var modified = fetched!
    modified.lastSeenGeneration = 4
    modified.name = "Renamed Library"
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.lastSeenGeneration == 4)
    #expect(updated.name == "Renamed Library")
  }

  @Test func librarySelectionRecordsFailOpenAndPersistClosedValues() throws {
    let database = try AppDatabase.inMemory()
    let account = try database.write { db in
      try AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0", librarySelectionMode: .selected
      ).inserted(db)
    }
    let library = try database.write { db in
      try LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library",
        isIncluded: false
      ).inserted(db)
    }

    #expect(account.librarySelectionMode == .selected)
    #expect(library.isIncluded == false)
    #expect(
      LibrarySelectionMode.allCases.map(\.rawValue)
        == ["all", "pending", "selected"])
    #expect(
      try database.read { db in
        try String.fetchOne(
          db, sql: "SELECT librarySelectionMode FROM account WHERE id = ?", arguments: [account.id!])
      } == "selected")

    try database.write { db in
      try db.execute(
        sql: "UPDATE account SET librarySelectionMode = 'unrecognized-future-mode' WHERE id = ?",
        arguments: [account.id!])
    }
    let decoded = try database.read { db in try AccountRecord.fetchOne(db, key: account.id) }
    #expect(decoded?.librarySelectionMode == .all)

    let toSave = try #require(decoded)
    try database.write { db in try toSave.update(db) }
    #expect(
      try database.read { db in
        try String.fetchOne(
          db, sql: "SELECT librarySelectionMode FROM account WHERE id = ?", arguments: [account.id!])
      } == "all")
  }

  @Test func itemRoundTripsIncludingSoftDelete() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let item = try await database.writeAsync { db in
      try ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "A Title", sortTitle: "title, a", author: "Author Name", durationSeconds: 3600,
        softDeleted: false
      ).inserted(db)
    }
    let fetched = try database.read { db in try ItemRecord.fetchOne(db, key: item.id) }
    #expect(fetched == item)

    var modified = fetched!
    modified.softDeleted = true
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.softDeleted == true)
    #expect(updated.author == "Author Name")
  }

  @Test func itemSeenRoundTripsAndCascadesWithItsItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let item = try await database.writeAsync { db in
      try ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "A Title", sortTitle: "title, a"
      ).inserted(db)
    }
    let itemRowId = try #require(item.id)
    try await database.writeAsync { db in
      try ItemSeenRecord(itemId: itemRowId, generation: 2).save(db)
    }
    #expect(
      try database.read { db in try ItemSeenRecord.fetchOne(db, key: itemRowId) }
        == ItemSeenRecord(itemId: itemRowId, generation: 2))

    // Re-stamping is an upsert on the item's own key, not a second row.
    try await database.writeAsync { db in
      try ItemSeenRecord(itemId: itemRowId, generation: 3).save(db)
    }
    #expect(try database.read { db in try ItemSeenRecord.fetchCount(db) } == 1)
    #expect(
      try database.read { db in try ItemSeenRecord.fetchOne(db, key: itemRowId)?.generation } == 3)

    // A hard delete must not leave a seen row behind to be joined against a later item reusing
    // the row id.
    try await database.writeAsync { db in _ = try item.delete(db) }
    #expect(try database.read { db in try ItemSeenRecord.fetchCount(db) } == 0)
  }

  @Test func podcastEpisodeRoundTripsIncludingSoftDeleteAndGeneration() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")
    let episode = try await database.writeAsync { db in
      try PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "ep-1", title: "Episode 1",
        episodeNumber: "1", lastSeenGeneration: 1, softDeleted: false
      ).inserted(db)
    }
    let fetched = try database.read { db in try PodcastEpisodeRecord.fetchOne(db, key: episode.id) }
    #expect(fetched == episode)

    var modified = fetched!
    modified.softDeleted = true
    modified.lastSeenGeneration = 2
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.softDeleted == true)
    #expect(updated.lastSeenGeneration == 2)
  }

  @Test func savedShelfEntryRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")
    let episode = try await database.writeAsync { db in
      try PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "episode-1", title: "Episode 1",
        lastSeenGeneration: 1
      ).inserted(db)
    }
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = try await database.writeAsync { db in
      try SavedShelfEntryRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episode.id, savedAt: savedAt
      ).inserted(db)
    }
    let fetched = try database.read { db in
      try SavedShelfEntryRecord.fetchOne(db, key: entry.id)
    }
    #expect(fetched == entry)

    var modified = fetched!
    modified.savedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.savedAt == Date(timeIntervalSince1970: 1_700_000_100))
    #expect(updated.podcastEpisodeId == episode.id)
  }

  @Test func mediaProgressRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let progress = try await database.writeAsync { db in
      try MediaProgressRecord(
        accountId: accountId, itemId: itemId, currentTime: 12.5, isFinished: false,
        serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), localSequence: 1,
        origin: .local, originKey: "client-uuid-1"
      ).inserted(db)
    }
    let fetched = try database.read { db in try MediaProgressRecord.fetchOne(db, key: progress.id) }
    #expect(fetched == progress)

    var modified = fetched!
    modified.currentTime = 99.0
    modified.isFinished = true
    modified.localSequence = 2
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.currentTime == 99.0)
    #expect(updated.isFinished == true)
    #expect(updated.localSequence == 2)
  }

  @Test func outboxOperationRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let operation = try await database.writeAsync { db in
      try OutboxOperationRecord(
        accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "item:1",
        podcastEpisodeId: nil,
        operationKind: "progressUpdate", coalescingKey: "item:1:progress", payloadVersion: 1,
        localSequence: 1, attempts: 0, nextAttemptAt: nil, state: .pending
      ).inserted(db)
    }
    let fetched = try database.read { db in
      try OutboxOperationRecord.fetchOne(db, key: operation.id)
    }
    #expect(fetched == operation)

    var modified = fetched!
    modified.state = .retryWaiting
    modified.attempts = 1
    modified.nextAttemptAt = Date(timeIntervalSince1970: 1_700_000_500)
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.state == .retryWaiting)
    #expect(updated.attempts == 1)
    #expect(updated.nextAttemptAt == Date(timeIntervalSince1970: 1_700_000_500))
  }

  @Test func playbackSessionRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let session = try await database.writeAsync { db in
      try PlaybackSessionRecord(
        accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100), listenedDeltaSeconds: 30,
        closePending: false, isOffline: true
      ).inserted(db)
    }
    let fetched = try database.read { db in
      try PlaybackSessionRecord.fetchOne(db, key: session.id)
    }
    #expect(fetched == session)

    var modified = fetched!
    modified.closePending = true
    modified.listenedDeltaSeconds = 45
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.closePending == true)
    #expect(updated.listenedDeltaSeconds == 45)
  }

  @Test func downloadRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let download = try await database.writeAsync { db in
      try DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "downloads/item-1.m4b", expectedBytes: 1_000_000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 3600, receivedBytes: 0, state: .pending
      ).inserted(db)
    }
    let fetched = try database.read { db in try DownloadRecord.fetchOne(db, key: download.id) }
    #expect(fetched == download)

    var modified = fetched!
    modified.receivedBytes = 500_000
    modified.state = .downloading
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.receivedBytes == 500_000)
    #expect(updated.state == .downloading)
  }

  /// Every download row that predates the automatic pass, and every manual request, reads back
  /// `.manual`, the type's own default.
  @Test func downloadOriginDefaultsToManual() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let download = try await database.writeAsync { db in
      try DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-manual", orderIndex: 0,
        destinationRelativePath: "downloads/manual.m4b", expectedBytes: 1_000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60
      ).inserted(db)
    }
    #expect(download.origin == .manual)

    let fetched = try database.read { db in try DownloadRecord.fetchOne(db, key: download.id) }
    #expect(fetched?.origin == .manual)
  }

  /// The automatic pass marks the row `.automatic` at creation, and that must survive a round
  /// trip like every other closed enum column here.
  @Test func downloadOriginRoundTripsAutomatic() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")
    let download = try await database.writeAsync { db in
      try DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-automatic", orderIndex: 0,
        destinationRelativePath: "downloads/automatic.mp3", expectedBytes: 2_000,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 120, origin: .automatic
      ).inserted(db)
    }
    let fetched = try database.read { db in try DownloadRecord.fetchOne(db, key: download.id) }
    #expect(fetched?.origin == .automatic)

    // The one permitted direction: a manual request promotes an automatic row.
    var modified = fetched!
    modified.origin = .manual
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.origin == .manual)
  }

  /// Stamped only when the automatic pass creates a download row, and must survive a round trip
  /// so the candidate query can rely on it.
  @Test func autoDownloadDecidedAtRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")
    let episode = try await database.writeAsync { db in
      try PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "ep-1", title: "Episode 1",
        lastSeenGeneration: 1
      ).inserted(db)
    }
    #expect(episode.autoDownloadDecidedAt == nil)

    let decidedAt = Date(timeIntervalSince1970: 1_700_000_000)
    var modified = episode
    modified.autoDownloadDecidedAt = decidedAt
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.autoDownloadDecidedAt == decidedAt)

    let fetched = try database.read { db in
      try PodcastEpisodeRecord.fetchOne(db, key: episode.id)
    }
    #expect(fetched?.autoDownloadDecidedAt == decidedAt)
  }

  /// Both settings tables round-trip like every other record, including the tri-state override
  /// enum and the nullable per-show overrides.
  @Test func podcastSettingsRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
    let settings = try await database.writeAsync { db in
      try PodcastSettingsRecord(
        accountId: accountId, autoDownloadEnabled: true, keepLatestCount: 5,
        deleteAfterPlayed: true, allowCellularAutoDownload: true, enabledAt: enabledAt
      ).inserted(db)
    }
    let fetched = try database.read { db in
      try PodcastSettingsRecord.fetchOne(db, key: accountId)
    }
    #expect(fetched == settings)

    var modified = fetched!
    modified.keepLatestCount = 0
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.keepLatestCount == 0)
  }

  @Test func podcastShowSettingsRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")
    let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
    let settings = try await database.writeAsync { db in
      try PodcastShowSettingsRecord(
        itemId: itemId, accountId: accountId, autoDownloadOverride: .enabled,
        keepLatestOverride: 10, deleteAfterPlayedOverride: false, enabledAt: enabledAt
      ).inserted(db)
    }
    let fetched = try database.read { db in
      try PodcastShowSettingsRecord.fetchOne(db, key: itemId)
    }
    #expect(fetched == settings)

    var modified = fetched!
    modified.autoDownloadOverride = .disabled
    modified.keepLatestOverride = nil
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.autoDownloadOverride == .disabled)
    #expect(updated.keepLatestOverride == nil)
  }

  /// An absent row means "inherit"/defaults, with no backfill or guarded heal, so every existing
  /// install is correct the moment it migrates. The query simply finds nothing, and the record
  /// type's own defaults are: auto-download off, keep latest 3, delete-after-played off, no
  /// cellular, and every show override `inherit`.
  @Test func absentSettingsRowsMeanInheritDefaults() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")

    let globalRow = try database.read { db in try PodcastSettingsRecord.fetchOne(db, key: accountId) }
    #expect(globalRow == nil)
    let showRow = try database.read { db in try PodcastShowSettingsRecord.fetchOne(db, key: itemId) }
    #expect(showRow == nil)

    let defaultGlobal = PodcastSettingsRecord(accountId: accountId)
    #expect(defaultGlobal.autoDownloadEnabled == false)
    #expect(defaultGlobal.keepLatestCount == 3)
    #expect(defaultGlobal.deleteAfterPlayed == false)
    #expect(defaultGlobal.allowCellularAutoDownload == false)
    #expect(defaultGlobal.enabledAt == nil)

    let defaultShow = PodcastShowSettingsRecord(itemId: itemId, accountId: accountId)
    #expect(defaultShow.autoDownloadOverride == .inherit)
    #expect(defaultShow.keepLatestOverride == nil)
    #expect(defaultShow.deleteAfterPlayedOverride == nil)
    #expect(defaultShow.enabledAt == nil)
  }

  @Test func syncRunRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let run = try await database.writeAsync { db in
      try SyncRunRecord(
        accountId: accountId, libraryId: libraryId, reason: "foreground", generation: 1,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ).inserted(db)
    }
    let fetched = try database.read { db in try SyncRunRecord.fetchOne(db, key: run.id) }
    #expect(fetched == run)

    var modified = fetched!
    modified.state = .completed
    modified.completedAt = Date(timeIntervalSince1970: 1_700_000_300)
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.state == .completed)
    #expect(updated.completedAt == Date(timeIntervalSince1970: 1_700_000_300))
  }

  @Test func syncPageRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let runId = try await database.writeAsync { db in
      try SyncRunRecord(
        accountId: accountId, libraryId: libraryId, reason: "foreground", generation: 1,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ).inserted(db).id!
    }
    let page = try await database.writeAsync { db in
      try SyncPageRecord(
        accountId: accountId, syncRunId: runId, pageNumber: 1, itemCount: 50,
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_010)
      ).inserted(db)
    }
    let fetched = try database.read { db in try SyncPageRecord.fetchOne(db, key: page.id) }
    #expect(fetched == page)

    var modified = fetched!
    modified.itemCount = 75
    modified.resultCategory = "ok"
    let toSave = modified
    let updated = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(updated.itemCount == 75)
    #expect(updated.resultCategory == "ok")
  }

  // MARK: - Helpers

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }

  private func insertItem(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, kind: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: kind,
        title: "Title", sortTitle: "title")
      try item.insert(db)
      return item.id!
    }
  }
}
