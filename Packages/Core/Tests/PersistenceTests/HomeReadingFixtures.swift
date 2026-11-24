import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

enum HomeReadingFixtures {
  // MARK: - Helpers

  static func seedAccountAndLibrary(
    _ database: AppDatabase, serverLibraryId: String,
    onlyShowLaterBooksInContinueSeries: Bool = false
  ) async throws -> (accountId: Int64, libraryRowId: Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      let accountId = account.id!

      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: serverLibraryId, mediaType: "book", name: "Library",
        onlyShowLaterBooksInContinueSeries: onlyShowLaterBooksInContinueSeries)
      try library.insert(db)
      let libraryRowId = library.id!

      return (accountId, libraryRowId)
    }
  }

  static func audiobook(
    accountId: Int64, libraryId: Int64, serverItemId: String
  ) -> ItemRecord {
    ItemRecord(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: "book",
      title: serverItemId, sortTitle: serverItemId, numAudioFiles: 3)
  }

  static func podcast(
    accountId: Int64, libraryId: Int64, serverItemId: String
  ) -> ItemRecord {
    ItemRecord(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
      mediaKind: "podcast", title: serverItemId, sortTitle: serverItemId)
  }

  static func ebook(
    accountId: Int64, libraryId: Int64, serverItemId: String
  ) -> ItemRecord {
    ItemRecord(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: "book",
      title: serverItemId, sortTitle: serverItemId, numAudioFiles: 0, ebookFormat: "epub")
  }

  /// A commit that re-runs every tracked Home query without changing any projected field.
  ///
  /// Any `item` column no Home row projects will do. A no-change traversal does not touch `item`
  /// (the seen-set lives in `itemSeen`), so it would not wake these observations; a podcast-only
  /// setting stands in, as the property under test is snapshot dedup.
  static func commitUntrackedFieldChange(
    _ database: AppDatabase, accountId: Int64
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET podcastMaxEpisodesToKeep = COALESCE(podcastMaxEpisodesToKeep, 0) + 1 WHERE accountId = ?",
        arguments: [accountId])
    }
  }

  static func commitTitleChange(_ database: AppDatabase, itemId: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET title = 'Changed' WHERE id = ?", arguments: [itemId])
    }
  }

  static func writeProgress(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, currentTime: Double,
    ebookProgress: Double? = nil, isFinished: Bool, localSequence: Int64,
    serverUpdatedAt: Date? = nil, lastActivityAt: Date? = nil
  ) async throws {
    let activity = lastActivityAt ?? serverUpdatedAt ?? Self.activityStamp(for: localSequence)
    try await database.writeAsync { db in
      var record =
        try MediaProgressRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemId)
        .filter(Column("podcastEpisodeId") == nil)
        .fetchOne(db)
        ?? MediaProgressRecord(
          accountId: accountId, itemId: itemId, currentTime: currentTime, isFinished: isFinished,
          serverUpdatedAt: serverUpdatedAt, localSequence: localSequence, origin: .local,
          originKey: "client-uuid", ebookProgress: ebookProgress, lastActivityAt: activity)
      record.currentTime = currentTime
      record.ebookProgress = ebookProgress
      record.isFinished = isFinished
      record.serverUpdatedAt = serverUpdatedAt
      record.lastActivityAt = activity
      record.localSequence = localSequence
      try record.save(db)
    }
  }

  /// Tests express "listened to later" by giving a row a higher sequence. Production orders by
  /// `lastActivityAt`, so a seeded row without an explicit stamp gets one derived from its
  /// sequence, which carries the ordering each test means into the key that decides it.
  static func activityStamp(for localSequence: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(localSequence))
  }

  @discardableResult
  static func insertEpisode(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    serverEpisodeID: String,
    title: String,
    durationSeconds: Double?,
    publishedAt: Date? = nil
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeID, title: title,
        durationSeconds: durationSeconds, publishedAt: publishedAt, lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
  }

  static func writeEpisodeProgress(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    episodeId: Int64,
    currentTime: Double,
    isFinished: Bool,
    localSequence: Int64,
    lastActivityAt: Date? = nil
  ) async throws {
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId,
        currentTime: currentTime, isFinished: isFinished, localSequence: localSequence,
        origin: .local, originKey: "client-uuid",
        lastActivityAt: lastActivityAt ?? Self.activityStamp(for: localSequence))
      try record.insert(db)
    }
  }

  /// Drains an `AsyncStream` iterator, discarding intermediate emissions, until `predicate`
  /// holds or the stream ends. For assertions that only care about the eventual settled state
  /// across a helper that performs several separate writes (e.g. `completeDownload`'s
  /// pending -> downloading -> completed transitions, each of which re-emits).
  static func next(
    _ observations: PersistenceObservationCollector<[HomeItem]>,
    until predicate: @Sendable @escaping ([HomeItem]) -> Bool
  ) async throws -> [HomeItem] {
    #expect(await TestSupport.waitUntil { observations.contains(where: predicate) })
    return try #require(observations.last(where: predicate))
  }

  static func completeDownload(
    _ store: DownloadStore, accountId: Int64, itemId: Int64
  ) throws {
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "file-\(itemId)", orderIndex: 0,
      destinationRelativePath: "\(itemId).mp3", expectedBytes: 100, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 10)
    try store.transition(downloadId: try #require(record.id), to: .downloading)
    try store.complete(downloadId: try #require(record.id), finalSizeBytes: 100)
  }

  static func completeEbookDownload(
    _ store: DownloadStore, accountId: Int64, itemId: Int64
  ) throws {
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ebook-file-\(itemId)", orderIndex: 0,
      destinationRelativePath: "\(itemId).epub", expectedBytes: 100,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
    try store.transition(downloadId: try #require(record.id), to: .downloading)
    try store.complete(downloadId: try #require(record.id), finalSizeBytes: 100)
  }

  static func completeEpisodeDownload(
    _ store: DownloadStore,
    accountId: Int64,
    itemId: Int64,
    episodeId: Int64
  ) throws {
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId,
      serverFileIno: "episode-file-\(episodeId)", orderIndex: 0,
      destinationRelativePath: "episode-\(episodeId).mp3", expectedBytes: 100,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 10)
    try store.transition(downloadId: try #require(record.id), to: .downloading)
    try store.complete(downloadId: try #require(record.id), finalSizeBytes: 100)
  }
}
