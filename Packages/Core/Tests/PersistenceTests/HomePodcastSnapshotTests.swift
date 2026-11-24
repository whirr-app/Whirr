import Foundation
import GRDB
import Persistence
import Synchronization
import Testing

@testable import Persistence

/// The two account-scoped Home projections. These tests seed the durable rows the projections
/// correlate instead of going through the coordinator: the contract is about exact persisted
/// identity and current eligibility, independent of which operation wrote the rows.
@Suite struct HomePodcastSnapshotTests {

  @Test("recently added independently caps policies and hides only exact feed twins")
  func recentlyAddedPoliciesAreIndependentAndExact() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "home-snapshot-recent")
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    // URL spelling differences are normalised by the shared identity helper.
    let nativeFeedURL = "HTTPS://EXAMPLE.TEST:443/show///"
    let matchingFingerprint = try #require(
      PodcastFeedIdentity.fingerprint("https://example.test/show"))
    _ = try await Self.insertFeed(
      database, feedURL: nativeFeedURL, fingerprint: nil, refreshGeneration: 4)

    var paired = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "paired")
    paired.title = "Same Title"
    paired.addedAt = now.addingTimeInterval(4)
    paired.podcastServerEpisodeCount = 2
    paired.podcastFeedFingerprint = matchingFingerprint
    _ = try await itemDAO.upsertAsync(paired)

    var unmatched = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "unmatched")
    unmatched.title = "Same Title"
    unmatched.addedAt = now.addingTimeInterval(3)
    unmatched.podcastServerEpisodeCount = nil
    _ = try await itemDAO.upsertAsync(unmatched)

    var differentFeed = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "different-feed")
    differentFeed.title = "Same Title"
    differentFeed.addedAt = now.addingTimeInterval(2)
    differentFeed.podcastServerEpisodeCount = -1
    differentFeed.podcastFeedFingerprint = String(repeating: "b", count: 64)
    _ = try await itemDAO.upsertAsync(differentFeed)

    var malformed = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "malformed")
    malformed.addedAt = now.addingTimeInterval(1)
    malformed.podcastServerEpisodeCount = 1
    malformed.podcastFeedFingerprint = "not-a-fingerprint"
    _ = try await itemDAO.upsertAsync(malformed)

    var knownEmpty = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "known-empty")
    knownEmpty.addedAt = now.addingTimeInterval(5)
    knownEmpty.podcastServerEpisodeCount = 0
    knownEmpty.podcastFeedFingerprint = matchingFingerprint
    _ = try await itemDAO.upsertAsync(knownEmpty)

    var recent = reading.observeRecentlyAdded(category: .podcast, limit: 1).makeAsyncIterator()
    let limited = try #require(await recent.next())
    #expect(limited.all.map(\.serverItemId) == ["paired"])
    #expect(limited.nativePreferred.map(\.serverItemId) == ["unmatched"])
    #expect(limited.all.count <= 1)
    #expect(limited.nativePreferred.count <= 1)

    var unbounded = reading.observeRecentlyAdded(category: .podcast, limit: 20).makeAsyncIterator()
    let snapshot = try #require(await unbounded.next())
    #expect(snapshot.all.map(\.serverItemId) == ["paired", "unmatched", "different-feed", "malformed"])
    #expect(snapshot.nativePreferred.map(\.serverItemId) == ["unmatched", "different-feed", "malformed"])
    #expect(snapshot.all.contains { $0.serverItemId == "known-empty" } == false)
    #expect(snapshot.nativePreferred.contains { $0.serverItemId == "known-empty" } == false)

    var zero = reading.observeRecentlyAdded(category: nil, limit: 0).makeAsyncIterator()
    let zeroSnapshot = try #require(await zero.next())
    #expect(zeroSnapshot.all.isEmpty)
    #expect(zeroSnapshot.nativePreferred.isEmpty)

    var negative = reading.observeRecentlyAdded(category: nil, limit: -3).makeAsyncIterator()
    let negativeSnapshot = try #require(await negative.next())
    #expect(negativeSnapshot.all.isEmpty)
    #expect(negativeSnapshot.nativePreferred.isEmpty)
  }

  @Test("recently added tie ordering is stable by item row id in both policies")
  func recentlyAddedTieOrderingIsStable() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "home-snapshot-ties")
    let addedAt = Date(timeIntervalSince1970: 1_900_000_000)

    var first = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "z-first")
    first.addedAt = addedAt
    first.podcastServerEpisodeCount = 1
    let firstRow = try await itemDAO.upsertAsync(first)

    var second = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "a-second")
    second.addedAt = addedAt
    second.podcastServerEpisodeCount = 1
    let secondRow = try await itemDAO.upsertAsync(second)

    let firstID = try #require(firstRow.id)
    let secondID = try #require(secondRow.id)
    #expect(firstID < secondID)
    var iterator = reading.observeRecentlyAdded(category: .podcast, limit: 10).makeAsyncIterator()
    let snapshot = try #require(await iterator.next())
    #expect(snapshot.all.map(\.serverItemId) == ["z-first", "a-second"])
    #expect(snapshot.nativePreferred.map(\.serverItemId) == ["z-first", "a-second"])
  }

  @Test("recently added never coalesces a non-podcast carrying a matching fingerprint")
  func recentlyAddedNonPodcastFingerprintFailsOpen() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "home-snapshot-non-podcast")
    let fingerprint = try #require(
      PodcastFeedIdentity.fingerprint("https://native.example.test/show"))
    _ = try await Self.insertFeed(
      database, feedURL: "https://native.example.test/show", fingerprint: fingerprint,
      refreshGeneration: 1)

    // The mapping layer normally prevents this corrupt state. The catalogue projection still
    // fails open: feed identity can coalesce only a server podcast, never a book or audiobook.
    var audiobook = HomeReadingFixtures.audiobook(
      accountId: accountId, libraryId: libraryId, serverItemId: "server-audiobook")
    audiobook.addedAt = Date(timeIntervalSince1970: 1_900_000_000)
    audiobook.podcastFeedFingerprint = fingerprint
    _ = try await itemDAO.upsertAsync(audiobook)

    var iterator = reading.observeRecentlyAdded(category: nil, limit: 10).makeAsyncIterator()
    let snapshot = try #require(await iterator.next())
    #expect(snapshot.all.map(\.serverItemId) == ["server-audiobook"])
    #expect(snapshot.nativePreferred.map(\.serverItemId) == ["server-audiobook"])
  }

  @Test("latest snapshot uses an exact account-fenced native EXISTS without duplicate output")
  func latestSnapshotUsesExactTwinAndIgnoresAttemptLifecycle() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "home-snapshot-latest")
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let cutoff = now.addingTimeInterval(-7 * 86_400)

    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "server-show")
    show.title = "Twin Show"
    show.podcastServerEpisodeCount = 1
    show.podcastFeedFingerprint = String(repeating: "c", count: 64)
    let storedShow = try await itemDAO.upsertAsync(show)
    let showID = try #require(storedShow.id)
    _ = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showID, serverEpisodeID: "server-episode",
      title: "Server Episode", durationSeconds: 1_800,
      publishedAt: now.addingTimeInterval(-86_400))

    let nativeFeed = try await Self.insertFeed(
      database, feedURL: "https://native.example.test/twin", fingerprint: show.podcastFeedFingerprint,
      refreshGeneration: 1)
    let nativeEpisode = try await Self.insertNativeEpisode(
      database, feedId: try #require(nativeFeed.id), identityKey: "native-primary",
      alternateIdentityKey: "native-alternate", publishedAt: now.addingTimeInterval(-86_400),
      generation: 1)
    let account = try #require(
      try await database.readAsync { db in
        try AccountRecord.fetchOne(db, key: accountId)
      })
    // Two older rows with different lifecycle states must act as one boolean association.
    _ = try await Self.insertAttempt(
      database, account: account, feedId: try #require(nativeFeed.id),
      episodeId: try #require(nativeEpisode.id), episodeIdentityKey: "native-alternate",
      serverItemID: "server-show", serverEpisodeID: "server-episode", state: .confirmed)
    _ = try await Self.insertAttempt(
      database, account: account, feedId: try #require(nativeFeed.id),
      episodeId: try #require(nativeEpisode.id), episodeIdentityKey: "native-alternate",
      serverItemID: "server-show", serverEpisodeID: "server-episode", state: .deleting)
    func latest(limit: Int = 10) async throws -> HomeLatestPodcastEpisodesSnapshot {
      var iterator = reading.observeNewPodcastEpisodes(
        cutoff: { cutoff }, limit: limit
      ).makeAsyncIterator()
      return try #require(await iterator.next())
    }

    let snapshot = try await latest()
    #expect(snapshot.all.map(\.episodeID) == ["server-episode"])
    #expect(snapshot.nativePreferred.isEmpty)
    #expect(snapshot.all.count == 1)

    // A pre-existing server episode and a removal-stale attempt still have identity evidence; the
    // projection does not treat lifecycle state as an eligibility filter.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE nativeEpisodeServerSaveAttempt SET state = 'accepted' WHERE accountId = ?",
        arguments: [accountId])
    }
    // The projected value is unchanged, so `removeDuplicates` correctly emits nothing on the
    // original stream. Read a fresh snapshot to verify lifecycle independence without awaiting a
    // publication that the observation contract suppresses.
    let preExisting = try await latest()
    #expect(preExisting.nativePreferred.isEmpty)

    // A negative and zero limit are both an empty bounded projection, never an unbounded query.
    let zeroSnapshot = try await latest(limit: 0)
    #expect(zeroSnapshot.all.isEmpty)
    #expect(zeroSnapshot.nativePreferred.isEmpty)
    let negativeSnapshot = try await latest(limit: -1)
    #expect(negativeSnapshot.all.isEmpty)
    #expect(negativeSnapshot.nativePreferred.isEmpty)
  }

  @Test("latest native twin fails open for stale, malformed, or replaced evidence")
  func latestSnapshotNativeEligibilityFailsOpen() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "home-snapshot-eligibility")
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let cutoff = now.addingTimeInterval(-7 * 86_400)
    let fingerprint = String(repeating: "d", count: 64)

    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "server-show")
    show.podcastServerEpisodeCount = 1
    show.podcastFeedFingerprint = fingerprint
    let storedShow = try await itemDAO.upsertAsync(show)
    let showID = try #require(storedShow.id)
    _ = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: showID, serverEpisodeID: "server-episode",
      title: "Server Episode", durationSeconds: 1_800,
      publishedAt: now.addingTimeInterval(-86_400))
    let feed = try await Self.insertFeed(
      database, feedURL: "https://native.example.test/eligibility", fingerprint: fingerprint,
      refreshGeneration: 1)
    let feedID = try #require(feed.id)
    let native = try await Self.insertNativeEpisode(
      database, feedId: feedID, identityKey: "native-id", publishedAt: now.addingTimeInterval(-86_400),
      generation: 1)
    let nativeID = try #require(native.id)
    let account = try #require(
      try await database.readAsync { db in
        try AccountRecord.fetchOne(db, key: accountId)
      })
    _ = try await Self.insertAttempt(
      database, account: account, feedId: feedID, episodeId: nativeID,
      episodeIdentityKey: "native-id", serverItemID: "server-show", serverEpisodeID: "server-episode",
      state: .confirmed)

    func latest() async throws -> HomeLatestPodcastEpisodesSnapshot {
      var iterator = reading.observeNewPodcastEpisodes(cutoff: { cutoff }, limit: 10).makeAsyncIterator()
      return try #require(await iterator.next())
    }

    #expect((try await latest()).nativePreferred.isEmpty)

    // Each mutation below removes one exact eligibility/identity condition; the ABS episode stays
    // visible in `all` and reappears in nativePreferred rather than being hidden speculatively.
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET refreshGeneration = 2 WHERE id = ?", arguments: [feedID])
    }
    #expect((try await latest()).nativePreferred.map(\.episodeID) == ["server-episode"])

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET refreshGeneration = 1 WHERE id = ?",
        arguments: [feedID])
      try db.execute(
        sql: "UPDATE rssEpisode SET lastSeenGeneration = 1, publishedAt = ? WHERE id = ?",
        arguments: [now.addingTimeInterval(-90 * 86_400), nativeID])
    }
    #expect((try await latest()).nativePreferred.map(\.episodeID) == ["server-episode"])

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisode SET publishedAt = ? WHERE id = ?",
        arguments: [now.addingTimeInterval(-86_400), nativeID])
      try db.execute(
        sql:
          "INSERT OR REPLACE INTO rssFeedSettings (feedId, autoDownload, includeInLatest, notificationOverride) VALUES (?, 'inherit', 0, 'inherit')",
        arguments: [feedID])
    }
    #expect((try await latest()).nativePreferred.map(\.episodeID) == ["server-episode"])

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeedSettings SET includeInLatest = 1 WHERE feedId = ?",
        arguments: [feedID])
      try db.execute(
        sql:
          "INSERT OR REPLACE INTO rssEpisodeState (episodeId, position, finished, hideFromContinueListening, localSequence, updatedAt) VALUES (?, 0, 1, 0, 1, ?)",
        arguments: [nativeID, now])
    }
    #expect((try await latest()).nativePreferred.map(\.episodeID) == ["server-episode"])

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisodeState SET finished = 0 WHERE episodeId = ?",
        arguments: [nativeID])
      try db.execute(
        sql: "UPDATE rssFeed SET podcastFeedFingerprint = NULL WHERE id = ?",
        arguments: [feedID])
    }
    #expect((try await latest()).nativePreferred.map(\.episodeID) == ["server-episode"])

    // Changing the active address is an endpoint switch, not a replacement: the attempt stays
    // bound to the same account and the native twin still hides the ABS episode.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET podcastFeedFingerprint = ? WHERE id = ?",
        arguments: [fingerprint, feedID])
      try db.execute(
        sql: "UPDATE account SET serverBaseURL = ? WHERE id = ?",
        arguments: ["https://replacement.example.test", accountId])
    }
    #expect((try await latest()).nativePreferred.isEmpty)

    // Replacing the account's user identity must invalidate the captured account fence even
    // though the SQLite account row id remains unchanged.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE account SET serverUserId = ? WHERE id = ?",
        arguments: ["replacement-user", accountId])
    }
    #expect((try await latest()).nativePreferred.map(\.episodeID) == ["server-episode"])

    // Recycle both native row ids with a different feed identity. The old attempt must not bind to
    // unrelated rows merely because SQLite reused the integer ids.
    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM rssFeed WHERE id = ?", arguments: [feedID])
      var replacementFeed = RSSFeedRecord(
        id: feedID, feedURL: "https://replacement-native.example.test/feed",
        subscribedAt: now, refreshGeneration: 1, podcastFeedFingerprint: String(repeating: "e", count: 64))
      try replacementFeed.insert(db)
      var replacementEpisode = RSSEpisodeRecord(
        id: nativeID, feedId: feedID, identityKey: "native-id",
        enclosureURL: "https://replacement-native.example.test/e.mp3",
        publishedAt: now.addingTimeInterval(-86_400), durationSeconds: 1_800, lastSeenGeneration: 1)
      try replacementEpisode.insert(db)
    }
    #expect((try await latest()).nativePreferred.map(\.episodeID) == ["server-episode"])

    // Soft-deleting the server row is a source projection exclusion, not a native association.
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [showID])
    }
    let deleted = try await latest()
    #expect(deleted.all.isEmpty)
    #expect(deleted.nativePreferred.isEmpty)

  }

  @Test("native-preferred Home projections use the feed and saved-episode identity indexes")
  func nativePreferredProjectionQueryPlansUseCoalescingIndexes() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultHomeReading(database: database)
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await HomeReadingFixtures.seedAccountAndLibrary(
      database, serverLibraryId: "home-snapshot-query-plan")
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let fingerprint = String(repeating: "f", count: 64)

    var show = HomeReadingFixtures.podcast(
      accountId: accountId, libraryId: libraryId, serverItemId: "server-show")
    show.addedAt = now
    show.podcastServerEpisodeCount = 1
    show.podcastFeedFingerprint = fingerprint
    let storedShow = try await itemDAO.upsertAsync(show)
    let serverEpisodeID = "server-episode"
    _ = try await HomeReadingFixtures.insertEpisode(
      database, accountId: accountId, itemId: try #require(storedShow.id),
      serverEpisodeID: serverEpisodeID, title: "Server Episode", durationSeconds: 1_800,
      publishedAt: now.addingTimeInterval(-86_400))
    let feed = try await Self.insertFeed(
      database, feedURL: "https://native.example.test/query-plan", fingerprint: fingerprint,
      refreshGeneration: 1)
    let nativeEpisode = try await Self.insertNativeEpisode(
      database, feedId: try #require(feed.id), identityKey: "native-episode",
      publishedAt: now.addingTimeInterval(-86_400), generation: 1)
    let account = try #require(
      try await database.readAsync { db in
        try AccountRecord.fetchOne(db, key: accountId)
      })
    _ = try await Self.insertAttempt(
      database, account: account, feedId: try #require(feed.id),
      episodeId: try #require(nativeEpisode.id), episodeIdentityKey: "native-episode",
      serverItemID: show.serverItemId, serverEpisodeID: serverEpisodeID,
      state: .confirmed)

    let expandedStatements = Mutex<[String]>([])
    try await database.writeAsync { db in
      db.trace { event in
        guard case .statement(let statement) = event else { return }
        expandedStatements.withLock { $0.append(statement.expandedSQL) }
      }
    }

    var recentlyAdded = reading.observeRecentlyAdded(
      category: nil, limit: 10
    ).makeAsyncIterator()
    _ = try #require(await recentlyAdded.next())
    var latest = reading.observeNewPodcastEpisodes(
      cutoff: { now.addingTimeInterval(-7 * 86_400) }, limit: 10
    ).makeAsyncIterator()
    _ = try #require(await latest.next())

    let recentSQL = try #require(
      expandedStatements.withLock {
        $0.first {
          $0.contains("FROM rssFeed AS feed") && $0.contains("item.addedAt AS addedAt")
        }
      })
    let latestSQL = try #require(
      expandedStatements.withLock {
        $0.first { $0.contains("FROM nativeEpisodeServerSaveAttempt AS attempt") }
      })
    let (recentPlan, latestPlan) = try database.read { db in
      (
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(recentSQL)")
          .map { $0["detail"] as String },
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(latestSQL)")
          .map { $0["detail"] as String }
      )
    }

    #expect(
      recentPlan.contains {
        $0.contains("index_rssFeed_on_podcastFeedFingerprint")
      },
      "recently-added native preference must use the persisted feed-fingerprint index")
    #expect(
      latestPlan.contains {
        $0.contains("index_nativeEpisodeServerSaveAttempt_on_account_server_identity")
      },
      "latest-episode native preference must use the account/server episode identity index")
  }

  private static func insertFeed(
    _ database: AppDatabase,
    feedURL: String,
    fingerprint: String?,
    refreshGeneration: Int
  ) async throws -> RSSFeedRecord {
    try await database.writeAsync { db in
      var feed = RSSFeedRecord(
        feedURL: feedURL, subscribedAt: Date(timeIntervalSince1970: 1_900_000_000),
        refreshGeneration: refreshGeneration, podcastFeedFingerprint: fingerprint)
      try feed.insert(db)
      return feed
    }
  }

  private static func insertNativeEpisode(
    _ database: AppDatabase,
    feedId: Int64,
    identityKey: String,
    alternateIdentityKey: String? = nil,
    publishedAt: Date,
    generation: Int
  ) async throws -> RSSEpisodeRecord {
    try await database.writeAsync { db in
      var episode = RSSEpisodeRecord(
        feedId: feedId, identityKey: identityKey, alternateIdentityKey: alternateIdentityKey,
        title: "Native Episode", enclosureURL: "https://native.example.test/episode.mp3",
        publishedAt: publishedAt, durationSeconds: 1_800, lastSeenGeneration: generation)
      try episode.insert(db)
      return episode
    }
  }

  private static func insertAttempt(
    _ database: AppDatabase,
    account: AccountRecord,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    serverItemID: String,
    serverEpisodeID: String,
    state: NativeEpisodeServerSaveAttemptState
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync { db in
      var attempt = NativeEpisodeServerSaveAttemptRecord(
        accountId: try #require(account.id), accountClientUUID: account.clientUUID,
        accountServerIdentityFingerprint:
          account.serverIdentityFingerprint,
        feedId: feedId, episodeId: episodeId, episodeIdentityKey: episodeIdentityKey,
        serverItemId: serverItemID, serverEpisodeId: serverEpisodeID, state: state,
        createdAt: Date(timeIntervalSince1970: 1_900_000_000))
      try attempt.insert(db)
      return attempt
    }
  }
}
