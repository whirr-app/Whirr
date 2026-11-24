import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct PodcastShowOrderingTests {
  @Test("no stored preference orders live podcasts by sortTitle, then server id")
  func absentPreferenceOrdersLivePodcastsBySortTitleThenID() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedShow(database, account: account, id: "show-b", sortTitle: "bravo")
    try await Self.seedShow(database, account: account, id: "show-a2", sortTitle: "alpha")
    try await Self.seedShow(database, account: account, id: "show-a1", sortTitle: "alpha")
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)

    let snapshot = await store.fetchShows()
    #expect(snapshot.mode == .alphabetical)
    #expect(snapshot.shows.map(\.serverItemId) == ["show-a1", "show-a2", "show-b"])
  }

  @Test("an unrecognized stored mode falls back to alphabetical and still lists every show")
  func unknownStoredModeFallsBackToAlphabeticalWithoutHidingShows() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedShow(database, account: account, id: "show-a", sortTitle: "alpha")
    try await Self.seedShow(database, account: account, id: "show-b", sortTitle: "bravo")
    try await Self.seedShow(database, account: account, id: "show-c", sortTitle: "charlie")
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-b", "show-a"])

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastShowOrder SET mode = 'haphazard' WHERE accountId = ?",
        arguments: [account.accountId])
    }

    let snapshot = await store.fetchShows()
    #expect(snapshot.mode == .alphabetical)
    #expect(snapshot.shows.map(\.serverItemId) == ["show-a", "show-b", "show-c"])
  }

  @Test("the show query excludes books, other accounts, and soft-deleted shows")
  func alphabeticalQueryExcludesBooksAndSoftDeletedShows() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    let other = try await Self.seedAccount(database, suffix: "other")
    try await Self.seedShow(database, account: account, id: "show-a", sortTitle: "alpha")
    try await Self.seedShow(database, account: account, id: "show-b", sortTitle: "bravo")
    try await Self.seedShow(
      database, account: account, id: "show-gone", sortTitle: "charlie", softDeleted: true)
    try await Self.seedBook(database, account: account, id: "book-a", sortTitle: "aardvark")
    try await Self.seedShow(database, account: other, id: "show-elsewhere", sortTitle: "aaa")

    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    #expect(await store.fetchShows().shows.map(\.serverItemId) == ["show-a", "show-b"])
  }

  @Test("custom order lists positioned shows first, in position order")
  func customOrderPlacesPositionedShowsFirst() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    try await database.writeAsync { db in
      var excludedLibrary = LibraryRecord(
        accountId: account.accountId, serverLibraryId: "excluded-podcasts", mediaType: "podcast",
        name: "Excluded", isIncluded: false)
      try excludedLibrary.insert(db)
      var excludedShow = ItemRecord(
        accountId: account.accountId, libraryId: excludedLibrary.id!, serverItemId: "excluded-show",
        mediaKind: "podcast", title: "Excluded", sortTitle: "excluded")
      try excludedShow.insert(db)
    }
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)

    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    let snapshot = await store.fetchShows()
    #expect(snapshot.mode == .custom)
    #expect(snapshot.shows.map(\.serverItemId) == ["show-c", "show-a", "show-b"])
  }

  @Test("shows synced after a custom order append alphabetically among themselves")
  func newUnpositionedShowsAppendAlphabetically() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    // Inserted in reverse alphabetical order, and with sortTitles that would sort first, so the
    // assertion can only pass if unpositioned shows are appended and sorted among themselves.
    try await Self.seedShow(database, account: account, id: "show-e", sortTitle: "aardvark-e")
    try await Self.seedShow(database, account: account, id: "show-d", sortTitle: "aardvark-d")

    #expect(
      await store.fetchShows().shows.map(\.serverItemId) == [
        "show-c", "show-a", "show-b", "show-d", "show-e",
      ])
  }

  @Test("a replacement persists dense zero-based positions and no outbox row")
  func replaceCustomOrderPersistsDensePositions() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)

    try await store.replaceCustomOrder(itemIDs: ["show-b", "show-c", "show-a"])
    try await store.replaceCustomOrder(itemIDs: ["show-a", "show-c", "show-b"])

    #expect(try Self.entries(database, account: account) == ["show-a:0", "show-c:1", "show-b:2"])
    let outboxCount = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outboxOperation")
    }
    #expect(outboxCount == 0)
  }

  @Test("a replacement must name every live podcast exactly once")
  func replaceCustomOrderRequiresEveryLivePodcastExactlyOnce() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)

    await #expect(throws: PodcastShowOrderingError.missingItemIDs(["show-c"])) {
      try await store.replaceCustomOrder(itemIDs: ["show-b", "show-a"])
    }
    #expect(try Self.entries(database, account: account).isEmpty)
    #expect(await store.fetchShows().mode == .alphabetical)
  }

  @Test("a replacement naming the same show twice is rejected before any mutation")
  func replaceCustomOrderRejectsDuplicateIDsWithoutMutation() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    await #expect(throws: PodcastShowOrderingError.duplicateItemID("show-a")) {
      try await store.replaceCustomOrder(itemIDs: ["show-a", "show-a", "show-b"])
    }
    #expect(
      try Self.entries(database, account: account) == ["show-c:0", "show-a:1", "show-b:2"])
    #expect(await store.fetchShows().shows.map(\.serverItemId) == ["show-c", "show-a", "show-b"])
  }

  @Test("unknown, non-podcast, and other-account ids are rejected before any mutation")
  func replaceCustomOrderRejectsUnknownNonPodcastAndOtherAccountIDs() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    let other = try await Self.seedAccount(database, suffix: "other")
    try await Self.seedThreeShows(database, account: account)
    try await Self.seedBook(database, account: account, id: "book-a", sortTitle: "aardvark")
    try await Self.seedShow(database, account: other, id: "show-elsewhere", sortTitle: "aaa")
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    for rejected in ["show-nonexistent", "book-a", "show-elsewhere"] {
      await #expect(throws: PodcastShowOrderingError.unknownItemID(rejected)) {
        try await store.replaceCustomOrder(
          itemIDs: ["show-a", "show-b", "show-c", rejected])
      }
      #expect(
        try Self.entries(database, account: account) == ["show-c:0", "show-a:1", "show-b:2"])
    }
  }

  @Test(
    "failure at either replacement checkpoint rolls the whole replacement back",
    arguments: [
      PodcastShowOrderMutationCheckpoint.afterDeletingPositions,
      PodcastShowOrderMutationCheckpoint.afterInsertingPositions,
    ])
  func replacementIsAtomicAtDeleteAndInsertFailureCheckpoints(
    checkpointToFail: PodcastShowOrderMutationCheckpoint
  ) async throws {
    struct InjectedFailure: Error {}
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    let failing = DefaultPodcastShowOrdering(
      database: database, accountId: account.accountId,
      mutationCheckpoint: { checkpoint in
        if checkpoint == checkpointToFail { throw InjectedFailure() }
      })
    await #expect(throws: InjectedFailure.self) {
      try await failing.replaceCustomOrder(itemIDs: ["show-a", "show-b", "show-c"])
    }

    #expect(
      try Self.entries(database, account: account) == ["show-c:0", "show-a:1", "show-b:2"])
    #expect(await store.fetchShows().shows.map(\.serverItemId) == ["show-c", "show-a", "show-b"])
  }

  @Test("reset removes the mode row and every position row in one transaction")
  func resetDeletesModeAndPositionsAtomically() async throws {
    struct InjectedFailure: Error {}
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    let failing = DefaultPodcastShowOrdering(
      database: database, accountId: account.accountId,
      mutationCheckpoint: { checkpoint in
        if checkpoint == .afterDeletingPositions { throw InjectedFailure() }
      })
    await #expect(throws: InjectedFailure.self) { try await failing.resetToAlphabetical() }
    #expect(
      try Self.entries(database, account: account) == ["show-c:0", "show-a:1", "show-b:2"])
    #expect(await store.fetchShows().mode == .custom)

    try await store.resetToAlphabetical()
    #expect(try Self.entries(database, account: account).isEmpty)
    #expect(try Self.modeRowCount(database, account: account) == 0)
    let snapshot = await store.fetchShows()
    #expect(snapshot.mode == .alphabetical)
    #expect(snapshot.shows.map(\.serverItemId) == ["show-a", "show-b", "show-c"])
  }

  @Test("a soft-deleted show disappears from the snapshot but keeps its stored position")
  func softDeletedShowRetainsPositionUntilAReplacementOccurs() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    try await Self.setSoftDeleted(database, id: "show-a", softDeleted: true)
    #expect(await store.fetchShows().shows.map(\.serverItemId) == ["show-c", "show-b"])
    #expect(
      try Self.entries(database, account: account) == ["show-c:0", "show-a:1", "show-b:2"])

    try await Self.setSoftDeleted(database, id: "show-a", softDeleted: false)
    #expect(await store.fetchShows().shows.map(\.serverItemId) == ["show-c", "show-a", "show-b"])
  }

  @Test("a replacement made while a show is absent drops that show's position")
  func replacementDropsAbsentShowPosition() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])

    try await Self.setSoftDeleted(database, id: "show-a", softDeleted: true)
    try await store.replaceCustomOrder(itemIDs: ["show-b", "show-c"])
    #expect(try Self.entries(database, account: account) == ["show-b:0", "show-c:1"])

    try await Self.setSoftDeleted(database, id: "show-a", softDeleted: false)
    #expect(await store.fetchShows().shows.map(\.serverItemId) == ["show-b", "show-c", "show-a"])
  }

  @Test("custom order survives reopening an on-disk database")
  func relaunchPreservesCustomOrder() async throws {
    try await withOnDiskDatabases { scope in
      let database = try scope.open()
      let account = try await Self.seedAccount(database)
      try await Self.seedThreeShows(database, account: account)
      try await DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
        .replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])
      scope.close(database)

      let reopened = try scope.open(at: scope.url())
      let snapshot = await DefaultPodcastShowOrdering(
        database: reopened, accountId: account.accountId
      ).fetchShows()
      #expect(snapshot.mode == .custom)
      #expect(snapshot.shows.map(\.serverItemId) == ["show-c", "show-a", "show-b"])
    }
  }

  @Test("observation re-emits the committed order after a replacement and after a reset")
  func observationEmitsAfterReplaceAndReset() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    let observations = PersistenceObservationCollector(store.observeShows())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    var snapshot = try #require(observations.values.first)
    #expect(snapshot.mode == .alphabetical)
    #expect(snapshot.shows.map(\.serverItemId) == ["show-a", "show-b", "show-c"])

    try await store.replaceCustomOrder(itemIDs: ["show-c", "show-a", "show-b"])
    #expect(await TestSupport.waitUntil { observations.contains { $0.mode == .custom } })
    snapshot = try #require(observations.last { $0.mode == .custom })
    #expect(snapshot.shows.map(\.serverItemId) == ["show-c", "show-a", "show-b"])

    try await store.resetToAlphabetical()
    #expect(await TestSupport.waitUntil { observations.contains { $0.mode == .alphabetical } })
    snapshot = try #require(observations.last { $0.mode == .alphabetical })
    #expect(snapshot.shows.map(\.serverItemId) == ["show-a", "show-b", "show-c"])
  }

  @Test("show-list observation removes and restores an excluded library live")
  func showListObservationTracksLibraryInclusion() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await Self.seedThreeShows(database, account: account)
    let store = DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
    let observations = PersistenceObservationCollector(store.observeShows())
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.shows.map(\.serverItemId) == ["show-a", "show-b", "show-c"] }
      })

    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("id") == account.podcastLibraryId)
        .updateAll(db, Column("isIncluded").set(to: false))
    }
    #expect(await TestSupport.waitUntil { observations.contains { $0.shows.isEmpty } })

    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("id") == account.podcastLibraryId)
        .updateAll(db, Column("isIncluded").set(to: true))
    }
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.shows.map(\.serverItemId) == ["show-a", "show-b", "show-c"] }
      })
  }

  // MARK: - Fixtures

  private struct Account {
    let accountId: Int64
    let podcastLibraryId: Int64
    let bookLibraryId: Int64
  }

  private static func seedAccount(
    _ database: AppDatabase, suffix: String = "primary"
  ) async throws -> Account {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)", serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)
      var podcasts = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts-\(suffix)", mediaType: "podcast",
        name: "Podcasts")
      try podcasts.insert(db)
      var books = LibraryRecord(
        accountId: account.id!, serverLibraryId: "books-\(suffix)", mediaType: "book",
        name: "Books")
      try books.insert(db)
      return Account(
        accountId: account.id!, podcastLibraryId: podcasts.id!, bookLibraryId: books.id!)
    }
  }

  private static func seedThreeShows(_ database: AppDatabase, account: Account) async throws {
    try await seedShow(database, account: account, id: "show-a", sortTitle: "alpha")
    try await seedShow(database, account: account, id: "show-b", sortTitle: "bravo")
    try await seedShow(database, account: account, id: "show-c", sortTitle: "charlie")
  }

  private static func seedShow(
    _ database: AppDatabase,
    account: Account,
    id: String,
    sortTitle: String,
    softDeleted: Bool = false
  ) async throws {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: account.accountId, libraryId: account.podcastLibraryId, serverItemId: id,
        mediaKind: "podcast", title: sortTitle, sortTitle: sortTitle, softDeleted: softDeleted)
      try item.insert(db)
    }
  }

  private static func seedBook(
    _ database: AppDatabase, account: Account, id: String, sortTitle: String
  ) async throws {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: account.accountId, libraryId: account.bookLibraryId, serverItemId: id,
        mediaKind: "book", title: sortTitle, sortTitle: sortTitle, numAudioFiles: 3)
      try item.insert(db)
    }
  }

  private static func setSoftDeleted(
    _ database: AppDatabase, id: String, softDeleted: Bool
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = ? WHERE serverItemId = ?",
        arguments: [softDeleted, id])
    }
  }

  /// `"<serverItemId>:<position>"` per stored row, in position order. One comparable value that
  /// asserts identity, density, and order together.
  private static func entries(
    _ database: AppDatabase, account: Account
  ) throws -> [String] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT item.serverItemId AS serverItemId, entry.position AS position
          FROM podcastShowOrderEntry AS entry
          JOIN item ON item.id = entry.itemId AND item.accountId = entry.accountId
          WHERE entry.accountId = ?
          ORDER BY entry.position
          """,
        arguments: [account.accountId]
      ).map { "\($0["serverItemId"] as String):\($0["position"] as Int)" }
    }
  }

  private static func modeRowCount(_ database: AppDatabase, account: Account) throws -> Int {
    try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM podcastShowOrder WHERE accountId = ?",
        arguments: [account.accountId]) ?? 0
    }
  }
}
