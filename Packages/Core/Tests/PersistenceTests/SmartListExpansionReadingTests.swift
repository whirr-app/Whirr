import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct SmartListExpansionReadingTests {
  // MARK: - Naming

  @Test func onlyScopeNamesItsIncludedAndPriorityShowsOnly() async throws {
    let fixture = try await Fixture()
    let a = try await fixture.insertShow("a", count: 10)
    let b = try await fixture.insertShow("b", count: nil)
    _ = try await fixture.insertShow("c", count: 3)
    let list = try await fixture.makeList(
      scope: .only, shows: [("a", .included), ("b", .priority), ("c", .excluded)])

    let named = try await fixture.reading.namedShows(accountID: fixture.accountID, listID: list)

    #expect(named.map(\.localItemID) == [a, b])
    #expect(named.map(\.knownEpisodeCount) == [10, nil])
    #expect(named.map(\.serverItemID) == ["a", "b"])
  }

  @Test func allScopeNamesEveryPodcastInIncludedLibrariesOnly() async throws {
    let fixture = try await Fixture()
    let a = try await fixture.insertShow("a", count: 1)
    let b = try await fixture.insertShow("b", count: 1)
    _ = try await fixture.insertShow("book", mediaKind: "book")
    _ = try await fixture.insertShow("gone", softDeleted: true)
    _ = try await fixture.insertShow("hidden-library", libraryID: fixture.excludedLibraryID)
    let list = try await fixture.makeList(scope: .all, shows: [])

    let named = try await fixture.reading.namedShows(accountID: fixture.accountID, listID: list)

    #expect(named.map(\.localItemID) == [a, b])
  }

  @Test func allExceptScopeDropsItsExcludedShows() async throws {
    let fixture = try await Fixture()
    let a = try await fixture.insertShow("a", count: 1)
    _ = try await fixture.insertShow("b", count: 1)
    let c = try await fixture.insertShow("c", count: 1)
    let list = try await fixture.makeList(scope: .allExcept, shows: [("b", .excluded)])

    let named = try await fixture.reading.namedShows(accountID: fixture.accountID, listID: list)

    #expect(named.map(\.localItemID) == [a, c])
  }

  @Test func keysOfAnotherUserAndNativeRowsNameNothing() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.insertShow("a", count: 1)
    let list = try await SmartListStore(database: fixture.database).create(
      name: "Foreign", rules: SmartListRules(showScope: .only),
      shows: [
        SmartListShowSelection(
          ref: .server(serverUserID: "someone-else", serverItemID: "a"), role: .included,
          titleSnapshot: "a"),
        SmartListShowSelection(
          ref: .native(feedURL: "user|a"), role: .included, titleSnapshot: "a"),
      ]
    ).id

    #expect(
      try await fixture.reading.namedShows(accountID: fixture.accountID, listID: list).isEmpty)
  }

  @Test func withoutAListIdEveryListContributesOnce() async throws {
    let fixture = try await Fixture()
    let a = try await fixture.insertShow("a", count: 1)
    let b = try await fixture.insertShow("b", count: 1)
    _ = try await fixture.insertShow("c", count: 1)
    _ = try await fixture.makeList(scope: .only, shows: [("a", .included)])
    _ = try await fixture.makeList(scope: .only, shows: [("a", .priority), ("b", .included)])

    let named = try await fixture.reading.namedShows(accountID: fixture.accountID)

    #expect(named.map(\.localItemID) == [a, b])
  }

  // MARK: - Updating

  @Test func aListIsUpdatingUntilEveryNamedShowIsComplete() async throws {
    let fixture = try await Fixture()
    let a = try await fixture.insertShow("a", count: 1)
    let b = try await fixture.insertShow("b", count: 1)
    let list = try await fixture.makeList(scope: .only, shows: [("a", .included), ("b", .included)])
    let store = PodcastCatalogRefreshStore(database: fixture.database)

    #expect(try await fixture.reading.isUpdating(listID: list, accountID: fixture.accountID))
    try await store.recordSuccess(
      itemID: a, at: Date(timeIntervalSince1970: 10), episodeListIsComplete: true)
    try await store.recordSuccess(itemID: b, at: Date(timeIntervalSince1970: 10))
    #expect(try await fixture.reading.isUpdating(listID: list, accountID: fixture.accountID))
    try await store.recordSuccess(
      itemID: b, at: Date(timeIntervalSince1970: 20), episodeListIsComplete: true)
    #expect(try await fixture.reading.isUpdating(listID: list, accountID: fixture.accountID) == false)
  }

  @Test func aListNamingNothingOnTheDeviceIsNotUpdating() async throws {
    let fixture = try await Fixture()
    let list = try await fixture.makeList(scope: .only, shows: [("missing", .included)])

    #expect(try await fixture.reading.isUpdating(listID: list, accountID: fixture.accountID) == false)
  }

  @Test func observationYieldsTheCurrentValueFirst() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.insertShow("a", count: 1)
    let list = try await fixture.makeList(scope: .only, shows: [("a", .included)])

    var iterator = fixture.reading.observeIsUpdating(listID: list, accountID: fixture.accountID)
      .makeAsyncIterator()

    #expect(await iterator.next() == true)
  }

  // MARK: - Fixture

  private struct Fixture {
    let database: AppDatabase
    let accountID: Int64
    let libraryID: Int64
    let excludedLibraryID: Int64
    var reading: SmartListExpansionReading { SmartListExpansionReading(database: database) }

    init() async throws {
      database = try AppDatabase.inMemory()
      (accountID, libraryID, excludedLibraryID) = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: "expansion-client", serverBaseURL: "https://example.test",
          serverUserId: "user", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast",
          name: "Podcasts")
        try library.insert(db)
        var excluded = LibraryRecord(
          accountId: account.id!, serverLibraryId: "excluded", mediaType: "podcast",
          name: "Excluded", isIncluded: false)
        try excluded.insert(db)
        return (account.id!, library.id!, excluded.id!)
      }
    }

    @discardableResult
    func insertShow(
      _ serverID: String, count: Int? = nil, mediaKind: String = "podcast",
      softDeleted: Bool = false, libraryID: Int64? = nil
    ) async throws -> Int64 {
      try await database.writeAsync { [accountID, self] db in
        var item = ItemRecord(
          accountId: accountID, libraryId: libraryID ?? self.libraryID, serverItemId: serverID,
          mediaKind: mediaKind, title: serverID, sortTitle: serverID,
          podcastServerEpisodeCount: count, softDeleted: softDeleted)
        try item.insert(db)
        return item.id!
      }
    }

    func makeList(
      scope: SmartListShowScope, shows: [(String, SmartListShowRole)]
    ) async throws -> Int64 {
      try await SmartListStore(database: database).create(
        name: "List \(UUID().uuidString.prefix(6))", rules: SmartListRules(showScope: scope),
        shows: shows.map {
          SmartListShowSelection(
            ref: .server(serverUserID: "user", serverItemID: $0.0), role: $0.1,
            titleSnapshot: $0.0)
        }
      ).id
    }
  }
}
