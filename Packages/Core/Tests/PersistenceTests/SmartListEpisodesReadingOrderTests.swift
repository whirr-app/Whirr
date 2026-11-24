import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("SmartListEpisodesReading order and run reads", .timeLimit(.minutes(1)))
struct SmartListEpisodesReadingOrderTests {
  typealias World = SmartListReadingWorld

  /// Two feeds and a server show with a spread of dates, lengths and gaps, no progress.
  private func mixedWorld() async throws -> World {
    let w = try await World.make()
    let f1 = try await w.feed("https://f/1")
    let f2 = try await w.feed("https://f/2")
    let show = try await w.show("s")
    try await w.native(feed: f1, "n1", published: World.at(-100), duration: 600)
    try await w.native(feed: f1, "n2", published: World.at(-300), duration: 1_200)
    try await w.native(feed: f2, "n3", published: nil, duration: 900)
    try await w.native(feed: f2, "n4", published: World.at(-200), duration: nil)
    try await w.server(show: show, "s1", published: World.at(-100), duration: 600)
    try await w.server(show: show, "s2", published: nil, duration: nil)
    try await w.server(show: show, "s3", published: World.at(-400), duration: 1_200)
    return w
  }

  @Test("newest and oldest sort undated last, and ties break native before server then by key")
  func dateOrders() async throws {
    let w = try await mixedWorld()
    let newest = try await w.list(SmartListRules(sortOrder: .newest))
    #expect(try await w.ids(newest) == ["n:n1", "s:s1", "n:n4", "n:n2", "s:s3", "n:n3", "s:s2"])
    let oldest = try await w.list(SmartListRules(sortOrder: .oldest))
    #expect(try await w.ids(oldest) == ["s:s3", "n:n2", "n:n4", "n:n1", "s:s1", "n:n3", "s:s2"])
  }

  @Test("shortest and longest sort unknown length last")
  func lengthOrders() async throws {
    let w = try await mixedWorld()
    let shortest = try await w.list(SmartListRules(sortOrder: .shortest))
    #expect(try await w.ids(shortest) == ["n:n1", "s:s1", "n:n3", "n:n2", "s:s3", "n:n4", "s:s2"])
    let longest = try await w.list(SmartListRules(sortOrder: .longest))
    #expect(try await w.ids(longest) == ["n:n2", "s:s3", "n:n3", "n:n1", "s:s1", "n:n4", "s:s2"])
  }

  @Test("ties on the sort value break by source, show key, then episode id in byte order")
  func tieOrder() async throws {
    let w = try await World.make()
    let fb = try await w.feed("https://f/b")
    let fa = try await w.feed("https://f/a")
    let show = try await w.show("s")
    let same = World.at(-5)
    try await w.native(feed: fb, "z", published: same)
    try await w.native(feed: fa, "z", published: same)
    try await w.native(feed: fa, "B", published: same)
    try await w.native(feed: fa, "a", published: same)
    try await w.server(show: show, "x", published: same)
    let list = try await w.list()
    #expect(try await w.ids(list) == ["n:B", "n:a", "n:z", "n:z", "s:x"])
    let rows = try await w.snapshot(list).episodes
    #expect(rows.map(\.showKey).dropFirst(2).prefix(2) == ["https://f/a", "https://f/b"])
  }

  @Test("priority episodes come first in every order, then the order applies")
  func priorityFirst() async throws {
    let w = try await World.make()
    let f1 = try await w.feed("https://f/1")
    let f2 = try await w.feed("https://f/2")
    try await w.native(feed: f1, "new", published: World.at(-1))
    try await w.native(feed: f2, "oldPriority", published: World.at(-900))
    try await w.native(feed: f2, "undatedPriority")
    let shows: [SmartListShowSelection] = [.native("https://f/2", .priority)]
    for order in SmartListSortOrder.allCases {
      let list = try await w.list(SmartListRules(sortOrder: order), shows: shows)
      let ids = try await w.ids(list)
      #expect(ids.last == "n:new")
      #expect(Set(ids.prefix(2)) == ["n:oldPriority", "n:undatedPriority"])
    }
    let newest = try await w.list(SmartListRules(sortOrder: .newest), shows: shows)
    #expect(try await w.ids(newest) == ["n:oldPriority", "n:undatedPriority", "n:new"])
  }

  // MARK: Keyset

