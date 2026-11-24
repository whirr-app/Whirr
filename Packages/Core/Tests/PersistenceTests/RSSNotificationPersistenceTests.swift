import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct RSSNotificationPersistenceTests {
  @Test func firstRefreshIsSilentAndLaterBackgroundDiscoveryBecomesPending() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribeFeed(in: database, name: "baseline")
    let store = RSSEpisodeStore(database: database)
    let baseline = Date(timeIntervalSince1970: 10_000)

    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [episode("first", publishedAt: baseline.addingTimeInterval(-60))],
      notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [
        episode("first", publishedAt: baseline.addingTimeInterval(-60)),
        episode("second", publishedAt: baseline.addingTimeInterval(60)),
      ],
      notificationContext: .background(
        globalEnabled: true, discoveredAt: baseline.addingTimeInterval(120)))

    let ledger = try await ledgerRows(database, feedID: feedID)
    #expect(ledger["first"] == .silentBaseline)
    #expect(ledger["second"] == .pending)
  }

  @Test func foregroundDiscoveryIsDurablySuppressed() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribeFeed(in: database, name: "foreground")
    let store = RSSEpisodeStore(database: database)
    let baseline = Date(timeIntervalSince1970: 20_000)
    _ = try await store.applyRefresh(
      feedId: feedID, episodes: [],
      notificationContext: .foreground(discoveredAt: baseline))

    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [episode("new", publishedAt: baseline.addingTimeInterval(60))],
      notificationContext: .foreground(discoveredAt: baseline.addingTimeInterval(120)))

    #expect(
      try await ledgerRows(database, feedID: feedID)["new"] == .suppressedForeground)
  }

  @Test func alternateIdentityAndDropReinsertNeverCreateASecondCandidate() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribeFeed(in: database, name: "durable")
    let store = RSSEpisodeStore(database: database)
    let baseline = Date(timeIntervalSince1970: 30_000)
    _ = try await store.applyRefresh(
      feedId: feedID, episodes: [],
      notificationContext: .background(globalEnabled: true, discoveredAt: baseline))

    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "sha256:item", enclosureURL: enclosureURL,
          publishedAt: baseline.addingTimeInterval(60))
      ],
      notificationContext: .background(
        globalEnabled: true, discoveredAt: baseline.addingTimeInterval(120)))
    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:item", alternateIdentityKey: "sha256:item",
          enclosureURL: enclosureURL, publishedAt: baseline.addingTimeInterval(60))
      ],
      notificationContext: .background(
        globalEnabled: true, discoveredAt: baseline.addingTimeInterval(180)))
    _ = try await store.applyRefresh(
      feedId: feedID, episodes: [],
      notificationContext: .background(
        globalEnabled: true, discoveredAt: baseline.addingTimeInterval(240)))
    _ = try await store.sweepDroppedEpisodes(feedId: feedID)
    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:item", alternateIdentityKey: "sha256:item",
          enclosureURL: enclosureURL, publishedAt: baseline.addingTimeInterval(60))
      ],
      notificationContext: .background(
        globalEnabled: true, discoveredAt: baseline.addingTimeInterval(300)))

    let rows: [(String, String)] = try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT identityKey, disposition
          FROM rssEpisodeNotificationLedger
          WHERE feedId = ?
          ORDER BY identityKey
          """,
        arguments: [feedID]
      ).map { row in
        (row["identityKey"], row["disposition"])
      }
    }
    #expect(rows.count == 2)
    #expect(rows.filter { $0.1 == RSSNotificationDisposition.pending.rawValue }.count == 1)
    #expect(rows.contains { $0.0 == "guid:item" })
  }

  @Test func ledgerOutlivesEpisodeRowsButCascadesWithSubscription() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribeFeed(in: database, name: "lifetime")
    let store = RSSEpisodeStore(database: database)
    let baseline = Date(timeIntervalSince1970: 40_000)
    _ = try await store.applyRefresh(
      feedId: feedID,
      episodes: [episode("old", publishedAt: baseline)],
      notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
    _ = try await store.applyRefresh(
      feedId: feedID, episodes: [],
      notificationContext: .background(
        globalEnabled: true, discoveredAt: baseline.addingTimeInterval(60)))
    _ = try await store.sweepDroppedEpisodes(feedId: feedID)

    let beforeUnsubscribe = try await database.readAsync { db in
      (
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE feedId = ?", arguments: [feedID]),
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM rssEpisodeNotificationLedger WHERE feedId = ?",
          arguments: [feedID])
      )
    }
    #expect(beforeUnsubscribe.0 == 0)
    #expect(beforeUnsubscribe.1 == 1)

    try await RSSFeedStore(database: database).unsubscribe(feedId: feedID)
    #expect(
      try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisodeNotificationLedger")
      } == 0)
  }

  @Test func eligibilitySuppressesDisabledStaleUndatedAndUnplayableRows() async throws {
    let database = try AppDatabase.inMemory()
    let enabledFeed = try await subscribeFeed(in: database, name: "eligible")
    let disabledFeed = try await subscribeFeed(in: database, name: "disabled")
    let store = RSSEpisodeStore(database: database)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let baseline = now.addingTimeInterval(-3_600)
    for feedID in [enabledFeed, disabledFeed] {
      _ = try await store.applyRefresh(
        feedId: feedID, episodes: [],
        notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
    }
    try await RSSFeedSettingsStore(database: database).setNotificationOverride(
      feedId: disabledFeed, override: .disabled)

    _ = try await store.applyRefresh(
      feedId: enabledFeed,
      episodes: [
        episode("eligible", publishedAt: now.addingTimeInterval(-60)),
        episode("undated", publishedAt: nil),
        episode("before-baseline", publishedAt: baseline.addingTimeInterval(-1)),
        episode("stale", publishedAt: now.addingTimeInterval(-PodcastEpisodeRecency.window - 1)),
        episode("video", publishedAt: now.addingTimeInterval(-60), enclosureType: "video/mp4"),
      ],
      notificationContext: .background(globalEnabled: true, discoveredAt: now))
    _ = try await store.applyRefresh(
      feedId: disabledFeed,
      episodes: [episode("disabled", publishedAt: now.addingTimeInterval(-60))],
      notificationContext: .background(globalEnabled: true, discoveredAt: now))

    let ledger = RSSNotificationLedgerStore(database: database)
    let candidates = try await ledger.eligibleCandidates(
      globalEnabled: true, now: now, limit: 12)

    #expect(candidates.map(\.identityKey) == ["eligible"])
    #expect(candidates[0].feedID == enabledFeed)
    #expect(candidates[0].showTitle == "eligible")
    let dispositions = try await ledgerRows(database, feedID: enabledFeed)
    #expect(dispositions["undated"] == .suppressedIneligible)
    #expect(dispositions["before-baseline"] == .suppressedIneligible)
    #expect(dispositions["stale"] == .suppressedIneligible)
    #expect(dispositions["video"] == .suppressedIneligible)
  }

  @Test func markScheduledReportsOnlyPendingRowsItTransitions() async throws {
    let suppressedDatabase = try AppDatabase.inMemory()
    let suppressedFeedID = try await subscribeFeed(in: suppressedDatabase, name: "suppressed")
    let suppressedStore = RSSEpisodeStore(database: suppressedDatabase)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let baseline = now.addingTimeInterval(-3_600)
    _ = try await suppressedStore.applyRefresh(
      feedId: suppressedFeedID, episodes: [],
      notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
    _ = try await suppressedStore.applyRefresh(
      feedId: suppressedFeedID, episodes: [episode("suppressed", publishedAt: now)],
      notificationContext: .background(globalEnabled: true, discoveredAt: now))
    let suppressedLedger = RSSNotificationLedgerStore(database: suppressedDatabase)
    let suppressedCandidates = try await suppressedLedger.eligibleCandidates(
      globalEnabled: true, now: now, limit: 12)
    try await suppressedLedger.suppressPending()

    #expect(
      try await suppressedLedger.markScheduled(suppressedCandidates, requestID: "suppressed") == 0)

    let pendingDatabase = try AppDatabase.inMemory()
    let pendingFeedID = try await subscribeFeed(in: pendingDatabase, name: "pending")
    let pendingStore = RSSEpisodeStore(database: pendingDatabase)
    _ = try await pendingStore.applyRefresh(
      feedId: pendingFeedID, episodes: [],
      notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
    _ = try await pendingStore.applyRefresh(
      feedId: pendingFeedID,
      episodes: [
        episode("first-pending", publishedAt: now),
        episode("second-pending", publishedAt: now.addingTimeInterval(-60)),
      ],
      notificationContext: .background(globalEnabled: true, discoveredAt: now))
    let pendingLedger = RSSNotificationLedgerStore(database: pendingDatabase)
    let pendingCandidates = try await pendingLedger.eligibleCandidates(
      globalEnabled: true, now: now, limit: 12)

    #expect(
      try await pendingLedger.markScheduled(pendingCandidates, requestID: "pending")
        == pendingCandidates.count)
  }

  /// F121: a disarm that silences only part of a bundled batch must not leave the surviving rows
  /// marked scheduled against a request the caller is about to cancel.
  @Test func markScheduledRollsBackAPartiallySuppressedBatch() async throws {
    let database = try AppDatabase.inMemory()
    let disarmedFeedID = try await subscribeFeed(in: database, name: "disarmed")
    let armedFeedID = try await subscribeFeed(in: database, name: "armed")
    let store = RSSEpisodeStore(database: database)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let baseline = now.addingTimeInterval(-3_600)
    for feedID in [disarmedFeedID, armedFeedID] {
      _ = try await store.applyRefresh(
        feedId: feedID, episodes: [],
        notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
      _ = try await store.applyRefresh(
        feedId: feedID, episodes: [episode("new-episode", publishedAt: now)],
        notificationContext: .background(globalEnabled: true, discoveredAt: now))
    }
    let ledger = RSSNotificationLedgerStore(database: database)
    let candidates = try await ledger.eligibleCandidates(globalEnabled: true, now: now, limit: 12)
    #expect(candidates.count == 2)

    // The user silences one of the two feeds after the batch was assembled.
    try await ledger.suppressPending(feedID: disarmedFeedID)

    #expect(try await ledger.markScheduled(candidates, requestID: "partial") == 0)

    // The surviving row stays pending, not scheduled against a request that will be cancelled,
    // so the next pass can offer it again.
    let armedRows = try await ledgerRows(database, feedID: armedFeedID)
    #expect(armedRows["new-episode"] == .pending)
    let disarmedRows = try await ledgerRows(database, feedID: disarmedFeedID)
    #expect(disarmedRows["new-episode"] == .suppressedLifecycle)
  }

  @Test func globalDisarmSuppressesPendingAndScheduledRowsWithoutReplay() async throws {
    let database = try AppDatabase.inMemory()
    let firstFeedID = try await subscribeFeed(in: database, name: "first-global")
    let secondFeedID = try await subscribeFeed(in: database, name: "second-global")
    let store = RSSEpisodeStore(database: database)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let baseline = now.addingTimeInterval(-3_600)
    for feedID in [firstFeedID, secondFeedID] {
      _ = try await store.applyRefresh(
        feedId: feedID, episodes: [],
        notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
      _ = try await store.applyRefresh(
        feedId: feedID, episodes: [episode("new-episode", publishedAt: now)],
        notificationContext: .background(globalEnabled: true, discoveredAt: now))
    }
    let ledger = RSSNotificationLedgerStore(database: database)
    let scheduledCandidate = try #require(
      try await ledger.eligibleCandidates(globalEnabled: true, now: now, limit: 1).first)
    #expect(try await ledger.markScheduled([scheduledCandidate], requestID: "global-request") == 1)

    #expect(try await ledger.disarm() == ["global-request"])
    #expect(try await ledgerRows(database, feedID: firstFeedID)["new-episode"] == .suppressedLifecycle)
    #expect(try await ledgerRows(database, feedID: secondFeedID)["new-episode"] == .suppressedLifecycle)
    #expect(
      try await ledger.eligibleCandidates(globalEnabled: true, now: now, limit: 12).isEmpty)
  }

  @Test func feedDisarmRequeuesSurvivorsOfSharedScheduledRequest() async throws {
    let database = try AppDatabase.inMemory()
    let disarmedFeedID = try await subscribeFeed(in: database, name: "disarmed-shared")
    let survivingFeedID = try await subscribeFeed(in: database, name: "surviving-shared")
    let store = RSSEpisodeStore(database: database)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let baseline = now.addingTimeInterval(-3_600)
    for feedID in [disarmedFeedID, survivingFeedID] {
      _ = try await store.applyRefresh(
        feedId: feedID, episodes: [],
        notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
      _ = try await store.applyRefresh(
        feedId: feedID, episodes: [episode("new-episode", publishedAt: now)],
        notificationContext: .background(globalEnabled: true, discoveredAt: now))
    }
    let ledger = RSSNotificationLedgerStore(database: database)
    let candidates = try await ledger.eligibleCandidates(globalEnabled: true, now: now, limit: 12)
    #expect(candidates.count == 2)
    #expect(try await ledger.markScheduled(candidates, requestID: "shared-request") == 2)

    #expect(try await ledger.disarm(feedID: disarmedFeedID) == ["shared-request"])
    #expect(
      try await ledgerRows(database, feedID: disarmedFeedID)["new-episode"]
        == .suppressedLifecycle)
    #expect(try await ledgerRows(database, feedID: survivingFeedID)["new-episode"] == .pending)
    let survivors = try await ledger.eligibleCandidates(globalEnabled: true, now: now, limit: 12)
    #expect(survivors.map(\.feedID) == [survivingFeedID])
  }

  private let enclosureURL = URL(string: "https://example.com/episode.mp3")!

  private func episode(
    _ key: String, publishedAt: Date?, enclosureType: String? = "audio/mpeg"
  ) -> RSSEpisodeUpsert {
    RSSEpisodeUpsert(
      identityKey: key, title: key, enclosureURL: enclosureURL,
      enclosureType: enclosureType, publishedAt: publishedAt)
  }

  private func subscribeFeed(in database: AppDatabase, name: String) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(name).xml")!, title: name, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }

  private func ledgerRows(
    _ database: AppDatabase, feedID: Int64
  ) async throws -> [String: RSSNotificationDisposition] {
    try await database.readAsync { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT identityKey, disposition
          FROM rssEpisodeNotificationLedger
          WHERE feedId = ?
          """,
        arguments: [feedID])
      return Dictionary(
        uniqueKeysWithValues: rows.compactMap { row in
          let key: String = row["identityKey"]
          let raw: String = row["disposition"]
          return RSSNotificationDisposition(rawValue: raw).map { (key, $0) }
        })
    }
  }
}
