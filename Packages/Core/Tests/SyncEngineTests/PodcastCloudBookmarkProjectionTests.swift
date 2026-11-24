import Foundation
import GRDB
import Persistence
import Testing

@testable import SyncEngine

/// Bookmark projection is fenced by the parent subscription's follow register: a bookmark whose
/// subscription was unfollowed, or re-followed under a new generation, never moves the marker.
@Suite struct PodcastCloudBookmarkProjectionTests {
  private static let feedURL = "https://example.com/feed.xml"
  private static let key = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 11, count: 32))

  private struct Fixture {
    let database: AppDatabase
    let entry: PodcastCloudRegistryEntry
    let episodeIds: [String: Int64]
  }

  private func stamp(_ milliseconds: Int64) throws -> PodcastCloudMutationStamp {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: milliseconds, logicalCounter: 0,
      installationUUID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      mutationUUID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
  }

  private func fixture() async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: Self.feedURL)!, title: "Feed", author: nil, synopsis: nil,
      artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:one", guid: "one",
          enclosureURL: URL(string: "https://example.com/1.mp3")!),
        RSSEpisodeUpsert(
          identityKey: "guid:two", guid: "two",
          enclosureURL: URL(string: "https://example.com/2.mp3")!),
      ])
    _ = try await PodcastCloudRegistryBackfill.run(database: database)
    let entry = try #require(
      try await PodcastCloudRegistryStore(database: database).allEntries().first)
    let ids = try await database.readAsync { db in
      var ids: [String: Int64] = [:]
      let rows = try Row.fetchAll(
        db, sql: "SELECT id, identityKey FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
      for row in rows { ids[row["identityKey"]] = row["id"] }
      return ids
    }
    return Fixture(database: database, entry: entry, episodeIds: ids)
  }

  private func reference(
    for entry: PodcastCloudRegistryEntry, identityKey: String = "guid:one"
  ) throws -> EpisodeReference {
    EpisodeReference(
      subscriptionUUID: try #require(UUID(uuidString: entry.subscriptionUUID)),
      generationUUID: try #require(UUID(uuidString: entry.generationUUID)),
      representativeDigest: PodcastCloudIdentity.episodeDigest(identityKey: identityKey))
  }

  private func project(_ reference: EpisodeReference, into fixture: Fixture) async throws {
    let now = Date(timeIntervalSince1970: 5)
    let stamp = try stamp(9_000)
    let recordName = try PodcastCloudIdentity.recordName(
      kind: "bookmark", components: [], key: Self.key)
    let fields = try PodcastCloudRecordCodec.encode(
      bookmark: StampedBookmark(reference: reference, writeStamp: stamp), recordName: recordName)
    let applier = PodcastCloudProjectingApplier(
      recordNameKeys: PodcastCloudRecordNameKeyBox(Self.key), now: { now })
    try await fixture.database.writeAsync { db in
      try applier.apply(
        PodcastCloudAdmittedRecord(fields: fields, stamp: stamp, receivedAt: now), in: db)
    }
  }

  private func bookmarkedEpisode(_ database: AppDatabase) async throws -> Int64? {
    try await database.readAsync { db in
      try Int64.fetchOne(db, sql: "SELECT episodeId FROM rssPlaybackBookmark WHERE id = 0")
    }
  }

  @Test func aFollowedParentsBookmarkMovesTheMarker() async throws {
    let fixture = try await fixture()

    try await project(try reference(for: fixture.entry), into: fixture)

    #expect(try await bookmarkedEpisode(fixture.database) == fixture.episodeIds["guid:one"])
  }

  @Test func anUnfollowedParentsBookmarkIsNotApplied() async throws {
    let fixture = try await fixture()
    try await fixture.database.writeAsync { db in
      try PodcastCloudRegistryStore.retire(
        in: db, subscriptionUUID: fixture.entry.subscriptionUUID,
        stamp: PodcastCloudStampFields(try stamp(10_000)))
    }

    try await project(try reference(for: fixture.entry), into: fixture)

    #expect(try await bookmarkedEpisode(fixture.database) == nil)
  }

  @Test func aRefollowedParentsOldGenerationBookmarkIsNotApplied() async throws {
    let fixture = try await fixture()
    let old = try reference(for: fixture.entry)
    let refollowed = PodcastCloudRegistryEntry(
      subscriptionUUID: fixture.entry.subscriptionUUID, fingerprint: fixture.entry.fingerprint,
      normalizedURL: fixture.entry.normalizedURL,
      canonicalizationVersion: fixture.entry.canonicalizationVersion,
      generationUUID: UUID().uuidString.lowercased(), isFollowed: true,
      followStamp: PodcastCloudStampFields(try stamp(10_000)))
    try await fixture.database.writeAsync { db in
      try PodcastCloudRegistryStore.register(in: db, entry: refollowed)
    }

    try await project(old, into: fixture)

    #expect(try await bookmarkedEpisode(fixture.database) == nil)

    try await project(try reference(for: refollowed), into: fixture)

    #expect(try await bookmarkedEpisode(fixture.database) == fixture.episodeIds["guid:one"])
  }

  @Test func aBookmarkUnderAnUnknownSubscriptionIsNotApplied() async throws {
    let fixture = try await fixture()
    let other = EpisodeReference(
      subscriptionUUID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      generationUUID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
      representativeDigest: PodcastCloudIdentity.episodeDigest(identityKey: "guid:one"))

    try await project(other, into: fixture)

    #expect(try await bookmarkedEpisode(fixture.database) == nil)
  }
}
