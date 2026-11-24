import Foundation
import GRDB
import Testing

@testable import Persistence

/// Schema-level account removal (ordering across sessions, downloads, diagnostics files and
/// Keychain is covered elsewhere): no account-owned rows remain, the sweep finding those tables is
/// schema-driven, and a crash mid-removal leaves a resumable, non-partial store.
@Suite struct AccountRemovalTests {

  /// The set of tables SchemaMigrationTests independently confirms carry a cascading
  /// `accountId` FK. Only the expected value an assertion compares against; the production sweep
  /// in `AccountRemover` must derive this set from the schema itself, never from a list like this.
  private static let expectedAccountOwnedTables: Set<String> = [
    "library", "item", "podcastEpisode", "mediaProgress", "outboxOperation", "playbackSession",
    "download", "syncRun", "syncPage", "diagnosticsEvent",
    // The PDFs that accompany an audiobook, with their device-local page memory.
    "itemSupplement",
    // Per-account observed server clock offset.
    "observedServerTime",
    // Held server progress the zero-position guard rejected, pending resolution.
    "progressConflict",
    // Cached per-item listening-session history.
    "listeningHistoryEntry",
    // Cached account listening-stats snapshot.
    "listeningStatsSnapshot",
    // Device-local pinned lists with their claims and declines.
    "pinnedList", "pinnedListClaim", "pinnedListDecline",
    // Single row per account: "what was last played".
    "playbackBookmark",
    // Durable local Up Next rows.
    "listeningQueueEntry",
    // Per-account recent searches.
    "recentSearch",
    // Global and per-show device auto-download settings.
    "podcastSettings", "podcastShowSettings",
    // Durable, account-scoped custom Your Shows order.
    "podcastShowOrder", "podcastShowOrderEntry",
    // The queue store's per-account clear/restore revision counter.
    "listeningQueueRevision",
    // One opaque reader-preferences payload per account.
    "readerPreferences",
    // Per-title playback-rate overrides.
    "itemPlaybackSettings",
    // Local-only Saved for Later shelf entries.
    "savedShelfEntry",
    // Server-owned Continue Series dismissals.
    "hiddenContinueSeries",
    // Detached audit markers for quarantined server item identities.
    "itemQuarantine",
    // Account-owned native RSS episode server-save attempts.
    "nativeEpisodeServerSaveAttempt",
    // Per-episode chapters.
    "podcastEpisodeChapter",
    // Ordered server addresses.
    "accountEndpoint",
    // Audiobookshelf audio bookmarks.
    "audioBookmark",
    // Download claims of server episodes; native claims carry no account.
    "smartListDownloadClaim",
    // Hand-removal declines of server episodes; native declines carry no account.
    "smartListDownloadDecline",
    // The Audiobookshelf books and episodes this account sent to the Watch (ADR 0021).
    "absWatchCopy",
  ]

  private struct InjectedCrash: Error {}

