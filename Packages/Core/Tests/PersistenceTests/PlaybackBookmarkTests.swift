import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The single-row-per-account "what was last played" bookmark and its projection. Mirrors
/// `HomeReadingTests`: a GRDB `ValueObservation` bridged to `AsyncStream`, so only plain
/// `PlaybackBookmark` values cross the boundary.
@Suite struct PlaybackBookmarkTests {

  @Test func setBookmarkRoundTripsThroughObservation() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    try await Self.insertItem(database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")

    let observations = PersistenceObservationCollector(store.observeBookmark())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = observations.values.first
    #expect(initial == PlaybackBookmark?.none)

    try await store.setBookmark(itemID: "item-1")
    let afterSet = try await Self.next(observations) { $0 != nil }
    #expect(afterSet?.serverItemId == "item-1")
  }

  /// The Watch catalogue publisher holds these open for the app's life and republishes on every
  /// value, so a write that leaves the bookmark as it was must not emit it again.
  @Test func anUnchangedProgressWriteDoesNotReEmitTheBookmark() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    try await Self.writeProgress(
      database, accountId: accountId, itemId: itemId, currentTime: 42, isFinished: false,
      localSequence: 1)
    try await store.setBookmark(itemID: "item-1")
    let account = PersistenceObservationCollector(store.observeBookmark())
    let merged = PersistenceObservationCollector(MergedPlaybackBookmarkReading(database: database).observeBookmark())
    _ = try await Self.next(account) { $0?.positionSeconds == 42 }
    _ = try await Self.next(merged) { $0?.positionSeconds == 42 }
    await awaitQuiescence("the first bookmark settles") { "\(account.values.count) \(merged.values.count)" }
    let baseline = (account.values.count, merged.values.count)

    for sequence in Int64(2)...6 {
      // A sync that rewrites the row with the same position and state.
      try await Self.writeProgress(
        database, accountId: accountId, itemId: itemId, currentTime: 42, isFinished: false,
        localSequence: sequence)
    }
    await awaitQuiescence("unchanged writes deliver nothing") { "\(account.values.count) \(merged.values.count)" }
    #expect(account.values.count == baseline.0)
    #expect(merged.values.count == baseline.1)

