import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

/// `HomeReading`'s three account-scoped, cross-library projections: continue listening, recently
/// added, downloaded. GRDB `ValueObservation` is bridged to `AsyncStream`, so only plain
/// `HomeItem` values cross the boundary.
@Suite(.timeLimit(.minutes(1))) struct HomeReadingTests {

  // MARK: - Continue reading

  @Test("continue reading orders EPUB progress by server update, falls back to local sequence, and limits")
  func continueReadingOrdersFiltersAndLimits() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let serverOlder = try itemDAO.upsert(
      HomeReadingFixtures.ebook(accountId: accountId, libraryId: libraryRowId, serverItemId: "server-older"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(serverOlder.id), currentTime: 0,
      ebookProgress: 0.2, isFinished: false, localSequence: 100,
      serverUpdatedAt: Date(timeIntervalSince1970: 1_000))

    let serverNewer = try itemDAO.upsert(
      HomeReadingFixtures.ebook(accountId: accountId, libraryId: libraryRowId, serverItemId: "server-newer"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(serverNewer.id), currentTime: 0,
      ebookProgress: 0.3, isFinished: false, localSequence: 1,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    let fallbackLow = try itemDAO.upsert(
      HomeReadingFixtures.ebook(accountId: accountId, libraryId: libraryRowId, serverItemId: "fallback-low"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(fallbackLow.id), currentTime: 0,
      ebookProgress: 0.4, isFinished: false, localSequence: 2)

    let fallbackHigh = try itemDAO.upsert(
      HomeReadingFixtures.ebook(accountId: accountId, libraryId: libraryRowId, serverItemId: "fallback-high"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(fallbackHigh.id), currentTime: 0,
      ebookProgress: 0.5, isFinished: false, localSequence: 3)

    var iterator = reading.observeContinueReading(category: nil, limit: 3).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["server-newer", "server-older", "fallback-high"])

    var limited = reading.observeContinueReading(category: nil, limit: 1).makeAsyncIterator()
    #expect(try #require(await limited.next()).map(\.serverItemId) == ["server-newer"])
  }

  @Test("continue reading includes ebooks and bundled EPUB audiobooks but excludes podcasts")
  func continueReadingIncludesEPUBCategoriesAndExcludesPodcasts() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let ebook = try itemDAO.upsert(
      HomeReadingFixtures.ebook(accountId: accountId, libraryId: libraryRowId, serverItemId: "ebook"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(ebook.id), currentTime: 0,
      ebookProgress: 0.25, isFinished: false, localSequence: 1)

    var bundled = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "bundled")
    bundled.ebookFormat = "epub"
    let bundledRow = try itemDAO.upsert(bundled)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(bundledRow.id), currentTime: 0,
      ebookProgress: 0.5, isFinished: false, localSequence: 2)

    var pdfSidecar = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "pdf-sidecar")
    pdfSidecar.ebookFormat = "pdf"
    let pdfSidecarRow = try itemDAO.upsert(pdfSidecar)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(pdfSidecarRow.id), currentTime: 0,
      ebookProgress: 0.6, isFinished: false, localSequence: 3)

    var podcast = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast")
    podcast.ebookFormat = "epub"
    let podcastRow = try itemDAO.upsert(podcast)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(podcastRow.id), currentTime: 0,
      ebookProgress: 0.75, isFinished: false, localSequence: 4)

    var iterator = reading.observeContinueReading(category: nil, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["bundled", "ebook"])
    #expect(result.map(\.category) == [.audiobook, .ebook])
    #expect(result.map(\.hasReadableEbook) == [true, true])
  }

  @Test("ebook Home filters include mixed items while Continue Listening stays identity-strict")
  func ebookHomeFiltersIncludeMixedItemsExceptContinueListening() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var mixed = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "mixed")
    mixed.ebookFormat = "epub"
    mixed.addedAt = Date(timeIntervalSince1970: 1_000)
    let mixedRow = try itemDAO.upsert(mixed)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(mixedRow.id), currentTime: 0,
      ebookProgress: 0.25, isFinished: false, localSequence: 1)
    try HomeReadingFixtures.completeDownload(
      downloadStore, accountId: accountId, itemId: try #require(mixedRow.id))

    var pdfSidecar = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "pdf-sidecar")
    pdfSidecar.ebookFormat = "pdf"
    pdfSidecar.addedAt = Date(timeIntervalSince1970: 2_000)
    let pdfSidecarRow = try itemDAO.upsert(pdfSidecar)
    try HomeReadingFixtures.completeDownload(
      downloadStore, accountId: accountId, itemId: try #require(pdfSidecarRow.id))

    var readingIterator = reading.observeContinueReading(category: .ebook, limit: 10).makeAsyncIterator()
    #expect(try #require(await readingIterator.next()).map(\.serverItemId) == ["mixed"])

    var recentIterator = reading.observeRecentlyAdded(category: .ebook, limit: 10).makeAsyncIterator()
    #expect(try #require(await recentIterator.next()).map(\.serverItemId) == ["mixed"])

    var downloadedIterator = reading.observeDownloaded(category: .ebook, limit: 10).makeAsyncIterator()
    #expect(try #require(await downloadedIterator.next()).map(\.serverItemId) == ["mixed"])

    var listeningOnly = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "listening-only")
    listeningOnly.ebookFormat = "epub"
    let listeningRow = try itemDAO.upsert(listeningOnly)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(listeningRow.id), currentTime: 120,
      ebookProgress: nil, isFinished: false, localSequence: 2)

    var listeningIterator = reading.observeContinueListening(category: .ebook, limit: 10).makeAsyncIterator()
    #expect(try #require(await listeningIterator.next()).isEmpty)
  }

  @Test("continue reading and continue listening keep audio-only and ebook-only progress separate")
  func readingAndListeningUseTheirOwnProgressFields() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let audioOnly = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "audio-only"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(audioOnly.id), currentTime: 120,
      ebookProgress: nil, isFinished: false, localSequence: 1)

    let ebookOnly = try itemDAO.upsert(
      HomeReadingFixtures.ebook(accountId: accountId, libraryId: libraryRowId, serverItemId: "ebook-only"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(ebookOnly.id), currentTime: 0,
      ebookProgress: 0.2, isFinished: false, localSequence: 2)

    var listeningIterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await listeningIterator.next()).map(\.serverItemId) == ["audio-only"])
    var readingIterator = reading.observeContinueReading(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await readingIterator.next()).map(\.serverItemId) == ["ebook-only"])
  }

  @Test("a finished bundled EPUB audiobook leaves both continuation shelves")
  func finishedBundledEPUBLeavesBothShelves() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var bundled = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "finished-bundled")
    bundled.ebookFormat = "epub"
    let row = try itemDAO.upsert(bundled)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(row.id), currentTime: 1_800,
      ebookProgress: 1, isFinished: true, localSequence: 1)

    var readingIterator = reading.observeContinueReading(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await readingIterator.next()).isEmpty)
    var listeningIterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await listeningIterator.next()).isEmpty)
  }

  @Test("adding Continue Reading does not change existing Home projections")
  func existingHomeProjectionsRemainValueEquivalent() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let item = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "existing"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(item.id), currentTime: 120,
      isFinished: false, localSequence: 4)
    try HomeReadingFixtures.completeDownload(downloadStore, accountId: accountId, itemId: try #require(item.id))

    let expected = HomeItem(
      serverItemId: "existing", title: "existing", author: nil, category: .audiobook,
      durationSeconds: nil, progressSeconds: 120, isFinished: false, addedAt: nil,
      isDownloaded: true, audioDownloaded: true)
    let expectedListening = HomeItem(
      serverItemId: "existing", title: "existing", author: nil, category: .audiobook,
      durationSeconds: nil, progressSeconds: 120, isFinished: false, addedAt: nil,
      isDownloaded: true, audioDownloaded: true,
      progressRecency: HomeReadingFixtures.activityStamp(for: 4))
    var listeningIterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await listeningIterator.next()) == [expectedListening])
    var recentIterator = reading.observeRecentlyAdded(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await recentIterator.next()) == [expected])
    var downloadedIterator = reading.observeDownloaded(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await downloadedIterator.next()) == [expected])
  }

  /// One stream per test: five concurrent ValueObservations on a single in-memory DatabaseQueue
  /// deadlock the suite under test parallelism, so each stream proves its dedup in isolation.
  @Test("Home rows carry the item's server updatedAt as the cover revision source")
  func homeRowsCarryServerUpdatedAt() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    var item = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "item-1")
    item.addedAt = now.addingTimeInterval(-86_400)
    item.serverUpdatedAt = updatedAt
    let itemID = try #require(try itemDAO.upsert(item).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: itemID, currentTime: 120,
      isFinished: false, localSequence: 1)

    var listening = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    let listeningRows = try #require(await listening.next())
    let listeningRow = try #require(listeningRows.first)
    var added =
      reading
      .observeRecentlyAdded(category: .audiobook, limit: 10, since: now.addingTimeInterval(-7 * 86_400))
      .makeAsyncIterator()
    let addedRows = try #require(await added.next())
    let addedRow = try #require(addedRows.first)

    #expect(listeningRow.serverUpdatedAt == updatedAt)
    #expect(listeningRow.itemSummary.serverUpdatedAt == updatedAt)
    #expect(addedRow.serverUpdatedAt == updatedAt)
  }

  @Test("continue listening suppresses equivalent snapshots but emits changed ones")
  func continueListeningSuppressesEquivalentSnapshots() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var item = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "item-1")
    item.title = "Initial"
    let itemID = try #require(try itemDAO.upsert(item).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: itemID, currentTime: 120,
      isFinished: false, localSequence: 1)

    let observations = PersistenceObservationCollector(
      reading.observeContinueListening(category: nil, limit: 10))
    #expect(await TestSupport.waitUntil { observations.values.count == 1 })

    try await HomeReadingFixtures.commitUntrackedFieldChange(database, accountId: accountId)
    try await HomeReadingFixtures.commitTitleChange(database, itemId: itemID)

    #expect(await TestSupport.waitUntil { observations.contains { $0.first?.title == "Changed" } })
    #expect(observations.values.count == 2)
  }

  @Test("continue reading suppresses equivalent snapshots but emits changed ones")
  func continueReadingSuppressesEquivalentSnapshots() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var item = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "item-1")
    item.title = "Initial"
    item.ebookFormat = "epub"
    let itemID = try #require(try itemDAO.upsert(item).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: itemID, currentTime: 0,
      ebookProgress: 0.2, isFinished: false, localSequence: 1)

    let observations = PersistenceObservationCollector(
      reading.observeContinueReading(category: nil, limit: 10))
    #expect(await TestSupport.waitUntil { observations.values.count == 1 })

    try await HomeReadingFixtures.commitUntrackedFieldChange(database, accountId: accountId)
    try await HomeReadingFixtures.commitTitleChange(database, itemId: itemID)

    #expect(await TestSupport.waitUntil { observations.contains { $0.first?.title == "Changed" } })
    #expect(observations.values.count == 2)
  }

  @Test("continue series suppresses equivalent snapshots but emits changed ones")
  func continueSeriesSuppressesEquivalentSnapshots() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var predecessor = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "series-1")
    predecessor.seriesName = "Home Series #1"
    let predecessorID = try #require(try itemDAO.upsert(predecessor).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: predecessorID, currentTime: 1_800,
      isFinished: true, localSequence: 1)
    var nextBook = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "series-2")
    nextBook.title = "Initial"
    nextBook.seriesName = "Home Series #2"
    let nextBookID = try #require(try itemDAO.upsert(nextBook).id)

    let observations = PersistenceObservationCollector(
      reading.observeContinueSeries(category: nil, limit: 10))
    #expect(await TestSupport.waitUntil { observations.values.count == 1 })

    try await HomeReadingFixtures.commitUntrackedFieldChange(database, accountId: accountId)
    try await HomeReadingFixtures.commitTitleChange(database, itemId: nextBookID)

    #expect(await TestSupport.waitUntil { observations.contains { $0.first?.title == "Changed" } })
    #expect(observations.values.count == 2)
  }

  @Test("recently added suppresses equivalent snapshots but emits changed ones")
  func recentlyAddedSuppressesEquivalentSnapshots() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var item = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "item-1")
    item.title = "Initial"
    item.addedAt = Date(timeIntervalSince1970: 2_000)
    let itemID = try #require(try itemDAO.upsert(item).id)

    let observations = PersistenceObservationCollector(
      reading.observeRecentlyAdded(category: nil, limit: 10))
    #expect(await TestSupport.waitUntil { observations.values.count == 1 })

    try await HomeReadingFixtures.commitUntrackedFieldChange(database, accountId: accountId)
    try await HomeReadingFixtures.commitTitleChange(database, itemId: itemID)

    #expect(await TestSupport.waitUntil { observations.contains { $0.first?.title == "Changed" } })
    #expect(observations.values.count == 2)
  }

  @Test("downloaded suppresses equivalent snapshots but emits changed ones")
  func downloadedSuppressesEquivalentSnapshots() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var item = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "item-1")
    item.title = "Initial"
    let itemID = try #require(try itemDAO.upsert(item).id)
    try HomeReadingFixtures.completeDownload(downloadStore, accountId: accountId, itemId: itemID)

    let observations = PersistenceObservationCollector(
      reading.observeDownloaded(category: nil, limit: 10))
    #expect(await TestSupport.waitUntil { observations.values.count == 1 })

    try await HomeReadingFixtures.commitUntrackedFieldChange(database, accountId: accountId)
    try await HomeReadingFixtures.commitTitleChange(database, itemId: itemID)

    #expect(await TestSupport.waitUntil { observations.contains { $0.first?.title == "Changed" } })
    #expect(observations.values.count == 2)
  }

  // MARK: - Continue listening

  @Test("continue listening returns in-progress, unfinished items, most-recently-progressed first")
  func continueListeningOrdersByLocalSequenceDescending() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let started = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "started"))
    let finished = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "finished"))
    let neverStarted = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "never-started"))
    let olderProgress = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "older-progress"))

    var iterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    let initial = try #require(await iterator.next())
    #expect(initial.isEmpty)

    // Older progress first (lower localSequence), then the more recently progressed item.
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(olderProgress.id), currentTime: 30,
      isFinished: false, localSequence: 1)
    _ = try #require(await iterator.next())

    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(started.id), currentTime: 120,
      isFinished: false, localSequence: 2)
    let afterStarted = try #require(await iterator.next())
    #expect(afterStarted.map(\.serverItemId) == ["started", "older-progress"])

    // Finished and never-started items never appear.
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(finished.id), currentTime: 500,
      isFinished: true, localSequence: 3)
    _ = try itemDAO.upsert(neverStarted)
    // Neither write changes Continue Listening: the finished item was already absent and the
    // never-started item still has no progress. Do not await an emission for either commit.
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(started.id), currentTime: 180,
      isFinished: false, localSequence: 4)
    let afterProgressChange = try #require(await iterator.next())
    #expect(afterProgressChange.map(\.serverItemId).sorted() == ["older-progress", "started"])
    #expect(afterProgressChange.first(where: { $0.serverItemId == "started" })?.progressSeconds == 180)
  }

  @Test("continue listening orders server progress by the item last listened")
  func continueListeningOrdersByServerUpdatedAtDescending() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let alphabeticallyFirst = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "alpha"))
    let listenedLast = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "zulu"))

    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(alphabeticallyFirst.id), currentTime: 30,
      isFinished: false, localSequence: 0,
      serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(listenedLast.id), currentTime: 60,
      isFinished: false, localSequence: 0,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    var iterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())

    #expect(result.map(\.serverItemId) == ["zulu", "alpha"])
  }

  /// The carousel is ordered by listening, and listening is a local event: a tick never reaches
  /// the server before the row is redrawn, and the pull that follows keeps the local value and so
  /// writes no `serverUpdatedAt`. Ordering has to follow the local `lastActivityAt` stamp, or the
  /// item being played right now never moves to the front.
  @Test("continue listening puts the item played most recently first")
  func continueListeningOrdersByMostRecentLocalPlayback() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let outbox = try OutboxStore(database: database)
    let sessions = PlaybackSessionStore(database: database, outbox: outbox)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let staleServerNewest = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "server-newest"))
    let playedNow = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "played-now"))

    // The item the reader is not touching carries both the newest server timestamp and the
    // higher per-row edit counter, so ordering by either would put it first.
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(staleServerNewest.id), currentTime: 30,
      isFinished: false, localSequence: 40,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      lastActivityAt: Date(timeIntervalSince1970: 2_000))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(playedNow.id), currentTime: 60,
      isFinished: false, localSequence: 1,
      serverUpdatedAt: Date(timeIntervalSince1970: 1_000),
      lastActivityAt: Date(timeIntervalSince1970: 1_000))

    var iterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await iterator.next()).map(\.serverItemId) == ["server-newest", "played-now"])

    _ = try sessions.recordSessionlessTick(
      accountId: accountId, itemId: try #require(playedNow.id), podcastEpisodeId: nil,
      serverItemId: "played-now",
      tick: PlaybackTick(
        globalPosition: 90, isFinished: false, deltaSecondsSinceLastTick: 30, localSequence: 2,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 3_000)))

    #expect(try #require(await iterator.next()).map(\.serverItemId) == ["played-now", "server-newest"])
  }

  @Test("continue listening re-emits when progress changes")
  func continueListeningReemitsWhenProgressChanges() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    let item = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "item1"))

    var iterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    _ = try #require(await iterator.next())

    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(item.id), currentTime: 10,
      isFinished: false, localSequence: 1)
    let afterFirstProgress = try #require(await iterator.next())
    #expect(afterFirstProgress.first?.progressSeconds == 10)

    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(item.id), currentTime: 40,
      isFinished: false, localSequence: 2)
    let afterSecondProgress = try #require(await iterator.next())
    #expect(afterSecondProgress.first?.progressSeconds == 40)
  }

  @Test("continue listening excludes known-duration audio with under one minute remaining")
  func continueListeningUsesOneMinuteRemainingBoundary() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var underOneMinute = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "under-one-minute")
    underOneMinute.durationSeconds = 600
    let underOneMinuteID = try #require(try itemDAO.upsert(underOneMinute).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: underOneMinuteID, currentTime: 541,
      isFinished: false, localSequence: 4)

    var exactlyOneMinute = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "exactly-one-minute")
    exactlyOneMinute.durationSeconds = 600
    let exactlyOneMinuteID = try #require(try itemDAO.upsert(exactlyOneMinute).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: exactlyOneMinuteID, currentTime: 540,
      isFinished: false, localSequence: 3)

    var beyondDuration = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "beyond-duration")
    beyondDuration.durationSeconds = 600
    let beyondDurationID = try #require(try itemDAO.upsert(beyondDuration).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: beyondDurationID, currentTime: 601,
      isFinished: false, localSequence: 2)

    let unknownDuration = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "unknown-duration"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(unknownDuration.id), currentTime: 120,
      isFinished: false, localSequence: 1)

    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast-under-one-minute")
    show.title = "Podcast"
    let showID = try #require(try itemDAO.upsert(show).id)
    let episodeID = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showID, serverEpisodeID: "episode-1",
      title: "Episode", durationSeconds: 1_800)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: showID, episodeId: episodeID,
      currentTime: 1_741, isFinished: false, localSequence: 5)

    let exactPodcast = try itemDAO.upsert(
      HomeReadingFixtures.podcast(
        accountId: accountId, libraryId: libraryRowId,
        serverItemId: "podcast-exactly-one-minute"))
    let exactEpisodeID = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(exactPodcast.id),
      serverEpisodeID: "episode-exact", title: "Exact", durationSeconds: 1_800)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(exactPodcast.id),
      episodeId: exactEpisodeID, currentTime: 1_740, isFinished: false, localSequence: 6)

    let unknownPodcast = try itemDAO.upsert(
      HomeReadingFixtures.podcast(
        accountId: accountId, libraryId: libraryRowId,
        serverItemId: "podcast-unknown-duration"))
    let unknownEpisodeID = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(unknownPodcast.id),
      serverEpisodeID: "episode-unknown", title: "Unknown", durationSeconds: nil)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(unknownPodcast.id),
      episodeId: unknownEpisodeID, currentTime: 120, isFinished: false, localSequence: 7)

    var iterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())

    #expect(
      result.map(\.serverItemId) == [
        "podcast-unknown-duration", "podcast-exactly-one-minute", "exactly-one-minute",
        "unknown-duration",
      ])
  }

  @Test("continue listening excludes server-hidden progress and local playback makes it visible again")
  func continueListeningHonorsAndClearsServerHiddenState() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let outbox = try OutboxStore(database: database)
    let sessions = PlaybackSessionStore(database: database, outbox: outbox)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var item = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "hidden-book")
    item.durationSeconds = 600
    let itemID = try #require(try itemDAO.upsert(item).id)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: itemID, currentTime: 120,
      isFinished: false, localSequence: 1)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE mediaProgress SET hideFromContinueListening = 1 WHERE itemId = ?",
        arguments: [itemID])
    }

    var iterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await iterator.next()).isEmpty)

    _ = try sessions.recordSessionlessTick(
      accountId: accountId, itemId: itemID, podcastEpisodeId: nil, serverItemId: "hidden-book",
      tick: PlaybackTick(
        globalPosition: 180, isFinished: false, deltaSecondsSinceLastTick: 60, localSequence: 2,
        originKey: "client-uuid", segmentKey: "segment-1",
        now: Date(timeIntervalSince1970: 2)))

    let visible = try #require(await iterator.next())
    #expect(visible.map(\.serverItemId) == ["hidden-book"])
    #expect(
      try database.read { db in
        try Bool.fetchOne(
          db, sql: "SELECT hideFromContinueListening FROM mediaProgress WHERE itemId = ?",
          arguments: [itemID])
      } == false)
  }

  @Test("Home projections resolve download state without a per-row SELECT")
  func homeProjectionAvoidsDownloadStateNPlusOne() async throws {
    let database = try AppDatabase.inMemory()
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    for index in 0..<4 {
      var item = HomeReadingFixtures.audiobook(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "item-\(index)")
      item.addedAt = Date(timeIntervalSince1970: Double(index + 1))
      _ = try itemDAO.upsert(item)
    }

    let statements = Mutex<[String]>([])
    let expandedStatements = Mutex<[String]>([])
    try await database.writeAsync { db in
      db.trace { event in
        guard case .statement(let statement) = event else { return }
        statements.withLock { $0.append(statement.sql) }
        expandedStatements.withLock { $0.append(statement.expandedSQL) }
      }
    }

    let reading = DefaultHomeReading(database: database)
    var iterator = reading.observeRecentlyAdded(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await iterator.next()).count == 4)

    let perRowDownloadQueries = statements.withLock {
      $0.filter { $0.contains("SELECT state FROM download WHERE itemId = ?") }.count
    }
    #expect(perRowDownloadQueries == 0)

    let projectionSQL = try #require(
      expandedStatements.withLock {
        $0.first { $0.contains("item.addedAt AS addedAt") && $0.contains("AS isDownloaded") }
      })
    let plan = try database.read { db in
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(projectionSQL)")
        .map { $0["detail"] as String }
    }
    #expect(
      plan.contains {
        $0.contains("CORRELATED SCALAR SUBQUERY") && $0.localizedCaseInsensitiveContains("download")
      } == false,
      "download completeness should be aggregated once, not rescanned for every Home row")
  }

  @Test("continue listening filters by category in SQL before the limit is applied")
  func continueListeningFiltersByCategoryBeforeLimit() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    // Three audiobooks progress more recently than the one podcast, so an unfiltered top-1 by
    // localSequence would never include the podcast, which proves the filter runs before the limit.
    let podcast = try itemDAO.upsert(
      HomeReadingFixtures.podcast(accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast-1"))
    let episodeID = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(podcast.id),
      serverEpisodeID: "episode-1", title: "Episode 1", durationSeconds: 1_800)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(podcast.id), episodeId: episodeID,
      currentTime: 10, isFinished: false, localSequence: 1)
    for index in 0..<3 {
      let book = try itemDAO.upsert(
        HomeReadingFixtures.audiobook(
          accountId: accountId, libraryId: libraryRowId, serverItemId: "book-\(index)"))
      try await HomeReadingFixtures.writeProgress(
        database, accountId: accountId, itemId: try #require(book.id), currentTime: 10,
        isFinished: false, localSequence: Int64(index) + 2)
    }

    var iterator =
      reading.observeContinueListening(category: .podcast, limit: 1).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["podcast-1"])
    #expect(result.first?.episodeID == "episode-1")
  }

  @Test("podcast continuation selects each show's most recently sequenced unfinished episode")
  func podcastContinuationSelectsLatestUnfinishedEpisodePerShow() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var firstShow = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "show-1")
    firstShow.title = "First Show"
    firstShow.author = "First Host"
    let firstShowRow = try itemDAO.upsert(firstShow)
    let olderEpisode = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(firstShowRow.id),
      serverEpisodeID: "older", title: "Older Episode", durationSeconds: 1_200)
    let newestFinishedEpisode = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(firstShowRow.id),
      serverEpisodeID: "newest-finished", title: "Newest Finished", durationSeconds: 1_800)
    let selectedEpisode = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(firstShowRow.id),
      serverEpisodeID: "selected", title: "Selected Episode", durationSeconds: 2_400)

    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(firstShowRow.id),
      episodeId: olderEpisode, currentTime: 120, isFinished: false, localSequence: 2)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(firstShowRow.id),
      episodeId: newestFinishedEpisode, currentTime: 1_800, isFinished: true, localSequence: 9)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(firstShowRow.id),
      episodeId: selectedEpisode, currentTime: 600, isFinished: false, localSequence: 7)

    let secondShow = try itemDAO.upsert(
      HomeReadingFixtures.podcast(accountId: accountId, libraryId: libraryRowId, serverItemId: "show-2"))
    let secondEpisode = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(secondShow.id),
      serverEpisodeID: "second-show-episode", title: "Second Show Episode",
      durationSeconds: 3_000)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(secondShow.id),
      episodeId: secondEpisode, currentTime: 300, isFinished: false, localSequence: 8)

    var iterator = reading.observeContinueListening(category: .podcast, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())

    #expect(result.map(\.serverItemId) == ["show-2", "show-1"])
    #expect(result.map(\.episodeID) == ["second-show-episode", "selected"])
    #expect(result.map(\.episodeTitle) == ["Second Show Episode", "Selected Episode"])
    #expect(result[1].title == "First Show")
    #expect(result[1].author == "First Host")
    #expect(result[1].durationSeconds == 2_400)
    #expect(result[1].progressSeconds == 600)
    #expect(result[1].isFinished == false)
  }

  @Test("audiobook continuation retains item progress and carries no episode identity")
  func audiobookContinuationRetainsItemProgress() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var book = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "book")
    book.title = "Book Title"
    book.durationSeconds = 7_200
    let stored = try itemDAO.upsert(book)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(stored.id), currentTime: 900,
      isFinished: false, localSequence: 3)

    var iterator = reading.observeContinueListening(category: .audiobook, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())
    let projected = try #require(result.first)

    #expect(projected.title == "Book Title")
    #expect(projected.durationSeconds == 7_200)
    #expect(projected.progressSeconds == 900)
    #expect(projected.episodeID == nil)
    #expect(projected.episodeTitle == nil)
  }

  /// Pins the consequence of `AND item.mediaKind <> 'podcast'` on the item-level Continue
  /// Listening branch: a podcast with only legacy item-level progress (no episode row for the
  /// episode-aware branch to select) is absent from Continue Listening. The audiobook control with
  /// identical item-level progress must still appear, and the same podcast row is present and
  /// projectable through Recently Added.
  @Test("a podcast with only legacy item-level progress is excluded from continue listening")
  func podcastWithOnlyItemLevelProgressIsExcludedFromContinueListening() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var legacyShow = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast-legacy")
    legacyShow.title = "Legacy Show"
    legacyShow.addedAt = Date(timeIntervalSince1970: 3_000)
    let storedShow = try itemDAO.upsert(legacyShow)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(storedShow.id), currentTime: 300,
      isFinished: false, localSequence: 5)

    let book = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "book"))
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(book.id), currentTime: 300,
      isFinished: false, localSequence: 4)

    var iterator = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    let continueListening = try #require(await iterator.next())
    #expect(continueListening.map(\.serverItemId) == ["book"])

    var podcastIterator =
      reading.observeContinueListening(category: .podcast, limit: 10).makeAsyncIterator()
    #expect(try #require(await podcastIterator.next()).isEmpty)

    // The exclusion is the media-kind predicate, not a missing fixture: Recently Added joins and
    // projects the same item-level progress row.
    var addedIterator =
      reading.observeRecentlyAdded(category: .podcast, limit: 10).makeAsyncIterator()
    let added = try #require(await addedIterator.next())
    #expect(added.map(\.serverItemId) == ["podcast-legacy"])
    #expect(added.first?.progressSeconds == 300)
  }

  // MARK: - Recently added

  @Test("recent podcast episodes are scoped to the seven-day cutoff and include show context")
  func recentPodcastEpisodesUsePublishedAtCutoff() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "show-1")
    show.title = "Signal House"
    show.author = "Host"
    show.serverUpdatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let storedShow = try itemDAO.upsert(show)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
    let newEpisode = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(storedShow.id),
      serverEpisodeID: "new", title: "The New One", durationSeconds: 1_200,
      publishedAt: now.addingTimeInterval(-86_400))
    _ = newEpisode
    _ = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(storedShow.id),
      serverEpisodeID: "old", title: "The Old One", durationSeconds: 1_200,
      publishedAt: cutoff.addingTimeInterval(-1))

    var iterator =
      reading.observeNewPodcastEpisodes(cutoff: { cutoff }, limit: 10).makeAsyncIterator()
    let episodes = try #require(await iterator.next())

    #expect(episodes.map(\.episodeID) == ["new"])
    #expect(episodes.first?.itemID == "show-1")
    #expect(episodes.first?.showTitle == "Signal House")
    #expect(episodes.first?.showAuthor == "Host")
    #expect(episodes.first?.showServerUpdatedAt == Date(timeIntervalSince1970: 1_790_000_000))
  }

  /// Latest episodes is a queue of what is left to listen to, not an archive of what was published:
  /// marking an episode finished takes it out of the list. Part-played and untouched episodes both
  /// stay, so an episode with real audio left is not lost by pausing partway through it.
  @Test("Home's item and episode projections floor playback position to the minute")
  func homeProjectionsFloorPlaybackPosition() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var book = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "book")
    book.durationSeconds = 7_200
    let storedBook = try itemDAO.upsert(book)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(storedBook.id), currentTime: 930.5,
      isFinished: false, localSequence: 1)
    let storedShow = try itemDAO.upsert(
      HomeReadingFixtures.podcast(accountId: accountId, libraryId: libraryRowId, serverItemId: "show"))
    let showId = try #require(storedShow.id)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cutoff = now.addingTimeInterval(-7 * 86_400)
    let episodeId = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeID: "playing",
      title: "Playing", durationSeconds: 1_800, publishedAt: now.addingTimeInterval(-86_400))
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: showId, episodeId: episodeId, currentTime: 754.3,
      isFinished: false, localSequence: 1)

    var continueIterator =
      reading.observeContinueListening(category: .audiobook, limit: 10).makeAsyncIterator()
    #expect(try #require(await continueIterator.next()).first?.progressSeconds == 900)
    var episodeIterator =
      reading.observeNewPodcastEpisodes(cutoff: { cutoff }, limit: 10).makeAsyncIterator()
    #expect(try #require(await episodeIterator.next()).first?.progressSeconds == 720)
  }

  @Test("finished episodes drop out of the latest-episodes projection")
  func recentPodcastEpisodesExcludeFinishedOnes() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "show-1")
    show.title = "Signal House"
    let storedShow = try itemDAO.upsert(show)
    let showId = try #require(storedShow.id)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cutoff = now.addingTimeInterval(-7 * 86_400)
    let finishedId = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeID: "finished",
      title: "Heard It", durationSeconds: 1_800, publishedAt: now.addingTimeInterval(-86_400))
    let partPlayedId = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeID: "part-played",
      title: "Halfway", durationSeconds: 1_800, publishedAt: now.addingTimeInterval(-2 * 86_400))
    _ = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeID: "fresh",
      title: "Not Started", durationSeconds: 1_800, publishedAt: now.addingTimeInterval(-3 * 86_400))
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: showId, episodeId: partPlayedId, currentTime: 900,
      isFinished: false, localSequence: 1)

    var iterator =
      reading.observeNewPodcastEpisodes(cutoff: { cutoff }, limit: 10).makeAsyncIterator()
    #expect(
      try #require(await iterator.next()).map(\.episodeID) == ["finished", "part-played", "fresh"])

    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: showId, episodeId: finishedId, currentTime: 1_800,
      isFinished: true, localSequence: 1)

    let remaining = try #require(await iterator.next())
    #expect(remaining.map(\.episodeID) == ["part-played", "fresh"])
    #expect(remaining.map(\.progressSeconds) == [900, 0])
  }

  /// Same product policy Continue Listening applies: trailing audio below one minute is adverts,
  /// credits or silence, so an episode inside its final minute is done and leaves the queue. The
  /// two shelves have to agree: an episode hidden from one and left in the other is what a sleep
  /// timer expiring at the end of an episode would produce.
  @Test("episodes inside their final minute drop out of the latest-episodes projection")
  func recentPodcastEpisodesExcludeNearlyFinishedOnes() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "show-1")
    show.title = "Signal House"
    let storedShow = try itemDAO.upsert(show)
    let showId = try #require(storedShow.id)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cutoff = now.addingTimeInterval(-7 * 86_400)
    let trailingId = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeID: "trailing",
      title: "Only Adverts Left", durationSeconds: 1_800, publishedAt: now.addingTimeInterval(-86_400))
    let remainingId = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeID: "remaining",
      title: "Still Has Audio", durationSeconds: 1_800,
      publishedAt: now.addingTimeInterval(-2 * 86_400))
    // No declared duration: "how much is left" is unanswerable, so the episode must stay.
    let unknownId = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeID: "unknown",
      title: "No Duration", durationSeconds: nil, publishedAt: now.addingTimeInterval(-3 * 86_400))
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: showId, episodeId: trailingId, currentTime: 1_759,
      isFinished: false, localSequence: 1)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: showId, episodeId: remainingId, currentTime: 1_740,
      isFinished: false, localSequence: 1)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: showId, episodeId: unknownId, currentTime: 1_799,
      isFinished: false, localSequence: 1)

    var iterator =
      reading.observeNewPodcastEpisodes(cutoff: { cutoff }, limit: 10).makeAsyncIterator()

    #expect(try #require(await iterator.next()).map(\.episodeID) == ["remaining", "unknown"])
  }

  @Test("the podcast cutoff is re-evaluated per emission, not frozen at subscribe time")
  func podcastCutoffAdvancesWhileSubscribed() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "show-1")
    show.title = "Signal House"
    let storedShow = try itemDAO.upsert(show)
    let showId = try #require(storedShow.id)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    // Six days old at `start`, eight once the clock moves: inside the window, then outside it.
    _ = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId,
      serverEpisodeID: "ageing", title: "Ageing Out", durationSeconds: 1_200,
      publishedAt: start.addingTimeInterval(-6 * 86_400))

    let clock = TestClock(start)
    var iterator =
      reading
      .observeNewPodcastEpisodes(
        cutoff: { clock.now.addingTimeInterval(-7 * 86_400) }, limit: 10
      )
      .makeAsyncIterator()
    #expect(try #require(await iterator.next()).map(\.episodeID) == ["ageing"])

    clock.advance(by: 2 * 86_400)
    // Any write to the observed region re-runs the fetch; the cutoff has to move with it rather
    // than stay pinned to the moment the caller subscribed.
    _ = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId,
      serverEpisodeID: "ancient", title: "Ancient History", durationSeconds: 1_200,
      publishedAt: start.addingTimeInterval(-90 * 86_400))

    #expect(try #require(await iterator.next()).isEmpty)
  }

  @Test("recently added items can be scoped to the seven-day cutoff")
  func recentlyAddedItemsUseAddedAtCutoff() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
    var newBook = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "new-book")
    newBook.addedAt = now.addingTimeInterval(-86_400)
    newBook.seriesName = "Home Series"
    newBook.narratorName = "Home Narrator"
    newBook.expandedMetadataFetchedAt = now
    var oldBook = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "old-book")
    oldBook.addedAt = cutoff.addingTimeInterval(-1)
    _ = try itemDAO.upsert(newBook)
    _ = try itemDAO.upsert(oldBook)

    var iterator =
      reading
      .observeRecentlyAdded(category: .audiobook, limit: 10, since: cutoff)
      .makeAsyncIterator()
    let items = try #require(await iterator.next())

    #expect(items.map(\.serverItemId) == ["new-book"])
    #expect(items.first?.seriesName == "Home Series")
    #expect(items.first?.narratorName == "Home Narrator")
    #expect(items.first?.expandedMetadataFetchedAt == now)
  }

  @Test("recently added orders by addedAt descending, nulls last, excludes soft-deleted, respects limit")
  func recentlyAddedOrdering() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var older = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "older")
    older.addedAt = Date(timeIntervalSince1970: 1_000)
    var newer = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "newer")
    newer.addedAt = Date(timeIntervalSince1970: 2_000)
    var noAddedAt = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "no-added-at")
    noAddedAt.addedAt = nil
    var softDeleted = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "soft-deleted")
    softDeleted.addedAt = Date(timeIntervalSince1970: 3_000)
    softDeleted.softDeleted = true

    _ = try itemDAO.upsert(older)
    _ = try itemDAO.upsert(newer)
    _ = try itemDAO.upsert(noAddedAt)
    _ = try itemDAO.upsert(softDeleted)

    var iterator = reading.observeRecentlyAdded(category: nil, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["newer", "older", "no-added-at"])

    var limited = reading.observeRecentlyAdded(category: nil, limit: 1).makeAsyncIterator()
    let limitedResult = try #require(await limited.next())
    #expect(limitedResult.map(\.serverItemId) == ["newer"])
  }

  @Test("recently added filters by category in SQL before the limit is applied")
  func recentlyAddedFiltersByCategoryBeforeLimit() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var ebook = HomeReadingFixtures.ebook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "ebook-1")
    ebook.addedAt = Date(timeIntervalSince1970: 500)
    _ = try itemDAO.upsert(ebook)

    for index in 0..<3 {
      var book = HomeReadingFixtures.audiobook(
        accountId: accountId, libraryId: libraryRowId, serverItemId: "book-\(index)")
      book.addedAt = Date(timeIntervalSince1970: 1_000 + Double(index))
      _ = try itemDAO.upsert(book)
    }

    var iterator = reading.observeRecentlyAdded(category: .ebook, limit: 1).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["ebook-1"])

    var podcastIterator =
      reading.observeRecentlyAdded(category: .podcast, limit: 5).makeAsyncIterator()
    let podcastResult = try #require(await podcastIterator.next())
    #expect(podcastResult.isEmpty)
  }

  @Test("recently added remains item-level when a podcast has episode progress")
  func recentlyAddedPodcastRemainsItemLevel() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast-1")
    show.title = "Show Title"
    show.durationSeconds = 9_000
    show.addedAt = Date(timeIntervalSince1970: 2_000)
    let stored = try itemDAO.upsert(show)
    let episodeID = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(stored.id),
      serverEpisodeID: "episode-1", title: "Episode Title", durationSeconds: 1_200)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(stored.id), episodeId: episodeID,
      currentTime: 300, isFinished: false, localSequence: 4)

    var iterator = reading.observeRecentlyAdded(category: .podcast, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())
    let projected = try #require(result.first)

    #expect(projected.title == "Show Title")
    #expect(projected.durationSeconds == 9_000)
    #expect(projected.progressSeconds == 0)
    #expect(projected.episodeID == nil)
    #expect(projected.episodeTitle == nil)
  }

  // MARK: - Continue Series

  @Test("continue series returns the unstarted book immediately after a finished numbered book")
  func continueSeriesReturnsNextUnstartedBook() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var bookSix = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "carl-6")
    bookSix.seriesName = "Dungeon Crawler Carl #6"
    let storedSix = try itemDAO.upsert(bookSix)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(storedSix.id),
      currentTime: 72_000, isFinished: true, localSequence: 42)

    var bookSeven = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "carl-7")
    bookSeven.title = "This Inevitable Ruin"
    bookSeven.seriesName = "Dungeon Crawler Carl #7"
    _ = try itemDAO.upsert(bookSeven)

    var bookNine = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "carl-9")
    bookNine.seriesName = "Dungeon Crawler Carl #9"
    _ = try itemDAO.upsert(bookNine)

    var iterator = reading.observeContinueSeries(category: nil, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())

    #expect(result.map(\.serverItemId) == ["carl-7"])
    #expect(result.first?.title == "This Inevitable Ruin")
    #expect(result.first?.seriesName == "Dungeon Crawler Carl #7")
  }

  @Test("continue series excludes a next book that is already started")
  func continueSeriesExcludesStartedNextBook() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var bookOne = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "series-1")
    bookOne.seriesName = "A Series #1"
    let storedOne = try itemDAO.upsert(bookOne)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(storedOne.id),
      currentTime: 3_600, isFinished: true, localSequence: 1)

    var bookTwo = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "series-2")
    bookTwo.seriesName = "A Series #2"
    let storedTwo = try itemDAO.upsert(bookTwo)
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(storedTwo.id),
      currentTime: 120, isFinished: false, localSequence: 2)

    var iterator = reading.observeContinueSeries(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await iterator.next()).isEmpty)
  }

  // MARK: - Downloaded

  @Test("downloaded returns only items whose rollup is complete, ordered by sortTitle")
  func downloadedReturnsOnlyCompletedRollups() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    var zebra = HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "zebra")
    zebra.title = "Zebra"
    zebra.sortTitle = "zebra"
    let completedItem = try itemDAO.upsert(zebra)
    try HomeReadingFixtures.completeDownload(
      downloadStore, accountId: accountId, itemId: try #require(completedItem.id))

    var apple = HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "apple")
    apple.title = "Apple"
    apple.sortTitle = "apple"
    let anotherCompletedItem = try itemDAO.upsert(apple)
    try HomeReadingFixtures.completeDownload(
      downloadStore, accountId: accountId, itemId: try #require(anotherCompletedItem.id))

    let partialItem = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "partial"))
    try downloadStore.enqueue(
      accountId: accountId, itemId: try #require(partialItem.id), serverFileIno: "file-partial",
      orderIndex: 0, destinationRelativePath: "partial.mp3", expectedBytes: 100,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 10)

    _ = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "not-downloaded"))

    var iterator = reading.observeDownloaded(category: nil, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["apple", "zebra"])
  }

  @Test("downloaded includes completed audio or ebook rows for mixed items and pure ebooks")
  func downloadedIncludesAnyCompletedFormatForMixedItems() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var mixedAudio = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "mixed-audio")
    mixedAudio.ebookFormat = "epub"
    let mixedAudioItem = try itemDAO.upsert(mixedAudio)
    try HomeReadingFixtures.completeDownload(
      downloadStore, accountId: accountId, itemId: try #require(mixedAudioItem.id))

    var mixedEbook = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "mixed-ebook")
    mixedEbook.ebookFormat = "epub"
    let mixedEbookItem = try itemDAO.upsert(mixedEbook)
    try HomeReadingFixtures.completeEbookDownload(
      downloadStore, accountId: accountId, itemId: try #require(mixedEbookItem.id))

    var mixedBoth = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "mixed-both")
    mixedBoth.ebookFormat = "epub"
    let mixedBothItem = try itemDAO.upsert(mixedBoth)
    try HomeReadingFixtures.completeDownload(
      downloadStore, accountId: accountId, itemId: try #require(mixedBothItem.id))
    try HomeReadingFixtures.completeEbookDownload(
      downloadStore, accountId: accountId, itemId: try #require(mixedBothItem.id))

    let pureEbook = try itemDAO.upsert(
      HomeReadingFixtures.ebook(accountId: accountId, libraryId: libraryRowId, serverItemId: "pure-ebook"))
    try HomeReadingFixtures.completeEbookDownload(
      downloadStore, accountId: accountId, itemId: try #require(pureEbook.id))

    var iterator = reading.observeDownloaded(category: nil, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["mixed-audio", "mixed-both", "mixed-ebook", "pure-ebook"])
    #expect(result.allSatisfy { $0.isDownloaded })

    let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.serverItemId, $0) })
    #expect(byID["mixed-audio"]?.audioDownloaded == true)
    #expect(byID["mixed-audio"]?.ebookDownloaded == false)
    #expect(byID["mixed-both"]?.audioDownloaded == true)
    #expect(byID["mixed-both"]?.ebookDownloaded == true)
    #expect(byID["mixed-ebook"]?.audioDownloaded == false)
    #expect(byID["mixed-ebook"]?.ebookDownloaded == true)
  }

  @Test("downloaded re-emits when a download completes")
  func downloadedReemitsWhenADownloadCompletes() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    let item = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "item1"))

    let observations = PersistenceObservationCollector(
      reading.observeDownloaded(category: nil, limit: 10))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    // `completeDownload` is three separate writes (pending -> downloading -> completed), each of
    // which touches the tracked `download` table and so re-emits. Only the last is complete.
    try HomeReadingFixtures.completeDownload(downloadStore, accountId: accountId, itemId: try #require(item.id))
    let afterComplete = try await HomeReadingFixtures.next(observations) { $0.map(\.serverItemId) == ["item1"] }
    #expect(afterComplete.map(\.serverItemId) == ["item1"])
  }

  @Test("downloaded does not re-emit for a received-byte-only checkpoint")
  func downloadedIgnoresReceivedByteCheckpoints() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    let item = try itemDAO.upsert(
      HomeReadingFixtures.audiobook(accountId: accountId, libraryId: libraryRowId, serverItemId: "item1"))
    let download = try downloadStore.enqueue(
      accountId: accountId, itemId: try #require(item.id), serverFileIno: "file-item1",
      orderIndex: 0, destinationRelativePath: "item1.mp3", expectedBytes: 100,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 10)
    _ = try downloadStore.transition(downloadId: try #require(download.id), to: .downloading)

    let observations = PersistenceObservationCollector(
      reading.observeDownloaded(category: nil, limit: 10))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    _ = try downloadStore.updateProgress(
      downloadId: try #require(download.id), receivedBytes: 50)

    _ = try downloadStore.complete(
      downloadId: try #require(download.id), finalSizeBytes: 100)
    let next = try await HomeReadingFixtures.next(observations) { $0.map(\.serverItemId) == ["item1"] }
    #expect(next.map(\.serverItemId) == ["item1"])
  }

  @Test("downloaded filters by category in SQL before the limit is applied")
  func downloadedFiltersByCategoryBeforeLimit() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    let podcastItem = try itemDAO.upsert(
      HomeReadingFixtures.podcast(accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast-1"))
    try HomeReadingFixtures.completeDownload(downloadStore, accountId: accountId, itemId: try #require(podcastItem.id))

    for index in 0..<3 {
      let book = try itemDAO.upsert(
        HomeReadingFixtures.audiobook(
          accountId: accountId, libraryId: libraryRowId, serverItemId: "book-\(index)"))
      try HomeReadingFixtures.completeDownload(downloadStore, accountId: accountId, itemId: try #require(book.id))
    }

    var iterator = reading.observeDownloaded(category: .podcast, limit: 1).makeAsyncIterator()
    let result = try #require(await iterator.next())
    #expect(result.map(\.serverItemId) == ["podcast-1"])
  }

  @Test("downloaded remains item-level for a podcast with a downloaded episode")
  func downloadedPodcastRemainsItemLevel() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let downloadStore = try DownloadStore(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")
    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryRowId, serverItemId: "podcast-1")
    show.title = "Show Title"
    let stored = try itemDAO.upsert(show)
    let episodeID = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(stored.id),
      serverEpisodeID: "episode-1", title: "Episode Title", durationSeconds: 1_200)
    try HomeReadingFixtures.completeEpisodeDownload(
      downloadStore, accountId: accountId, itemId: try #require(stored.id), episodeId: episodeID)
    // Both a legacy item-level row and an episode-scoped row exist, with different positions. The
    // Downloaded join must decorate the show with the item-level one (only Continue Listening is
    // episode-aware), and must project exactly one row for the show.
    try await HomeReadingFixtures.writeProgress(
      database, accountId: accountId, itemId: try #require(stored.id), currentTime: 120,
      isFinished: false, localSequence: 2)
    try await HomeReadingFixtures.writeEpisodeProgress(
      database, accountId: accountId, itemId: try #require(stored.id), episodeId: episodeID,
      currentTime: 300, isFinished: true, localSequence: 4)

    var iterator = reading.observeDownloaded(category: .podcast, limit: 10).makeAsyncIterator()
    let result = try #require(await iterator.next())
    let projected = try #require(result.first)

    #expect(result.count == 1)
    #expect(projected.title == "Show Title")
    #expect(projected.progressSeconds == 120)
    #expect(projected.isFinished == false)
    #expect(projected.episodeID == nil)
    #expect(projected.episodeTitle == nil)
  }

  // MARK: - Derivation parity

  /// `ItemCategoryPredicate` is the identity predicate used by Continue Listening and Continue
  /// Series. The ebook filter has different membership semantics, so this test runs
  /// the strict SQL directly and keeps its parity pin separate from the filter-surface tests.
  @Test("the strict SQL category predicate selects exactly what ItemMediaCategory.derive returns")
  func sqlCategoryPredicateMatchesDeriveAcrossTheSignalMatrix() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryRowId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "lib1")

    // (id, mediaKind, numAudioFiles, ebookFormat): every row of `derive`'s documented matrix,
    // including the ones no per-section test exercises: audio-plus-ebook, nil-vs-zero audio files,
    // empty-string format, and a podcast carrying book-shaped signals.
    let matrix: [(String, String, Int?, String?)] = [
      ("audio-only", "book", 3, nil),
      ("audio-and-ebook", "book", 3, "epub"),
      ("ebook-zero-audio", "book", 0, "epub"),
      ("ebook-nil-audio", "book", nil, "epub"),
      ("no-signals", "book", nil, nil),
      ("zero-audio-no-format", "book", 0, nil),
      ("empty-format", "book", 0, ""),
      ("podcast-plain", "podcast", nil, nil),
      ("podcast-with-book-signals", "podcast", 3, "epub"),
    ]

    for (index, row) in matrix.enumerated() {
      let (serverItemId, mediaKind, numAudioFiles, ebookFormat) = row
      _ = try itemDAO.upsert(
        ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemId,
          mediaKind: mediaKind, title: serverItemId, sortTitle: serverItemId,
          addedAt: Date(timeIntervalSince1970: TimeInterval(index)), numAudioFiles: numAudioFiles,
          ebookFormat: ebookFormat))
    }

    for category in ItemMediaCategory.allCases {
      let expected = Set(
        matrix
          .filter {
            ItemMediaCategory.derive(
              mediaKind: $0.1, numAudioFiles: $0.2, ebookFormat: $0.3) == category
          }
          .map(\.0))

      let selected = try database.read { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT item.serverItemId FROM item
            WHERE \(ItemCategoryPredicate.sql(category))
            ORDER BY item.serverItemId
            """,
          arguments: [])
      }
      #expect(
        Set(selected) == expected,
        "SQL predicate and derive disagree for \(category.rawValue)")
    }

    // The unfiltered query is the union: no row is lost or double-counted by the predicates.
    var allIterator = reading.observeRecentlyAdded(category: nil, limit: matrix.count)
      .makeAsyncIterator()
    let all = try #require(await allIterator.next())
    #expect(Set(all.map(\.serverItemId)) == Set(matrix.map(\.0)))
  }

  @Test("Home discovery shelves exclude opted-out libraries while downloads remain retained")
  func homeDiscoveryShelvesExcludeOptedOutLibraries() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let seeded = try await database.writeAsync { db -> (Int64, Int64, Int64, Int64) in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)
      var included = LibraryRecord(
        accountId: account.id!, serverLibraryId: "included", mediaType: "book", name: "Included")
      try included.insert(db)
      var excluded = LibraryRecord(
        accountId: account.id!, serverLibraryId: "excluded", mediaType: "book", name: "Excluded",
        isIncluded: false)
      try excluded.insert(db)

      var includedRecent = HomeReadingFixtures.audiobook(
        accountId: account.id!, libraryId: included.id!, serverItemId: "included-recent")
      includedRecent.addedAt = now
      try includedRecent.insert(db)
      var excludedRecent = HomeReadingFixtures.audiobook(
        accountId: account.id!, libraryId: excluded.id!, serverItemId: "excluded-recent")
      excludedRecent.addedAt = now
      try excludedRecent.insert(db)
      var excludedContinue = HomeReadingFixtures.audiobook(
        accountId: account.id!, libraryId: excluded.id!, serverItemId: "excluded-continue")
      try excludedContinue.insert(db)
      var excludedReading = HomeReadingFixtures.ebook(
        accountId: account.id!, libraryId: excluded.id!, serverItemId: "excluded-reading")
      try excludedReading.insert(db)

      var includedOne = HomeReadingFixtures.audiobook(
        accountId: account.id!, libraryId: included.id!, serverItemId: "included-series-1")
      includedOne.seriesName = "Included Saga #1"
      try includedOne.insert(db)
      var includedTwo = HomeReadingFixtures.audiobook(
        accountId: account.id!, libraryId: included.id!, serverItemId: "included-series-2")
      includedTwo.seriesName = "Included Saga #2"
      try includedTwo.insert(db)
      var excludedOne = HomeReadingFixtures.audiobook(
        accountId: account.id!, libraryId: excluded.id!, serverItemId: "excluded-series-1")
      excludedOne.seriesName = "Excluded Saga #1"
      try excludedOne.insert(db)
      var excludedTwo = HomeReadingFixtures.audiobook(
        accountId: account.id!, libraryId: excluded.id!, serverItemId: "excluded-series-2")
      excludedTwo.seriesName = "Excluded Saga #2"
      try excludedTwo.insert(db)

      var includedShow = HomeReadingFixtures.podcast(
        accountId: account.id!, libraryId: included.id!, serverItemId: "included-show")
      try includedShow.insert(db)
      var excludedShow = HomeReadingFixtures.podcast(
        accountId: account.id!, libraryId: excluded.id!, serverItemId: "excluded-show")
      try excludedShow.insert(db)
      var includedEpisode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: includedShow.id!, serverEpisodeId: "included-episode",
        title: "Included Episode", publishedAt: now, lastSeenGeneration: 1)
      try includedEpisode.insert(db)
      var excludedEpisode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: excludedShow.id!, serverEpisodeId: "excluded-episode",
        title: "Excluded Episode", publishedAt: now, lastSeenGeneration: 1)
      try excludedEpisode.insert(db)

      for item in [includedOne, excludedOne] {
        var progress = MediaProgressRecord(
          accountId: account.id!, itemId: item.id!, currentTime: 100, isFinished: true,
          localSequence: 1, origin: .local, originKey: "test")
        try progress.insert(db)
      }
      var retainedProgress = MediaProgressRecord(
        accountId: account.id!, itemId: excludedContinue.id!, currentTime: 20, isFinished: false,
        localSequence: 2, origin: .local, originKey: "test")
      try retainedProgress.insert(db)
      var excludedReadingProgress = MediaProgressRecord(
        accountId: account.id!, itemId: excludedReading.id!, currentTime: 0, isFinished: false,
        localSequence: 3, origin: .local, originKey: "test", ebookProgress: 0.2)
      try excludedReadingProgress.insert(db)
      return (account.id!, included.id!, excluded.id!, excludedContinue.id!)
    }
    _ = seeded

    var recent = reading.observeRecentlyAdded(category: nil, limit: 10).makeAsyncIterator()
    let recentIDs = try #require(await recent.next()).map(\.serverItemId)
    #expect(recentIDs.contains("included-recent"))
    #expect(recentIDs.contains("excluded-recent") == false)
    var series = reading.observeContinueSeries(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await series.next()).map(\.serverItemId) == ["included-series-2"])
    var episodes = reading.observeNewPodcastEpisodes(cutoff: { now.addingTimeInterval(-1) }, limit: 10)
      .makeAsyncIterator()
    #expect(try #require(await episodes.next()).map(\.episodeID) == ["included-episode"])
    var continueListening = reading.observeContinueListening(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await continueListening.next()).map(\.serverItemId).contains("excluded-continue") == false)
    var continueReading = reading.observeContinueReading(category: nil, limit: 10).makeAsyncIterator()
    #expect(try #require(await continueReading.next()).map(\.serverItemId).contains("excluded-reading") == false)
  }

}
