import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct PodcastCatalogueVisibilityTests {
  @Test("only an exact zero hides a podcast from the pure catalogue predicate")
  func exactZeroIsOnlyHiddenState() {
    let cases: [(mediaKind: String, count: Int?, visible: Bool)] = [
      ("podcast", 0, false),
      ("podcast", nil, true),
      ("podcast", -1, true),
      ("podcast", 1, true),
      ("book", 0, true),
    ]

    for value in cases {
      #expect(
        PodcastCatalogueVisibilityPredicate.matches(
          mediaKind: value.mediaKind, podcastServerEpisodeCount: value.count) == value.visible,
        "unexpected visibility for \(value.mediaKind) / \(String(describing: value.count))")
    }
  }

  @Test("all catalogue projections agree on nil, negative, positive, and zero counts")
  func catalogueProjectionsHaveListAndCountParity() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    for (id, count) in [
      ("podcast-zero", Optional(0)),
      ("podcast-nil", Optional<Int>.none),
      ("podcast-negative", Optional(-1)),
      ("podcast-positive", Optional(2)),
    ] {
      try await Self.insertItem(
        database, accountId: scope.accountId, libraryId: scope.libraryId, serverItemId: id,
        mediaKind: "podcast", count: count)
    }
    // A zero in the podcast-specific column must not hide a non-podcast item.
    try await Self.insertItem(
      database, accountId: scope.accountId, libraryId: scope.libraryId, serverItemId: "book-zero",
      mediaKind: "book", count: 0)

    let expectedAll = Set(["book-zero", "podcast-negative", "podcast-nil", "podcast-positive"])
    let expectedPodcasts = Set(["podcast-negative", "podcast-nil", "podcast-positive"])
    let library = DefaultLibraryReading(database: database)
    let search = DefaultSearchReading(database: database)
    let ordering = DefaultPodcastShowOrdering(database: database, accountId: scope.accountId)
    let home = DefaultHomeReading(database: database)

    var libraryIterator = library.observeBrowseList(libraryId: scope.serverLibraryId).makeAsyncIterator()
    let libraryRows = try #require(await libraryIterator.next())
    #expect(Set(libraryRows.map(\.serverItemId)) == expectedAll)
    #expect(library.itemCount == expectedAll.count)

    var categoryIterator = library.observeBrowseList(category: .podcast).makeAsyncIterator()
    let categoryRows = try #require(await categoryIterator.next())
    #expect(Set(categoryRows.map(\.serverItemId)) == expectedPodcasts)

    var filteredIterator = library.observeBrowseList(filters: .unfiltered).makeAsyncIterator()
    let filtered = try #require(await filteredIterator.next())
    #expect(Set(filtered.items.map(\.serverItemId)) == expectedAll)
    #expect(filtered.unfilteredItemCount == expectedAll.count)

    let ids = Array(expectedAll).sorted()
    let admitted = try await search.admittedItemIDs(ids, filters: .unfiltered)
    #expect(admitted == expectedAll)
    let searchPage = try await search.searchItems(
      query: "podcast", libraryIDs: nil, filters: .unfiltered, limit: 20, offset: 0)
    #expect(Set(searchPage.rows.map(\.entityID)) == expectedPodcasts)

    // Search each item's own title so every expected row exercises the matched CTE's predicate.
    for id in expectedAll {
      let page = try await search.searchItems(
        query: id, libraryIDs: nil, filters: .unfiltered, limit: 20, offset: 0)
      #expect(page.rows.map(\.entityID) == [id])
    }

    #expect(Set((await ordering.fetchShows()).shows.map(\.serverItemId)) == expectedPodcasts)

    var homeIterator = home.observeRecentlyAdded(category: nil, limit: 20).makeAsyncIterator()
    let homeRows = try #require(await homeIterator.next())
    #expect(Set(homeRows.map(\.serverItemId)) == expectedAll)

    // Catalogue filtering must not make a retained empty container impossible to address directly.
    #expect(library.currentItemDetail(itemId: "podcast-zero") != nil)
  }

  @Test("positive to zero hides a show live and zero to positive restores it")
  func catalogueVisibilityTransitionsAreLive() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    let itemId = try await Self.insertItem(
      database, accountId: scope.accountId, libraryId: scope.libraryId, serverItemId: "transition",
      mediaKind: "podcast", count: 1)
    let library = DefaultLibraryReading(database: database)
    let ordering = DefaultPodcastShowOrdering(database: database, accountId: scope.accountId)
    let home = DefaultHomeReading(database: database)

    var libraryIterator = library.observeBrowseList(libraryId: scope.serverLibraryId).makeAsyncIterator()
    var orderingIterator = ordering.observeShows().makeAsyncIterator()
    var homeIterator = home.observeRecentlyAdded(category: .podcast, limit: 10).makeAsyncIterator()
    #expect(try #require(await libraryIterator.next()).map(\.serverItemId) == ["transition"])
    #expect(try #require(await orderingIterator.next()).shows.map(\.serverItemId) == ["transition"])
    #expect(try #require(await homeIterator.next()).map(\.serverItemId) == ["transition"])

    try await Self.setCount(database, itemId: itemId, count: 0)
    #expect(try #require(await libraryIterator.next()).isEmpty)
    #expect(try #require(await orderingIterator.next()).shows.isEmpty)
    #expect(try #require(await homeIterator.next()).isEmpty)

    let search = DefaultSearchReading(database: database)
    #expect(
      try await search.admittedItemIDs(["transition"], filters: .unfiltered).isEmpty)
    #expect(
      try await search.searchItems(
        query: "transition", libraryIDs: nil, filters: .unfiltered, limit: 10, offset: 0
      ).rows.isEmpty)
    #expect(library.itemCount == 0)

    // A later positive observation makes the same retained row visible again without any
    // re-subscription.
    try await Self.setCount(database, itemId: itemId, count: 1)
    #expect(try #require(await libraryIterator.next()).map(\.serverItemId) == ["transition"])
    #expect(try #require(await orderingIterator.next()).shows.map(\.serverItemId) == ["transition"])
    #expect(try #require(await homeIterator.next()).map(\.serverItemId) == ["transition"])
    #expect(library.itemCount == 1)
  }

  private struct Scope {
    let accountId: Int64
    let libraryId: Int64
    let serverLibraryId: String
  }

  private static func seedScope(_ database: AppDatabase) async throws -> Scope {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "catalogue-test-client", serverBaseURL: "https://example.test",
        serverUserId: "catalogue-test-user", serverVersion: "2.35.1")
      try account.insert(db)
      let serverLibraryId = "catalogue-podcasts"
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: serverLibraryId, mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return Scope(accountId: account.id!, libraryId: library.id!, serverLibraryId: serverLibraryId)
    }
  }

  @discardableResult
  private static func insertItem(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    mediaKind: String,
    count: Int?
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        mediaKind: mediaKind, title: serverItemId, sortTitle: serverItemId,
        addedAt: Date(timeIntervalSince1970: 1_000), podcastServerEpisodeCount: count)
      try item.insert(db)
      return item.id!
    }
  }

  private static func setCount(_ database: AppDatabase, itemId: Int64, count: Int?) async throws {
    try await database.writeAsync { db in
      try ItemRecord
        .filter(Column("id") == itemId)
        .updateAll(db, Column("podcastServerEpisodeCount").set(to: count))
    }
  }
}
