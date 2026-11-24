import Foundation
import TestSupport
import Testing

@testable import Persistence

@Suite struct ExpandedMetadataBatchStoreTests {

  @Test func storesAllFieldsAndChaptersForA50ItemBatch() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let serverItemIds = (0..<50).map { "item-\($0)" }
    try await insertItems(
      database, accountId: accountId, libraryId: libraryId, serverItemIds: serverItemIds)
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let mutations = serverItemIds.enumerated().map { index, serverItemId in
      makeMutation(serverItemId: serverItemId, index: index)
    }
    let store = ExpandedMetadataBatchStore(database: database)

    try await store.store(mutations, accountId: accountId, fetchedAt: fetchedAt)

    let itemDAO = ItemDAO(database: database)
    let chapterStore = ItemChapterStore(database: database)
    for (index, serverItemId) in serverItemIds.enumerated() {
      let item = try #require(
        await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: serverItemId))
      #expect(item.seriesName == "Series \(index)")
      #expect(item.narratorName == "Narrator \(index)")
      #expect(item.itemDescription == "Description \(index)")
      #expect(item.ebookFileIno == "ino-\(index)")
      #expect(item.ebookFileExt == "epub")
      #expect(item.audioDownloadExpectedBytes == Int64(index * 1_000))
      #expect(item.ebookDownloadExpectedBytes == Int64(index * 2_000))
      #expect(item.expandedMetadataFetchedAt == fetchedAt)
      #expect(
        try await chapterStore.fetchAsync(accountId: accountId, itemId: try #require(item.id))
          == mutations[index].chapters)
    }
  }

  @Test func emptyAuthoritativeChapterListClearsPriorChapters() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let item = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    let itemId = try #require(item.id)
    let chapterStore = ItemChapterStore(database: database)
    try await chapterStore.replaceAsync(
      accountId: accountId,
      itemId: itemId,
      chapters: [
        StoredItemChapter(serverChapterId: 1, position: 0, start: 0, end: 10, title: "Old")
      ])

    let store = ExpandedMetadataBatchStore(database: database)
    try await store.store(
      [makeMutation(serverItemId: "item-1", index: 1, chapters: [])],
      accountId: accountId,
      fetchedAt: Date(timeIntervalSince1970: 1_750_000_001))

    #expect(try await chapterStore.fetchAsync(accountId: accountId, itemId: itemId).isEmpty)
  }

  @Test func aFailureRollsBackEveryMutationInTheBatch() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let serverItemIds = ["item-1", "item-2", "item-3"]
    let oldFetchedAt = Date(timeIntervalSince1970: 1_740_000_000)
    try await insertItems(
      database,
      accountId: accountId,
      libraryId: libraryId,
      serverItemIds: serverItemIds,
      expandedMetadataFetchedAt: oldFetchedAt)
    let invalidChapters = [
      StoredItemChapter(serverChapterId: 20, position: 0, start: 0, end: 10, title: "First"),
      StoredItemChapter(serverChapterId: 21, position: 0, start: 10, end: 20, title: "Duplicate"),
    ]
    let mutations = [
      makeMutation(serverItemId: "item-1", index: 1),
      makeMutation(serverItemId: "item-2", index: 2, chapters: invalidChapters),
      makeMutation(serverItemId: "item-3", index: 3),
    ]
    let store = ExpandedMetadataBatchStore(database: database)

    await #expect(throws: (any Error).self) {
      try await store.store(
        mutations,
        accountId: accountId,
        fetchedAt: Date(timeIntervalSince1970: 1_750_000_002))
    }

    let itemDAO = ItemDAO(database: database)
    let chapterStore = ItemChapterStore(database: database)
    for serverItemId in serverItemIds {
      let item = try #require(
        await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: serverItemId))
      #expect(item.expandedMetadataFetchedAt == oldFetchedAt)
      #expect(try await chapterStore.fetchAsync(accountId: accountId, itemId: try #require(item.id)).isEmpty)
    }
  }

  @Test func anEarlierSuccessfulBatchSurvivesALaterFailure() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let serverItemIds = ["item-1", "item-2", "item-3"]
    let oldFetchedAt = Date(timeIntervalSince1970: 1_740_000_000)
    try await insertItems(
      database,
      accountId: accountId,
      libraryId: libraryId,
      serverItemIds: serverItemIds,
      expandedMetadataFetchedAt: oldFetchedAt)
    let store = ExpandedMetadataBatchStore(database: database)
    let firstFetchedAt = Date(timeIntervalSince1970: 1_750_000_003)

    try await store.store(
      [makeMutation(serverItemId: "item-1", index: 1)],
      accountId: accountId,
      fetchedAt: firstFetchedAt)

    let invalidChapters = [
      StoredItemChapter(serverChapterId: 30, position: 0, start: 0, end: 10, title: "First"),
      StoredItemChapter(serverChapterId: 31, position: 0, start: 10, end: 20, title: "Duplicate"),
    ]
    await #expect(throws: (any Error).self) {
      try await store.store(
        [
          makeMutation(serverItemId: "item-2", index: 2),
          makeMutation(serverItemId: "item-3", index: 3, chapters: invalidChapters),
        ],
        accountId: accountId,
        fetchedAt: Date(timeIntervalSince1970: 1_750_000_004))
    }

    let itemDAO = ItemDAO(database: database)
    let chapterStore = ItemChapterStore(database: database)
    let first = try #require(
      await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: "item-1"))
    #expect(first.expandedMetadataFetchedAt == firstFetchedAt)
    #expect(first.seriesName == "Series 1")
    #expect(
      try await chapterStore.fetchAsync(accountId: accountId, itemId: try #require(first.id))
        == makeMutation(serverItemId: "item-1", index: 1).chapters)

    for serverItemId in ["item-2", "item-3"] {
      let item = try #require(
        await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: serverItemId))
      #expect(item.expandedMetadataFetchedAt == oldFetchedAt)
      #expect(try await chapterStore.fetchAsync(accountId: accountId, itemId: try #require(item.id)).isEmpty)
    }
  }

  @Test func explicitNilClearsDescriptionAndEbookIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database,
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: "item-1",
      itemDescription: "Old description",
      ebookFileIno: "old-ino",
      ebookFileExt: "epub")
    let store = ExpandedMetadataBatchStore(database: database)

    try await store.store(
      [
        ExpandedItemMetadataMutation(
          serverItemId: "item-1",
          seriesName: nil,
          narratorName: nil,
          itemDescription: nil,
          ebookFileIno: nil,
          ebookFileExt: nil,
          chapters: [])
      ],
      accountId: accountId,
      fetchedAt: Date(timeIntervalSince1970: 1_750_000_005))

    let item = try #require(
      await ItemDAO(database: database).fetchOneAsync(
        accountId: accountId, serverItemId: "item-1"))
    #expect(item.itemDescription == nil)
    #expect(item.ebookFileIno == nil)
    #expect(item.ebookFileExt == nil)
  }

  @Test func ebookFileValuesUseTheSingleItemNormalizationRules() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    let store = ExpandedMetadataBatchStore(database: database)

    try await store.store(
      [
        ExpandedItemMetadataMutation(
          serverItemId: "item-1",
          seriesName: nil,
          narratorName: nil,
          itemDescription: nil,
          ebookFileIno: "",
          ebookFileExt: " .EPUB ",
          chapters: [])
      ],
      accountId: accountId,
      fetchedAt: Date(timeIntervalSince1970: 1_750_000_006))

    let item = try #require(
      await ItemDAO(database: database).fetchOneAsync(
        accountId: accountId, serverItemId: "item-1"))
    #expect(item.ebookFileIno == nil)
    #expect(item.ebookFileExt == "epub")
  }

  @Test func aMissingServerItemIdIsSkippedWhileTheRestCommits() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    let store = ExpandedMetadataBatchStore(database: database)
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_007)

    try await store.store(
      [
        makeMutation(serverItemId: "missing", index: 0),
        makeMutation(serverItemId: "item-1", index: 1),
      ],
      accountId: accountId,
      fetchedAt: fetchedAt)

    let item = try #require(
      await ItemDAO(database: database).fetchOneAsync(
        accountId: accountId, serverItemId: "item-1"))
    #expect(item.expandedMetadataFetchedAt == fetchedAt)
    #expect(item.seriesName == "Series 1")
    #expect(
      try await ItemChapterStore(database: database).fetchAsync(
        accountId: accountId, itemId: try #require(item.id))
        == makeMutation(serverItemId: "item-1", index: 1).chapters)
    #expect(
      try await ItemDAO(database: database).fetchOneAsync(
        accountId: accountId, serverItemId: "missing") == nil)
  }

  @Test func explicitNilClearsKnownSeriesAndNarrator() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database,
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: "item-1",
      seriesName: "Old",
      narratorName: "Old Narrator")
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let store = ExpandedMetadataBatchStore(database: database)

    try await store.store(
      [
        ExpandedItemMetadataMutation(
          serverItemId: "item-1",
          seriesName: nil,
          narratorName: nil,
          itemDescription: nil,
          ebookFileIno: nil,
          ebookFileExt: nil,
          chapters: [])
      ],
      accountId: accountId,
      fetchedAt: fetchedAt)

    let found = try #require(
      await ItemDAO(database: database).fetchOneAsync(
        accountId: accountId, serverItemId: "item-1"))
    #expect(found.seriesName == nil)
    #expect(found.narratorName == nil)
    #expect(found.expandedMetadataFetchedAt == fetchedAt)
  }

  /// The batch store is the authoritative writer of `itemDescription`; the minified library
  /// traversal must not undo it. The pull re-supplies the preserved value it read back, which is
  /// the mechanism that keeps an expanded description alive across a resync.
  @Test func expandedDescriptionSurvivesTheMinifiedLibraryPull() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-description-pull")
    let store = ExpandedMetadataBatchStore(database: database)
    try await store.store(
      [
        ExpandedItemMetadataMutation(
          serverItemId: "item-description-pull",
          seriesName: nil,
          narratorName: nil,
          itemDescription: "Description retained across the pull.",
          ebookFileIno: nil,
          ebookFileExt: nil,
          chapters: [])
      ],
      accountId: accountId,
      fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))

    let preserved = try await itemDAO.preservedMetadataByServerItemIdAsync(
      libraryId: libraryId, serverItemIds: ["item-description-pull"])
    let syncRunDAO = SyncRunDAO(database: database)
    let run = try await syncRunDAO.startRunAsync(
      accountId: accountId,
      libraryId: libraryId,
      reason: "test",
      generation: 2,
      sortRequested: nil,
      startedAt: Date(timeIntervalSince1970: 1_750_000_100))
    _ = try await syncRunDAO.applyPageAsync(
      runId: try #require(run.id),
      accountId: accountId,
      libraryId: libraryId,
      generation: 2,
      items: [
        ItemRecord(
          accountId: accountId,
          libraryId: libraryId,
          serverItemId: "item-description-pull",
          mediaKind: "book",
          title: "Title refreshed",
          sortTitle: "description pull refreshed",
          itemDescription: preserved["item-description-pull"]?.itemDescription)
      ],
      pageNumber: 0,
      fetchedAt: Date(timeIntervalSince1970: 1_750_000_100),
      resultCategory: nil)

    let found = try await itemDAO.fetchOneAsync(
      accountId: accountId, serverItemId: "item-description-pull")
    #expect(found?.itemDescription == "Description retained across the pull.")
  }

  /// The minified traversal omits `ebookFile` entirely, so the item-row upsert must leave the
  /// identity the batch store wrote alone rather than clearing it. Only an authoritative expanded
  /// response carrying an explicit nil may clear it.
  @Test func minifiedTraversalPreservesEbookIdentityWrittenByTheBatch() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1",
      ebookFormat: "epub")
    let store = ExpandedMetadataBatchStore(database: database)
    try await store.store(
      [
        ExpandedItemMetadataMutation(
          serverItemId: "item-1",
          seriesName: "Series",
          narratorName: "Narrator",
          itemDescription: nil,
          ebookFileIno: "154409",
          ebookFileExt: ".EPUB",
          chapters: [])
      ],
      accountId: accountId,
      fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))

    let syncRunDAO = SyncRunDAO(database: database)
    let run = try await syncRunDAO.startRunAsync(
      accountId: accountId,
      libraryId: libraryId,
      reason: "test",
      generation: 2,
      sortRequested: nil,
      startedAt: Date(timeIntervalSince1970: 1_750_000_100))
    _ = try await syncRunDAO.applyPageAsync(
      runId: try #require(run.id),
      accountId: accountId,
      libraryId: libraryId,
      generation: 2,
      items: [
        ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
          title: "Title refreshed", sortTitle: "title refreshed", ebookFormat: "epub")
      ],
      pageNumber: 0,
      fetchedAt: Date(timeIntervalSince1970: 1_750_000_100),
      resultCategory: nil)

    let found = try #require(
      await itemDAO.fetchOneAsync(libraryId: libraryId, serverItemId: "item-1"))
    #expect(found.ebookFileIno == "154409")
    #expect(found.ebookFileExt == "epub")
  }

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws
    -> (accountId: Int64, libraryId: Int64)
  {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: "https://example.com",
        serverUserId: "user-1",
        serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return (account.id!, library.id!)
    }
  }

  private func insertItems(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    serverItemIds: [String],
    expandedMetadataFetchedAt: Date? = nil
  ) async throws {
    for serverItemId in serverItemIds {
      _ = try await insertItem(
        database,
        accountId: accountId,
        libraryId: libraryId,
        serverItemId: serverItemId,
        expandedMetadataFetchedAt: expandedMetadataFetchedAt)
    }
  }

  private func insertItem(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    itemDescription: String? = nil,
    ebookFormat: String? = nil,
    ebookFileIno: String? = nil,
    ebookFileExt: String? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil
  ) async throws -> ItemRecord {
    try await ItemDAO(database: database).upsertAsync(
      PersistenceFixtures.item(
        accountId: accountId,
        libraryId: libraryId,
        serverItemId: serverItemId,
        mediaKind: "book",
        title: serverItemId,
        sortTitle: serverItemId,
        itemDescription: itemDescription,
        ebookFormat: ebookFormat,
        ebookFileIno: ebookFileIno,
        ebookFileExt: ebookFileExt,
        seriesName: seriesName,
        narratorName: narratorName,
        expandedMetadataFetchedAt: expandedMetadataFetchedAt))
  }

  private func makeMutation(
    serverItemId: String,
    index: Int,
    chapters: [StoredItemChapter]? = nil
  ) -> ExpandedItemMetadataMutation {
    ExpandedItemMetadataMutation(
      serverItemId: serverItemId,
      seriesName: "Series \(index)",
      narratorName: "Narrator \(index)",
      itemDescription: "Description \(index)",
      ebookFileIno: "ino-\(index)",
      ebookFileExt: ".EPUB",
      audioDownloadExpectedBytes: Int64(index * 1_000),
      ebookDownloadExpectedBytes: Int64(index * 2_000),
      chapters: chapters ?? [
        StoredItemChapter(
          serverChapterId: index * 10,
          position: 0,
          start: 0,
          end: 10,
          title: "Chapter \(index)-0"),
        StoredItemChapter(
          serverChapterId: index * 10 + 1,
          position: 1,
          start: 10,
          end: 20,
          title: "Chapter \(index)-1"),
      ])
  }
}
