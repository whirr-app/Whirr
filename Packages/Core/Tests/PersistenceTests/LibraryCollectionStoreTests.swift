import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Persistence for library collections.
@Suite struct LibraryCollectionStoreTests {
  @Test func replaceAndReadBackKeepsServerOrderAndCountsOnlyHeldMembers() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)

    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [
        list("col-b", name: "Beta", members: ["held-2", "missing", "held-1"]),
        list("col-a", name: "alpha", members: ["held-1"]),
      ])

    #expect(await store.hasSnapshot(accountID: fixture.accountID, libraryID: "books", kind: .collection))
    #expect(
      await store.hasSnapshot(accountID: fixture.accountID, libraryID: "books", kind: .playlist)
        == false)
    let listings = await store.listings(accountID: fixture.accountID)
    #expect(listings.map(\.key.serverID) == ["col-a", "col-b"])
    #expect(listings.map(\.heldMemberCount) == [1, 2])
    #expect(listings.first?.libraryName == "Books")

    let members = try #require(
      await store.members(accountID: fixture.accountID, key: key("col-b")))
    #expect(members.map(\.serverItemID) == ["held-2", "missing", "held-1"])
    #expect(members.map(\.isHeld) == [true, false, true])
  }

  @Test func emptyReplaceIsAFetchedSnapshotAndOtherKindIsUntouched() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("col", members: ["held-1"])])
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .playlist,
      lists: [list("pl", members: ["held-1"])])

    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection, lists: [])

    #expect(await store.hasSnapshot(accountID: fixture.accountID, libraryID: "books", kind: .collection))
    #expect(await store.listings(accountID: fixture.accountID).map(\.key.serverID) == ["pl"])
    #expect(await store.members(accountID: fixture.accountID, key: key("col")) == nil)
  }

  @Test func episodeMembersMatchThroughTheirShowItem() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .playlist,
      lists: [
        LibraryCollectionSnapshotList(
          serverID: "pl", name: "Mixed", description: nil, lastUpdate: nil,
          members: [
            LibraryCollectionSnapshotMember(
              serverItemID: "show", serverEpisodeID: "ep-live", fallbackTitle: "Live"),
            LibraryCollectionSnapshotMember(
              serverItemID: "show", serverEpisodeID: "ep-unknown", fallbackTitle: "Unknown"),
            LibraryCollectionSnapshotMember(
              serverItemID: "show", serverEpisodeID: "ep-deleted", fallbackTitle: nil),
          ])
      ])

    let members = try #require(
      await store.members(accountID: fixture.accountID, key: key("pl", kind: .playlist)))
    #expect(members.map(\.isHeld) == [true, false, false])
    #expect(members.first?.episodeID != nil)
    #expect(members[1].fallbackTitle == "Unknown")
    #expect(await store.listings(accountID: fixture.accountID).first?.heldMemberCount == 1)
  }

  @Test func softDeletedAndOtherLibraryItemsAreNotHeld() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("col", members: ["soft-deleted", "other-library-item"])])

    let members = try #require(await store.members(accountID: fixture.accountID, key: key("col")))
    #expect(members.map(\.isHeld) == [false, false])
  }

  @Test func repeatedServerIDKeepsTheFirstList() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("col", name: "First", members: []), list("col", name: "Second", members: [])])

    #expect(await store.listings(accountID: fixture.accountID).map(\.name) == ["First"])
  }

  @Test func excludedLibraryIsNeitherReadNorReplaced() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("col", members: [])])
    try await fixture.database.writeAsync { db in
      try db.execute(sql: "UPDATE library SET isIncluded = 0 WHERE serverLibraryId = 'books'")
    }

    #expect(await store.listings(accountID: fixture.accountID).isEmpty)
    #expect(
      await store.hasSnapshot(accountID: fixture.accountID, libraryID: "books", kind: .collection)
        == false)
    let replaced = try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("other", members: [])])
    #expect(replaced == false)
  }

  @Test func libraryAndAccountRemovalCascadeEveryRow() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    for kind in LibraryCollectionListKind.allCases {
      try await store.replaceSnapshot(
        accountID: fixture.accountID, libraryID: "books", kind: kind,
        lists: [list("x", members: ["held-1"])])
      try await store.replaceSnapshot(
        accountID: fixture.accountID, libraryID: "other", kind: kind,
        lists: [list("y", members: ["other-library-item"])])
    }
    #expect(try await Self.rowCounts(fixture.database) == [4, 4, 4])

    try await fixture.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM library WHERE serverLibraryId = 'other'")
    }
    #expect(try await Self.rowCounts(fixture.database) == [2, 2, 2])

    try AccountRemover(database: fixture.database).removeAccount(accountId: fixture.accountID)
    #expect(try await Self.rowCounts(fixture.database) == [0, 0, 0])
  }

  // MARK: - Contents

  @Test func contentsKeepServerOrderJoinEpisodesThroughTheirShowAndHideAbsentMembers()
    async throws
  {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .playlist,
      lists: [
        LibraryCollectionSnapshotList(
          serverID: "pl", name: "Mixed", description: nil, lastUpdate: nil,
          members: [
            LibraryCollectionSnapshotMember(serverItemID: "held-2"),
            LibraryCollectionSnapshotMember(serverItemID: "missing"),
            LibraryCollectionSnapshotMember(serverItemID: "show", serverEpisodeID: "ep-live"),
            LibraryCollectionSnapshotMember(serverItemID: "show", serverEpisodeID: "ep-deleted"),
            LibraryCollectionSnapshotMember(serverItemID: "held-1"),
            LibraryCollectionSnapshotMember(serverItemID: "held-2"),
          ])
      ])

    let contents = try #require(
      await store.contents(accountID: fixture.accountID, key: key("pl", kind: .playlist)))

    #expect(contents.entries.map(\.id) == ["held-2", "show/ep-live", "held-1"])
    #expect(contents.listing.heldMemberCount == 3)
    #expect(contents.listing.heldCategories == [.audiobook, .podcast])
    guard case .episode(let episode) = contents.entries[1] else {
      Issue.record("expected an episode entry")
      return
    }
    #expect(episode.showTitle == "show")
    #expect(episode.title == "ep-live")
  }

  @Test func contentsCarryFinishedStateAndCategory() async throws {
    let fixture = try await Self.fixture()
    try await fixture.database.writeAsync { db in
      let held1 = try Int64.fetchOne(db, sql: "SELECT id FROM item WHERE serverItemId = 'held-1'")!
      var progress = MediaProgressRecord(
        accountId: fixture.accountID, itemId: held1, currentTime: 100, isFinished: true,
        localSequence: 1, origin: .server, originKey: "fixture")
      try progress.insert(db)
      try db.execute(
        sql: "UPDATE item SET numAudioFiles = 0, ebookFormat = 'epub' WHERE serverItemId = 'held-2'")
    }
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("col", members: ["held-1", "held-2"])])

    let contents = try #require(
      await store.contents(accountID: fixture.accountID, key: key("col")))

    #expect(contents.entries.map(\.isFinished) == [true, false])
    #expect(contents.entries.map(\.category) == [.audiobook, .ebook])
    #expect(contents.listing.heldCategories == [.audiobook, .ebook])
  }

  @Test func contentsFollowTheServerIdentityAcrossAReplaceAndReportARemovedList() async throws {
    let fixture = try await Self.fixture()
    let store = LibraryCollectionStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("col", name: "Before", members: ["held-1"])])
    var updates = store.observeContents(accountID: fixture.accountID, key: key("col"))
      .makeAsyncIterator()
    #expect(await updates.next()??.listing.name == "Before")

    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection,
      lists: [list("col", name: "After", members: ["held-2", "held-1"])])
    let replaced = await updates.next()
    #expect(replaced??.listing.name == "After")
    #expect(replaced??.entries.map(\.id) == ["held-2", "held-1"])

    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", kind: .collection, lists: [])
    let removed = await updates.next()
    #expect(removed == .some(nil))
  }

  // MARK: - Fixture

  private func key(
    _ serverID: String, kind: LibraryCollectionListKind = .collection
  ) -> LibraryCollectionKey {
    LibraryCollectionKey(serverLibraryID: "books", kind: kind, serverID: serverID)
  }

  private func list(
    _ serverID: String, name: String? = nil, members: [String]
  ) -> LibraryCollectionSnapshotList {
    LibraryCollectionSnapshotList(
      serverID: serverID, name: name, description: nil, lastUpdate: nil,
      members: members.map { LibraryCollectionSnapshotMember(serverItemID: $0) })
  }

  private static func rowCounts(_ database: AppDatabase) async throws -> [Int] {
    try await database.readAsync { db in
      try ["libraryCollectionSnapshot", "libraryCollection", "libraryCollectionMember"].map {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
      }
    }
  }

  /// Library "books" holds held-1, held-2, a soft-deleted item and a show with one live and one
  /// soft-deleted episode; library "other" holds other-library-item.
  private static func fixture() async throws -> (database: AppDatabase, accountID: Int64) {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)
      let accountID = account.id!
      var books = LibraryRecord(
        accountId: accountID, serverLibraryId: "books", mediaType: "book", name: "Books")
      try books.insert(db)
      var other = LibraryRecord(
        accountId: accountID, serverLibraryId: "other", mediaType: "book", name: "Other")
      try other.insert(db)

      func insertItem(_ serverID: String, library: Int64, kind: String = "book") throws -> Int64 {
        var item = PersistenceFixtures.item(
          accountId: accountID, libraryId: library, serverItemId: serverID, mediaKind: kind,
          title: serverID, sortTitle: serverID)
        try item.insert(db)
        return item.id!
      }
      _ = try insertItem("held-1", library: books.id!)
      _ = try insertItem("held-2", library: books.id!)
      let deleted = try insertItem("soft-deleted", library: books.id!)
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [deleted])
      _ = try insertItem("other-library-item", library: other.id!)
      let show = try insertItem("show", library: books.id!, kind: "podcast")
      for (episodeID, softDeleted) in [("ep-live", false), ("ep-deleted", true)] {
        var episode = PodcastEpisodeRecord(
          accountId: accountID, itemId: show, serverEpisodeId: episodeID, title: episodeID,
          lastSeenGeneration: 1)
        try episode.insert(db)
        try db.execute(
          sql: "UPDATE podcastEpisode SET softDeleted = ? WHERE id = ?",
          arguments: [softDeleted, episode.id!])
      }
      return accountID
    }
    return (database, accountID)
  }
}
