import Foundation
import TestSupport
import Testing

@testable import Persistence

/// `ItemDAO.fetchOne(accountId:serverItemId:)` resolves a local item row from just the server
/// item id (the only identity a playback-session request carries), without knowing the library.
@Suite struct ItemDAOTests {

  @Test func fetchOneByAccountAndServerItemIdFindsTheMatchingRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)
    let inserted = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "Title", sortTitle: "title"))

    let found = try itemDAO.fetchOne(accountId: accountId, serverItemId: "item-1")

    #expect(found?.id == inserted.id)
    #expect(found?.serverItemId == "item-1")
  }

  @Test func fetchOneByAccountAndServerItemIdIsNilWhenNoRowMatches() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, _) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)

    #expect(try itemDAO.fetchOne(accountId: accountId, serverItemId: "missing") == nil)
  }

  @Test func fetchOneByAccountAndServerItemIdNeverCrossesAccounts() async throws {
    let database = try AppDatabase.inMemory()
    let (firstAccountId, libraryId) = try await insertAccountAndLibrary(database, serverUserId: "user-1")
    let secondAccountId = try await PersistenceFixtures.insertAccount(database, serverUserId: "user-2")
    let itemDAO = ItemDAO(database: database)
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: firstAccountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "Title", sortTitle: "title"))

    #expect(try itemDAO.fetchOne(accountId: secondAccountId, serverItemId: "item-1") == nil)
  }

  @Test func fetchOneByIdAsyncMatchesTheSyncTwin() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)
    let inserted = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-async-id", mediaKind: "book",
        title: "Async ID", sortTitle: "async id"))
    let itemId = try #require(inserted.id)

    let syncResult = try itemDAO.fetchOne(id: itemId)
    let asyncResult = try await itemDAO.fetchOneAsync(id: itemId)

    #expect(asyncResult == syncResult)
    #expect(asyncResult?.serverItemId == "item-async-id")
  }

  @Test func fetchOneByAccountAndServerItemIdAsyncMatchesTheSyncTwin() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)
    _ = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-async-account",
        mediaKind: "book", title: "Async account", sortTitle: "async account"))

    let syncResult = try itemDAO.fetchOne(
      accountId: accountId, serverItemId: "item-async-account")
    let asyncResult = try await itemDAO.fetchOneAsync(
      accountId: accountId, serverItemId: "item-async-account")

    #expect(asyncResult == syncResult)
    #expect(asyncResult?.accountId == accountId)
    #expect(asyncResult?.serverItemId == "item-async-account")
  }

  /// `addedAt`/`numAudioFiles`/`ebookFormat` round-trip losslessly.
  @Test func upsertRoundTripsAddedAtNumAudioFilesAndEbookFileFormat() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)
    let addedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let inserted = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "Title", sortTitle: "title", addedAt: addedAt, numAudioFiles: 12,
        ebookFormat: "epub"))

    let found = try itemDAO.fetchOne(id: inserted.id!)

    #expect(found?.addedAt == addedAt)
    #expect(found?.numAudioFiles == 12)
    #expect(found?.ebookFormat == "epub")
  }

  /// A row written without the new fields reads back with them nil rather than failing to decode.
  @Test func aRowWrittenWithoutTheNewFieldsReadsBackNil() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)

    let inserted = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "Title", sortTitle: "title"))

    let found = try itemDAO.fetchOne(id: inserted.id!)

    #expect(found?.addedAt == nil)
    #expect(found?.numAudioFiles == nil)
    #expect(found?.ebookFormat == nil)
  }

  /// The show synopsis is expanded-only, so a resync that rebuilds the row from a minified payload
  /// has to read it back out of `preservedMetadataByServerItemIdAsync`, as `addedAt` and
  /// `narratorName` are, or every traversal blanks it. A later expanded refresh still updates it.
  @Test func descriptionSurvivesResync() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemDAO = ItemDAO(database: database)
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "podcast",
        title: "Title", sortTitle: "title", itemDescription: "A show about shows"))

    let preserved = try await itemDAO.preservedMetadataByServerItemIdAsync(
      libraryId: libraryId, serverItemIds: ["item-1"])
    #expect(preserved["item-1"]?.itemDescription == "A show about shows")

    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "podcast",
        title: "Title", sortTitle: "title",
        itemDescription: preserved["item-1"]?.itemDescription))
    #expect(
      try itemDAO.fetchOne(accountId: accountId, serverItemId: "item-1")?.itemDescription
        == "A show about shows")

    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "podcast",
        title: "Title", sortTitle: "title", itemDescription: "A rewritten blurb"))
    #expect(
      try itemDAO.fetchOne(accountId: accountId, serverItemId: "item-1")?.itemDescription
        == "A rewritten blurb")
  }

  @Test func missingExpandedMetadataExcludesPodcastDeletedAndFetchedRowsInSortOrder()
    async throws
  {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-zulu",
      sortTitle: "zulu")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-alpha",
      sortTitle: "alpha")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-missing",
      mediaKind: "podcast", sortTitle: "bravo")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-deleted",
      sortTitle: "charlie", softDeleted: true)
    _ = try await insertItem(
      database,
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: "book-fetched",
      sortTitle: "delta",
      expandedMetadataFetchedAt: fetchedAt)

    let result = try await ItemDAO(database: database)
      .serverItemIdsNeedingExpandedMetadataAsync(accountId: accountId, limit: 20)

    #expect(result == ["book-alpha", "book-zulu"])
  }

  /// A row whose server record changed after the last expanded fetch is owed another one. Without
  /// it, `ExpandedMetadataBatchStore` (the only writer of `ebookFileIno`/`ebookFileExt`) would
  /// never run again for that item, so a file the server replaced could not be corrected locally.
  @Test func expandedMetadataRefreshClaimsRowsTheServerChangedSinceTheLastFetch() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-rescanned",
      sortTitle: "alpha", expandedMetadataFetchedAt: fetchedAt,
      serverUpdatedAt: fetchedAt.addingTimeInterval(60))
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-unchanged",
      sortTitle: "bravo", expandedMetadataFetchedAt: fetchedAt,
      serverUpdatedAt: fetchedAt.addingTimeInterval(-60))
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-no-signal",
      sortTitle: "charlie", expandedMetadataFetchedAt: fetchedAt, serverUpdatedAt: nil)

    let result = try await ItemDAO(database: database)
      .serverItemIdsNeedingExpandedMetadataAsync(accountId: accountId, limit: 20)

    #expect(result == ["book-rescanned"])
  }

  @Test func missingExpandedMetadataHonorsLimitAndNonPositiveLimit() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    for (serverItemId, sortTitle) in [
      ("book-alpha", "alpha"), ("book-bravo", "bravo"),
      ("book-charlie", "charlie"),
    ] {
      _ = try await insertItem(
        database,
        accountId: accountId,
        libraryId: libraryId,
        serverItemId: serverItemId,
        sortTitle: sortTitle)
    }
    let itemDAO = ItemDAO(database: database)

    let limited = try await itemDAO.serverItemIdsNeedingExpandedMetadataAsync(
      accountId: accountId, limit: 2)
    let zero = try await itemDAO.serverItemIdsNeedingExpandedMetadataAsync(
      accountId: accountId, limit: 0)
    let negative = try await itemDAO.serverItemIdsNeedingExpandedMetadataAsync(
      accountId: accountId, limit: -1)

    #expect(limited == ["book-alpha", "book-bravo"])
    #expect(zero.isEmpty)
    #expect(negative.isEmpty)
  }

  @Test func expandedMetadataCensusCountsCoveredAndTotalAndEmptyAccounts() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-missing",
      sortTitle: "missing")
    _ = try await insertItem(
      database,
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: "book-covered",
      sortTitle: "covered",
      expandedMetadataFetchedAt: fetchedAt)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-missing",
      mediaKind: "podcast", sortTitle: "podcast")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-deleted",
      sortTitle: "deleted", softDeleted: true)

    let emptyAccount = try await insertAccountAndLibrary(database, serverUserId: "user-empty")
    _ = try await insertItem(
      database,
      accountId: emptyAccount.accountId,
      libraryId: emptyAccount.libraryId,
      serverItemId: "podcast-only",
      mediaKind: "podcast",
      sortTitle: "podcast only")
    let itemDAO = ItemDAO(database: database)

    let census = try await itemDAO.expandedMetadataCensusAsync(accountId: accountId)
    let emptyCensus = try await itemDAO.expandedMetadataCensusAsync(
      accountId: emptyAccount.accountId)

    #expect(census == ItemDAO.MetadataCensus(covered: 1, total: 2))
    #expect(emptyCensus == ItemDAO.MetadataCensus(covered: 0, total: 0))
  }

  @Test func allServerItemIdsIncludesPodcastsAndExcludesSoftDeletedRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-item",
      sortTitle: "book")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-show",
      mediaKind: "podcast", sortTitle: "podcast")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "deleted-item",
      sortTitle: "deleted", softDeleted: true)

    let result = try await ItemDAO(database: database).allServerItemIdsAsync(accountId: accountId)

    #expect(result == ["book-item", "podcast-show"])
  }

  @Test func allServerItemKindsRetainsPodcastClassificationAndExcludesSoftDeletedRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "book-item",
      sortTitle: "book")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "podcast-show",
      mediaKind: "podcast", sortTitle: "podcast")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "deleted-item",
      mediaKind: "podcast", sortTitle: "deleted", softDeleted: true)

    let result = try await ItemDAO(database: database).allServerItemKindsAsync(accountId: accountId)

    #expect(
      result == [
        ItemDAO.ServerItemKind(serverItemId: "book-item", mediaKind: "book"),
        ItemDAO.ServerItemKind(serverItemId: "podcast-show", mediaKind: "podcast"),
      ])
  }

  @Test func artworkEligibilityExcludesOnlyAnExplicitlyMissingServerCover() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "has-cover",
      sortTitle: "a", hasServerArtwork: true)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "unknown-cover",
      sortTitle: "b", hasServerArtwork: nil)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "generated-cover",
      sortTitle: "c", hasServerArtwork: false)

    let dao = ItemDAO(database: database)
    let eligible = try await dao.serverItemKindsEligibleForArtworkAsync(accountId: accountId)

    #expect(eligible.map(\.serverItemId) == ["has-cover", "unknown-cover"])
    try await dao.setHasServerArtworkAsync(
      false, accountId: accountId, serverItemId: "unknown-cover")
    #expect(
      try await dao.serverItemKindsEligibleForArtworkAsync(accountId: accountId)
        .map(\.serverItemId) == ["has-cover"])
  }

  @Test func cacheAndMetadataCandidatesExcludeItemsInAnExcludedLibrary() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, includedLibraryId) = try await insertAccountAndLibrary(database)
    let excludedLibraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "excluded", mediaType: "book", name: "Excluded",
        isIncluded: false)
      try library.insert(db)
      return try #require(library.id)
    }
    _ = try await insertItem(
      database, accountId: accountId, libraryId: includedLibraryId, serverItemId: "included",
      sortTitle: "included", hasServerArtwork: true)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: excludedLibraryId, serverItemId: "excluded",
      sortTitle: "excluded", hasServerArtwork: true)
    let dao = ItemDAO(database: database)

    #expect(
      try await dao.serverItemIdsNeedingExpandedMetadataAsync(accountId: accountId, limit: 10)
        == ["included"])
    #expect(try await dao.expandedMetadataCensusAsync(accountId: accountId) == .init(covered: 0, total: 1))
    #expect(
      try await dao.serverItemKindsEligibleForArtworkAsync(accountId: accountId)
        .map(\.serverItemId) == ["included"])
  }

  @Test func accountWideMetadataReadsNeverCrossAccountBoundaries() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await insertAccountAndLibrary(database, serverUserId: "user-first")
    let second = try await insertAccountAndLibrary(database, serverUserId: "user-second")
    _ = try await insertItem(
      database,
      accountId: first.accountId,
      libraryId: first.libraryId,
      serverItemId: "first-book",
      sortTitle: "z first")
    _ = try await insertItem(
      database,
      accountId: first.accountId,
      libraryId: first.libraryId,
      serverItemId: "first-podcast",
      mediaKind: "podcast",
      sortTitle: "z podcast")
    _ = try await insertItem(
      database,
      accountId: second.accountId,
      libraryId: second.libraryId,
      serverItemId: "second-book",
      sortTitle: "a second")

    let itemDAO = ItemDAO(database: database)
    let missing = try await itemDAO.serverItemIdsNeedingExpandedMetadataAsync(
      accountId: first.accountId, limit: 20)
    let census = try await itemDAO.expandedMetadataCensusAsync(accountId: first.accountId)
    let all = try await itemDAO.allServerItemIdsAsync(accountId: first.accountId)

    #expect(missing == ["first-book"])
    #expect(census == ItemDAO.MetadataCensus(covered: 0, total: 1))
    #expect(all == ["first-book", "first-podcast"])
  }

  // MARK: - Helpers

  @Test func progressTargetsResolvesOnlyRequestedLibraries() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let otherLibraryId = try await insertLibrary(database, accountId: accountId, serverLibraryId: "lib-2")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "wanted", sortTitle: "a")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: otherLibraryId, serverItemId: "unwanted",
      sortTitle: "b")

    let targets = try await ItemDAO(database: database).progressTargetsAsync(
      accountId: accountId, libraryIds: [libraryId], serverItemIds: ["wanted", "unwanted"])

    #expect(targets.map(\.serverItemId) == ["wanted"])
  }

  @Test func progressTargetsSkipsSoftDeletedRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "live", sortTitle: "a")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "tombstoned",
      sortTitle: "b", softDeleted: true)

    let targets = try await ItemDAO(database: database).progressTargetsAsync(
      accountId: accountId, libraryIds: [libraryId], serverItemIds: ["live", "tombstoned"])

    #expect(targets.map(\.serverItemId) == ["live"])
  }

  @Test func progressTargetsNeverCrossesAccounts() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database, serverUserId: "user-1")
    let otherAccountId = try await PersistenceFixtures.insertAccount(database, serverUserId: "user-2")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1", sortTitle: "a")

    let targets = try await ItemDAO(database: database).progressTargetsAsync(
      accountId: otherAccountId, libraryIds: [libraryId], serverItemIds: ["item-1"])

    #expect(targets.isEmpty)
  }

  /// The duration feeds the audio zero-position guard's fraction floor, and a row the server never
  /// dated must arrive as nil rather than as a zero the guard would compare against.
  @Test func progressTargetsCarriesDurationIncludingItsAbsence() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await ItemDAO(database: database).upsertAsync(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "timed", mediaKind: "book",
        title: "Timed", sortTitle: "timed", durationSeconds: 1234.5))
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "untimed", sortTitle: "u")

    let targets = try await ItemDAO(database: database).progressTargetsAsync(
      accountId: accountId, libraryIds: [libraryId], serverItemIds: ["timed", "untimed"])

    let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.serverItemId, $0) })
    #expect(byID["timed"]?.durationSeconds == 1234.5)
    #expect(byID["untimed"]?.durationSeconds == nil)
  }

  /// A whole-account `/api/me` snapshot is the caller-supplied list here, so it must survive past
  /// SQLite's per-statement bound-variable ceiling rather than throwing on a large library.
  @Test func progressTargetsChunksLargeIdentifierLists() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let serverItemIds = (0..<950).map { "item-\($0)" }
    for serverItemId in serverItemIds {
      _ = try await insertItem(
        database, accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        sortTitle: serverItemId)
    }

    let targets = try await ItemDAO(database: database).progressTargetsAsync(
      accountId: accountId, libraryIds: [libraryId], serverItemIds: serverItemIds)

    #expect(Set(targets.map(\.serverItemId)) == Set(serverItemIds))
  }

  @Test func progressTargetsIsEmptyForAnEmptyRequest() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-1", sortTitle: "a")
    let itemDAO = ItemDAO(database: database)

    #expect(
      try await itemDAO.progressTargetsAsync(
        accountId: accountId, libraryIds: [], serverItemIds: ["item-1"]
      ).isEmpty)
    #expect(
      try await itemDAO.progressTargetsAsync(
        accountId: accountId, libraryIds: [libraryId], serverItemIds: []
      ).isEmpty)
  }

  private func insertLibrary(
    _ database: AppDatabase, accountId: Int64, serverLibraryId: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: serverLibraryId, mediaType: "book",
        name: serverLibraryId)
      try library.insert(db)
      return library.id!
    }
  }

  private func insertAccountAndLibrary(_ database: AppDatabase, serverUserId: String = "user-1")
    async throws -> (accountId: Int64, libraryId: Int64)
  {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: serverUserId, serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }

  private func insertItem(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    mediaKind: String = "book",
    sortTitle: String,
    itemDescription: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    serverUpdatedAt: Date? = nil,
    hasServerArtwork: Bool? = nil,
    softDeleted: Bool = false
  ) async throws -> ItemRecord {
    try await ItemDAO(database: database).upsertAsync(
      PersistenceFixtures.item(
        accountId: accountId,
        libraryId: libraryId,
        serverItemId: serverItemId,
        mediaKind: mediaKind,
        title: sortTitle,
        sortTitle: sortTitle,
        itemDescription: itemDescription,
        expandedMetadataFetchedAt: expandedMetadataFetchedAt,
        serverUpdatedAt: serverUpdatedAt,
        hasServerArtwork: hasServerArtwork,
        softDeleted: softDeleted))
  }
}
