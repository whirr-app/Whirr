import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct SmartListSupportStoreTests {
  private func fixture() async throws -> (AppDatabase, SmartList, SmartList) {
    let database = try AppDatabase.inMemory()
    let store = SmartListStore(database: database)
    return (
      database, try await store.create(name: "A"), try await store.create(name: "B")
    )
  }

  @Test func aRunBeginsWithoutAnAnchorAndIsReplacedByTheNextBegin() async throws {
    let (database, a, b) = try await fixture()
    let runs = SmartListRunStore(database: database)
    #expect(try await runs.current() == nil)
    #expect(try await runs.setAnchor(itemID: "i", episodeID: "e", sortKey: "k") == false)

    try await runs.begin(listID: a.id, now: Date(timeIntervalSince1970: 5))
    var run = try #require(try await runs.current())
    #expect(run.listId == a.id)
    #expect(run.anchorItemID == nil && run.anchorEpisodeID == nil && run.anchorSortKey == nil)
    #expect(run.startedAt == Date(timeIntervalSince1970: 5))

    #expect(try await runs.setAnchor(itemID: "rss:1", episodeID: "g", sortKey: "key-1"))
    run = try #require(try await runs.current())
    #expect([run.anchorItemID, run.anchorEpisodeID, run.anchorSortKey] == ["rss:1", "g", "key-1"])

    try await runs.begin(listID: b.id)
    run = try #require(try await runs.current())
    #expect(run.listId == b.id)
    #expect(run.anchorSortKey == nil)
    let rows = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM smartListRun") ?? -1
    }
    #expect(rows == 1)

    try await runs.end()
    #expect(try await runs.current() == nil)
    await #expect(throws: SmartListStoreError.listNotFound) { try await runs.begin(listID: 999) }
  }

  @Test func observingTheRunEmitsEachChangeOnceAndSkipsRepeats() async throws {
    let (database, a, b) = try await fixture()
    let runs = SmartListRunStore(database: database)
    var iterator = runs.observeCurrent().makeAsyncIterator()
    #expect(await iterator.next() == .some(nil))

    try await runs.begin(listID: a.id)
    #expect(await iterator.next()??.listId == a.id)

    // Writing the same anchor twice is one change.
    try await runs.setAnchor(itemID: "rss:1", episodeID: "g", sortKey: "k")
    try await runs.setAnchor(itemID: "rss:1", episodeID: "g", sortKey: "k")
    #expect(await iterator.next()??.anchorEpisodeID == "g")

    try await runs.begin(listID: b.id)
    #expect(await iterator.next()??.listId == b.id)

    try await runs.end()
    #expect(await iterator.next() == .some(nil))
  }

  @Test func hideUnhideAndPrune() async throws {
    let (database, a, b) = try await fixture()
    let hidden = SmartListHiddenEpisodeStore(database: database)
    try await hidden.hide(listID: a.id, itemID: "rss:1", episodeID: "e1")
    try await hidden.hide(listID: a.id, itemID: "rss:1", episodeID: "e1")
    try await hidden.hide(listID: a.id, itemID: "rss:1", episodeID: "e2")
    try await hidden.hide(listID: b.id, itemID: "rss:1", episodeID: "e1")
    #expect(try await hidden.hiddenEpisodes(listID: a.id).map(\.episodeID) == ["e1", "e2"])

    try await hidden.unhide(listID: a.id, itemID: "rss:1", episodeID: "e2")
    #expect(try await hidden.hiddenEpisodes(listID: a.id).map(\.episodeID) == ["e1"])

    #expect(try await hidden.prune(episodes: [("rss:1", "e1"), ("rss:9", "none")]) == 2)
    #expect(try await hidden.hiddenEpisodes(listID: a.id).isEmpty)
    #expect(try await hidden.hiddenEpisodes(listID: b.id).isEmpty)
  }

  @Test func claimsAreOnePerListAndEpisodeAndListable() async throws {
    let (database, a, b) = try await fixture()
    let claims = SmartListDownloadClaimStore(database: database)
    try await claims.add(
      listID: a.id, itemID: "rss:1", episodeID: "e", accountID: nil,
      now: Date(timeIntervalSince1970: 1))
    try await claims.add(
      listID: a.id, itemID: "rss:1", episodeID: "e", accountID: nil,
      now: Date(timeIntervalSince1970: 2))
    try await claims.add(
      listID: b.id, itemID: "rss:1", episodeID: "e", accountID: nil,
      now: Date(timeIntervalSince1970: 3))

    let ofA = try await claims.claims(listID: a.id)
    #expect(ofA.count == 1)
    #expect(ofA.first?.claimedAt == Date(timeIntervalSince1970: 1))
    #expect(try await claims.allClaims().map(\.listId) == [a.id, b.id])

    try await claims.remove(listID: a.id, itemID: "rss:1", episodeID: "e")
    #expect(try await claims.claims(listID: a.id).isEmpty)
    #expect(try await claims.allClaims().count == 1)
  }
}