    try await Self.writeProgress(
      database, accountId: accountId, itemId: itemId, currentTime: 99, isFinished: false,
      localSequence: 7)
    _ = try await Self.next(account) { $0?.positionSeconds == 99 }
    _ = try await Self.next(merged) { $0?.positionSeconds == 99 }
  }

  @Test func fetchBookmarkReturnsTheCurrentAccountProjectionWithoutWaitingForObservation() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1",
      title: "The Title", author: "The Author", durationSeconds: 3_600)
    try await Self.writeProgress(
      database, accountId: accountId, itemId: itemId, currentTime: 42, isFinished: false,
      localSequence: 1)
    try await store.setBookmark(itemID: "item-1")

    let bookmark = try #require(await store.fetchBookmark())

    #expect(
      bookmark
        == PlaybackBookmark(
          serverItemId: "item-1", title: "The Title", author: "The Author",
          durationSeconds: 3_600, positionSeconds: 42, isFinished: false))
  }

  @Test func fetchBookmarkReturnsNilWithoutAnAccountBookmarkOrLiveTarget() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)

    #expect(await store.fetchBookmark() == nil)

    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    #expect(await store.fetchBookmark() == nil)

    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    try await store.setBookmark(itemID: "item-1")
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [itemId])
    }

    #expect(await store.fetchBookmark() == nil)
  }

  @Test func setBookmarkReplacesThePreviousItem() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    try await Self.insertItem(database, accountId: accountId, libraryId: libraryId, serverItemId: "first")
    try await Self.insertItem(database, accountId: accountId, libraryId: libraryId, serverItemId: "second")

    try await store.setBookmark(itemID: "first")
    try await store.setBookmark(itemID: "second")

    let (rowCount, bookmarked) = try database.read { db in
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playbackBookmark") ?? -1
      let serverItemId = try String.fetchOne(
        db,
        sql: """
          SELECT item.serverItemId FROM playbackBookmark
          JOIN item ON item.id = playbackBookmark.itemId
          """)
      return (count, serverItemId)
    }
    #expect(rowCount == 1, "at most one bookmark row per account")
    #expect(bookmarked == "second")
  }

  @Test func bookmarkIsDeletedByTheAccountCascade() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    try await Self.insertItem(database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    try await store.setBookmark(itemID: "item-1")

    try AccountRemover(database: database).removeAccount(accountId: accountId)

    let rowCount = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playbackBookmark") ?? -1
    }
    #expect(rowCount == 0)
  }

  @Test func bookmarkProjectionJoinsTitleAuthorDurationAndSavedPosition() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1",
      title: "The Title", author: "The Author", durationSeconds: 3_600)
    try await Self.writeProgress(
      database, accountId: accountId, itemId: itemId, currentTime: 42, isFinished: false,
      localSequence: 1)
    try await store.setBookmark(itemID: "item-1")

    let observations = PersistenceObservationCollector(store.observeBookmark())
    let bookmark = try #require(try await Self.next(observations) { $0 != nil })
    #expect(bookmark.serverItemId == "item-1")
    #expect(bookmark.episodeID == nil)
    #expect(bookmark.showTitle == nil)
    // A book keeps its own author in the secondary slot; only an episode promotes the show.
    #expect(bookmark.title == "The Title")
    #expect(bookmark.author == "The Author")
    #expect(bookmark.durationSeconds == 3_600)
    #expect(bookmark.positionSeconds == 42)
    #expect(bookmark.isFinished == false)
  }

  @Test func podcastBookmarkProjectsEpisodeIdentityMetadataAndEpisodeProgress() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1",
      title: "The Show", author: "The Host", durationSeconds: 9_999, mediaKind: "podcast")
    let episodeId = try await Self.insertEpisode(
      database, accountId: accountId, itemId: itemId, serverEpisodeId: "episode-1",
      title: "The Episode", durationSeconds: 1_800)
    try await Self.writeProgress(
      database, accountId: accountId, itemId: itemId, currentTime: 700, isFinished: false,
      localSequence: 1)
    try await Self.writeEpisodeProgress(
      database, accountId: accountId, itemId: itemId, episodeId: episodeId, currentTime: 125,
      isFinished: true, localSequence: 2)

    try await store.setBookmark(itemID: "show-1", episodeID: "episode-1")

    let observations = PersistenceObservationCollector(store.observeBookmark())
    let bookmark = try #require(
      try await Self.next(observations) { $0?.episodeID == "episode-1" })
    #expect(bookmark.serverItemId == "show-1")
    #expect(bookmark.episodeID == "episode-1")
    #expect(bookmark.episodeTitle == "The Episode")
    #expect(bookmark.showTitle == "The Show")
    #expect(bookmark.title == "The Episode")
    #expect(bookmark.author == "The Show")
    #expect(bookmark.durationSeconds == 1_800)
    #expect(bookmark.positionSeconds == 125)
    #expect(bookmark.isFinished)
  }

  /// The episode's own title wins the primary line, but a blank one falls back to the show rather
  /// than projecting an empty title. The secondary line stays the show in both cases.
  @Test func podcastBookmarkFallsBackToTheShowTitleForAnUntitledEpisode() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "show-1",
      title: "The Show", author: "The Host", durationSeconds: 9_999, mediaKind: "podcast")
    _ = try await Self.insertEpisode(
      database, accountId: accountId, itemId: itemId, serverEpisodeId: "episode-1",
      title: "", durationSeconds: 1_800)
    try await store.setBookmark(itemID: "show-1", episodeID: "episode-1")

    let observations = PersistenceObservationCollector(store.observeBookmark())
    let bookmark = try #require(
      try await Self.next(observations) { $0?.episodeID == "episode-1" })
    #expect(bookmark.title == "The Show")
    #expect(bookmark.author == "The Show")
    #expect(bookmark.showTitle == "The Show")
  }

  @Test func podcastBookmarkRejectsAnEpisodeOutsideTheRequestedAccountAndShow() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let requestedShowId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "requested-show",
      mediaKind: "podcast")
    let otherShowId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "other-show",
      mediaKind: "podcast")
    _ = requestedShowId
    _ = try await Self.insertEpisode(
      database, accountId: accountId, itemId: otherShowId, serverEpisodeId: "episode-1",
      title: "Wrong Show", durationSeconds: 60)

    await #expect(
      throws: DefaultPlaybackBookmarkStoring.UnresolvedBookmarkTarget(
        serverItemId: "requested-show", episodeID: "episode-1")
    ) {
      try await store.setBookmark(itemID: "requested-show", episodeID: "episode-1")
    }

    let rowCount = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playbackBookmark") ?? -1
    }
    #expect(rowCount == 0)
  }

  @Test func podcastBookmarkRejectsAnEpisodeThatExistsOnlyInAnotherAccount() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    _ = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "requested-show",
      mediaKind: "podcast")

    let (otherAccountId, otherLibraryId) = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://other.example.com",
        serverUserId: "user-2", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "other-lib", mediaType: "podcast",
        name: "Other Podcasts")
      try library.insert(db)
      return (account.id!, library.id!)
    }
    let otherShowId = try await Self.insertItem(
      database, accountId: otherAccountId, libraryId: otherLibraryId,
      serverItemId: "other-account-show", mediaKind: "podcast")
    _ = try await Self.insertEpisode(
      database, accountId: otherAccountId, itemId: otherShowId, serverEpisodeId: "episode-1",
      title: "Other Account", durationSeconds: 60)

    await #expect(
      throws: DefaultPlaybackBookmarkStoring.UnresolvedBookmarkTarget(
        serverItemId: "requested-show", episodeID: "episode-1")
    ) {
      try await store.setBookmark(itemID: "requested-show", episodeID: "episode-1")
    }
  }

  /// The bookmark row is kept when the item it points at is soft-deleted. Soft-deletion is
  /// inferred and reversible, so a wrong inference must not destroy the resume point, but the
  /// projection reads nil meanwhile. A hard delete takes the row with it via the FK cascade, which
  /// also projects nil.
  @Test func softDeletedOrMissingItemProjectsNil() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    try await store.setBookmark(itemID: "item-1")

    let observations = PersistenceObservationCollector(store.observeBookmark())
    _ = try await Self.next(observations) { $0 != nil }

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [itemId])
    }
    let afterSoftDelete = try await Self.next(observations) { $0 == nil }
    #expect(afterSoftDelete == nil)

    let survivingRowCount = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playbackBookmark") ?? -1
    }
    #expect(survivingRowCount == 1, "a soft delete must not destroy the bookmark row itself")

    // A hard delete cascades the bookmark row away, and still projects nil.
    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [itemId])
    }
    let afterHardDelete = try await Self.next(observations) { $0 == nil }
    #expect(afterHardDelete == nil)
    let rowCountAfterHardDelete = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playbackBookmark") ?? -1
    }
    #expect(rowCountAfterHardDelete == 0)
  }

  @Test func observationReEmitsWhenSavedProgressChanges() async throws {
    let database = try AppDatabase.inMemory()
    let store = DefaultPlaybackBookmarkStoring(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemId = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    try await store.setBookmark(itemID: "item-1")

    let observations = PersistenceObservationCollector(store.observeBookmark())
    _ = try await Self.next(observations) { $0 != nil }

    try await Self.writeProgress(
      database, accountId: accountId, itemId: itemId, currentTime: 10, isFinished: false,
      localSequence: 1)
    let afterFirst = try await Self.next(observations) { $0?.positionSeconds == 10 }
    #expect(afterFirst?.positionSeconds == 10)

    try await Self.writeProgress(
      database, accountId: accountId, itemId: itemId, currentTime: 40, isFinished: true,
      localSequence: 2)
    let afterSecond = try await Self.next(observations) { $0?.positionSeconds == 40 }
    #expect(afterSecond?.isFinished == true)
  }

  // MARK: - Helpers

  private static func seedAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return (account.id!, library.id!)
    }
  }

  @discardableResult
  private static func insertItem(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, serverItemId: String,
    title: String = "Title", author: String? = nil, durationSeconds: Double? = nil,
    mediaKind: String = "book"
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: mediaKind,
        title: title, sortTitle: title.lowercased(), author: author,
        durationSeconds: durationSeconds, numAudioFiles: 3)
      try item.insert(db)
      return item.id!
    }
  }

  @discardableResult
  private static func insertEpisode(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, serverEpisodeId: String,
    title: String, durationSeconds: Double?
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeId,
        title: title, durationSeconds: durationSeconds, lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
  }

  private static func writeProgress(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, currentTime: Double,
    isFinished: Bool, localSequence: Int64
  ) async throws {
    try await database.writeAsync { db in
      var record =
        try MediaProgressRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemId)
        .filter(Column("podcastEpisodeId") == nil)
        .fetchOne(db)
        ?? MediaProgressRecord(
          accountId: accountId, itemId: itemId, currentTime: currentTime, isFinished: isFinished,
          localSequence: localSequence, origin: .local, originKey: "client-uuid")
      record.currentTime = currentTime
      record.isFinished = isFinished
      record.localSequence = localSequence
      try record.save(db)
    }
  }

  private static func writeEpisodeProgress(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, episodeId: Int64,
    currentTime: Double, isFinished: Bool, localSequence: Int64
  ) async throws {
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId,
        currentTime: currentTime, isFinished: isFinished, localSequence: localSequence,
        origin: .local, originKey: "client-uuid")
      try record.insert(db)
    }
  }

  /// Drains intermediate emissions until `predicate` holds. `setBookmark` and the progress writes
  /// each touch several tracked tables, so the settled value is what matters, not each step.
  private static func next(
    _ observations: PersistenceObservationCollector<PlaybackBookmark?>,
    until predicate: @Sendable @escaping (PlaybackBookmark?) -> Bool
  ) async throws -> PlaybackBookmark? {
    #expect(await TestSupport.waitUntil { observations.contains(where: predicate) })
    return try #require(observations.last(where: predicate))
  }
}
