import Foundation
import GRDB
import Persistence
import Testing

@testable import SyncEngine

@Suite struct PodcastCloudRegistryBackfillTests {
  private func database() throws -> AppDatabase { try AppDatabase.inMemory() }

  @discardableResult
  private func insertFeed(
    _ database: AppDatabase, url: String, subscribedAt: Date = Date(timeIntervalSince1970: 1_000)
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssFeed (feedURL, subscribedAt) VALUES (?, ?)",
        arguments: [url, subscribedAt])
      return db.lastInsertedRowID
    }
  }

  private func entries(_ database: AppDatabase) async throws -> [PodcastCloudRegistryEntry] {
    try await PodcastCloudRegistryStore(database: database).allEntries()
  }

  // MARK: - What a backfilled follow looks like

  @Test func anExistingFeedGainsTheIdentityAFreshFollowWouldHaveDerived() async throws {
    let database = try database()
    try await insertFeed(database, url: "https://example.com/feed.xml")

    let summary = try await PodcastCloudRegistryBackfill.run(database: database)
    #expect(summary.registered == 1)

    let entry = try #require(try await entries(database).first)
    let expected = try #require(PodcastCloudIdentity.subscriptionUUID(feedURL: "https://example.com/feed.xml"))
    #expect(entry.subscriptionUUID == expected.uuidString.lowercased())
    #expect(entry.isFollowed)
    #expect(entry.normalizedURL == "https://example.com/feed.xml")
    #expect(entry.canonicalizationVersion == 1)
    #expect(
      entry.generationUUID
        == PodcastCloudIdentity.initialGenerationUUID(subscriptionUUID: expected).uuidString.lowercased())
  }

  @Test func theSeededStampCarriesTheSubscriptionDateAndTheReservedAuthorToken() async throws {
    let database = try database()
    try await insertFeed(
      database, url: "https://example.com/feed.xml", subscribedAt: Date(timeIntervalSince1970: 1_234.567))

    _ = try await PodcastCloudRegistryBackfill.run(database: database)

    let entry = try #require(try await entries(database).first)
    #expect(entry.followStamp.physicalMilliseconds == 1_234_567)
    #expect(entry.followStamp.logicalCounter == 0)
    #expect(entry.followStamp.installationUUID == PodcastCloudIdentity.migrationAuthorInstallationUUID)
    #expect(entry.followStamp.mutationUUID.isEmpty == false)
  }

  /// The two properties the token is chosen for, asserted as guarantees rather than sampled: a real
  /// device's mutation beats bookkeeping that landed on the same millisecond and counter, and no
  /// device can ever mint an identity equal to the token.
  @Test func theReservedAuthorTokenIsTheMinimumUUIDAndUnmintable() async throws {
    let token = PodcastCloudIdentity.migrationAuthorInstallationUUID
    // Minimum of the whole string space: every character is already the lowest a UUID string
    // admits, so no UUID can sort below it and only the token itself can equal it.
    #expect(token == token.map { $0 == "-" ? "-" : "0" }.reduce(into: "") { $0.append($1) })
    // Minting produces version 4; the token's version nibble is 0.
    for _ in 0..<64 {
      let minted = UUID().uuidString.lowercased()
      #expect(minted != token)
      #expect(token < minted)
    }
  }

  // MARK: - Determinism

  @Test func twoDevicesHoldingTheSameCatalogueBackfillToByteIdenticalEntries() async throws {
    let deviceA = try database()
    let deviceB = try database()
    // Inserted in opposite orders, and with different local row IDs, to prove neither reaches the
    // derived identity or the seeded stamp.
    try await insertFeed(deviceA, url: "https://a.example.com/feed", subscribedAt: Date(timeIntervalSince1970: 10))
    try await insertFeed(deviceA, url: "https://b.example.com/feed", subscribedAt: Date(timeIntervalSince1970: 20))
    try await insertFeed(deviceB, url: "https://b.example.com/feed", subscribedAt: Date(timeIntervalSince1970: 20))
    try await insertFeed(deviceB, url: "https://a.example.com/feed", subscribedAt: Date(timeIntervalSince1970: 10))

    _ = try await PodcastCloudRegistryBackfill.run(database: deviceA)
    _ = try await PodcastCloudRegistryBackfill.run(database: deviceB)

    let a = try await entries(deviceA)
    #expect(a.count == 2)
    #expect(a == (try await entries(deviceB)))
  }

  @Test func runningTheBackfillTwiceChangesNothingTheSecondTime() async throws {
    let database = try database()
    try await insertFeed(database, url: "https://example.com/feed")

    let first = try await PodcastCloudRegistryBackfill.run(database: database)
    let before = try await entries(database)
    let second = try await PodcastCloudRegistryBackfill.run(database: database)

    #expect(first.registered == 1)
    #expect(second.registered == 0)
    #expect(second.alreadyRegistered == 1)
    #expect(try await entries(database) == before)
  }

  /// The failure a re-run would cause if it rewrote what it found: an unfollow is a fact the
  /// registry holds, and the catalogue row it was derived from may well still exist.
  @Test func aRerunDoesNotResurrectASubscriptionTheUserUnfollowed() async throws {
    let database = try database()
    try await insertFeed(database, url: "https://example.com/feed")
    _ = try await PodcastCloudRegistryBackfill.run(database: database)

    let store = PodcastCloudRegistryStore(database: database)
    let entry = try #require(try await store.allEntries().first)
    try await store.retire(
      subscriptionUUID: entry.subscriptionUUID,
      stamp: PodcastCloudStampFields(
        physicalMilliseconds: 9_000, logicalCounter: 1, installationUUID: "install-a",
        mutationUUID: "mutation-2"))

    _ = try await PodcastCloudRegistryBackfill.run(database: database)

    let after = try #require(try await store.entry(subscriptionUUID: entry.subscriptionUUID))
    #expect(after.isFollowed == false)
    #expect(after.followStamp.installationUUID == "install-a")
  }

  // MARK: - Duplicate canonical URLs

  @Test func catalogueRowsThatNormalizeAlikeCollapseOntoOneRegistryEntry() async throws {
    let database = try database()
    // Distinct raw URLs (`rssFeed.feedURL` is unique) that canonicalize to one identity.
    try await insertFeed(database, url: "https://example.com/feed", subscribedAt: Date(timeIntervalSince1970: 50))
    try await insertFeed(database, url: "https://EXAMPLE.com/feed/", subscribedAt: Date(timeIntervalSince1970: 90))
    try await insertFeed(database, url: "https://example.com:443/feed", subscribedAt: Date(timeIntervalSince1970: 70))

    let summary = try await PodcastCloudRegistryBackfill.run(database: database)

    #expect(summary.registered == 1)
    #expect(summary.collapsedDuplicates == 2)
    let entry = try #require(try await entries(database).first)
    // Earliest subscription wins, not lowest row ID: the earliest is when the follow happened.
    #expect(entry.followStamp.physicalMilliseconds == 50_000)
  }

  @Test func duplicatesCollapseToTheSameEntryWhicheverOrderTheyWereAddedIn() async throws {
    let forward = try database()
    let reverse = try database()
    try await insertFeed(forward, url: "https://example.com/feed", subscribedAt: Date(timeIntervalSince1970: 50))
    try await insertFeed(forward, url: "https://EXAMPLE.com/feed/", subscribedAt: Date(timeIntervalSince1970: 90))
    try await insertFeed(reverse, url: "https://EXAMPLE.com/feed/", subscribedAt: Date(timeIntervalSince1970: 90))
    try await insertFeed(reverse, url: "https://example.com/feed", subscribedAt: Date(timeIntervalSince1970: 50))

    _ = try await PodcastCloudRegistryBackfill.run(database: forward)
    _ = try await PodcastCloudRegistryBackfill.run(database: reverse)

    let collapsed = try await entries(forward)
    #expect(collapsed.count == 1)
    #expect(collapsed == (try await entries(reverse)))
  }

  @Test func aFingerprintHeldUnderADifferentIdentityIsReportedRatherThanRewritten() async throws {
    let database = try database()
    let url = "https://example.com/feed"
    let fingerprint = try #require(PodcastFeedIdentity.fingerprint(url))
    let store = PodcastCloudRegistryStore(database: database)
    try await store.register(
      PodcastCloudRegistryEntry(
        subscriptionUUID: "00000000-0000-8000-8000-0000000000ff", fingerprint: fingerprint,
        normalizedURL: url, canonicalizationVersion: 0, generationUUID: "gen-legacy",
        isFollowed: true,
        followStamp: PodcastCloudStampFields(
          physicalMilliseconds: 1, logicalCounter: 0, installationUUID: "install-a",
          mutationUUID: "mutation-1")))
    try await insertFeed(database, url: url)

    let summary = try await PodcastCloudRegistryBackfill.run(database: database)

    #expect(summary.registered == 0)
    #expect(summary.identityMismatches == 1)
    let entry = try #require(try await entries(database).first)
    #expect(entry.subscriptionUUID == "00000000-0000-8000-8000-0000000000ff")
    #expect(entry.generationUUID == "gen-legacy")
  }

  // MARK: - Feeds that cannot be given an identity

  @Test func aFeedURLThatDoesNotNormalizeIsSkippedAndNamed() async throws {
    let database = try database()
    let good = try await insertFeed(database, url: "https://example.com/feed")
    let bad = try await insertFeed(database, url: "not a url at all")

    let summary = try await PodcastCloudRegistryBackfill.run(database: database)

    #expect(summary.registered == 1)
    #expect(summary.skippedFeedIDs == [bad])
    #expect(good != bad)
    #expect(try await entries(database).count == 1)
  }

  @Test func anEmptyCatalogueBackfillsToNothingAtAll() async throws {
    let database = try database()
    let summary = try await PodcastCloudRegistryBackfill.run(database: database)
    #expect(summary.isEmpty)
    #expect(try await entries(database).isEmpty)
  }

  // MARK: - Transactionality

  /// The backfill takes the caller's `Database` precisely so a wider failure takes it down too.
  /// Half a registry is worse than none: the entries that did land would be treated as authoritative
  /// identities by every later run, since a present fingerprint is never revisited.
  @Test func aFailureAfterTheBackfillRollsBackEveryEntryItWrote() async throws {
    let database = try database()
    try await insertFeed(database, url: "https://example.com/one")
    try await insertFeed(database, url: "https://example.com/two")

    struct CallerFailure: Error {}
    await #expect(throws: CallerFailure.self) {
      try await database.writeAsync { db in
        _ = try PodcastCloudRegistryBackfill.run(in: db)
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudSubscriptionRegistry") == 2)
        throw CallerFailure()
      }
    }

    #expect(try await entries(database).isEmpty)
  }
}
