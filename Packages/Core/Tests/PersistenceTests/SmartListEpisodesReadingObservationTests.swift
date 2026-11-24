import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite("SmartListEpisodesReading observation", .timeLimit(.minutes(1)))
struct SmartListEpisodesReadingObservationTests {
  typealias World = SmartListReadingWorld

  private func collect(
    _ world: World, list: Int64, limit: Int = 200
  ) -> PersistenceObservationCollector<SmartListSnapshot> {
    PersistenceObservationCollector(world.reading().observeEpisodes(listID: list, limit: limit))
  }

  @Test("a new matching episode in either source is emitted")
  func newMatch() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    let list = try await w.list()
    let collector = collect(w, list: list)
    #expect(await TestSupport.waitUntil { collector.contains { $0.episodes.isEmpty } })

    try await w.native(feed: feed, "n", published: World.at(-1))
    #expect(await TestSupport.waitUntil { collector.contains { $0.episodes.map(\.episodeID) == ["n"] } })
    try await w.server(show: show, "s", published: World.at(-2))
    #expect(
      await TestSupport.waitUntil {
        collector.contains { $0.episodes.map(\.episodeID) == ["n", "s"] && $0.matchCount == 2 }
      })
  }

  @Test("finishing an episode drops it, from either source")
  func finish() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    let n = try await w.native(feed: feed, "n", published: World.at(-1))
    let s = try await w.server(show: show, "s", published: World.at(-2))
    let list = try await w.list()
    let collector = collect(w, list: list)
    #expect(await TestSupport.waitUntil { collector.contains { $0.episodes.count == 2 } })

    try await w.nativeProgress(n, position: 1, finished: true)
    #expect(await TestSupport.waitUntil { collector.values.last?.episodes.map(\.episodeID) == ["s"] })
    try await w.serverProgress(show: show, episode: s, position: 1, finished: true)
    #expect(await TestSupport.waitUntil { collector.values.last?.episodes.isEmpty == true })
  }

  @Test("editing the list's shows re-emits")
  func showEdit() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    try await w.native(feed: feed, "n", published: World.at(-1))
    let list = try await w.list(SmartListRules(showScope: .only))
    let collector = collect(w, list: list)
    #expect(await TestSupport.waitUntil { collector.contains { $0.episodes.isEmpty } })
    try await SmartListStore(database: w.database).setShows(
      listID: list, shows: [.native("https://f/1", .included)])
    #expect(await TestSupport.waitUntil { collector.contains { $0.episodes.count == 1 } })
  }

  @Test("a byte-column download write, and progress inside one quantum, emit nothing new")
  func byteWritesAreQuiet() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let show = try await w.show("s")
    let n = try await w.native(feed: feed, "n", published: World.at(-1))
    let s = try await w.server(show: show, "s", published: World.at(-2))
    try await w.nativeDownload(n, state: .downloading)
    try await w.serverDownload(show: show, episode: s)
    try await w.database.writeAsync { db in
      try db.execute(sql: "UPDATE download SET state = 'downloading'")
    }
    let list = try await w.list()
    let collector = collect(w, list: list)
    #expect(await TestSupport.waitUntil { !collector.values.isEmpty })
    let baseline = collector.values.count

    for bytes in 1...20 {
      try await w.database.writeAsync { db in
        try db.execute(sql: "UPDATE rssDownload SET actualBytes = ?", arguments: [bytes * 100])
        try db.execute(sql: "UPDATE download SET receivedBytes = ?", arguments: [bytes * 100])
      }
    }
    await awaitQuiescence("byte writes deliver nothing") { "\(collector.values.count)" }
    #expect(collector.values.count == baseline)

    // A progress tick that stays inside the same minute changes nothing a row shows.
    try await w.nativeProgress(n, position: 70)
    #expect(await TestSupport.waitUntil { collector.values.count == baseline + 1 })
    try await w.nativeProgress(n, position: 80)
    await awaitQuiescence("an in-quantum tick delivers nothing") { "\(collector.values.count)" }
    #expect(collector.values.count == baseline + 1)

    // Completing a download does change what a row shows.
    try await w.database.writeAsync { db in
      try db.execute(sql: "UPDATE rssDownload SET state = 'completed'")
    }
    #expect(
      await TestSupport.waitUntil { collector.contains { $0.episodes.contains { $0.isDownloaded } } })
  }

  @Test("limit and hasMore: one extra row is read, the cap is 1,000, and matchCount counts all")
  func paging() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    for index in 0..<7 {
      try await w.native(feed: feed, "e\(index)", published: World.at(-Double(index)))
    }
    let list = try await w.list()
    let page = try await w.snapshot(list, limit: 5)
    #expect(page.episodes.count == 5 && page.hasMore && page.matchCount == 7)
    let all = try await w.snapshot(list, limit: 7)
    #expect(all.episodes.count == 7 && !all.hasMore)
    let clamped = try await w.snapshot(list, limit: 5_000)
    #expect(clamped.episodes.count == 7 && !clamped.hasMore)
    let floor = try await w.snapshot(list, limit: 0)
    #expect(floor.episodes.count == 1 && floor.hasMore)
  }

  @Test("progress is quantized to the minute in rows, and status follows the stored value")
  func quantized() async throws {
    let w = try await World.make()
    let feed = try await w.feed("https://f/1")
    let n = try await w.native(feed: feed, "n", published: World.at(-1))
    try await w.nativeProgress(n, position: 754.3)
    let list = try await w.list()
    let row = try #require(try await w.snapshot(list).episodes.first)
    #expect(row.progressSeconds == 720 && row.status == .inProgress)
  }
}