  @Test func removalSweepDiscoversExactlyTheSchemasAccountOwnedTables() throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)

    let discovered = try remover.accountOwnedTables()

    #expect(discovered == Self.expectedAccountOwnedTables)
  }

  /// The sweep discovers `podcastShowOrder`/`podcastShowOrderEntry` schema-driven, via their
  /// cascading `accountId` FK rather than a hand-maintained list, and removal clears both.
  @Test func accountRemovalSweepIncludesPodcastShowOrderTables() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")

    let discovered = try remover.accountOwnedTables()
    #expect(discovered.contains("podcastShowOrder"))
    #expect(discovered.contains("podcastShowOrderEntry"))

    try remover.removeAccount(accountId: accountId)

    try database.read { db in
      let remainingOrder = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowOrder") ?? -1
      let remainingEntries =
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastShowOrderEntry") ?? -1
      #expect(remainingOrder == 0)
      #expect(remainingEntries == 0)
    }
  }

  /// A show's Trim Silences override is a column of its `podcastShowSettings` row, so it goes with
  /// the account. Pause analysis is device-owned, like `adSkipEpisode`: the sweep leaves it, and
  /// the pause-trim coordinator deletes a row once its download is gone, which is how an
  /// account's removal reaches it.
  @Test func accountRemovalTakesTheShowOverrideAndLeavesPauseAnalysisToItsCoordinator() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE podcastShowSettings SET trimSilencesOverride = 'maximum'")
      var analysis = PauseTrimEpisodeRecord(
        source: .abs, accountId: accountId, itemID: "item-1", episodeID: "episode-1",
        fileByteSize: 1, fileModificationTime: 1, detectorRevision: 1, state: .analysed,
        runs: Data(), analysedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try analysis.insert(db)
    }

    #expect(try remover.accountOwnedTables().contains("pauseTrimEpisode") == false)
    try remover.removeAccount(accountId: accountId)

    let (overrides, analyses) = try database.read { db in
      (
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM podcastShowSettings WHERE trimSilencesOverride != 'inherit'"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pauseTrimEpisode")
      )
    }
    #expect(overrides == 0)
    #expect(analyses == 1)
  }

  /// Transcripts are device-owned, like pause analysis: the sweep leaves them, and the
  /// transcript coordinator deletes a row (and its file) once its download is gone, which is how
  /// an account's removal reaches it.
  @Test func accountRemovalLeavesTranscriptsToTheirCoordinator() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")
    try await database.writeAsync { db in
      var transcript = EpisodeTranscriptRecord(
        identity: AdSkipEpisodeIdentity(
          source: .abs, accountId: accountId, itemID: "item-1", episodeID: "episode-1"),
        fingerprint: EpisodeTranscriptFingerprint(fileByteSize: 1, fileModificationTime: 1),
        transcriberRevision: "r", state: .failed, transcriptFileName: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try transcript.insert(db)
    }

    #expect(try remover.accountOwnedTables().contains("episodeTranscript") == false)
    try remover.removeAccount(accountId: accountId)

    let transcripts = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM episodeTranscript")
    }
    #expect(transcripts == 1)
  }

  /// The direct account FK is what makes this table discoverable by the schema-driven removal
  /// sweep; the composite item FK supplies the separate account-integrity constraint.
  @Test func accountRemovalSweepIncludesItemPlaybackSettings() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")

    #expect(try remover.accountOwnedTables().contains("itemPlaybackSettings"))

    try remover.removeAccount(accountId: accountId)

    let remaining = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemPlaybackSettings") ?? -1
    }
    #expect(remaining == 0)
  }

  @Test func removingAnAccountLeavesNoAccountOwnedRowsAcrossEveryTable() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")

    try remover.removeAccount(accountId: accountId)

    try database.read { db in
      let accountCount = try AccountRecord.fetchCount(db)
      #expect(accountCount == 0)

      for table in Self.expectedAccountOwnedTables {
        let rowCount =
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? -1
        #expect(rowCount == 0, "\(table) should have zero rows after account removal")
      }
    }
  }

  @Test func removingTheSingleAccountAlsoClearsUnscopedDerivedCoverPalettes() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")
    try await CoverPaletteRecordStore(database: database).upsert(
      CoverPaletteRecord(
        itemId: "old-account-item", artworkKey: "old-account-artwork", accentHue: 0.1,
        accentSaturation: 0.2, accentBrightness: 0.3, extractedAt: Date()))

    try remover.removeAccount(accountId: accountId)

    #expect(
      try await CoverPaletteRecordStore(database: database).fetch(itemId: "old-account-item")
        == nil)
  }

  @Test func removingOneAccountNeverTouchesAnotherAccountsRows() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let removedAccountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")
    let survivingAccountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-2")

    try remover.removeAccount(accountId: removedAccountId)

    try database.read { db in
      let survivingAccount = try AccountRecord.fetchOne(
        db, sql: "SELECT * FROM account WHERE id = ?", arguments: [survivingAccountId])
      #expect(survivingAccount != nil)

      for table in Self.expectedAccountOwnedTables {
        let survivingRowCount =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier) WHERE accountId = ?",
            arguments: [survivingAccountId]) ?? -1
        #expect(survivingRowCount > 0, "\(table) should keep the surviving account's rows")

        let removedRowCount =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier) WHERE accountId = ?",
            arguments: [removedAccountId]) ?? -1
        #expect(removedRowCount == 0, "\(table) should have no rows left for the removed account")
      }
    }
  }

  /// A crash mid-removal is simulated as `TransactionRollbackTests` does: the removal is a single
  /// GRDB transaction, and a thrown error before commit leaves SQLite as if the process had died,
  /// so nothing partially applied survives.
  @Test func aSimulatedCrashMidRemovalLeavesTheFullAccountIntact() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")

    await #expect(throws: InjectedCrash.self) {
      try await database.writeAsync { db in
        // Same first step as `AccountRemover.removeAccount` (the cascade delete), aborted before
        // commit to simulate a crash mid-removal.
        try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        throw InjectedCrash()
      }
    }

    try database.read { db in
      let accountCount = try AccountRecord.fetchCount(db)
      #expect(accountCount == 1, "the aborted transaction must leave the full account intact")

      for table in Self.expectedAccountOwnedTables {
        let rowCount =
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier) WHERE accountId = ?",
            arguments: [accountId]) ?? -1
        #expect(rowCount > 0, "\(table) should still carry its row after the aborted transaction")
      }
    }
  }

  @Test func rerunningRemovalAfterASimulatedCrashCompletes() async throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")

    await #expect(throws: InjectedCrash.self) {
      try await database.writeAsync { db in
        try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        throw InjectedCrash()
      }
    }

    // A rerun after the simulated crash completes the removal.
    try remover.removeAccount(accountId: accountId)

    try database.read { db in
      let accountCount = try AccountRecord.fetchCount(db)
      #expect(accountCount == 0)

      for table in Self.expectedAccountOwnedTables {
        let rowCount =
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? -1
        #expect(rowCount == 0)
      }
    }
  }

  @Test func journalFetchAsyncMatchesSyncTwin() async throws {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let record = journalRecord()
    _ = try await syncDatabase.writeAsync { db in
      var row = record
      try row.insert(db)
      return row
    }
    _ = try await asyncDatabase.writeAsync { db in
      var row = record
      try row.insert(db)
      return row
    }
    let sync = try AccountRemovalJournalStore(database: syncDatabase).fetch()
    let async = try await AccountRemovalJournalStore(database: asyncDatabase).fetchAsync()
    #expect(async == sync)
  }

  @Test func journalCreateAsyncMatchesSyncTwin() async throws {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let record = journalRecord()

    let sync = try AccountRemovalJournalStore(database: syncDatabase).create(record)
    let async = try await AccountRemovalJournalStore(database: asyncDatabase).createAsync(record)

    #expect(async == sync)
    #expect(async.id != nil)
    #expect(try await AccountRemovalJournalStore(database: asyncDatabase).fetchAsync() == async)
  }

  @Test func journalClearAsyncMatchesSyncTwin() async throws {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let record = journalRecord()
    _ = try AccountRemovalJournalStore(database: syncDatabase).create(record)
    _ = try await AccountRemovalJournalStore(database: asyncDatabase).createAsync(record)

    try AccountRemovalJournalStore(database: syncDatabase).clear()
    try await AccountRemovalJournalStore(database: asyncDatabase).clearAsync()

    #expect(try AccountRemovalJournalStore(database: syncDatabase).fetch() == nil)
    #expect(try await AccountRemovalJournalStore(database: asyncDatabase).fetchAsync() == nil)
  }

  /// A native claim has no account, so removal drops the server's claims and keeps it.
  @Test func removingAnAccountKeepsNativeSmartListClaims() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await populateEveryAccountOwnedTable(database, serverUserId: "user-1")
    let store = SmartListDownloadClaimStore(database: database)
    let listID = try await SmartListStore(database: database).create(name: "Native").id
    try await store.add(listID: listID, itemID: "rss:1", episodeID: "guid-1", accountID: nil)
    try await store.add(listID: listID, itemID: "item-1", episodeID: "ep-2", accountID: accountId)

    try AccountRemover(database: database).removeAccount(accountId: accountId)

    let remaining = try await store.allClaims()
    #expect(remaining.map(\.itemID) == ["rss:1"])
    #expect(remaining.first?.accountId == nil)
  }

  // MARK: - Helpers

  private func journalRecord() -> AccountRemovalJournalRecord {
    AccountRemovalJournalRecord(
      serverBaseURL: "https://example.com",
      serverUserId: "user-1",
      accountRowId: 42,
      downloadsRootRelativePath: "downloads/user-1",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  /// Inserts one row into `account` plus one row into every account-owned table, all
  /// referencing that account, and returns the account's id.
  @discardableResult
  private func populateEveryAccountOwnedTable(_ database: AppDatabase, serverUserId: String)
    async throws -> Int64
  {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: serverUserId, serverVersion: "2.10.0")
      try account.insert(db)
      let accountId = account.id!

      var endpoint = AccountEndpointRecord(
        accountId: accountId, normalizedURL: account.serverBaseURL, isPreferred: true, sortOrder: 0,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try endpoint.insert(db)

      try db.execute(
        sql: "INSERT INTO hiddenContinueSeries (accountId, serverSeriesId) VALUES (?, ?)",
        arguments: [accountId, "series-1"])

      try AudioBookmarkRecord(
        accountId: accountId, serverItemId: "item-1", time: 12.5, title: "Bookmark",
        createdAt: nil
      ).insert(db)

      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      let libraryId = library.id!

      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "podcast",
        title: "Title", sortTitle: "title", ebookFormat: "epub", ebookFileIno: "ebook-ino-1",
        ebookFileExt: ".EPUB")
      try item.insert(db)
      let itemId = item.id!

      try db.execute(
        sql: """
          INSERT INTO itemQuarantine (
            itemId, accountId, serverItemId, reason, quarantinedAt, terminalizedOperationCount
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          itemId, accountId, "rss:7", "reservedPodcastSourceIdentity",
          Date(timeIntervalSince1970: 1_700_000_000), 0,
        ])

      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "ep-1", title: "Episode",
        lastSeenGeneration: 1)
      try episode.insert(db)
      let episodeId = episode.id!

      var episodeChapter = PodcastEpisodeChapterRecord(
        accountId: accountId, podcastEpisodeId: episodeId, position: 0, serverChapterId: 0,
        start: 0, end: 60, title: "Chapter")
      try episodeChapter.insert(db)

      // Local RSS identities are values rather than foreign keys. Included so the schema-driven
      // removal proof exercises this account-owned table too.
      var serverSaveAttempt = NativeEpisodeServerSaveAttemptRecord(
        accountId: accountId, accountClientUUID: account.clientUUID,
        accountServerIdentityFingerprint:
          account.serverIdentityFingerprint,
        feedId: 1, episodeId: episodeId,
        episodeIdentityKey: "server-episode:ep-1", createdAt: Date())
      try serverSaveAttempt.insert(db)

      var savedShelfEntry = SavedShelfEntryRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId,
        savedAt: Date(timeIntervalSince1970: 1_700_000_005))
      try savedShelfEntry.insert(db)

      var queueEntry = ListeningQueueEntryRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, position: 0)
      try queueEntry.insert(db)

      var progress = MediaProgressRecord(
        accountId: accountId, itemId: itemId, currentTime: 12, isFinished: false,
        localSequence: 1, origin: .local, originKey: "client-uuid",
        readingPositionJSON: "{\"href\":\"book.xhtml\"}", ebookProgress: 0.25,
        ebookLocation: "epubcfi(/6/4!/4/2/1:0)")
      try progress.insert(db)

      var outboxOperation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "item:\(itemId)",
        podcastEpisodeId: episodeId,
        operationKind: "progressUpdate", coalescingKey: "item:\(itemId):progress",
        payloadVersion: 1, localSequence: 1, state: .pending)
      try outboxOperation.insert(db)

      var session = PlaybackSessionRecord(
        accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try session.insert(db)

      var download = DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "item-1/file.mp3", expectedBytes: 1_000,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 60)
      try download.insert(db)

      var supplement = ItemSupplementRecord(
        accountId: accountId, itemId: itemId, position: 0, serverFileIno: "pdf-1",
        filename: "Maps.pdf", sizeBytes: 1_000, lastViewedPage: 3)
      try supplement.insert(db)

      var run = SyncRunRecord(
        accountId: accountId, libraryId: libraryId, reason: "foreground", generation: 1,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try run.insert(db)
      let runId = run.id!

      var page = SyncPageRecord(
        accountId: accountId, syncRunId: runId, pageNumber: 1, itemCount: 1,
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_010))
      try page.insert(db)

      var diagnosticsEvent = DiagnosticsEventRecord(
        accountId: accountId, category: .syncRun, statusClass: .success,
        durationMilliseconds: 5, occurredAt: Date(timeIntervalSince1970: 1_700_000_020))
      try diagnosticsEvent.insert(db)

      var observedServerTime = ObservedServerTimeRecord(
        accountId: accountId, offsetSeconds: 1, observedAt: Date(timeIntervalSince1970: 1_700_000_030))
      try observedServerTime.insert(db)

      var progressConflict = ProgressConflictRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, serverCurrentTime: 34,
        serverIsFinished: false, detectedAt: Date(timeIntervalSince1970: 1_700_000_040))
      try progressConflict.insert(db)

      var listeningHistoryEntry = ListeningHistoryEntryRecord(
        accountId: accountId, itemId: itemId, sessionId: "session-1",
        startedAt: Date(timeIntervalSince1970: 1_700_000_050), startPosition: 0, endPosition: 100,
        listenedSeconds: 100)
      try listeningHistoryEntry.insert(db)

      try db.execute(
        sql: """
          INSERT INTO listeningStatsSnapshot
            (accountId, fetchedAt, totalSeconds, daysJSON, weekdaysJSON, titlesJSON)
          VALUES (?, ?, 0, '[]', '{}', '[]')
          """,
        arguments: [accountId, Date(timeIntervalSince1970: 1_700_000_055)])

      var playbackBookmark = PlaybackBookmarkRecord(
        accountId: accountId, itemId: itemId, updatedAt: Date(timeIntervalSince1970: 1_700_000_060))
      try playbackBookmark.insert(db)

      var recentSearch = RecentSearchRecord(
        accountId: accountId, normalizedQuery: "gaiman", displayQuery: "Gaiman",
        lastUsedAt: Date(timeIntervalSince1970: 1_700_000_070))
      try recentSearch.insert(db)

      let podcastSettings = PodcastSettingsRecord(accountId: accountId, autoDownloadEnabled: true)
      try podcastSettings.insert(db)

      let podcastShowSettings = PodcastShowSettingsRecord(
        itemId: itemId, accountId: accountId, autoDownloadOverride: .enabled)
      try podcastShowSettings.insert(db)

      let podcastShowOrder = PodcastShowOrderRecord(accountId: accountId, mode: "custom")
      try podcastShowOrder.insert(db)

      var podcastShowOrderEntry = PodcastShowOrderEntryRecord(
        accountId: accountId, itemId: itemId, position: 0)
      try podcastShowOrderEntry.insert(db)

      let listeningQueueRevision = ListeningQueueRevisionRecord(accountId: accountId, revision: 1)
      try listeningQueueRevision.insert(db)

      let readerPreferences = ReaderPreferencesRecord(
        accountId: accountId, preferencesJSON: "{\"theme\":\"system\"}")
      try readerPreferences.insert(db)

      let itemPlaybackSettings = ItemPlaybackSettingsRecord(
        itemId: itemId, accountId: accountId, rateStep: 20)
      try itemPlaybackSettings.insert(db)

      let pinnedAt = Date(timeIntervalSince1970: 1_700_000_080)
      try db.execute(
        sql: """
          INSERT INTO pinnedList (accountId, serverLibraryId, kind, serverId, pinnedAt)
          VALUES (?, 'lib-1', 'collection', 'col-1', ?)
          """,
        arguments: [accountId, pinnedAt])
      for table in ["pinnedListClaim", "pinnedListDecline"] {
        try db.execute(
          sql: """
            INSERT INTO \(table)
              (accountId, serverLibraryId, kind, serverId, serverItemId, serverEpisodeId, recordedAt)
            VALUES (?, 'lib-1', 'collection', 'col-1', 'item-1', '', ?)
            """,
          arguments: [accountId, pinnedAt])
      }

      var list = SmartListRecord(
        name: "List", position: try SmartListRecord.fetchCount(db), rules: .default,
        createdAt: pinnedAt, updatedAt: pinnedAt)
      try list.insert(db)
      try SmartListDownloadClaimRecord(
        listId: list.id!, itemID: "item-1", episodeID: "ep-1", accountId: accountId,
        claimedAt: pinnedAt
      ).insert(db)
      try db.execute(
        sql: """
          INSERT INTO smartListDownloadDecline (itemID, episodeID, accountId, declinedAt)
          VALUES (?, 'ep-1', ?, ?)
          """,
        arguments: ["item-\(serverUserId)", accountId, pinnedAt])
      try ABSWatchCopy(
        accountId: accountId, key: ABSWatchCopyKey(itemId: "item-1", episodeId: nil), title: "Book",
        state: .wanted, requestedAt: pinnedAt, updatedAt: pinnedAt
      ).insert(db)

      return accountId
    }
  }
}
