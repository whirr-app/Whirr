import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `Thread.isMainThread` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`, hence this indirection.
/// `LibraryReadingObservationTests` has an identical helper.
private func currentThreadIsMain() -> Bool { Thread.isMainThread }

/// Purgeable download storage accounting: only `download` rows are summed (the cover cache is
/// always disposable). No query touches the filesystem, as `DownloadStore.complete` verifies
/// `receivedBytes` against the on-disk file size before a row is `completed`.
@Suite struct StorageAccountingTests {

  // MARK: - Per-item and total byte accounting

  @Test func totalsCountCompletedRowsAtTheirVerifiedFileStoreSize() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)
    let accounting = StorageAccounting(downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 500)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 500),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 500))

    let relativePath = try #require(try downloadStore.fetch(downloadId: downloadId)?.destinationRelativePath)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fileStore.absoluteURL(forRelativePath: relativePath).path)
    let onDiskSize = try #require(attributes[.size] as? NSNumber).int64Value

    let itemTotals = try accounting.itemTotals(itemId: itemId)
    let accountTotals = try accounting.accountTotals()
    #expect(itemTotals.totalBytes == 500)
    #expect(itemTotals.totalBytes == onDiskSize, "accounting agrees with what the file store actually wrote")
    #expect(accountTotals.totalBytes == 500)
  }

  @Test func totalsIncludeInFlightRowsAtTheirCurrentProgress() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let accounting = StorageAccounting(downloadStore: downloadStore)

    let completedId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 1000)
    _ = try downloadStore.transition(downloadId: completedId, to: .downloading)
    _ = try downloadStore.complete(downloadId: completedId, finalSizeBytes: 1000)

    let inFlightId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 2000)
    _ = try downloadStore.transition(downloadId: inFlightId, to: .downloading)
    _ = try downloadStore.updateProgress(downloadId: inFlightId, receivedBytes: 300)

    let itemTotals = try accounting.itemTotals(itemId: itemId)
    #expect(itemTotals.totalBytes == 1300, "1000 completed + 300 accrued so far on the in-flight row")
  }

  @Test func totalsExcludeDeletingRows() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let accounting = StorageAccounting(downloadStore: downloadStore)

    let completedId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 1000)
    _ = try downloadStore.transition(downloadId: completedId, to: .downloading)
    _ = try downloadStore.complete(downloadId: completedId, finalSizeBytes: 1000)
    _ = try downloadStore.transition(downloadId: completedId, to: .deleting)

    let itemTotals = try accounting.itemTotals(itemId: itemId)
    let accountTotals = try accounting.accountTotals()
    #expect(itemTotals.totalBytes == 0, "a deleting row is being removed - it never counts as live storage")
    #expect(accountTotals.totalBytes == 0)
  }

  @Test func itemTotalsAreScopedToOneItemButAccountTotalsSumEveryItem() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, firstItemId) = try await insertAccountAndItem(database, serverItemId: "item-1")
    let secondItemId = try await insertItem(database, accountId: accountId, serverItemId: "item-2")
    let accounting = StorageAccounting(downloadStore: downloadStore)

    let firstId = try enqueue(downloadStore, accountId: accountId, itemId: firstItemId, expectedBytes: 400)
    _ = try downloadStore.transition(downloadId: firstId, to: .downloading)
    _ = try downloadStore.complete(downloadId: firstId, finalSizeBytes: 400)

    let secondId = try enqueue(downloadStore, accountId: accountId, itemId: secondItemId, expectedBytes: 600)
    _ = try downloadStore.transition(downloadId: secondId, to: .downloading)
    _ = try downloadStore.complete(downloadId: secondId, finalSizeBytes: 600)

    #expect(try accounting.itemTotals(itemId: firstItemId).totalBytes == 400)
    #expect(try accounting.itemTotals(itemId: secondItemId).totalBytes == 600)
    #expect(try accounting.accountTotals().totalBytes == 1000)
  }

  @Test func totalsAreZeroForAnItemWithNoRows() async throws {
    let (database, _) = try makeStore()
    let (_, itemId) = try await insertAccountAndItem(database)
    let downloadStore = try DownloadStore(database: database)
    let accounting = StorageAccounting(downloadStore: downloadStore)

    #expect(try accounting.itemTotals(itemId: itemId).totalBytes == 0)
  }

  // MARK: - Observation surface updates on completion and deletion

  @Test("observeAccountStorageTotals emits on completion and deletion, off the main actor")
  func observationEmitsOnCompletionAndDeletion() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let reading = DefaultStorageReading(database: database)

    let observations = PersistenceObservationCollector(reading.observeAccountStorageTotals())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.totalBytes == 0)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 800)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadStore.complete(downloadId: downloadId, finalSizeBytes: 800)

    #expect(await TestSupport.waitUntil { observations.contains { $0.totalBytes == 800 } })
    _ = try #require(observations.last { $0.totalBytes == 800 })
    #expect(currentThreadIsMain() == false)

    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)
    _ = try downloadStore.finalizeDeletion(downloadId: downloadId)

    #expect(await TestSupport.waitUntil { observations.contains { $0.totalBytes == 0 } })
    let afterDeletion = try #require(observations.last { $0.totalBytes == 0 })
    #expect(afterDeletion.totalBytes == 0)
  }

  @Test("completed-byte observation ignores ordinary progress writes")
  func completedByteObservationDeduplicatesInFlightProgress() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let reading = DefaultStorageReading(database: database)
    let observations = PersistenceObservationCollector(reading.observeCompletedDownloadTotals())

    #expect(await TestSupport.waitUntil { observations.values.contains(0) })

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 800)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadStore.updateProgress(downloadId: downloadId, receivedBytes: 300)

    #expect(observations.values == [0], "in-flight progress leaves the completed total unchanged")

    _ = try downloadStore.complete(downloadId: downloadId, finalSizeBytes: 800)
    #expect(await TestSupport.waitUntil { observations.values.contains(800) })
    #expect(observations.values == [0, 800])
  }

  @Test("observeItemStorageTotals scopes to one item and emits on that item's changes")
  func itemObservationScopesToOneItem() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database, serverItemId: "item-watched")
    let otherItemId = try await insertItem(database, accountId: accountId, serverItemId: "item-other")
    let reading = DefaultStorageReading(database: database)

    let observations = PersistenceObservationCollector(
      reading.observeItemStorageTotals(itemId: "item-watched"))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.totalBytes == 0)

    // A completion on a different item must never appear on this item's stream.
    let otherDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: otherItemId, expectedBytes: 999)
    _ = try downloadStore.transition(downloadId: otherDownloadId, to: .downloading)
    _ = try downloadStore.complete(downloadId: otherDownloadId, finalSizeBytes: 999)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 250)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadStore.complete(downloadId: downloadId, finalSizeBytes: 250)

    #expect(await TestSupport.waitUntil { observations.contains { $0.totalBytes == 250 } })
    let afterCompletion = try #require(observations.last { $0.totalBytes == 250 })
    #expect(afterCompletion.totalBytes == 250, "never the other item's 999 bytes")
  }

  // MARK: - Downloaded-item enumeration (the storage screen's row source)

  @Test("observeDownloadedItems lists only items that actually have download rows")
  func downloadedItemsExcludeItemsWithNoDownloads() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, downloadedItemId) = try await insertAccountAndItem(database, serverItemId: "item-downloaded")
    _ = try await insertItem(database, accountId: accountId, serverItemId: "item-never-downloaded")
    let reading = DefaultStorageReading(database: database)

    let observations = PersistenceObservationCollector(reading.observeDownloadedItems())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty, "a library full of undownloaded items has no storage rows at all")

    let downloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: downloadedItemId, expectedBytes: 700)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    _ = try downloadStore.complete(downloadId: downloadId, finalSizeBytes: 700)

    #expect(await TestSupport.waitUntil { observations.contains { $0.map(\.totalBytes) == [700] } })
    let afterCompletion = try #require(observations.last { $0.map(\.totalBytes) == [700] })
    #expect(afterCompletion.map(\.itemId) == ["item-downloaded"], "never the item that was never downloaded")
    #expect(afterCompletion.map(\.title) == ["Title"])
  }

  @Test("observeDownloadedItems sums an item's files once and drops it when its rows are gone")
  func downloadedItemsSumFilesAndDisappearOnDeletion() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let reading = DefaultStorageReading(database: database)

    let firstId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 400)
    _ = try downloadStore.transition(downloadId: firstId, to: .downloading)
    _ = try downloadStore.complete(downloadId: firstId, finalSizeBytes: 400)
    let secondId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 600)
    _ = try downloadStore.transition(downloadId: secondId, to: .downloading)
    _ = try downloadStore.complete(downloadId: secondId, finalSizeBytes: 600)

    let observations = PersistenceObservationCollector(reading.observeDownloadedItems())
    #expect(await TestSupport.waitUntil { observations.contains { $0.map(\.totalBytes) == [1000] } })
    let summed = try #require(observations.last { $0.map(\.totalBytes) == [1000] })
    #expect(summed.count == 1, "one row per item, never one per audio file")

    for downloadId in [firstId, secondId] {
      _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)
      _ = try downloadStore.finalizeDeletion(downloadId: downloadId)
    }

    #expect(await TestSupport.waitUntil { observations.contains { $0.isEmpty } })
    let afterDeletion = try #require(observations.last { $0.isEmpty })
    #expect(afterDeletion.isEmpty)
  }

  @Test("a show's storage row separates the bytes stranded behind a soft-deleted episode")
  func downloadedItemsReportTombstonedEpisodeBytesSeparately() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, _) = try await insertAccountAndItem(database, serverItemId: "item-1")
    let showId = try await insertPodcastItem(database, accountId: accountId, serverItemId: "show-1")
    let liveEpisodeId = try await insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-live")
    let goneEpisodeId = try await insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-gone")

    for (episodeId, bytes) in [(liveEpisodeId, Int64(400)), (goneEpisodeId, Int64(600))] {
      let downloadId = try enqueue(
        downloadStore, accountId: accountId, itemId: showId, podcastEpisodeId: episodeId,
        expectedBytes: bytes)
      _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
      _ = try downloadStore.complete(downloadId: downloadId, finalSizeBytes: bytes)
    }

    let beforeTombstone = try database.read { db in try StorageAccounting.downloadedItems(db) }
    let beforeShow = try #require(beforeTombstone.first(where: { $0.itemId == "show-1" }))
    #expect(beforeShow.tombstonedEpisodeBytes == 0)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [goneEpisodeId])
    }

    let rows = try database.read { db in try StorageAccounting.downloadedItems(db) }
    let show = try #require(rows.first(where: { $0.itemId == "show-1" }))
    #expect(show.totalBytes == 1000, "every downloaded byte still occupies the disk")
    #expect(
      show.tombstonedEpisodeBytes == 600,
      "the stranded share is separately visible so it can be offered for reclamation")
  }

  @Test("an RSS feed row reports bytes stranded by a retained episode")
  func downloadedItemsReportRSSFeedTombstonedEpisodeBytes() async throws {
    let (database, _) = try makeStore()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: "RSS Show", author: "Host",
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    _ = try await episodeStore.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "gone", title: "Gone", enclosureURL: URL(string: "https://example.com/gone.mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: 600)
      ])
    let episode = try #require(
      await episodeStore.fetchEpisode(feedId: feedID, identityKey: "gone"))
    let rssStore = try RSSDownloadStore(database: database)
    let download = try await rssStore.claimOrCreateAsync(episodeId: try #require(episode.id))
    let downloadID = try #require(download.id)
    _ = try await rssStore.transitionAsync(downloadId: downloadID, to: .downloading)
    _ = try await rssStore.completeAsync(downloadId: downloadID, actualBytes: 600)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET refreshGeneration = 2 WHERE id = ?", arguments: [feedID])
      try db.execute(
        sql: "UPDATE rssEpisode SET retained = 1, lastSeenGeneration = 1 WHERE id = ?",
        arguments: [episode.id!])
    }

    let row = try #require(
      database.read { db in try StorageAccounting.downloadedItems(db).first })
    #expect(row.source == .rss)
    #expect(row.author == "Host")
    #expect(row.totalBytes == 600)
    #expect(row.tombstonedEpisodeBytes == 600)
  }

  @Test("the storage union sums ABS and RSS while isolating same-number rows")
  func storageUnionSumsSourcesAndPreservesABSItemTotals() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let absDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 100)
    _ = try downloadStore.transition(downloadId: absDownloadId, to: .downloading)
    _ = try downloadStore.complete(downloadId: absDownloadId, finalSizeBytes: 100)

    let (feedId, episodeId) = try await insertRSSEpisode(
      database, title: "RSS Episode", author: "RSS Author", declaredBytes: 400)
    let rssStore = try RSSDownloadStore(database: database)
    let rssRow = try await rssStore.claimOrCreateAsync(episodeId: episodeId)
    let rssDownloadId = try #require(rssRow.id)
    _ = try await rssStore.transitionAsync(downloadId: rssDownloadId, to: .downloading)
    _ = try await rssStore.completeAsync(downloadId: rssDownloadId, actualBytes: 400)

    let deletingEpisodeId = try await insertRSSEpisode(
      database, title: "Removing", author: "RSS Author", declaredBytes: 300
    ).episodeId
    let deleting = try await rssStore.claimOrCreateAsync(episodeId: deletingEpisodeId)
    let deletingId = try #require(deleting.id)
    _ = try await rssStore.transitionAsync(downloadId: deletingId, to: .downloading)
    _ = try await rssStore.completeAsync(downloadId: deletingId, actualBytes: 300)
    _ = try await rssStore.transitionAsync(downloadId: deletingId, to: .deleting)

    #expect(rssDownloadId == absDownloadId, "independent source tables may mint the same row id")
    let accounting = StorageAccounting(downloadStore: downloadStore, rssDownloadStore: rssStore)
    #expect(try accounting.accountTotals().totalBytes == 500)
    #expect(try accounting.itemTotals(itemId: itemId).totalBytes == 100)
    #expect(try database.read { db in try StorageAccounting.completedBytes(db) } == 500)

    let downloaded = try database.read { db in try StorageAccounting.downloadedItems(db) }
    let abs = try #require(downloaded.first { $0.source == .abs })
    let rss = try #require(downloaded.first { $0.source == .rss && $0.itemId == "rss:\(feedId)" })
    #expect(abs.itemId == "item-1")
    #expect(abs.totalBytes == 100)
    #expect(rss.title == "RSS Show")
    #expect(rss.author == "RSS Author")
    #expect(rss.totalBytes == 400)

    let reading = DefaultStorageReading(database: database)
    let observations = PersistenceObservationCollector(reading.observeAccountStorageTotals())
    #expect(await TestSupport.waitUntil { observations.contains { $0.totalBytes == 500 } })
  }

  // MARK: - Breakdown by kind

  @Test("the breakdown sorts every row into one kind and adds up to the account total")
  func breakdownSplitsByKindAndMatchesTheAccountTotal() async throws {
    let (database, downloadStore) = try makeStore()
    let (accountId, bookId) = try await insertAccountAndItem(database)

    // An audiobook: one completed track and one still transferring, which counts at its progress.
    let track = try enqueue(downloadStore, accountId: accountId, itemId: bookId, expectedBytes: 100)
    _ = try downloadStore.transition(downloadId: track, to: .downloading)
    _ = try downloadStore.complete(downloadId: track, finalSizeBytes: 100)
    let partial = try enqueue(downloadStore, accountId: accountId, itemId: bookId, expectedBytes: 900)
    _ = try downloadStore.transition(downloadId: partial, to: .downloading)

    // The same book's ebook and its PDF supplement: documents, whatever the item is.
    let ebook = try enqueue(downloadStore, accountId: accountId, itemId: bookId, expectedBytes: 30)
    let supplement = try enqueue(downloadStore, accountId: accountId, itemId: bookId, expectedBytes: 7)
    // A row on its way out counts nowhere.
    let leaving = try enqueue(downloadStore, accountId: accountId, itemId: bookId, expectedBytes: 5_000)

    // A server podcast episode.
    let showId = try await insertPodcastItem(database, accountId: accountId, serverItemId: "show-1")
    let episodeId = try await insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "episode-1")
    let episode = try enqueue(
      downloadStore, accountId: accountId, itemId: showId, podcastEpisodeId: episodeId,
      expectedBytes: 40)

    try await database.writeAsync { db in
      func set(_ id: Int64, bytes: Int64, kind: DownloadMediaKind = .audio, state: DownloadState? = nil)
        throws
      {
        try db.execute(
          sql: "UPDATE download SET receivedBytes = ?, mediaKind = ? WHERE id = ?",
          arguments: [bytes, kind.rawValue, id])
        if let state {
          try db.execute(
            sql: "UPDATE download SET state = ? WHERE id = ?", arguments: [state.rawValue, id])
        }
      }
      try set(partial, bytes: 250)
      try set(ebook, bytes: 30, kind: .ebook)
      try set(supplement, bytes: 7, kind: .supplement)
      try set(leaving, bytes: 5_000, state: .deleting)
      try set(episode, bytes: 40)
    }

    // A followed-feed episode, and one of those on its way out.
    let rssStore = try RSSDownloadStore(database: database)
    let rssEpisodeId = try await insertRSSEpisode(
      database, title: "RSS Episode", author: "Host", declaredBytes: 600
    ).episodeId
    let rssRow = try #require(try await rssStore.claimOrCreateAsync(episodeId: rssEpisodeId).id)
    _ = try await rssStore.transitionAsync(downloadId: rssRow, to: .downloading)
    _ = try await rssStore.completeAsync(downloadId: rssRow, actualBytes: 600)
    let rssLeavingEpisodeId = try await insertRSSEpisode(
      database, title: "Removing", author: "Host", declaredBytes: 300
    ).episodeId
    let rssLeaving = try #require(
      try await rssStore.claimOrCreateAsync(episodeId: rssLeavingEpisodeId).id)
    _ = try await rssStore.transitionAsync(downloadId: rssLeaving, to: .downloading)
    _ = try await rssStore.completeAsync(downloadId: rssLeaving, actualBytes: 300)
    _ = try await rssStore.transitionAsync(downloadId: rssLeaving, to: .deleting)

    let breakdown = try database.read { db in try StorageAccounting.breakdown(db) }
    #expect(breakdown.audiobookBytes == 350)
    #expect(breakdown.podcastBytes == 640)
    #expect(breakdown.documentBytes == 37)

    let accounting = StorageAccounting(downloadStore: downloadStore, rssDownloadStore: rssStore)
    #expect(try accounting.accountTotals().totalBytes == breakdown.totalBytes)

    let reading = DefaultStorageReading(database: database)
    let observations = PersistenceObservationCollector(reading.observeStorageBreakdown())
    #expect(await TestSupport.waitUntil { observations.contains { $0 == breakdown } })
  }

  @Test func anEmptyDatabaseBreaksDownToZero() async throws {
    let (database, _) = try makeStore()
    let breakdown = try database.read { db in try StorageAccounting.breakdown(db) }
    #expect(breakdown == StorageBreakdown())
  }

  // MARK: - Helpers

  private func makeStore() throws -> (AppDatabase, DownloadStore) {
    let database = try AppDatabase.inMemory()
    let store = try DownloadStore(database: database)
    return (database, store)
  }

  private func insertAccountAndItem(
    _ database: AppDatabase, serverItemId: String = "item-1"
  ) async throws -> (accountId: Int64, itemId: Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: serverItemId, mediaKind: "book",
        title: "Title", sortTitle: "title")
      try item.insert(db)

      return (account.id!, item.id!)
    }
  }

  private func insertItem(
    _ database: AppDatabase, accountId: Int64, serverItemId: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      let libraryId =
        try LibraryRecord
        .filter(Column("accountId") == accountId)
        .fetchOne(db)?.id!
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId!, serverItemId: serverItemId, mediaKind: "book",
        title: "Title", sortTitle: "title")
      try item.insert(db)
      return item.id!
    }
  }

  private func insertPodcastItem(
    _ database: AppDatabase, accountId: Int64, serverItemId: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      let libraryId = try LibraryRecord.filter(Column("accountId") == accountId).fetchOne(db)?.id!
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId!, serverItemId: serverItemId,
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
      return item.id!
    }
  }

  private func insertEpisode(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, serverEpisodeId: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeId,
        title: serverEpisodeId, lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
  }

  private func insertRSSEpisode(
    _ database: AppDatabase, title: String, author: String, declaredBytes: Int64
  ) async throws -> (feedId: Int64, episodeId: Int64) {
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed-\(UUID().uuidString).xml")!,
      title: "RSS Show", author: author, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    _ = try await episodeStore.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: title, title: title,
          enclosureURL: URL(string: "https://example.com/\(UUID().uuidString).mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: declaredBytes)
      ])
    let episode = try #require(
      await episodeStore.fetchEpisode(feedId: feedId, identityKey: title))
    return (feedId, try #require(episode.id))
  }

  private func enqueue(
    _ store: DownloadStore, accountId: Int64, itemId: Int64, podcastEpisodeId: Int64? = nil,
    expectedBytes: Int64
  ) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId, orderIndex: 0,
      serverFileIno: "ino-\(UUID().uuidString)", mimeType: "audio/mp4")
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
      serverFileIno: UUID().uuidString, orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: expectedBytes,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    return record.id!
  }

  private func makeTempRoot() throws -> (url: URL, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StorageAccountingTests-\(UUID().uuidString)", isDirectory: true)
    return (directory, { try? FileManager.default.removeItem(at: directory) })
  }

  private func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x42, count: bytes).write(to: url)
    return url
  }
}
