import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// Held remote episode state is matched to local episodes after a feed refresh, released only
/// once projected, and kept within a bound otherwise.
@Suite struct PodcastCloudEpisodeStateResolutionTests {
  private static let feedURL = "https://example.com/feed.xml"
  private static let key = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 9, count: 32))

  /// An applier that projects every resolved state, recording what it was given.
  private final class ProjectingApplier: PodcastCloudRemoteApplying, @unchecked Sendable {
    let resolved = Locked<[PodcastCloudResolvedEpisodeState]>([])

    func apply(_ record: PodcastCloudAdmittedRecord, in db: Database) throws {}

    func applyResolvedEpisodeState(_ state: PodcastCloudResolvedEpisodeState, in db: Database) throws
      -> Bool
    {
      resolved.withValue { $0.append(state) }
      return true
    }
  }

  private struct Fixture {
    let database: AppDatabase
    let feedId: Int64
    let episodeIds: [String: Int64]
    let entry: PodcastCloudRegistryEntry
  }

  private func fixture(episodes: [RSSEpisodeUpsert]? = nil) async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: Self.feedURL)!, title: "Feed", author: nil, synopsis: nil,
      artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: episodes ?? [
        RSSEpisodeUpsert(
          identityKey: "guid:one", guid: "one", enclosureURL: URL(string: "https://example.com/1.mp3")!),
        RSSEpisodeUpsert(
          identityKey: "guid:two", guid: "two", enclosureURL: URL(string: "https://example.com/2.mp3")!),
      ])
    _ = try await PodcastCloudRegistryBackfill.run(database: database)
    let entry = try #require(try await PodcastCloudRegistryStore(database: database).allEntries().first)
    let ids = try await database.readAsync { db in
      var ids: [String: Int64] = [:]
      let rows = try Row.fetchAll(
        db, sql: "SELECT id, identityKey FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
      for row in rows { ids[row["identityKey"]] = row["id"] }
      return ids
    }
    return Fixture(database: database, feedId: feedId, episodeIds: ids, entry: entry)
  }

  /// Holds a remote state the way the coordinator does, named for `identityKey`.
  @discardableResult
  private func holdRemoteState(
    for identityKey: String, guid: String? = nil, enclosureURL: String? = nil, in fixture: Fixture
  ) async throws -> String {
    let recordName = try PodcastCloudIdentity.recordName(
      kind: "state",
      components: [
        fixture.entry.subscriptionUUID, fixture.entry.generationUUID,
        PodcastCloudIdentity.episodeDigest(identityKey: identityKey),
      ],
      key: Self.key)
    let stamp = try PodcastCloudMutationStamp(
      physicalMilliseconds: 5_000, logicalCounter: 0,
      installationUUID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      mutationUUID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)
    let fields = try PodcastCloudRecordCodec.encode(
      episodeState: try PodcastCloudEpisodeState(
        position: 42, isFinished: false, isDismissed: false, writeStamp: stamp),
      identity: PodcastCloudEpisodeIdentityFields(
        identityKey: identityKey, guid: guid, enclosureURL: enclosureURL),
      recordName: recordName)
    try await fixture.database.writeAsync { db in
      try PodcastCloudHoldingApplier().apply(
        PodcastCloudAdmittedRecord(
          fields: fields, stamp: stamp, receivedAt: Date(timeIntervalSince1970: 10)),
        in: db)
    }
    return recordName
  }

  private func heldCount(_ database: AppDatabase) async throws -> Int {
    try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudUnresolvedEpisodeState") ?? -1
    }
  }

  @Test func aMatchIsKeptUntilSomethingProjectsIt() async throws {
    let fixture = try await fixture()
    try await holdRemoteState(for: "guid:one", in: fixture)

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: Self.key,
      applier: PodcastCloudHoldingApplier())

    #expect(outcome.matchedButRetained == 1)
    #expect(outcome.applied == 0)
    #expect(try await heldCount(fixture.database) == 1)
  }

  @Test func aProjectedMatchIsReleased() async throws {
    let fixture = try await fixture()
    let recordName = try await holdRemoteState(for: "guid:one", in: fixture)
    let applier = ProjectingApplier()

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: Self.key,
      applier: applier)

    #expect(outcome.applied == 1)
    #expect(try await heldCount(fixture.database) == 0)
    let resolved = try #require(applier.resolved.value.first)
    #expect(resolved.recordName == recordName)
    #expect(resolved.episodeId == fixture.episodeIds["guid:one"])
    #expect(resolved.state.position == 42)
  }

  @Test func aUniqueGUIDResolvesWhenTheIdentityKeyIsUnknown() async throws {
    let fixture = try await fixture()
    try await holdRemoteState(for: "guid:renamed", guid: "two", in: fixture)
    let applier = ProjectingApplier()

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: Self.key,
      applier: applier)

    #expect(outcome.applied == 1)
    #expect(applier.resolved.value.first?.episodeId == fixture.episodeIds["guid:two"])
  }

  @Test func aCredentialFreeEnclosureResolvesWhenNothingElseDoes() async throws {
    let fixture = try await fixture()
    try await holdRemoteState(
      for: "guid:renamed", enclosureURL: "https://user:secret@example.com/1.mp3", in: fixture)
    let applier = ProjectingApplier()

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: Self.key,
      applier: applier)

    #expect(outcome.applied == 1)
    #expect(applier.resolved.value.first?.episodeId == fixture.episodeIds["guid:one"])
  }

  @Test func anAmbiguousGUIDIsNeverGuessed() async throws {
    let fixture = try await fixture(episodes: [
      RSSEpisodeUpsert(
        identityKey: "guid:a", guid: "reused", enclosureURL: URL(string: "https://example.com/a.mp3")!),
      RSSEpisodeUpsert(
        identityKey: "guid:b", guid: "reused", enclosureURL: URL(string: "https://example.com/b.mp3")!),
    ])
    try await holdRemoteState(for: "guid:renamed", guid: "reused", in: fixture)
    let applier = ProjectingApplier()

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: Self.key,
      applier: applier)

    #expect(outcome.ambiguous == 1)
    #expect(applier.resolved.value.isEmpty)
    #expect(try await heldCount(fixture.database) == 1)
  }

  @Test func anUnknownEpisodeStaysHeld() async throws {
    let fixture = try await fixture()
    try await holdRemoteState(for: "guid:future", in: fixture)

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: Self.key,
      applier: ProjectingApplier())

    #expect(outcome.unmatched == 1)
    #expect(try await heldCount(fixture.database) == 1)
  }

  @Test func heldHistoryIsBounded() async throws {
    let fixture = try await fixture()
    try await holdRemoteState(for: "guid:future-1", in: fixture)
    try await holdRemoteState(for: "guid:future-2", in: fixture)

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: Self.key,
      applier: ProjectingApplier(), retentionLimit: 1)

    #expect(outcome.pruned == 1)
    #expect(try await heldCount(fixture.database) == 1)
  }

  @Test func anotherAccountsKeyMatchesNothing() async throws {
    let fixture = try await fixture()
    try await holdRemoteState(for: "guid:one", in: fixture)
    let otherKey = try PodcastCloudRecordNameKey(bytes: Data(repeating: 3, count: 32))

    let outcome = try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: fixture.feedId, database: fixture.database, recordNameKey: otherKey,
      applier: ProjectingApplier())

    #expect(outcome == PodcastCloudEpisodeStateResolution.Outcome())
    #expect(try await heldCount(fixture.database) == 1)
  }

  @Test func credentialsNeverTakePartInEnclosureIdentity() {
    #expect(
      PodcastCloudEpisodeStateResolution.credentialFree("https://user:pw@example.com/a.mp3")
        == "https://example.com/a.mp3")
    #expect(PodcastCloudEpisodeStateResolution.credentialFree("not a url") == nil)
  }
}
