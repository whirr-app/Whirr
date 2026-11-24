import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// A Saved-shelf removal made while the clock was quarantined leaves a debt. The explicit repair
/// re-stamps and sends it from current local state.
@Suite struct PodcastCloudClockRepairTests {
  private static let feedURL = "https://example.com/feed.xml"
  private static let namespace = Data("namespace".utf8)
  private static let key = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 7, count: 32))

  private struct Fixture {
    let database: AppDatabase
    let savedEpisodeId: Int64
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
          identityKey: "guid:one", enclosureURL: URL(string: "https://example.com/1.mp3")!)
      ])
    let episodeId = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
      })
    try await save(episodeId: episodeId, in: database)
    _ = try await PodcastCloudRegistryBackfill.run(database: database)
    _ = try await PodcastCloudInstallationStore(
      database: database, anchor: FakePodcastCloudInstallationAnchor()
    ).clock()
    let transport = PodcastCloudTransportStore(database: database)
    try await transport.activate(namespace: Self.namespace)
    try await transport.completeBootstrap(namespace: Self.namespace, engineState: Data())
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE podcastCloudInstallation SET repairRequired = 1 WHERE id = 1")
    }
    return Fixture(database: database, savedEpisodeId: episodeId)
  }

  private func save(episodeId: Int64, in database: AppDatabase) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt, subjectTitle, contextTitle)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [episodeId, Date(timeIntervalSince1970: 50), "Episode", "Feed"])
    }
  }

  private func finishWhileQuarantined(_ fixture: Fixture) async throws {
    let store = RSSEpisodeStateStore(
      database: fixture.database,
      savedIntent: PodcastCloudSavedIntentResolver(
        recordNameKey: Self.key, now: { Date(timeIntervalSince1970: 1_700_000_000) }))
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))
  }

  @Test func repairRestampsAndSendsTheSkippedRemoval() async throws {
    let fixture = try await fixture()
    try await finishWhileQuarantined(fixture)
    let transport = PodcastCloudTransportStore(database: fixture.database)
    #expect(try await transport.pendingSends(namespace: Self.namespace).isEmpty)

    let outcome = try await PodcastCloudClockRepair.repair(
      database: fixture.database, recordNameKey: Self.key,
      now: Date(timeIntervalSince1970: 1_700_000_100))

    #expect(outcome.republished.count == 1)
    #expect(outcome.settledWithoutSend == 0)
    let sends = try await transport.pendingSends(namespace: Self.namespace)
    #expect(sends.map(\.recordName) == outcome.republished)
    let register = try PodcastCloudRecordCodec.decodeSavedRegister(
      try PodcastCloudRecordPayload.decode(try #require(sends.first).payload))
    #expect(register.isSaved == false)
    #expect(register.stamp.physicalMilliseconds == 1_700_000_100_000)

    let remaining = try await fixture.database.readAsync { db in
      try PodcastCloudRepublishDebtStore.all(in: db)
    }
    #expect(remaining.isEmpty)
    let clock = try await fixture.database.readAsync { db in
      try PodcastCloudInstallationStore.clock(in: db)
    }
    #expect(clock?.repairRequired == false)
  }

  @Test func aDebtWhoseEpisodeWasSavedAgainSettlesWithoutARemoval() async throws {
    let fixture = try await fixture()
    try await finishWhileQuarantined(fixture)
    try await save(episodeId: fixture.savedEpisodeId, in: fixture.database)

    let outcome = try await PodcastCloudClockRepair.repair(
      database: fixture.database, recordNameKey: Self.key,
      now: Date(timeIntervalSince1970: 1_700_000_100))

    #expect(outcome.republished.isEmpty)
    #expect(outcome.settledWithoutSend == 1)
    #expect(
      try await PodcastCloudTransportStore(database: fixture.database)
        .pendingSends(namespace: Self.namespace).isEmpty)
  }

  @Test func repairWithoutAClockIsRefused() async throws {
    let database = try AppDatabase.inMemory()

    await #expect(throws: PodcastCloudClockRepair.Failure.noClock) {
      try await PodcastCloudClockRepair.repair(
        database: database, recordNameKey: Self.key, now: Date(timeIntervalSince1970: 1))
    }
  }
}
