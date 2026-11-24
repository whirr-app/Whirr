import Foundation
import Persistence
import Testing

@testable import AppModel
@testable import Persistence

/// `SmartListContinuation` over a real database: the run row, the list reading and the availability
/// rule that lets completion ignore a run without deleting it.
@Suite(.timeLimit(.minutes(1)))
struct SmartListContinuationTests {
  private static let epoch = Date(timeIntervalSince1970: 1_900_000_000)

  struct World {
    let database: AppDatabase
    let continuation: SmartListContinuation
    let runs: SmartListRunStore
    let listID: Int64
    let available: AvailabilityBox
  }

  final class AvailabilityBox: @unchecked Sendable {
    var value = true
  }

  /// Three native episodes, newest first: c (day 3), b (day 2), a (day 1).
  static func makeWorld() async throws -> World {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      var feed = RSSFeedRecord(
        feedURL: "https://feeds.example.test/f.xml", title: "Feed", subscribedAt: epoch,
        refreshGeneration: 1)
      try feed.insert(db)
      let feedID = try #require(feed.id)
      for (key, day) in [("a", 1), ("b", 2), ("c", 3)] {
        var episode = RSSEpisodeRecord(
          feedId: feedID, identityKey: key, title: "T-\(key)",
          enclosureURL: "https://audio.example/\(key).mp3",
          publishedAt: epoch.addingTimeInterval(Double(day) * 86_400), durationSeconds: 1_800,
          lastSeenGeneration: 1)
        try episode.insert(db)
      }
    }
    let listID = try await SmartListStore(database: database)
      .create(name: "L", rules: .default, shows: []).id
    let runs = SmartListRunStore(database: database)
    let available = AvailabilityBox()
    let continuation = SmartListContinuation(
      runs: runs,
      reading: {
        SmartListEpisodesReading(database: database, nativeEnabled: true, now: { epoch })
      },
      hasAvailableSource: { available.value })
    return World(
      database: database, continuation: continuation, runs: runs, listID: listID,
      available: available)
  }

  static func feedItemID(_ database: AppDatabase) async throws -> String {
    let id = try await database.readAsync { db in
      try #require(try RSSFeedRecord.fetchOne(db)?.id)
    }
    return try #require(PodcastSourceIdentity.rss(feedId: id)).itemId
  }

  @Test("beginning a run stores the started episode and its place in the list")
  func beginStoresAnchorWithSortKey() async throws {
    let world = try await Self.makeWorld()
    let item = try await Self.feedItemID(world.database)

    let wrote = await world.continuation.recordListStart(
      itemID: item, episodeID: "b", listID: world.listID)

    #expect(wrote)
    let row = try #require(try await world.runs.current())
    #expect(row.listId == world.listID)
    #expect(row.anchorEpisodeID == "b")
    #expect(row.anchorSortKey.flatMap { SmartListSortKey(encoded: $0) } != nil)
    let run = try #require(await world.continuation.currentRun())
    let next = try await world.continuation.nextEpisode(
      after: run, excluding: try #require(ListeningIdentity.resolving(itemID: item, episodeID: "b")))
    #expect(next?.episodeID == "a", "the next episode after b in newest-first order")
  }

  @Test("advancing moves the anchor of the active run and writes nothing without one")
  func advanceNeedsARun() async throws {
    let world = try await Self.makeWorld()
    let item = try await Self.feedItemID(world.database)
    #expect(await world.continuation.recordListStart(itemID: item, episodeID: "c", listID: nil) == false)
    #expect(try await world.runs.current() == nil)

    _ = await world.continuation.recordListStart(itemID: item, episodeID: "c", listID: world.listID)
    let wrote = await world.continuation.recordListStart(itemID: item, episodeID: "b", listID: nil)

    #expect(wrote)
    #expect(try await world.runs.current()?.anchorEpisodeID == "b")
  }

  @Test("the list drains: a read after the last episode wraps, and excluding the finished one ends it")
  func drainsTheList() async throws {
    let world = try await Self.makeWorld()
    let item = try await Self.feedItemID(world.database)
    _ = await world.continuation.recordListStart(itemID: item, episodeID: "a", listID: world.listID)
    let run = try #require(await world.continuation.currentRun())
    let first = try await world.continuation.nextEpisode(
      after: run, excluding: try #require(ListeningIdentity.resolving(itemID: item, episodeID: "a")))
    #expect(first?.episodeID == "c", "after the last row the run wraps to the top")

    // Everything finished: nothing is left, which is what ends the run.
    try await world.database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          SELECT id, 0, 1, 1, ? FROM rssEpisode
          """, arguments: [Self.epoch])
    }
    let none = try await world.continuation.nextEpisode(
      after: run, excluding: try #require(ListeningIdentity.resolving(itemID: item, episodeID: "a")))
    #expect(none == nil)
  }

  @Test("ending unless anchored keeps the anchor episode's run and ends any other")
  func endUnlessAnchored() async throws {
    let world = try await Self.makeWorld()
    let item = try await Self.feedItemID(world.database)
    _ = await world.continuation.recordListStart(itemID: item, episodeID: "b", listID: world.listID)

    await world.continuation.endRunUnlessAnchored(itemID: item, episodeID: "b")
    #expect(try await world.runs.current() != nil)
    await world.continuation.endRunUnlessAnchored(itemID: item, episodeID: "c")
    #expect(try await world.runs.current() == nil)
  }

  @Test("with no available source the run is hidden from completion but its row is kept")
  func unavailableSourceKeepsRow() async throws {
    let world = try await Self.makeWorld()
    let item = try await Self.feedItemID(world.database)
    _ = await world.continuation.recordListStart(itemID: item, episodeID: "b", listID: world.listID)

    world.available.value = false
    #expect(await world.continuation.currentRun() == nil)
    #expect(try await world.runs.current() != nil)

    world.available.value = true
    #expect(await world.continuation.currentRun()?.listID == world.listID)
  }

  @Test("endRun deletes the row")
  func endRunDeletes() async throws {
    let world = try await Self.makeWorld()
    _ = await world.continuation.recordListStart(
      itemID: try await Self.feedItemID(world.database), episodeID: "b", listID: world.listID)
    await world.continuation.endRun(reason: .listExhausted)
    #expect(try await world.runs.current() == nil)
  }
}
