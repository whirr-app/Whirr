import Foundation
import GRDB
import Testing

@testable import Persistence

/// The smart-list reading budget as a host benchmark: "all shows, oldest first" over 50,000 episodes per source.
///
/// Opt-in, `WHIRR_BENCHMARKS=1`. Seeding 100,000 episodes costs seconds of a gate's Persistence
/// run, and a wall-clock budget asserted inside a parallel suite measures the machine's load as
/// much as the query. Run it alone on a quiet machine when the query or its indexes change:
///
///     WHIRR_BENCHMARKS=1 swift test --package-path Packages/Core \
///       --filter SmartListEpisodesReadingBenchmarkTests
@Suite(
  "SmartListEpisodesReading benchmark",
  .enabled(if: ProcessInfo.processInfo.environment["WHIRR_BENCHMARKS"] == "1"),
  .timeLimit(.minutes(1)))
struct SmartListEpisodesReadingBenchmarkTests {
  static let perSource = 50_000

  @Test("all shows, oldest first, over 50,000 episodes per source stays inside the budget")
  func allShowsOldestFirst() async throws {
    let w = try await SmartListReadingWorld.make()
    let accountId = try #require(w.accountId)
    let libraryId = try #require(w.libraryId)
    let perSource = Self.perSource
    // 50 feeds and 50 shows of 1,000 episodes each, dates spread over ~5.7 years, an eighth
    // finished or part played, a tenth downloaded, a twentieth saved.
    try await w.database.writeAsync { db in
      for index in 0..<50 {
        try db.execute(
          sql: """
            INSERT INTO rssFeed (feedURL, title, subscribedAt, refreshGeneration)
            VALUES (?, ?, '2020-01-01 00:00:00.000', 1)
            """,
          arguments: ["https://bench.example/\(index)", "Feed \(index)"])
        var item = HomeReadingFixtures.podcast(
          accountId: accountId, libraryId: libraryId, serverItemId: "bench-\(index)")
        try item.insert(db)
      }
      let numbers = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(perSource))"
      try db.execute(
        sql: """
          \(numbers)
          INSERT INTO rssEpisode (feedId, identityKey, title, enclosureURL, publishedAt,
            durationSeconds, lastSeenGeneration, retained)
          SELECT (SELECT MIN(id) FROM rssFeed) + (i % 50), 'ep-' || i, 'Episode ' || i,
            'https://bench.example/' || i || '.mp3',
            strftime('%Y-%m-%d %H:%M:%f', 1500000000 + i * 4000, 'unixepoch'),
            600 + (i % 3000), 1, 0
          FROM n
          """)
      try db.execute(
        sql: """
          \(numbers)
          INSERT INTO podcastEpisode (accountId, itemId, serverEpisodeId, title, publishedAt,
            durationSeconds, lastSeenGeneration, softDeleted)
          SELECT ?, (SELECT MIN(id) FROM item WHERE mediaKind = 'podcast') + (i % 50),
            'sep-' || i, 'Server ' || i,
            strftime('%Y-%m-%d %H:%M:%f', 1500000000 + i * 4000 + 7, 'unixepoch'),
            600 + (i % 3000), 1, 0
          FROM n
          """,
        arguments: [accountId])
      try db.execute(
        sql: """
          INSERT INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          SELECT id, 100, id % 16 = 0, 1, '2020-01-01 00:00:00.000' FROM rssEpisode WHERE id % 8 = 0
          """)
      try db.execute(
        sql: """
          INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt, subjectTitle)
          SELECT id, '2020-01-01 00:00:00.000', '' FROM rssEpisode WHERE id % 20 = 0
          """)
      try db.execute(
        sql: """
          INSERT INTO mediaProgress (accountId, itemId, podcastEpisodeId, currentTime, isFinished,
            localSequence, origin, originKey, lastActivityAt)
          SELECT accountId, itemId, id, 100, id % 16 = 0, 1, 'local', 'c', '2020-01-01 00:00:00.000'
          FROM podcastEpisode WHERE id % 8 = 0
          """)
    }

    let list = try await w.list(SmartListRules(includePlayed: true, sortOrder: .oldest))
    let reading = w.reading()

    // Warm-up, then the measured runs: the first 200 rows with the match count, as the screen
    // reads them, and the run's one-row "next after the anchor" read.
    var iterator = reading.observeEpisodes(listID: list, limit: 200).makeAsyncIterator()
    let clock = ContinuousClock()
    var snapshot: SmartListSnapshot?
    let observe = await clock.measure { snapshot = await iterator.next() }
    let page = try #require(snapshot)
    #expect(page.episodes.count == 200 && page.hasMore && page.matchCount == perSource * 2)

    var samples: [Duration] = []
    for _ in 0..<3 {
      samples.append(
        try await clock.measure {
          _ = try await reading.nextEpisodes(
            listID: list, after: page.episodes[100].sortKey, count: 1)
        })
    }
    let next = samples.min() ?? .zero
    let count = try await clock.measure {
      _ = try await reading.matchCount(rules: .default, shows: [])
    }
    print("smart-list benchmark: observe(200)=\(observe) next=\(next) matchCount=\(count)")

    #expect(observe < .seconds(1), "observe took \(observe)")
    #expect(next < .seconds(1), "next took \(next)")

    // Report the plan for the record.
    let statement = SmartListQuery(
      rules: SmartListRules(includePlayed: true, sortOrder: .oldest), shows: .stored(listID: list),
      hiddenListID: list,
      account: try await w.database.readAsync { db in
        let record = try #require(try AccountRecord.fetchOne(db))
        return SmartListQuery.AccountBinding(
          id: try #require(record.id), clientUUID: record.clientUUID,
          serverIdentityFingerprint: record.serverIdentityFingerprint)
      }, nativeEnabled: true, now: SmartListReadingWorld.epoch, unfinishedOnly: false
    ).listStatement(limit: 201, withCount: true)
    let plan = try await w.database.readAsync { db in
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments)
        .map { "\($0["id"] as Int) \($0["parent"] as Int) \($0["detail"] as String)" }
    }
    print("smart-list query plan:\n" + plan.joined(separator: "\n"))
  }
}
