import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("SmartListEpisodesReading rules", .timeLimit(.minutes(1)))
struct SmartListEpisodesReadingRulesTests {
  typealias World = SmartListReadingWorld

  // MARK: Projection

  @Test("native ids are rss:<feedId> and the identityKey; server ids are the server's")
  func identities() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1", title: "Native Show")
    try await w.native(feed: feed, "guid-1", published: World.at(-10))
    let show = try await w.show("srv-show", title: "Server Show")
    try await w.server(show: show, "srv-ep", published: World.at(-20))
    let list = try await w.list()

    let rows = try await w.snapshot(list).episodes
    #expect(rows.count == 2)
    let native = try #require(rows.first { $0.source == .native })
    #expect(native.itemID == "rss:\(feed)" && native.episodeID == "guid-1")
    #expect(native.showKey == "https://f/1" && native.showTitle == "Native Show")
    #expect(native.title == "T-guid-1" && native.durationSeconds == 1_800)
    let server = try #require(rows.first { $0.source == .server })
    #expect(server.itemID == "srv-show" && server.episodeID == "srv-ep")
    #expect(server.showKey == "user-1|srv-show" && server.showTitle == "Server Show")
  }

  @Test("unknown length is nil for both sources, and measured length fills a native gap")
  func lengthUnknownRule() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    try await w.native(feed: feed, "none", duration: nil)
    try await w.native(feed: feed, "zero", duration: 0)
    try await w.native(feed: feed, "measured", duration: nil, measured: 900)
    try await w.native(feed: feed, "zeroThenMeasured", duration: 0, measured: 600)
    let show = try await w.show("s")
    try await w.server(show: show, "none", duration: nil)
    try await w.server(show: show, "negative", duration: -5)
    let list = try await w.list()

    let byID = Dictionary(
      uniqueKeysWithValues: try await w.snapshot(list).episodes.map {
        ("\($0.source):\($0.episodeID)", $0.durationSeconds)
      })
    #expect(byID["native:none"] == .some(nil))
    #expect(byID["native:zero"] == .some(nil))
    #expect(byID["native:measured"] == .some(900))
    #expect(byID["native:zeroThenMeasured"] == .some(600))
    #expect(byID["server:none"] == .some(nil))
    #expect(byID["server:negative"] == .some(nil))
  }

  // MARK: Status

  @Test("status toggles and the 60 second rule, both sources")
  func status() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    var offset = 0.0
    func next() -> Date {
      offset -= 1
      return World.at(offset)
    }
    // Native: 1,800 s long.
    for (key, state) in [
      ("unplayed", nil), ("started", (100.0, false)), ("finished", (10.0, true)),
      ("boundaryLeft60", (1_740.0, false)), ("left59", (1_741.0, false)),
      ("zeroRow", (0.0, false)),
    ] as [(String, (Double, Bool)?)] {
      let id = try await w.native(feed: feed, key, published: next())
      if let state { try await w.nativeProgress(id, position: state.0, finished: state.1) }
    }
    for (key, state) in [
      ("unplayed", nil), ("started", (100.0, false)), ("finished", (10.0, true)),
      ("boundaryLeft60", (1_740.0, false)), ("left59", (1_741.0, false)),
      ("zeroRow", (0.0, false)),
    ] as [(String, (Double, Bool)?)] {
      let id = try await w.server(show: show, key, published: next())
      if let state {
        try await w.serverProgress(show: show, episode: id, position: state.0, finished: state.1)
      }
    }

    func keys(_ rules: SmartListRules) async throws -> Set<String> {
      Set(try await w.ids(try await w.list(rules)))
    }
    func both(_ names: [String]) -> Set<String> {
      Set(names.flatMap { ["n:\($0)", "s:\($0)"] })
    }
    let unplayed = both(["unplayed", "zeroRow"])
    let started = both(["started", "boundaryLeft60"])
    let played = both(["finished", "left59"])

    #expect(try await keys(SmartListRules()) == unplayed.union(started))
    #expect(
      try await keys(SmartListRules(includeUnplayed: false, includeInProgress: false, includePlayed: true))
        == played)
    #expect(
      try await keys(SmartListRules(includeUnplayed: false, includeInProgress: true))
        == started)
    #expect(
      try await keys(SmartListRules(includeUnplayed: true, includeInProgress: false))
        == unplayed)
    #expect(
      try await keys(SmartListRules(includePlayed: true)) == unplayed.union(started).union(played))
    #expect(
      try await keys(SmartListRules(includeUnplayed: false, includeInProgress: false, includePlayed: true))
        .isDisjoint(with: unplayed.union(started)))
  }

  @Test("an episode shorter than a minute with a progress row is played; without a row it is not")
  func shortEpisodeUnderTheRule() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let fresh = try await w.native(feed: feed, "fresh", published: World.at(-1), duration: 45)
    let touched = try await w.native(feed: feed, "touched", published: World.at(-2), duration: 45)
    try await w.nativeProgress(touched, position: 5)
    _ = fresh
    let list = try await w.list(SmartListRules(includePlayed: true))
    let rows = try await w.snapshot(list).episodes
    #expect(rows.first { $0.episodeID == "fresh" }?.status == .unplayed)
    #expect(rows.first { $0.episodeID == "touched" }?.status == .played)
  }

  @Test("unknown length never counts as played by the 60 second rule")
  func unknownLengthIsNotPlayed() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let id = try await w.native(feed: feed, "open", published: World.at(-1), duration: nil)
    try await w.nativeProgress(id, position: 5_000)
    let rows = try await w.snapshot(try await w.list()).episodes
    #expect(rows.map(\.status) == [.inProgress])
  }

  // MARK: Download and saved

  @Test("download toggles count only completed rows, both sources")
  func download() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    let nDone = try await w.native(feed: feed, "done", published: World.at(-1))
    let nPending = try await w.native(feed: feed, "pending", published: World.at(-2))
    _ = try await w.native(feed: feed, "none", published: World.at(-3))
    try await w.nativeDownload(nDone)
    try await w.nativeDownload(nPending, state: .downloading)
    let sDone = try await w.server(show: show, "done", published: World.at(-4))
    _ = try await w.server(show: show, "none", published: World.at(-5))
    try await w.serverDownload(show: show, episode: sDone)

    let downloaded = try await w.list(SmartListRules(includeNotDownloaded: false))
    #expect(try await w.ids(downloaded) == ["n:done", "s:done"])
    let notDownloaded = try await w.list(SmartListRules(includeDownloaded: false))
    #expect(try await w.ids(notDownloaded) == ["n:pending", "n:none", "s:none"])
    let both = try await w.list()
    #expect(try await w.ids(both).count == 5)
    let rows = try await w.snapshot(both).episodes
    #expect(rows.filter(\.isDownloaded).map(\.episodeID) == ["done", "done"])
  }

  @Test("Saved for Later only, both sources")
  func savedOnly() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    let n = try await w.native(feed: feed, "saved", published: World.at(-1))
    _ = try await w.native(feed: feed, "plain", published: World.at(-2))
    let s = try await w.server(show: show, "saved", published: World.at(-3))
    _ = try await w.server(show: show, "plain", published: World.at(-4))
    try await w.nativeSave(n)
    try await w.serverSave(show: show, episode: s)
    let list = try await w.list(SmartListRules(savedOnly: true))
    #expect(try await w.ids(list) == ["n:saved", "s:saved"])
    #expect(try await w.snapshot(list).episodes.allSatisfy(\.isSaved))
  }

  // MARK: Release window

  @Test("release window includes the edge, drops older and undated, and Any time keeps undated")
  func releaseWindow() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    let day: TimeInterval = 86_400
    try await w.native(feed: feed, "fresh", published: World.at(-3_600))
    try await w.native(feed: feed, "edge", published: World.at(-day))
    try await w.native(feed: feed, "old", published: World.at(-day - 1))
    try await w.native(feed: feed, "undated")
    try await w.server(show: show, "fresh", published: World.at(-7_200))
    try await w.server(show: show, "old", published: World.at(-3 * day))
    try await w.server(show: show, "undated")

    let window = try await w.list(SmartListRules(releaseWindow: .day))
    #expect(try await w.ids(window) == ["n:fresh", "s:fresh", "n:edge"])
    let three = try await w.list(SmartListRules(releaseWindow: .threeDays))
    #expect(Set(try await w.ids(three)) == ["n:fresh", "n:edge", "n:old", "s:fresh", "s:old"])
    let any = try await w.list()
    #expect(try await w.ids(any).suffix(2).sorted() == ["n:undated", "s:undated"])
    #expect(try await w.ids(any).count == 7)
  }

  // MARK: Duration

  @Test("duration is strict at both ends and unknown length matches, both sources")
  func duration() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    var offset = 0.0
    func next() -> Date {
      offset -= 1
      return World.at(offset)
    }
    for (key, length) in [
      ("under", 1_000.0), ("atLower", 1_200.0), ("inside", 1_800.0), ("atUpper", 2_400.0),
      ("over", 3_000.0),
    ] {
      try await w.native(feed: feed, key, published: next(), duration: length)
      try await w.server(show: show, key, published: next(), duration: length)
    }
    try await w.native(feed: feed, "unknown", published: next(), duration: nil)
    try await w.server(show: show, "unknown", published: next(), duration: 0)
    let list = try await w.list(
      SmartListRules(durationFilter: true, longerThanMinutes: 20, shorterThanMinutes: 40))
    #expect(
      Set(try await w.ids(list)) == ["n:inside", "s:inside", "n:unknown", "s:unknown"])

    let off = try await w.list(
      SmartListRules(durationFilter: false, longerThanMinutes: 20, shorterThanMinutes: 40))
    #expect(try await w.ids(off).count == 12)
  }

  // MARK: Show scope and priority

  @Test("show scope all, only and all-except join both halves by their show keys")
  func showScope() async throws {
    let w = try await World.make()
    let feedA = try await w.feed("https://f/a")
    let feedB = try await w.feed("https://f/b")
    let showA = try await w.show("a")
    let showB = try await w.show("b")
    try await w.native(feed: feedA, "nA", published: World.at(-1))
    try await w.native(feed: feedB, "nB", published: World.at(-2))
    try await w.server(show: showA, "sA", published: World.at(-3))
    try await w.server(show: showB, "sB", published: World.at(-4))

    let chosen: [SmartListShowSelection] = [.native("https://f/a", .included), .server("a", .included)]
    let only = try await w.list(SmartListRules(showScope: .only), shows: chosen)
    #expect(try await w.ids(only) == ["n:nA", "s:sA"])

    let excluded: [SmartListShowSelection] = [.native("https://f/a", .excluded), .server("a", .excluded)]
    let except = try await w.list(SmartListRules(showScope: .allExcept), shows: excluded)
    #expect(try await w.ids(except) == ["n:nB", "s:sB"])

    let all = try await w.list(SmartListRules(showScope: .all), shows: excluded)
    #expect(try await w.ids(all).count == 4)

    let none = try await w.list(SmartListRules(showScope: .only), shows: [])
    #expect(try await w.ids(none).isEmpty)

    // A different server user's key matches nothing; so does a different source with the same text.
    let foreign = try await w.list(
      SmartListRules(showScope: .only),
      shows: [.server(user: "someone-else", "a", .included), .native("a", .included)])
    #expect(try await w.ids(foreign).isEmpty)
  }

  @Test("a priority show is included in Only, kept in All-except, and flagged")
  func priorityRole() async throws {
    let w = try await World.make()
    let feedA = try await w.feed("https://f/a")
    let feedB = try await w.feed("https://f/b")
    let showA = try await w.show("a")
    try await w.native(feed: feedA, "nA", published: World.at(-1))
    try await w.native(feed: feedB, "nB", published: World.at(-2))
    try await w.server(show: showA, "sA", published: World.at(-3))

    let only = try await w.list(
      SmartListRules(showScope: .only), shows: [.native("https://f/b", .priority)])
    #expect(try await w.ids(only) == ["n:nB"])
    #expect(try await w.snapshot(only).episodes.map(\.isPriority) == [true])

    let except = try await w.list(
      SmartListRules(showScope: .allExcept),
      shows: [.server("a", .priority), .native("https://f/a", .excluded)])
    let rows = try await w.snapshot(except).episodes
    #expect(rows.map(\.episodeID) == ["sA", "nB"])
    #expect(rows.map(\.isPriority) == [true, false])
  }

  // MARK: Still current

  @Test("a dropped native episode and a soft-deleted server episode, item or excluded library drop")
  func currentness() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1", generation: 3)
    try await w.native(feed: feed, "live", published: World.at(-1), generation: 3)
    try await w.native(feed: feed, "dropped", published: World.at(-2), generation: 2)
    let show = try await w.show("live")
    let deadShow = try await w.show("dead")
    try await w.server(show: show, "live", published: World.at(-3))
    let gone = try await w.server(show: show, "gone", published: World.at(-4))
    try await w.server(show: deadShow, "orphan", published: World.at(-5))
    try await w.setSoftDeleted(item: deadShow, episode: gone)
    let list = try await w.list()
    #expect(try await w.ids(list) == ["n:live", "s:live"])

    let libraryId = try #require(w.libraryId)
    try await w.database.writeAsync { db in
      try db.execute(sql: "UPDATE library SET isIncluded = 0 WHERE id = ?", arguments: [libraryId])
    }
    #expect(try await w.ids(list) == ["n:live"])
  }

  // MARK: Hidden

  @Test("hidden episodes drop from their own list only")
  func hidden() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    try await w.native(feed: feed, "n", published: World.at(-1))
    try await w.server(show: show, "s", published: World.at(-2))
    let first = try await w.list()
    let second = try await w.list()
    let hidden = SmartListHiddenEpisodeStore(database: w.database)
    try await hidden.hide(listID: first, itemID: "rss:\(feed)", episodeID: "n")
    try await hidden.hide(listID: first, itemID: "s", episodeID: "s")
    #expect(try await w.ids(first).isEmpty)
    #expect(try await w.ids(second) == ["n:n", "s:s"])
  }

  // MARK: Sources gated by flags

  @Test("the server half is empty signed out and the native half is empty when native is off")
  func sourceGates() async throws {
    var w = try await World.make(signedIn: false)
    let feed = try await w.feed("https://f/1")
    try await w.native(feed: feed, "n", published: World.at(-1))
    let list = try await w.list()
    #expect(try await w.ids(list) == ["n:n"])
    #expect(try await w.ids(list, nativeEnabled: false).isEmpty)

    try await w.signIn()
    let show = try await w.show("s")
    try await w.server(show: show, "s", published: World.at(-2))
    #expect(try await w.ids(list) == ["n:n", "s:s"])
    #expect(try await w.ids(list, nativeEnabled: false) == ["s:s"])

    try await w.database.writeAsync { db in try db.execute(sql: "DELETE FROM account") }
    #expect(try await w.ids(list) == ["n:n"])
  }

  @Test("a second account's episodes are not read")
  func otherAccountEpisodes() async throws {
    let w = try await World.make()
    let show = try await w.show("s")
    try await w.server(show: show, "mine", published: World.at(-1))
    let accountId = try #require(w.accountId)
    try await w.database.writeAsync { db in
      var other = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://other", serverUserId: "user-2",
        serverVersion: "2")
      try other.insert(db)
      var library = LibraryRecord(
        accountId: try #require(other.id), serverLibraryId: "l2", mediaType: "podcast", name: "P")
      try library.insert(db)
      var item = HomeReadingFixtures.podcast(
        accountId: try #require(other.id), libraryId: try #require(library.id), serverItemId: "o")
      try item.insert(db)
      var episode = PodcastEpisodeRecord(
        accountId: try #require(other.id), itemId: try #require(item.id), serverEpisodeId: "theirs",
        title: "t", durationSeconds: 100, publishedAt: World.at(-2), lastSeenGeneration: 1)
      try episode.insert(db)
      _ = accountId
    }
    // `AccountRecord.fetchOne` is the single-account contract; whichever it returns, only that
    // account's episodes appear.
    let rows = try await w.ids(try await w.list())
    #expect(rows == ["s:mine"] || rows == ["s:theirs"])
  }

  // MARK: Interacting pairs

  @Test("status with download, saved with release, duration with scope")
  func interactingPairs() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let other = try await w.feed("https://f/2")
    let show = try await w.show("s")
    let a = try await w.native(feed: feed, "a", published: World.at(-100), duration: 600)
    let b = try await w.native(feed: feed, "b", published: World.at(-200), duration: 600)
    let c = try await w.native(feed: other, "c", published: World.at(-300), duration: 600)
    try await w.nativeProgress(a, position: 100)
    try await w.nativeDownload(a)
    try await w.nativeDownload(b)
    try await w.nativeSave(a)
    try await w.nativeSave(c)
    let s = try await w.server(show: show, "s", published: World.at(-400), duration: 600)
    try await w.serverProgress(show: show, episode: s, position: 100)
    try await w.serverDownload(show: show, episode: s)
    try await w.serverSave(show: show, episode: s)

    // In progress AND downloaded.
    let one = try await w.list(
      SmartListRules(includeUnplayed: false, includeInProgress: true, includeNotDownloaded: false))
    #expect(try await w.ids(one) == ["n:a", "s:s"])
    // Saved AND within 90 s.
    let two = try await w.list(SmartListRules(savedOnly: true, releaseWindow: .day))
    #expect(Set(try await w.ids(two)) == ["n:a", "n:c", "s:s"])
    // Duration (10 min is inside 5...15) AND Only the second feed.
    let three = try await w.list(
      SmartListRules(showScope: .only, durationFilter: true, longerThanMinutes: 5, shorterThanMinutes: 15),
      shows: [.native("https://f/2", .included)])
    #expect(try await w.ids(three) == ["n:c"])
    // Downloaded AND saved AND unplayed: nothing (the only downloaded+saved ones are in progress).
    let four = try await w.list(
      SmartListRules(
        includeUnplayed: true, includeInProgress: false, includeNotDownloaded: false, savedOnly: true))
    #expect(try await w.ids(four).isEmpty)
  }

  // MARK: Counts

  @Test("matchCount counts an unsaved draft, with its show choices and the list's hidden episodes")
  func draftCount() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    try await w.native(feed: feed, "n1", published: World.at(-1))
    try await w.native(feed: feed, "n2", published: World.at(-2))
    try await w.server(show: show, "s1", published: World.at(-3))
    let reading = w.reading()
    #expect(try await reading.matchCount(rules: .default, shows: []) == 3)
    #expect(
      try await reading.matchCount(
        rules: SmartListRules(showScope: .only), shows: [.native("https://f/1", .included)]) == 2)
    #expect(
      try await reading.matchCount(
        rules: SmartListRules(showScope: .allExcept),
        shows: [.native("https://f/1", .excluded), .native("https://f/1", .excluded)]) == 1)
    let list = try await w.list()
    try await SmartListHiddenEpisodeStore(database: w.database).hide(
      listID: list, itemID: "rss:\(feed)", episodeID: "n1")
    #expect(try await reading.matchCount(rules: .default, shows: [], listID: list) == 2)
    #expect(try await reading.matchCount(rules: .default, shows: []) == 3)
    #expect(try await w.reading(nativeEnabled: false).matchCount(rules: .default, shows: []) == 1)
    #expect(try await w.snapshot(list).matchCount == 2)
  }
}