  @Test("after any row's key the next episode is the following row, in all four orders")
  func keysetMatchesListOrder() async throws {
    let w = try await mixedWorld()
    let reading = w.reading()
    for order in SmartListSortOrder.allCases {
      let list = try await w.list(SmartListRules(sortOrder: order))
      let rows = try await w.snapshot(list).episodes
      for (index, row) in rows.enumerated() {
        // Swift's comparator agrees with the SQL order on every pair.
        for later in rows.dropFirst(index + 1) {
          #expect(row.sortKey.precedes(later.sortKey), "\(order) \(row.episodeID) < \(later.episodeID)")
          #expect(!later.sortKey.precedes(row.sortKey))
        }
        let next = try await reading.nextEpisodes(listID: list, after: row.sortKey, count: 1)
        let expected = rows[(index + 1) % rows.count]
        #expect(next.map(\.episodeID) == [expected.episodeID], "\(order) after \(row.episodeID)")
      }
    }
  }

  @Test("next wraps from the top and returns several in one read")
  func wrapAndCount() async throws {
    let w = try await mixedWorld()
    let list = try await w.list(SmartListRules(sortOrder: .newest))
    let rows = try await w.snapshot(list).episodes
    let anchor = rows[rows.count - 2].sortKey
    let next = try await w.reading().nextEpisodes(listID: list, after: anchor, count: 4)
    #expect(
      next.map(\.episodeID)
        == [rows[6], rows[0], rows[1], rows[2]].map(\.episodeID))
  }

  @Test("an anchor whose row was deleted or finished still positions the next read")
  func anchorWithoutRow() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    try await w.native(feed: feed, "a", published: World.at(-1))
    let gone = try await w.native(feed: feed, "b", published: World.at(-2))
    try await w.native(feed: feed, "c", published: World.at(-3))
    let list = try await w.list()
    let anchor = try #require(try await w.snapshot(list).episodes.first { $0.episodeID == "b" }).sortKey
    try await w.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM rssEpisode WHERE id = ?", arguments: [gone])
    }
    let next = try await w.reading().nextEpisodes(listID: list, after: anchor, count: 1)
    #expect(next.map(\.episodeID) == ["c"])
  }

  @Test("undated and unknown-length tiers continue through the keyset in both directions")
  func nullTierKeyset() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    try await w.native(feed: feed, "dated", published: World.at(-1))
    try await w.native(feed: feed, "u1")
    try await w.native(feed: feed, "u2")
    for order in [SmartListSortOrder.newest, .oldest] {
      let list = try await w.list(SmartListRules(sortOrder: order))
      let rows = try await w.snapshot(list).episodes
      #expect(rows.map(\.episodeID) == ["dated", "u1", "u2"])
      let reading = w.reading()
      let afterDated = try await reading.nextEpisodes(
        listID: list, after: rows[0].sortKey, count: 2)
      #expect(afterDated.map(\.episodeID) == ["u1", "u2"])
      let afterU1 = try await reading.nextEpisodes(listID: list, after: rows[1].sortKey, count: 2)
      #expect(afterU1.map(\.episodeID) == ["u2", "dated"])
      let afterU2 = try await reading.nextEpisodes(listID: list, after: rows[2].sortKey, count: 1)
      #expect(afterU2.map(\.episodeID) == ["dated"])
    }
  }

  @Test("a priority episode cuts in ahead of the anchor's successor, but never the anchor itself")
  func priorityCutsIn() async throws {
    let w = try await World.make()
    let normal = try await w.feed("https://f/n")
    let news = try await w.feed("https://f/news")
    try await w.native(feed: normal, "b1", published: World.at(-1))
    try await w.native(feed: normal, "b2", published: World.at(-2))
    try await w.native(feed: normal, "b3", published: World.at(-3))
    let p1 = try await w.native(feed: news, "p1", published: World.at(-900))
    let list = try await w.list(shows: [.native("https://f/news", .priority)])
    let reading = w.reading()
    let b2 = try #require(try await w.snapshot(list).episodes.first { $0.episodeID == "b2" }).sortKey

    #expect(try await reading.nextEpisodes(listID: list, after: b2, count: 1).map(\.episodeID) == ["p1"])
    // With the priority episode as the anchor it is not offered again; the rest follow in order.
    let p1Key = try #require(try await w.snapshot(list).episodes.first { $0.episodeID == "p1" }).sortKey
    #expect(
      try await reading.nextEpisodes(listID: list, after: p1Key, count: 4).map(\.episodeID)
        == ["b1", "b2", "b3", "p1"])
    // Finished, it is gone and the run continues after the anchor.
    try await w.nativeProgress(p1, position: 1, finished: true)
    #expect(try await reading.nextEpisodes(listID: list, after: b2, count: 1).map(\.episodeID) == ["b3"])
    #expect(try await reading.nextEpisodes(listID: list, after: b2, count: 3).map(\.episodeID) == ["b3", "b1", "b2"])
  }

  @Test("a run reads unfinished episodes only, whatever the Played toggle, and honours excluding")
  func unfinishedOnlyAndExcluding() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    let done = try await w.native(feed: feed, "done", published: World.at(-1))
    try await w.nativeProgress(done, position: 10, finished: true)
    try await w.native(feed: feed, "open1", published: World.at(-2))
    try await w.native(feed: feed, "open2", published: World.at(-3))
    let sDone = try await w.server(show: show, "sdone", published: World.at(-4))
    try await w.serverProgress(show: show, episode: sDone, position: 10, finished: true)
    try await w.server(show: show, "sopen", published: World.at(-5))
    let list = try await w.list(SmartListRules(includePlayed: true))
    #expect(try await w.ids(list).count == 5)

    let reading = w.reading()
    #expect(
      try await reading.nextEpisodes(listID: list, after: nil, count: 10).map(\.episodeID)
        == ["open1", "open2", "sopen"])
    #expect(
      try await reading.topEpisodes(listID: list, count: 2).map(\.episodeID) == ["open1", "open2"])
    let rows = try await reading.nextEpisodes(
      listID: list, after: nil, excluding: [("rss:\(feed)", "open1"), ("s", "sopen")], count: 10)
    #expect(rows.map(\.episodeID) == ["open2"])
    #expect(try await reading.nextEpisodes(listID: list, after: nil, count: 0).isEmpty)
  }

  @Test("hidden episodes are never offered, and a missing list offers nothing")
  func hiddenAndMissing() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    try await w.native(feed: feed, "a", published: World.at(-1))
    try await w.native(feed: feed, "b", published: World.at(-2))
    let list = try await w.list()
    try await SmartListHiddenEpisodeStore(database: w.database).hide(
      listID: list, itemID: "rss:\(feed)", episodeID: "a")
    #expect(try await w.reading().topEpisodes(listID: list, count: 5).map(\.episodeID) == ["b"])
    #expect(try await w.reading().topEpisodes(listID: 999, count: 5).isEmpty)
    #expect(try await w.snapshot(999) == .empty)
  }

  // MARK: Key encoding

  @Test("a key round-trips through its stored text, and an anchor from another order starts at the top")
  func keyEncoding() async throws {
    let key = SmartListSortKey(
      order: .newest, isPriority: true, value: 1_900_000_000_123, source: .server,
      showKey: "u|é\"x", episodeID: "e/1")
    #expect(SmartListSortKey(encoded: key.encoded) == key)
    let undated = SmartListSortKey(
      order: .longest, isPriority: false, value: nil, source: .native, showKey: "k", episodeID: "e")
    #expect(SmartListSortKey(encoded: undated.encoded) == undated)
    #expect(SmartListSortKey(encoded: "not a key") == nil)

    let w = try await mixedWorld()
    let newest = try await w.list(SmartListRules(sortOrder: .newest))
    let longest = try await w.list(SmartListRules(sortOrder: .longest))
    let rows = try await w.snapshot(newest).episodes
    let stale = try await w.reading().nextEpisodes(
      listID: longest, after: rows[3].sortKey, count: 1)
    let top = try await w.reading().nextEpisodes(listID: longest, after: nil, count: 1)
    #expect(stale.map(\.episodeID) == top.map(\.episodeID))
  }

  @Test("the date part of a key survives a round trip through bound arguments at millisecond precision")
  func millisecondKeys() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let base = World.at(0)
    try await w.native(feed: feed, "a", published: base.addingTimeInterval(0.002))
    try await w.native(feed: feed, "b", published: base.addingTimeInterval(0.001))
    try await w.native(feed: feed, "c", published: base)
    let list = try await w.list()
    let rows = try await w.snapshot(list).episodes
    #expect(rows.map(\.episodeID) == ["a", "b", "c"])
    let next = try await w.reading().nextEpisodes(listID: list, after: rows[0].sortKey, count: 1)
    #expect(next.map(\.episodeID) == ["b"])
  }
}
