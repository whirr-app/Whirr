import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// The cloud half of the Saved-shelf resolution. The local half has its own coverage in
/// `PersistenceTests`; what matters here is that the removal reaches the outbox stamped, in the
/// same transaction, and that a cloud that cannot represent the mutation never costs the listener
/// their playback progress.
@Suite struct PodcastCloudSavedIntentResolverTests {
  private static let feedURL = "https://example.com/feed.xml"
  private static let namespace = Data("namespace".utf8)
  private static let key = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 7, count: 32))

  private struct Fixture {
    let database: AppDatabase
    let savedEpisodeId: Int64
    let otherEpisodeId: Int64
    let installationUUID: UUID
  }

  /// A feed, two episodes with the first saved, a registered subscription, a minted installation
  /// clock and an activated transport. `registerSubscription` and `mintClock` are separable
  /// because their absence is behaviour under test, not a broken fixture.
  private func fixture(
    registerSubscription: Bool = true, mintClock: Bool = true, duration: Double? = nil
  ) async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: Self.feedURL)!, title: "Feed", author: nil, synopsis: nil,
      artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:one", enclosureURL: URL(string: "https://example.com/1.mp3")!,
          durationSeconds: duration),
        RSSEpisodeUpsert(
          identityKey: "guid:two", enclosureURL: URL(string: "https://example.com/2.mp3")!,
          durationSeconds: duration),
      ])
    let ids = try await database.readAsync { db in
      try Int64.fetchAll(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? ORDER BY identityKey",
        arguments: [feedId])
    }
    try #require(ids.count == 2)
    try await save(episodeId: ids[0], in: database)

    if registerSubscription {
      _ = try await PodcastCloudRegistryBackfill.run(database: database)
    }
    var installationUUID = UUID()
    if mintClock {
      let anchor = FakePodcastCloudInstallationAnchor()
      let minted = try await PodcastCloudInstallationStore(database: database, anchor: anchor)
        .clock()
      let mintedFields = try #require(minted)
      installationUUID = try #require(UUID(uuidString: mintedFields.installationUUID))
    }
    let transport = PodcastCloudTransportStore(database: database)
    try await transport.activate(namespace: Self.namespace)
    try await transport.completeBootstrap(namespace: Self.namespace, engineState: Data())

    return Fixture(
      database: database, savedEpisodeId: ids[0], otherEpisodeId: ids[1],
      installationUUID: installationUUID)
  }

  private func resolver(at seconds: TimeInterval = 1_700_000_000) -> PodcastCloudSavedIntentResolver {
    PodcastCloudSavedIntentResolver(
      recordNameKey: Self.key, now: { Date(timeIntervalSince1970: seconds) })
  }

  private func pending(_ database: AppDatabase) async throws -> [PodcastCloudPendingSend] {
    try await PodcastCloudTransportStore(database: database).pendingSends(namespace: Self.namespace)
  }

  private func savedCount(_ database: AppDatabase) async throws -> Int {
    try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssSavedShelfEntry") ?? -1
    }
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

  // MARK: - The removal reaches the outbox, stamped

  @Test func finishingAnEpisodeRemovesTheEntryAndEnqueuesAStampedRemoval() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 0)
    let sends = try await pending(fixture.database)
    #expect(sends.count == 1)
    let send = try #require(sends.first)
    let register = try PodcastCloudRecordCodec.decodeSavedRegister(
      try PodcastCloudRecordPayload.decode(send.payload))
    #expect(register.isSaved == false)
    // The durable removal marker, not an absent record: `savedAt` is nil precisely because the
    // register says "not saved", and the stamp is what orders it against a remote re-save.
    #expect(register.savedAt == nil)
    #expect(register.stamp.installationUUID == fixture.installationUUID)
    #expect(register.stamp.physicalMilliseconds == 1_700_000_000_000)
  }

  /// Logical removals are saves carrying a register. A physical deletion would be
  /// indistinguishable from a record that never existed.
  @Test func theRemovalIsASaveAndNotAPhysicalDeletion() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    #expect(try #require(try await pending(fixture.database).first).operation == "save")
  }

  @Test func nothingButTheSchemaMarkerReachesTheOutboxInTheClear() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    let fields = try PodcastCloudRecordPayload.decode(
      try #require(try await pending(fixture.database).first).payload)
    #expect(Set(fields.plaintext.keys) == [PodcastCloudRecordLayout.schemaFieldName])
  }

  /// The clock advance has to land in the same transaction as the enqueue, or a backup could
  /// capture the row behind the outbox and the restored device would re-emit a published stamp.
  @Test func theClockAdvanceCommitsWithTheEnqueue() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    let sends = try await pending(fixture.database)
    let register = try PodcastCloudRecordCodec.decodeSavedRegister(
      try PodcastCloudRecordPayload.decode(try #require(sends.first).payload))
    let stored = try #require(
      try await fixture.database.readAsync { db in
        try PodcastCloudInstallationStore.clock(in: db)
      })
    #expect(stored.physicalMilliseconds == register.stamp.physicalMilliseconds)
    #expect(stored.logicalCounter == register.stamp.logicalCounter)
  }

  @Test func theStampIsRecordedAsTheLastAcceptedOneForThatRecord() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    let send = try #require(try await pending(fixture.database).first)
    let accepted = try #require(
      try await PodcastCloudRegistryStore(database: fixture.database)
        .acceptedStamp(recordName: send.recordName))
    let register = try PodcastCloudRecordCodec.decodeSavedRegister(
      try PodcastCloudRecordPayload.decode(send.payload))
    #expect(accepted.physicalMilliseconds == register.stamp.physicalMilliseconds)
    #expect(accepted.mutationUUID == register.stamp.mutationUUID.uuidString.lowercased())
  }

  // MARK: - Nothing to resolve means nothing to send

  @Test func aDismissalRemovesNothingAndSendsNothing() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setHiddenFromContinueListening(
      episodeId: fixture.savedEpisodeId, isHidden: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 1)
    #expect(try await pending(fixture.database).isEmpty)
  }

  @Test func aTickAtZeroSendsNothing() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.recordTick(
      episodeId: fixture.savedEpisodeId, position: 0, finished: false, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 1)
    #expect(try await pending(fixture.database).isEmpty)
  }

  /// v56's rule survives the cloud resolver: a repeated identical finish is not a new decision, so
  /// it neither removes a later re-save nor sends anything.
  @Test func aRepeatedFinishPreservesALaterReSaveAndSendsNothingFurther() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))
    try await save(episodeId: fixture.savedEpisodeId, in: fixture.database)
    let firstGeneration = try #require(try await pending(fixture.database).first).generation

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 200))

    #expect(try await savedCount(fixture.database) == 1)
    let sends = try await pending(fixture.database)
    #expect(sends.count == 1)
    #expect(try #require(sends.first).generation == firstGeneration)
  }

  // MARK: - Playback outranks sync bookkeeping

  @Test func anUnregisteredFeedStillRemovesTheEntryLocally() async throws {
    let fixture = try await fixture(registerSubscription: false)
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 0)
    #expect(try await pending(fixture.database).isEmpty)
  }

  @Test func noMintedClockStillRemovesTheEntryLocally() async throws {
    let fixture = try await fixture(mintClock: false)
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 0)
    #expect(try await pending(fixture.database).isEmpty)
  }

  @Test func noRecordNameKeyStillRemovesTheEntryLocally() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(
      database: fixture.database,
      savedIntent: PodcastCloudSavedIntentResolver(
        recordNameKey: { nil }, now: { Date(timeIntervalSince1970: 1_700_000_000) }))

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 0)
    #expect(try await pending(fixture.database).isEmpty)
  }

  /// The key is asked for per mutation, not captured once, so an activation that happens after the
  /// store was built starts stamping without the store being rebuilt.
  @Test func aKeyThatArrivesAfterConstructionIsPickedUp() async throws {
    let fixture = try await fixture()
    let key = Locked<PodcastCloudRecordNameKey?>(nil)
    let store = RSSEpisodeStateStore(
      database: fixture.database,
      savedIntent: PodcastCloudSavedIntentResolver(
        recordNameKey: { key.value }, now: { Date(timeIntervalSince1970: 1_700_000_000) }))
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))
    #expect(try await pending(fixture.database).isEmpty)
    try await save(episodeId: fixture.savedEpisodeId, in: fixture.database)

    key.withValue { $0 = Self.key }
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: false, now: Date(timeIntervalSince1970: 200))
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 300))

    #expect(try await pending(fixture.database).count == 1)
  }

  /// A quarantined clock mints nothing, and refusing the write would cost the listener their
  /// progress. The removal commits locally and is not sent; it leaves a republish debt that the
  /// post-repair republish settles.
  @Test func aQuarantinedClockDoesNotBlockTheLocalRemoval() async throws {
    let fixture = try await fixture()
    try await fixture.database.writeAsync { db in
      try db.execute(sql: "UPDATE podcastCloudInstallation SET repairRequired = 1 WHERE id = 1")
    }
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 0)
    #expect(try await pending(fixture.database).isEmpty)
    let debts = try await fixture.database.readAsync { db in
      try PodcastCloudRepublishDebtStore.all(in: db)
    }
    #expect(debts.map(\.identityKey) == ["guid:one"])
    #expect(debts.map(\.recordKind) == ["saved"])
  }

  // MARK: - Atomicity

  /// A removal that cannot be named must take the playback write down with it rather than commit
  /// state the outbox never learns about.
  @Test func anUnnameableRemovalRollsBackThePlaybackWrite() async throws {
    let fixture = try await fixture()
    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudSubscriptionRegistry SET generationUUID = 'not-a-uuid'")
    }
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    await #expect(throws: PodcastCloudIdentity.RecordNameError.invalid) {
      _ = try await store.setFinished(
        episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))
    }

    #expect(try await savedCount(fixture.database) == 1)
    #expect(try await pending(fixture.database).isEmpty)
    let state = try await RSSEpisodeStateStore(database: fixture.database)
      .fetchState(episodeId: fixture.savedEpisodeId)
    #expect(state == nil)
  }

  /// Ties the two halves together: what the resolver enqueued is what a rebuilt engine would be
  /// seeded with, and it is seeded as a save rather than a deletion.
  @Test func theEnqueuedRemovalIsWhatARebuiltEngineWouldBeSeededWith() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())

    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))

    let send = try #require(try await pending(fixture.database).first)
    let work = try await PodcastCloudTransportStore(database: fixture.database)
      .pendingWork(namespace: Self.namespace)
    #expect(work.saves == [send.recordName])
    #expect(work.deletions.isEmpty)
  }

  // MARK: - Coalescing and ordering

  @Test func aSecondRemovalOfTheSameEpisodeCoalescesToOneRowWithANewerGeneration() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 100))
    let first = try #require(try await pending(fixture.database).first)
    try await save(episodeId: fixture.savedEpisodeId, in: fixture.database)

    // A genuine new decision: unplayed, then finished again.
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: false, now: Date(timeIntervalSince1970: 200))
    _ = try await store.setFinished(
      episodeId: fixture.savedEpisodeId, finished: true, now: Date(timeIntervalSince1970: 300))

    let sends = try await pending(fixture.database)
    #expect(sends.count == 1)
    let second = try #require(sends.first)
    #expect(second.recordName == first.recordName)
    #expect(second.generation > first.generation)
  }

  @Test func stampsForTwoEpisodesAdvanceStrictlyAndNameDifferentRecords() async throws {
    let fixture = try await fixture()
    let store = RSSEpisodeStateStore(database: fixture.database, savedIntent: resolver())
    try await save(episodeId: fixture.otherEpisodeId, in: fixture.database)

    _ = try await store.setFinished(
      episodeIds: [fixture.savedEpisodeId, fixture.otherEpisodeId], finished: true,
      now: Date(timeIntervalSince1970: 100))

    #expect(try await savedCount(fixture.database) == 0)
    let sends = try await pending(fixture.database)
    #expect(sends.count == 2)
    #expect(Set(sends.map(\.recordName)).count == 2)
    let stamps = try sends.map {
      try PodcastCloudRecordCodec.decodeSavedRegister(
        try PodcastCloudRecordPayload.decode($0.payload)
      ).stamp
    }
    // One wall-clock reading for both, so the logical counter is what separates them.
    #expect(Set(stamps).count == 2)
    #expect(stamps.sorted().first != stamps.sorted().last)
  }
}
