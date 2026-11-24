import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

/// `LibraryReading`'s real observation surface: GRDB `ValueObservation` bridged to
/// `AsyncStream`. Screens (via AppModel) only ever see the plain `ItemSummary`/
/// `LibrarySyncStatus` projections, never a GRDB type (ARCHITECTURE.md).
@Suite struct LibraryReadingObservationTests {

  @Test("current item detail returns cached metadata synchronously")
  func currentItemDetailReturnsCachedMetadataSynchronously() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "show-1",
        mediaKind: "podcast", title: "Cached Show", sortTitle: "cached show",
        itemDescription: "Cached description"))

    let cached = reading.currentItemDetail(itemId: "show-1")

    #expect(cached?.title == "Cached Show")
    #expect(cached?.itemDescription == "Cached description")
  }

  @Test("the browse list emits on insert, update, and soft-delete, off the main actor")
  func browseListEmitsOnInsertUpdateAndSoftDelete() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")

    var iterator = reading.observeBrowseList(libraryId: "lib1").makeAsyncIterator()

    let initial = try #require(await iterator.next())
    #expect(initial.isEmpty)

    var item = ItemRecord(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "item1", mediaKind: "book",
      title: "Original Title", sortTitle: "original title", seriesName: "Browse Series",
      narratorName: "Browse Narrator",
      expandedMetadataFetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    item = try itemDAO.upsert(item)

    let afterInsert = try #require(await iterator.next())
    // `Thread.isMainThread` cannot be referenced from an `async` body, so go through a plain
    // synchronous helper.
    #expect(LibraryReadingObservationFixtures.currentThreadIsMain() == false)
    #expect(afterInsert.map(\.serverItemId) == ["item1"])
    #expect(afterInsert.first?.title == "Original Title")
    #expect(afterInsert.first?.seriesName == "Browse Series")
    #expect(afterInsert.first?.narratorName == "Browse Narrator")
    #expect(
      afterInsert.first?.expandedMetadataFetchedAt
        == Date(timeIntervalSince1970: 1_700_000_000))

    item.title = "Updated Title"
    item.sortTitle = "updated title"
    _ = try itemDAO.upsert(item)

    let afterUpdate = try #require(await iterator.next())
    #expect(afterUpdate.first?.title == "Updated Title")

    item.softDeleted = true
    _ = try itemDAO.upsert(item)

    let afterSoftDelete = try #require(await iterator.next())
    #expect(afterSoftDelete.isEmpty)
  }

  @Test("item detail emits the current projection and nil once soft-deleted")
  func itemDetailEmitsAndClearsOnSoftDelete() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")

    var iterator = reading.observeItemDetail(itemId: "item1").makeAsyncIterator()

    let initial = try #require(await iterator.next())
    #expect(initial == nil)

    var item = ItemRecord(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "item1", mediaKind: "book",
      title: "Detail Title", sortTitle: "detail title", author: "Detail Author",
      seriesName: "Detail Series", narratorName: "Detail Narrator",
      expandedMetadataFetchedAt: Date(timeIntervalSince1970: 1_710_000_000))
    item = try itemDAO.upsert(item)

    let afterInsert = try #require(await iterator.next())
    #expect(afterInsert?.title == "Detail Title")
    #expect(afterInsert?.author == "Detail Author")
    #expect(afterInsert?.seriesName == "Detail Series")
    #expect(afterInsert?.narratorName == "Detail Narrator")
    #expect(
      afterInsert?.expandedMetadataFetchedAt
        == Date(timeIntervalSince1970: 1_710_000_000))

    item.softDeleted = true
    _ = try itemDAO.upsert(item)

    let afterSoftDelete = try #require(await iterator.next())
    #expect(afterSoftDelete == nil)
  }

  @Test("item detail reads persisted progress on its first cold-start emission")
  func itemDetailReadsPersistedProgressOnSubscription() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let item = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "item1", mediaKind: "book",
        title: "Detail Title", sortTitle: "detail title", durationSeconds: 100))
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountId, itemId: try #require(item.id), currentTime: 10,
        isFinished: false, localSequence: 1, origin: .local, originKey: "client-uuid")
      try progress.insert(db)
    }

    var iterator = reading.observeItemDetail(itemId: "item1").makeAsyncIterator()
    let summary = try #require(await iterator.next())

    #expect(summary?.progressSeconds == 10)
  }

  @Test("observeItems resolves an ordered id list to live rows, dropping unresolved ids")
  func observeItemsResolvesOrderedIdsAndDropsUnresolved() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")

    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "b", mediaKind: "book",
        title: "B Title", sortTitle: "b title"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "a", mediaKind: "book",
        title: "A Title", sortTitle: "a title"))

    var iterator = reading.observeItems(ids: ["a", "missing", "b"]).makeAsyncIterator()
    let resolved = try #require(await iterator.next())

    // Preserves the requested order (a, b), not sort-title order, and drops "missing".
    #expect(resolved.map(\.serverItemId) == ["a", "b"])
  }

  @Test("sync status reflects running, incomplete, and last-completed state")
  func syncStatusReflectsRunState() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let syncRunDAO = SyncRunDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")

    var iterator = reading.observeSyncStatus(libraryId: "lib1").makeAsyncIterator()
    let initial = try #require(await iterator.next())
    #expect(initial.isRunning == false)
    #expect(initial.lastCompletedAt == nil)

    let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let run = try syncRunDAO.startRun(
      accountId: accountId, libraryId: libraryRowId, reason: "explicit", generation: 1,
      sortRequested: nil, startedAt: completedAt.addingTimeInterval(-10))
    let afterStart = try #require(await iterator.next())
    #expect(afterStart.isRunning)

    try syncRunDAO.finish(runId: try #require(run.id), state: .completed, completedAt: completedAt, errorCategory: nil)
    let afterFinish = try #require(await iterator.next())
    #expect(afterFinish.isRunning == false)
    #expect(afterFinish.lastRunIncomplete == false)
    #expect(afterFinish.lastCompletedAt == completedAt)
  }

  @Test("browse list populates category, ebook capability, and addedAt")
  func browseListPopulatesDerivedCategoryEbookCapabilityAndAddedAt() async throws {
    // `DefaultLibraryReading.makeSummary` derives `ItemSummary.category` from the stored signals,
    // for both a podcast row and an ebook-signalled row.
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")
    let addedAt = Date(timeIntervalSince1970: 1_750_000_000)

    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast-item",
        mediaKind: "podcast", title: "Podcast Title", sortTitle: "podcast title",
        addedAt: addedAt))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "ebook-item",
        mediaKind: "book", title: "Ebook Title", sortTitle: "ebook title",
        numAudioFiles: 0, ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "mixed-item",
        mediaKind: "book", title: "Mixed Title", sortTitle: "mixed title",
        numAudioFiles: 2, ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "pdf-sidecar-item",
        mediaKind: "book", title: "PDF Sidecar", sortTitle: "pdf sidecar",
        numAudioFiles: 2, ebookFormat: "pdf"))

    var iterator = reading.observeBrowseList(libraryId: "lib1").makeAsyncIterator()
    let list = try #require(await iterator.next())
    let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.serverItemId, $0) })

    #expect(byId["podcast-item"]?.category == .podcast)
    #expect(byId["podcast-item"]?.addedAt == addedAt)
    #expect(byId["ebook-item"]?.category == .ebook)
    #expect(byId["ebook-item"]?.hasReadableEbook == true)
    #expect(byId["mixed-item"]?.category == .audiobook)
    #expect(byId["mixed-item"]?.hasReadableEbook == true)
    #expect(byId["pdf-sidecar-item"]?.category == .audiobook)
    #expect(byId["pdf-sidecar-item"]?.hasReadableEbook == false)
  }

  @Test("browse projections carry the item's server updatedAt as the cover revision source")
  func browseListCarriesServerUpdatedAt() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await Self.seedAccountAndLibrary(database, serverLibraryId: "lib1")
    let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "item-1",
        mediaKind: "book", title: "Title", sortTitle: "title", serverUpdatedAt: updatedAt))

    var iterator = reading.observeBrowseList(libraryId: "lib1").makeAsyncIterator()
    let list = try #require(await iterator.next())

    #expect(list.first?.serverUpdatedAt == updatedAt)
  }

  // MARK: - Cross-library browse

  @Test("the cross-library browse list spans every library, sorted, excluding soft-deleted")
  func crossLibraryBrowseListSpansEveryLibrary() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowIds) = try await Self.seedAccountAndLibraries(
      database, serverLibraryIds: ["books", "pods"])

    let observations = PersistenceObservationCollector(reading.observeBrowseList(category: nil))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowIds[0], serverItemId: "book-1",
        mediaKind: "book", title: "Beta Book", sortTitle: "beta book"))
    var podcast = ItemRecord(
      accountId: accountId, libraryId: libraryRowIds[1], serverItemId: "pod-1",
      mediaKind: "podcast", title: "Alpha Podcast", sortTitle: "alpha podcast")
    podcast = try itemDAO.upsert(podcast)

    #expect(await TestSupport.waitUntil { observations.contains { $0.count >= 2 } })
    let latest = try #require(observations.last { $0.count >= 2 })

    // Both libraries' items, interleaved by sortTitle rather than grouped by library.
    #expect(latest.map(\.serverItemId) == ["pod-1", "book-1"])

    podcast.softDeleted = true
    _ = try itemDAO.upsert(podcast)

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.map(\.serverItemId) == ["book-1"] }
      })
    let afterSoftDelete = try #require(
      observations.last { $0.map(\.serverItemId) == ["book-1"] })
    #expect(afterSoftDelete.map(\.serverItemId) == ["book-1"])
  }

  @Test("the cross-library browse list does not re-emit a row rewritten unchanged")
  func crossLibraryBrowseListDeduplicatesUnchangedWrites() async throws {
    // The Watch artwork sync holds this open for the app's life, and a sync re-pull saves every
    // row whether or not it changed.
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowIds) = try await Self.seedAccountAndLibraries(
      database, serverLibraryIds: ["books"])
    var book = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowIds[0], serverItemId: "book-1",
        mediaKind: "book", title: "Book", sortTitle: "book"))

    let observations = PersistenceObservationCollector(reading.observeBrowseList(category: nil))
    #expect(await TestSupport.waitUntil { observations.contains { $0.count == 1 } })
    await awaitQuiescence("the first list settles") { "\(observations.values.count)" }
    let baseline = observations.values.count

    for _ in 0..<5 { book = try itemDAO.upsert(book) }
    await awaitQuiescence("unchanged rewrites deliver nothing") { "\(observations.values.count)" }
    #expect(observations.values.count == baseline)

    book.title = "Sentinel"
    _ = try itemDAO.upsert(book)
    #expect(await TestSupport.waitUntil { observations.contains { $0.first?.title == "Sentinel" } })
  }

  @Test("the cross-library browse list honours the media-category filter")
  func crossLibraryBrowseListHonoursCategoryFilter() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowIds) = try await Self.seedAccountAndLibraries(
      database, serverLibraryIds: ["books", "pods"])

    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowIds[0], serverItemId: "audio-1",
        mediaKind: "book", title: "Audio", sortTitle: "audio", numAudioFiles: 3))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowIds[0], serverItemId: "ebook-1",
        mediaKind: "book", title: "Ebook", sortTitle: "ebook", numAudioFiles: 0, ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowIds[0], serverItemId: "mixed-1",
        mediaKind: "book", title: "Mixed", sortTitle: "mixed", numAudioFiles: 2,
        ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowIds[0], serverItemId: "mixed-pdf",
        mediaKind: "book", title: "Mixed PDF", sortTitle: "mixed pdf", numAudioFiles: 2,
        ebookFormat: "pdf"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryRowIds[1], serverItemId: "pod-1",
        mediaKind: "podcast", title: "Pod", sortTitle: "pod"))

    #expect(try await Self.settled(reading.observeBrowseList(category: .podcast), count: 1) == ["pod-1"])
    #expect(
      try await Self.settled(reading.observeBrowseList(category: .ebook), count: 2)
        == ["ebook-1", "mixed-1"])
    #expect(
      try await Self.settled(reading.observeBrowseList(category: .audiobook), count: 3)
        == ["audio-1", "mixed-1", "mixed-pdf"])
  }

  @Test("BrowseFilters ebooks include mixed items while audiobook and podcast filters stay distinct")
  func filteredBrowseCategoriesIncludeMixedItems() async throws {
    let fixture = try await FilterFixture()
    _ = try await fixture.book("audio", numAudioFiles: 2)
    _ = try await fixture.book("ebook", numAudioFiles: 0, ebookFormat: "epub")
    _ = try await fixture.book("mixed", numAudioFiles: 2, ebookFormat: "epub")
    _ = try await fixture.book("mixed-pdf", numAudioFiles: 2, ebookFormat: "pdf")
    _ = try await fixture.show("pod")

    #expect(
      try await Self.settledIDs(fixture.reading, BrowseFilters(categories: [.ebook]), count: 2)
        == ["ebook", "mixed"])
    #expect(
      try await Self.settledIDs(
        fixture.reading, BrowseFilters(categories: [.audiobook]), count: 3)
        == ["audio", "mixed", "mixed-pdf"])
    #expect(
      try await Self.settledIDs(fixture.reading, BrowseFilters(categories: [.podcast]), count: 1)
        == ["pod"])
  }

  @Test("browse projections follow included libraries live without resubscribing")
  func browseProjectionsFollowIncludedLibrariesLive() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountID, libraryRowIDs) = try await Self.seedAccountAndLibraries(
      database, serverLibraryIds: ["included", "excluded"])
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountID, libraryId: libraryRowIDs[0], serverItemId: "included-item",
        mediaKind: "book", title: "Included", sortTitle: "included"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountID, libraryId: libraryRowIDs[1], serverItemId: "excluded-item",
        mediaKind: "book", title: "Excluded", sortTitle: "excluded"))

    let observations = PersistenceObservationCollector(reading.observeBrowseList(category: nil))
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.map(\.serverItemId) == ["excluded-item", "included-item"] }
      })

    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("id") == libraryRowIDs[1])
        .updateAll(db, Column("isIncluded").set(to: false))
    }
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.map(\.serverItemId) == ["included-item"] }
      })

    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("id") == libraryRowIDs[1])
        .updateAll(db, Column("isIncluded").set(to: true))
    }
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.map(\.serverItemId) == ["excluded-item", "included-item"] }
      })

    let filtered = try await Self.settledSnapshot(
      reading.observeBrowseList(filters: BrowseFilters()), unfilteredCount: 2)
    #expect(filtered.items.map(\.serverItemId) == ["excluded-item", "included-item"])
  }

  @Test("an excluded library's completed download still resolves through download and detail reads")
  func retainedDownloadAndDetailReadsIgnoreLibraryInclusion() async throws {
    let database = try AppDatabase.inMemory()
    let libraryReading = DefaultLibraryReading(database: database)
    let downloadReading = DefaultDownloadReading(database: database)
    let (accountID, libraryRowIDs) = try await Self.seedAccountAndLibraries(
      database, serverLibraryIds: ["included", "excluded"])
    let itemID = try await database.writeAsync { db -> Int64 in
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryRowIDs[1], serverItemId: "retained-item",
        mediaKind: "book", title: "Retained", sortTitle: "retained")
      try item.insert(db)
      var download = DownloadRecord(
        accountId: accountID, itemId: item.id!, serverFileIno: "retained-file", orderIndex: 0,
        destinationRelativePath: "retained.mp3", expectedBytes: 100,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 60, receivedBytes: 100, state: .completed)
      try download.insert(db)
      try LibraryRecord
        .filter(Column("id") == libraryRowIDs[1])
        .updateAll(db, Column("isIncluded").set(to: false))
      return item.id!
    }
    _ = itemID

    #expect(downloadReading.currentItemDownloadStatus(itemId: "retained-item") == .completed)
    #expect(libraryReading.currentItemDetail(itemId: "retained-item")?.title == "Retained")
    var detail = libraryReading.observeItemDetail(itemId: "retained-item").makeAsyncIterator()
    #expect(try #require(await detail.next())?.serverItemId == "retained-item")
  }

  @Test("aggregate sync status runs when any library runs, and goes stale with the oldest one")
  func aggregateSyncStatusFoldsEveryLibrary() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultLibraryReading(database: database)
    let syncRunDAO = SyncRunDAO(database: database)
    let (accountId, libraryRowIds) = try await Self.seedAccountAndLibraries(
      database, serverLibraryIds: ["books", "pods"])

    let observations = PersistenceObservationCollector(reading.observeAggregateSyncStatus())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isRunning == false)
    #expect(initial.lastCompletedAt == nil)

    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let newer = Date(timeIntervalSince1970: 1_800_000_000)

    let booksRun = try syncRunDAO.startRun(
      accountId: accountId, libraryId: libraryRowIds[0], reason: "explicit", generation: 1,
      sortRequested: nil, startedAt: older.addingTimeInterval(-10))
    #expect(await TestSupport.waitUntil { observations.contains { $0.isRunning } })
    var status = try #require(observations.last { $0.isRunning })
    #expect(status.isRunning, "one library running makes the aggregate running")

    try syncRunDAO.finish(
      runId: try #require(booksRun.id), state: .completed, completedAt: older, errorCategory: nil)
    let podsRun = try syncRunDAO.startRun(
      accountId: accountId, libraryId: libraryRowIds[1], reason: "explicit", generation: 1,
      sortRequested: nil, startedAt: newer.addingTimeInterval(-10))
    try syncRunDAO.finish(
      runId: try #require(podsRun.id), state: .completed, completedAt: newer, errorCategory: nil)

    // Drain to the settled state: the observation also emits intermediate ones (books finished,
    // pods not yet started) where no library is running but one has never completed.
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.isRunning == false && $0.lastCompletedAt == older }
      })
    status = try #require(
      observations.last { $0.isRunning == false && $0.lastCompletedAt == older })

    // The oldest library's completion, not the newest: the list is only as fresh as its
    // least-recently-synced library.
    #expect(status.isRunning == false)
    #expect(status.lastCompletedAt == older)
  }

  // MARK: - Filtered browse

  @Test("a downloaded filter re-emits when a download row appears and disappears")
  func filteredBrowseReEmitsOnDownloadWrites() async throws {
    // A hand-written `WHERE` clause can silently fail this. An observation that touches only
    // `item` re-emits on item writes alone; once the predicate references `download`, a
    // completing transfer must re-evaluate membership or the Downloaded filter goes stale.
    let fixture = try await FilterFixture()
    let itemRowId = try await fixture.book("book-1")

    let observations = PersistenceObservationCollector(
      fixture.reading.observeBrowseList(filters: BrowseFilters(downloadedOnly: true)))

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.unfilteredItemCount == 1 && $0.items.isEmpty }
      })
    var snapshot = try #require(
      observations.last { $0.unfilteredItemCount == 1 && $0.items.isEmpty })
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.unfilteredItemCount == 1)

    let downloadRowId = try await fixture.download(itemId: itemRowId, state: .completed)

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.items.map(\.serverItemId) == ["book-1"] }
      })
    snapshot = try #require(observations.last { $0.items.map(\.serverItemId) == ["book-1"] })
    #expect(snapshot.items.map(\.serverItemId) == ["book-1"])

    try await fixture.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM download WHERE id = ?", arguments: [downloadRowId])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.items.isEmpty && $0.unfilteredItemCount == 1 }
      })
    snapshot = try #require(
      observations.last { $0.items.isEmpty && $0.unfilteredItemCount == 1 })
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.unfilteredItemCount == 1, "the row still exists - it is filtered out, not gone")
  }

  @Test("an unplayed filter re-emits when finished progress is written and removed")
  func filteredBrowseReEmitsOnProgressWrites() async throws {
    let fixture = try await FilterFixture()
    let itemRowId = try await fixture.book("book-1")

    let observations = PersistenceObservationCollector(
      fixture.reading.observeBrowseList(filters: BrowseFilters(playback: .unfinished)))

    #expect(await TestSupport.waitUntil { observations.contains { $0.items.isEmpty == false } })
    var snapshot = try #require(observations.last { $0.items.isEmpty == false })
    #expect(snapshot.items.map(\.serverItemId) == ["book-1"])

    let progressRowId = try await fixture.progress(itemId: itemRowId, isFinished: true)

    #expect(await TestSupport.waitUntil { observations.contains { $0.items.isEmpty } })
    snapshot = try #require(observations.last { $0.items.isEmpty })
    #expect(snapshot.items.isEmpty)

    try await fixture.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM mediaProgress WHERE id = ?", arguments: [progressRowId])
    }

    #expect(await TestSupport.waitUntil { observations.contains { $0.items.isEmpty == false } })
    snapshot = try #require(observations.last { $0.items.isEmpty == false })
    #expect(snapshot.items.map(\.serverItemId) == ["book-1"])
  }

  @Test("byte-count and tick writes leave the snapshot equal, so removeDuplicates suppresses them")
  func nonMembershipStatusWritesLeaveTheSnapshotEqual() async throws {
    // The deterministic half of the deduplication requirement. `removeDuplicates` suppresses
    // re-emission only when the two snapshots compare equal, so a byte-count or tick write must
    // change nothing the snapshot carries. A projected field that tracked download bytes would
    // break this and silently restore per-tick invalidation.
    let fixture = try await FilterFixture()
    let itemRowId = try await fixture.book("book-1")
    let downloadRowId = try await fixture.download(itemId: itemRowId, state: .completed)
    let progressRowId = try await fixture.progress(itemId: itemRowId, isFinished: false)

    let before = try await fixture.snapshot(filters: BrowseFilters(downloadedOnly: true))

    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE download SET receivedBytes = receivedBytes + 1 WHERE id = ?",
        arguments: [downloadRowId])
      try db.execute(
        sql: "UPDATE mediaProgress SET currentTime = currentTime + 30 WHERE id = ?",
        arguments: [progressRowId])
    }

    #expect(try await fixture.snapshot(filters: BrowseFilters(downloadedOnly: true)) == before)
    // In Progress, not Unplayed: a position tick moves an item out of Unplayed the first time it
    // crosses zero, so Unplayed membership is not left alone by a tick.
    #expect(try await fixture.snapshot(filters: BrowseFilters(playback: .inProgress)) == before)
  }

  @Test("a received-byte-only write on a completed row does not push an equal snapshot through")
  func filteredBrowseDeduplicatesNonMembershipDownloadWrites() async throws {
    // Checks the observable outcome (no stale snapshot stranded by a byte tick), not the negative:
    // an in-memory `DatabaseQueue` finishes these commits before the reducer gets a turn, so GRDB
    // coalesces them into one fetch whether or not anything deduplicates, and proving "no
    // emission" needs a wait. `nonMembershipStatusWritesLeaveTheSnapshotEqual` covers the part
    // that fails deterministically.
    let fixture = try await FilterFixture()
    let itemRowId = try await fixture.book("book-1")
    let downloadRowId = try await fixture.download(itemId: itemRowId, state: .completed)

    let observations = PersistenceObservationCollector(
      fixture.reading.observeBrowseList(filters: BrowseFilters(downloadedOnly: true)))

    #expect(await TestSupport.waitUntil { observations.contains { $0.items.isEmpty == false } })
    let snapshot = try #require(observations.last { $0.items.isEmpty == false })
    #expect(snapshot.items.first?.title == "book-1")

    for _ in 0..<20 {
      try await fixture.database.writeAsync { db in
        try db.execute(
          sql: "UPDATE download SET receivedBytes = receivedBytes + 1 WHERE id = ?",
          arguments: [downloadRowId])
      }
    }
    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET title = ? WHERE id = ?", arguments: ["Sentinel", itemRowId])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.items.first?.title == "Sentinel" }
      })
    let next = try #require(observations.last { $0.items.first?.title == "Sentinel" })
    #expect(next.items.first?.title == "Sentinel")
  }

  @Test("a current-time-only progress write does not push an equal snapshot through")
  func filteredBrowseDeduplicatesNonMembershipProgressWrites() async throws {
    let fixture = try await FilterFixture()
    let itemRowId = try await fixture.book("book-1")
    let progressRowId = try await fixture.progress(itemId: itemRowId, isFinished: false)

    // The row is already part-listened, so every further tick below leaves this filter's
    // membership untouched. That is the property under test.
    let observations = PersistenceObservationCollector(
      fixture.reading.observeBrowseList(filters: BrowseFilters(playback: .inProgress)))

    #expect(await TestSupport.waitUntil { observations.contains { $0.items.isEmpty == false } })
    let snapshot = try #require(observations.last { $0.items.isEmpty == false })
    #expect(snapshot.items.first?.title == "book-1")

    // Separate transactions, so GRDB cannot coalesce the writes into one fetch.
    for _ in 0..<20 {
      try await fixture.database.writeAsync { db in
        try db.execute(
          sql: "UPDATE mediaProgress SET currentTime = currentTime + 30 WHERE id = ?",
          arguments: [progressRowId])
      }
    }
    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET title = ? WHERE id = ?", arguments: ["Sentinel", itemRowId])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.items.first?.title == "Sentinel" }
      })
    let next = try #require(observations.last { $0.items.first?.title == "Sentinel" })
    #expect(next.items.first?.title == "Sentinel")
  }

  @Test("the unfiltered filtered-overload is inert: identical rows, order, and a full count")
  func unfilteredFilterMatchesTheCategoryOverload() async throws {
    let fixture = try await FilterFixture()
    _ = try await fixture.book("beta")
    _ = try await fixture.book("alpha")
    _ = try await fixture.show("gamma")
    let deleted = try await fixture.book("deleted")
    try await fixture.softDelete(itemId: deleted)

    let viaCategory = try await Self.settled(
      fixture.reading.observeBrowseList(category: nil), count: 3)
    let snapshot = try await Self.settledSnapshot(
      fixture.reading.observeBrowseList(filters: .unfiltered), count: 3)

    #expect(snapshot.items.map(\.serverItemId) == viaCategory)
    #expect(snapshot.items.map(\.serverItemId) == ["alpha", "beta", "gamma"])
    #expect(snapshot.unfilteredItemCount == 3, "soft-deleted rows are in neither the rows nor the count")
    #expect(snapshot.hasUnfilteredItems)
  }

  @Test("each dimension alone narrows the list: category, downloaded, and the three playback states")
  func eachDimensionAloneNarrowsTheList() async throws {
    let fixture = try await FilterFixture()
    let audiobook = try await fixture.book("audio", numAudioFiles: 3)
    let ebook = try await fixture.book("ebook", numAudioFiles: 0, ebookFormat: "epub")
    let started = try await fixture.book("started")
    _ = try await fixture.show("pod")

    try await fixture.download(itemId: audiobook, state: .completed)
    try await fixture.progress(itemId: ebook, isFinished: true)
    try await fixture.progress(itemId: started, isFinished: false)

    #expect(
      try await Self.settledIDs(fixture.reading, BrowseFilters(categories: [.podcast]), count: 1)
        == ["pod"])
    #expect(
      try await Self.settledIDs(fixture.reading, BrowseFilters(downloadedOnly: true), count: 1)
        == ["audio"])
    #expect(
      try await Self.settledIDs(fixture.reading, BrowseFilters(playback: .finished), count: 1)
        == ["ebook"])
    #expect(
      try await Self.settledIDs(fixture.reading, BrowseFilters(playback: .inProgress), count: 1)
        == ["started"])
    // Only the untouched audiobook: the show is excluded from every engaged playback state, and
    // "Unplayed" excludes the part-listened row.
    #expect(
      try await Self.settledIDs(fixture.reading, BrowseFilters(playback: .unfinished), count: 1)
        == ["audio"])
  }

  /// A show cannot answer an item-scoped playback question (podcast progress is episode-keyed),
  /// so it answers none of them rather than passing Unplayed however much has been heard. The
  /// count is the other half: the screen must say "nothing matches this filter", never "your
  /// library is empty", so `unfilteredItemCount` keeps counting what the filter excluded.
  @Test("a podcast show leaves the list under any engaged playback state, but not the count")
  func podcastShowsAreExcludedFromEngagedPlaybackStates() async throws {
    let fixture = try await FilterFixture()
    _ = try await fixture.show("pod")

    for state in [PlaybackFilter.unfinished, .inProgress, .finished] {
      let snapshot = try await Self.settledSnapshot(
        fixture.reading.observeBrowseList(filters: BrowseFilters(playback: state)), count: 0)
      #expect(snapshot.items.isEmpty, "\(state) admitted a podcast show")
      #expect(snapshot.hasUnfilteredItems, "\(state) reported an empty library rather than an empty filter")
    }

    let unfiltered = try await Self.settledSnapshot(
      fixture.reading.observeBrowseList(filters: .unfiltered), count: 1)
    #expect(unfiltered.items.map(\.serverItemId) == ["pod"])
  }

  @Test("downloaded and unplayed combine - the offline-packing query an exclusive enum cannot express")
  func downloadedAndUnplayedCombine() async throws {
    let fixture = try await FilterFixture()

    let both = try await fixture.book("both")
    try await fixture.download(itemId: both, state: .completed)

    let downloadedButFinished = try await fixture.book("downloaded-finished")
    try await fixture.download(itemId: downloadedButFinished, state: .completed)
    try await fixture.progress(itemId: downloadedButFinished, isFinished: true)

    let unplayedButNotDownloaded = try await fixture.book("unplayed-only")
    try await fixture.progress(itemId: unplayedButNotDownloaded, isFinished: false)

    #expect(
      try await Self.settledIDs(
        fixture.reading, BrowseFilters(downloadedOnly: true, playback: .unfinished), count: 1)
        == ["both"])
  }

  @Test("multiple categories are ORed while the dimensions are ANDed, always in sortTitle order")
  func multipleCategoriesAreOredAndDimensionsAnded() async throws {
    let fixture = try await FilterFixture()
    let ebook = try await fixture.book("b-ebook", numAudioFiles: 0, ebookFormat: "epub")
    let show = try await fixture.show("a-pod")
    let audiobook = try await fixture.book("c-audio", numAudioFiles: 2)

    try await fixture.download(itemId: ebook, state: .completed, mediaKind: .ebook)
    for itemRowId in [show, audiobook] {
      try await fixture.download(itemId: itemRowId, state: .completed)
    }

    // ORed among themselves, in sortTitle order rather than the order the set iterates.
    #expect(
      try await Self.settledIDs(
        fixture.reading, BrowseFilters(categories: [.ebook, .podcast]), count: 2)
        == ["a-pod", "b-ebook"])

    // ANDed with the download dimension: dropping one item's download drops it from the result.
    try await fixture.database.writeAsync { db in
      try db.execute(sql: "UPDATE download SET state = 'downloading' WHERE itemId = ?", arguments: [show])
    }
    #expect(
      try await Self.settledIDs(
        fixture.reading, BrowseFilters(categories: [.ebook, .podcast], downloadedOnly: true),
        count: 1) == ["b-ebook"])
  }

  @Test("a filter matching nothing yields no rows and a non-zero unfiltered count, not an error")
  func filterMatchingNothingYieldsAnEmptyListAndANonZeroCount() async throws {
    let fixture = try await FilterFixture()
    _ = try await fixture.book("book-1")
    _ = try await fixture.book("book-2")

    let snapshot = try await Self.settledSnapshot(
      fixture.reading.observeBrowseList(filters: BrowseFilters(downloadedOnly: true)),
      unfilteredCount: 2)

    #expect(snapshot.items.isEmpty)
    #expect(snapshot.unfilteredItemCount == 2)
    #expect(snapshot.hasUnfilteredItems, "the caller can tell 'filtered to nothing' from 'no library'")
  }

  @Test("a genuinely empty library reports no rows and no unfiltered items")
  func genuinelyEmptyLibraryReportsNoUnfilteredItems() async throws {
    let fixture = try await FilterFixture()

    var iterator = fixture.reading.observeBrowseList(filters: .unfiltered).makeAsyncIterator()
    let snapshot = try #require(await iterator.next())

    #expect(snapshot.items.isEmpty)
    #expect(snapshot.unfilteredItemCount == 0)
    #expect(snapshot.hasUnfilteredItems == false)
  }

  @Test("the Library's downloaded scope surfaces a podcast show whose episode downloads are complete")
  func downloadedScopeSurfacesShowsWithCompletedEpisodeDownloads() async throws {
    // The Library uses Home's library-entry scope, not Search's item-only scope. Podcast
    // downloads are episode-keyed, so the item-only scope would return no shows and a
    // `Podcasts + Downloaded` view would always be empty.
    let fixture = try await FilterFixture()
    let show = try await fixture.show("show")
    let episode = try await fixture.episode(itemId: show, serverEpisodeId: "ep1")
    try await fixture.download(itemId: show, podcastEpisodeId: episode, state: .completed)

    #expect(
      try await Self.settledIDs(
        fixture.reading, BrowseFilters(categories: [.podcast], downloadedOnly: true), count: 1)
        == ["show"])
  }
}
