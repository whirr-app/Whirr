import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct SmartListShowCatalogTests {
  private static let fingerprint = String(repeating: "cd", count: 32)

  private func first(_ world: SmartListReadingWorld) async throws -> [SmartListCatalogShow] {
    var iterator = DefaultSmartListShowCatalogReading(database: world.database).observeShows()
      .makeAsyncIterator()
    return try #require(await iterator.next())
  }

  @Test func listsFollowedFeedsAndTheAccountsPodcastShowsWithKeysAndFingerprints() async throws {
    let world = try await SmartListReadingWorld.make()
    try await world.feed("https://b.example/feed", title: "Bravo", fingerprint: Self.fingerprint)
    try await world.feed("https://a.example/feed", title: "alpha")
    try await world.show("s2", title: "Zulu", fingerprint: Self.fingerprint)
    try await world.show("s1", title: "Charlie")

    let shows = try await first(world)
    #expect(
      shows.map(\.ref) == [
        .native(feedURL: "https://a.example/feed"), .native(feedURL: "https://b.example/feed"),
        .server(serverUserID: "user-1", serverItemID: "s1"),
        .server(serverUserID: "user-1", serverItemID: "s2"),
      ])
    #expect(shows.map(\.title) == ["alpha", "Bravo", "Charlie", "Zulu"])
    #expect(shows.map(\.fingerprint).dropFirst() == [Self.fingerprint, nil, Self.fingerprint])
    #expect(shows.first?.fingerprint != nil)
  }

  @Test func signedOutHasOnlyTheNativeHalf() async throws {
    let world = try await SmartListReadingWorld.make(signedIn: false)
    try await world.feed("https://a.example/feed", title: "A")
    #expect(try await first(world).map(\.ref) == [.native(feedURL: "https://a.example/feed")])
  }

  @Test func aSoftDeletedShowAnExcludedLibraryAndAnotherAccountAreLeftOut() async throws {
    var world = try await SmartListReadingWorld.make()
    let gone = try await world.show("gone", title: "Gone")
    try await world.show("kept", title: "Kept")
    try await world.setSoftDeleted(item: gone)
    let accountID = try #require(world.accountId)
    try await world.database.writeAsync { db in
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "lib-excluded", mediaType: "podcast",
        name: "Excluded", isIncluded: false)
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountID, libraryId: try #require(library.id), serverItemId: "hidden",
        mediaKind: "podcast", title: "Hidden", sortTitle: "Hidden")
      try item.insert(db)
    }
    let firstAccount = try #require(world.accountId)
    try await world.signIn(userID: "user-2")
    try await world.show("other", title: "Other")
    #expect(try #require(world.accountId) != firstAccount)

    let shows = try await first(world)
    #expect(
      shows.map(\.ref) == [.server(serverUserID: "user-1", serverItemID: "kept")], "\(shows)")
  }

  @Test func aChangeIsObserved() async throws {
    let world = try await SmartListReadingWorld.make()
    var iterator = DefaultSmartListShowCatalogReading(database: world.database).observeShows()
      .makeAsyncIterator()
    #expect(try #require(await iterator.next()).isEmpty)
    try await world.feed("https://a.example/feed", title: "A")
    #expect(try #require(await iterator.next()).count == 1)
  }

  @Test func catalogKeysAreTheKeysTheReadingJoins() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed", title: "A")
    try await world.native(feed: feed, "n1", published: SmartListReadingWorld.at(-10))
    let show = try await world.show("s1", title: "S")
    try await world.server(show: show, "e1", published: SmartListReadingWorld.at(-20))
    try await world.server(show: try await world.show("s2", title: "Other"), "e2")

    for catalogShow in try await first(world) where catalogShow.title != "Other" {
      let list = try await world.list(
        SmartListRules(showScope: .only),
        shows: [
          SmartListShowSelection(ref: catalogShow.ref, role: .included, titleSnapshot: "x")
        ])
      let count = try await world.reading().matchCount(
        rules: SmartListRules(showScope: .only),
        shows: [SmartListShowSelection(ref: catalogShow.ref, role: .included, titleSnapshot: "x")])
      #expect(count == 1)
      let snapshot = try await world.reading().fetchSnapshot(listID: list)
      #expect(snapshot.episodes.map(\.showKey) == [catalogShow.ref.showKey])
    }
  }
}
