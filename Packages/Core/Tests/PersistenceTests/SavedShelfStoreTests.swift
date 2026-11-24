import Foundation
import GRDB
import Synchronization
import Testing

@testable import Persistence

/// Account-scoped Saved for Later writes. The store accepts whole audiobooks/eBooks and
/// individual podcast episodes, while keeping its membership independent from playback state.
@Suite struct SavedShelfStoreTests {

  // MARK: - Save and validation

  @Test("audiobook and ebook whole-item identities save")
  func audiobookAndEbookItemsSave() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.save(.item(itemID: fixture.audiobookServerItemID)) == .saved)
    #expect(try await store.save(.item(itemID: fixture.ebookServerItemID)) == .saved)

    let rows = try Self.savedRows(database, accountId: fixture.accountId)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.podcastEpisodeId == nil })
  }

  @Test("a podcast show cannot be saved as a whole item")
  func podcastShowWholeItemIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    await #expect(throws: SavedShelfStoreError.episodeIdentityRequired) {
      try await store.save(.item(itemID: fixture.showServerItemID))
    }
  }

  @Test("an episode of a podcast saves")
  func podcastEpisodeSaves() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.save(
        .podcastEpisode(
          itemID: fixture.showServerItemID, episodeID: fixture.episodeServerID)) == .saved)

    let rows = try Self.savedRows(database, accountId: fixture.accountId)
    #expect(rows.count == 1)
    #expect(rows[0].podcastEpisodeId == fixture.episodeId)
  }

  @Test("a native RSS episode saves, removes, and saves idempotently")
  func nativeEpisodeSaveRemoveAndIdempotence() async throws {
    let database = try AppDatabase.inMemory()
    let native = try await Self.seedNativeEpisode(database)
    let store = SavedShelfStore(database: database, accountId: native.accountId)
    let identity = SavedShelfIdentity.rssEpisode(
      itemID: native.itemID, episodeID: native.identityKey)

    #expect(try await store.save(identity) == .saved)
    #expect(try await store.save(identity) == .alreadySaved)
    let saved = try #require(
      try database.read { db in
        try RSSSavedShelfEntryRecord.fetchOne(
          db, sql: "SELECT * FROM rssSavedShelfEntry WHERE rssEpisodeId = ?", arguments: [native.episodeId])
      })
    #expect(saved.subjectTitle == "Native Episode")
    #expect(saved.contextTitle == "Native Feed")

    try await store.remove(identity)
    #expect(try database.read { db in try RSSSavedShelfEntryRecord.fetchCount(db) } == 0)
  }

  @Test("the source check rejects an ABS and RSS source in one row")
  func sourceCheckRejectsMixedSources() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seedNativeEpisode(database)

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        try db.execute(
          sql: """
            INSERT INTO savedShelfEntry
              (accountId, itemId, rssEpisodeId, savedAt, subjectTitle)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [fixture.accountId, fixture.absItemId, fixture.episodeId, Date(), "Invalid"])
      }
    }
  }

  @Test("deleting an RSS episode cascades its saved shelf row")
  func deletingNativeEpisodeCascadesSavedRow() async throws {
    let database = try AppDatabase.inMemory()
    let native = try await Self.seedNativeEpisode(database)
    let store = SavedShelfStore(database: database, accountId: native.accountId)
    let identity = SavedShelfIdentity.rssEpisode(itemID: native.itemID, episodeID: native.identityKey)
    _ = try await store.save(identity)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM rssEpisode WHERE id = ?", arguments: [native.episodeId])
    }
    #expect(try database.read { db in try RSSSavedShelfEntryRecord.fetchCount(db) } == 0)
  }

  /// Resolution is performed by `RSSEpisodeStateStore`, not by a trigger, so this drives the
  /// store. Writing `rssEpisodeState` directly would not resolve anything. See
  /// `NativeSavedIntentResolutionTests` for why that writer is the only one.
  @Test("RSS progress removes a saved row only after positive position")
  func nativeProgressRemovesTheSavedRowOnlyAfterPositivePosition() async throws {
    let database = try AppDatabase.inMemory()
    let native = try await Self.seedNativeEpisode(database)
    let store = SavedShelfStore(database: database, accountId: native.accountId)
    let identity = SavedShelfIdentity.rssEpisode(itemID: native.itemID, episodeID: native.identityKey)
    _ = try await store.save(identity)
    let stateStore = RSSEpisodeStateStore(database: database)

    _ = try await stateStore.recordTick(
      episodeId: native.episodeId, position: 0, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))
    #expect(try database.read { db in try RSSSavedShelfEntryRecord.fetchCount(db) } == 1)

    _ = try await stateStore.recordTick(
      episodeId: native.episodeId, position: 1, finished: false, capturedSequence: 1,
      now: Date(timeIntervalSince1970: 200))
    #expect(try database.read { db in try RSSSavedShelfEntryRecord.fetchCount(db) } == 0)
  }

  @Test("account removal preserves RSS saved rows and the RSS programme")
  func accountRemovalPreservesNativeRSSRows() async throws {
    let database = try AppDatabase.inMemory()
    let native = try await Self.seedNativeEpisode(database)
    let store = SavedShelfStore(database: database, accountId: native.accountId)
    _ = try await store.save(
      .rssEpisode(itemID: native.itemID, episodeID: native.identityKey))

    try AccountRemover(database: database).removeAccount(accountId: native.accountId)

    let counts = try database.read { db in
      (
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssSavedShelfEntry") ?? -1,
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssFeed WHERE id = ?", arguments: [native.feedId]) ?? -1,
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE id = ?", arguments: [native.episodeId]) ?? -1
      )
    }
    #expect(counts == (1, 1, 1))
  }

  @Test("a fresh save stores denormalized subject and context titles")
  func freshSaveStoresDenormalizedTitles() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    _ = try await store.save(.item(itemID: fixture.audiobookServerItemID))
    _ = try await store.save(
      .podcastEpisode(itemID: fixture.showServerItemID, episodeID: fixture.episodeServerID))

    let rows = try Self.savedRows(database, accountId: fixture.accountId)
    let wholeItem = try #require(rows.first { $0.podcastEpisodeId == nil })
    #expect(wholeItem.subjectTitle == "Book")
    #expect(wholeItem.contextTitle == nil)

    let episode = try #require(rows.first { $0.podcastEpisodeId == fixture.episodeId })
    #expect(episode.subjectTitle == "Episode")
    #expect(episode.contextTitle == "Show")
  }

  @Test("an episode identity whose parent is not a podcast is rejected")
  func episodeWhoseParentIsNotPodcastIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    await #expect(throws: SavedShelfStoreError.episodeIdentityNotAllowed) {
      try await store.save(
        .podcastEpisode(itemID: fixture.audiobookServerItemID, episodeID: "not-an-episode"))
    }
  }

  @Test("an episode belonging to a different item is rejected")
  func episodeNotBelongingToSuppliedItemIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    await #expect(throws: SavedShelfStoreError.episodeNotFound) {
      try await store.save(
        .podcastEpisode(
          itemID: fixture.showServerItemID, episodeID: fixture.otherEpisodeServerID))
    }
  }

  @Test("unknown item and episode identities are rejected")
  func unknownItemAndEpisodeAreRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    await #expect(throws: SavedShelfStoreError.itemNotFound) {
      try await store.save(.item(itemID: "missing-item"))
    }
    await #expect(throws: SavedShelfStoreError.episodeNotFound) {
      try await store.save(
        .podcastEpisode(itemID: fixture.showServerItemID, episodeID: "missing-episode"))
    }
  }

  @Test("an identity from another account is rejected")
  func wrongAccountIdentityIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, suffix: "first")
    let other = try await Self.seed(database, suffix: "second")
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    await #expect(throws: SavedShelfStoreError.itemNotFound) {
      try await store.save(.item(itemID: other.audiobookServerItemID))
    }
  }

  @Test("soft-deleted items and episodes are rejected at insertion")
  func softDeletedIdentitiesAreRejectedAtInsertion() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?",
        arguments: [fixture.audiobookItemId])
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?",
        arguments: [fixture.episodeId])
    }

    await #expect(throws: SavedShelfStoreError.itemSoftDeleted) {
      try await store.save(.item(itemID: fixture.audiobookServerItemID))
    }
    await #expect(throws: SavedShelfStoreError.episodeSoftDeleted) {
      try await store.save(
        .podcastEpisode(
          itemID: fixture.showServerItemID, episodeID: fixture.episodeServerID))
    }
  }

  // MARK: - Idempotence and timestamps

  @Test("duplicate save is idempotent and leaves savedAt unchanged")
  func duplicateSaveDoesNotBumpSavedAt() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    let store = SavedShelfStore(
      database: database, accountId: fixture.accountId, now: { clock.withLock { $0 } })
    let identity = SavedShelfIdentity.item(itemID: fixture.audiobookServerItemID)

    #expect(try await store.save(identity) == .saved)
    let firstSavedAt = try #require(
      Self.savedRows(database, accountId: fixture.accountId).first?.savedAt)

    clock.withLock { $0 = Date(timeIntervalSince1970: 1_700_000_100) }
    #expect(try await store.save(identity) == .alreadySaved)

    let row = try #require(Self.savedRows(database, accountId: fixture.accountId).first)
    #expect(row.savedAt == firstSavedAt)
  }

  @Test("removing deletes exactly one row and an absent identity is a no-op")
  func removeDeletesOneRowAndAbsentIsNoOp() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)
    let audiobook = SavedShelfIdentity.item(itemID: fixture.audiobookServerItemID)
    let ebook = SavedShelfIdentity.item(itemID: fixture.ebookServerItemID)

    _ = try await store.save(audiobook)
    _ = try await store.save(ebook)
    try await store.remove(audiobook)

    var rows = try Self.savedRows(database, accountId: fixture.accountId)
    #expect(rows.count == 1)
    #expect(rows[0].itemId == fixture.ebookItemId)

    try await store.remove(.item(itemID: "not-present"))
    rows = try Self.savedRows(database, accountId: fixture.accountId)
    #expect(rows.count == 1)
    #expect(rows[0].itemId == fixture.ebookItemId)
  }

  @Test("remove then re-save uses the new clock value")
  func removeThenResaveStampsNewClockValue() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    let store = SavedShelfStore(
      database: database, accountId: fixture.accountId, now: { clock.withLock { $0 } })
    let identity = SavedShelfIdentity.item(itemID: fixture.audiobookServerItemID)

    #expect(try await store.save(identity) == .saved)
    try await store.remove(identity)
    clock.withLock { $0 = Date(timeIntervalSince1970: 1_700_000_200) }

    #expect(try await store.save(identity) == .saved)
    let row = try #require(Self.savedRows(database, accountId: fixture.accountId).first)
    #expect(row.savedAt == Date(timeIntervalSince1970: 1_700_000_200))
  }

  // MARK: - Isolation from other state

  @Test("save and remove leave queue, download, progress, and session rows untouched")
  func saveRemoveLeavesOtherStateUntouched() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await Self.seedRelatedRows(database, fixture: fixture)
    let before = try Self.relatedRowCounts(database, accountId: fixture.accountId)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    let identity = SavedShelfIdentity.item(itemID: fixture.audiobookServerItemID)
    _ = try await store.save(identity)
    try await store.remove(identity)

    let after = try Self.relatedRowCounts(database, accountId: fixture.accountId)
    #expect(after == before)
    #expect(try Self.savedRows(database, accountId: fixture.accountId).isEmpty)
  }

  @Test("a row survives later soft deletion and remains removable")
  func laterSoftDeletionDoesNotInvalidateSavedRow() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)
    let audiobook = SavedShelfIdentity.item(itemID: fixture.audiobookServerItemID)
    let episode = SavedShelfIdentity.podcastEpisode(
      itemID: fixture.showServerItemID, episodeID: fixture.episodeServerID)

    _ = try await store.save(audiobook)
    _ = try await store.save(episode)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id IN (?, ?)",
        arguments: [fixture.audiobookItemId, fixture.showItemId])
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?",
        arguments: [fixture.episodeId])
    }

    #expect(try Self.savedRows(database, accountId: fixture.accountId).count == 2)
    try await store.remove(audiobook)
    try await store.remove(episode)
    #expect(try Self.savedRows(database, accountId: fixture.accountId).isEmpty)
  }

  // MARK: - Fixtures

  private struct Fixture: Sendable {
    let accountId: Int64
    let audiobookItemId: Int64
    let audiobookServerItemID: String
    let ebookItemId: Int64
    let ebookServerItemID: String
    let showItemId: Int64
    let showServerItemID: String
    let episodeId: Int64
    let episodeServerID: String
    let otherEpisodeServerID: String
  }

  private struct NativeFixture: Sendable {
    let accountId: Int64
    let feedId: Int64
    let episodeId: Int64
    let absItemId: Int64
    let itemID: String
    let identityKey: String
  }

  private struct RelatedRowCounts: Equatable, Sendable {
    let queue: Int
    let downloads: Int
    let progress: Int
    let sessions: Int
  }

  private static func seed(
    _ database: AppDatabase,
    suffix: String = "primary"
  ) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)-\(UUID().uuidString)", serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-\(suffix)", mediaType: "book",
        name: "Library")
      try library.insert(db)

      let audiobookServerItemID = "book-\(suffix)"
      var audiobook = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: audiobookServerItemID,
        mediaKind: "book", title: "Book", sortTitle: "book", author: "Author",
        numAudioFiles: 4)
      try audiobook.insert(db)

      let ebookServerItemID = "ebook-\(suffix)"
      var ebook = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: ebookServerItemID,
        mediaKind: "book", title: "Ebook", sortTitle: "ebook", ebookFormat: "epub")
      try ebook.insert(db)

      let showServerItemID = "show-\(suffix)"
      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: showServerItemID,
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)

      let episodeServerID = "episode-\(suffix)"
      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: episodeServerID,
        title: "Episode", lastSeenGeneration: 1)
      try episode.insert(db)

      var otherShow = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "other-show-\(suffix)",
        mediaKind: "podcast", title: "Other Show", sortTitle: "other-show")
      try otherShow.insert(db)
      let otherEpisodeServerID = "other-episode-\(suffix)"
      var otherEpisode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: otherShow.id!, serverEpisodeId: otherEpisodeServerID,
        title: "Other Episode", lastSeenGeneration: 1)
      try otherEpisode.insert(db)

      return Fixture(
        accountId: account.id!, audiobookItemId: audiobook.id!,
        audiobookServerItemID: audiobookServerItemID, ebookItemId: ebook.id!,
        ebookServerItemID: ebookServerItemID, showItemId: show.id!,
        showServerItemID: showServerItemID, episodeId: episode.id!,
        episodeServerID: episodeServerID, otherEpisodeServerID: otherEpisodeServerID)
    }
  }

  private static func seedNativeEpisode(_ database: AppDatabase) async throws -> NativeFixture {
    let (accountId, absItemId) = try await database.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: "native-client-(UUID().uuidString)", serverBaseURL: "native-server",
        serverUserId: "native-user", serverVersion: "2.52.0")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "native-library", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "native-book",
        mediaKind: "book", title: "Native Book", sortTitle: "native book")
      try item.insert(db)
      return (account.id!, item.id!)
    }
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/native-(UUID().uuidString).xml")!,
      title: "Native Feed", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let identityKey = "native-episode"
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: identityKey, title: "Native Episode",
          enclosureURL: URL(string: "https://example.com/native.mp3")!, durationSeconds: 60)
      ])
    let episodeId = try await database.readAsync { db in
      let fetched = try Int64.fetchOne(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
        arguments: [feedId, identityKey])
      return try #require(fetched)
    }
    return NativeFixture(
      accountId: accountId, feedId: feedId, episodeId: episodeId, absItemId: absItemId,
      itemID: try #require(PodcastSourceIdentity.rss(feedId: feedId)?.itemId),
      identityKey: identityKey)
  }

  private static func savedRows(_ database: AppDatabase, accountId: Int64) throws
    -> [SavedShelfEntryRecord]
  {
    try database.read { db in
      try SavedShelfEntryRecord
        .filter(Column("accountId") == accountId)
        .order(Column("id"))
        .fetchAll(db)
    }
  }

  private static func seedRelatedRows(_ database: AppDatabase, fixture: Fixture) async throws {
    try await database.writeAsync { db in
      var queueEntry = ListeningQueueEntryRecord(
        accountId: fixture.accountId, itemId: fixture.audiobookItemId, position: 0)
      try queueEntry.insert(db)

      var download = DownloadRecord(
        accountId: fixture.accountId, itemId: fixture.audiobookItemId, serverFileIno: "file-1",
        orderIndex: 0, destinationRelativePath: "book/file.m4b", expectedBytes: 100,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      try download.insert(db)

      var progress = MediaProgressRecord(
        accountId: fixture.accountId, itemId: fixture.audiobookItemId, currentTime: 12,
        isFinished: false, localSequence: 1, origin: .local, originKey: "client")
      try progress.insert(db)

      var session = PlaybackSessionRecord(
        accountId: fixture.accountId, clientSessionId: "session-1", itemId: fixture.audiobookItemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try session.insert(db)
    }
  }

  private static func relatedRowCounts(_ database: AppDatabase, accountId: Int64) throws
    -> RelatedRowCounts
  {
    try database.read { db in
      RelatedRowCounts(
        queue:
          try ListeningQueueEntryRecord
          .filter(Column("accountId") == accountId).fetchCount(db),
        downloads: try DownloadRecord.filter(Column("accountId") == accountId).fetchCount(db),
        progress: try MediaProgressRecord.filter(Column("accountId") == accountId).fetchCount(db),
        sessions:
          try PlaybackSessionRecord
          .filter(Column("accountId") == accountId).fetchCount(db))
    }
  }
}
