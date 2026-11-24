import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct PodcastCloudRegistryStoreTests {
  private func stamp(
    _ physical: Int64, _ logical: Int64 = 0, installation: String = "install-a",
    mutation: String = "mutation-1"
  ) -> PodcastCloudStampFields {
    PodcastCloudStampFields(
      physicalMilliseconds: physical, logicalCounter: logical, installationUUID: installation,
      mutationUUID: mutation)
  }

  private func entry(
    uuid: String = "sub-1", fingerprint: String = "fp-1", url: String = "https://example.com/feed",
    generation: String = "gen-1", isFollowed: Bool = true, stampAt: Int64 = 1_000
  ) -> PodcastCloudRegistryEntry {
    PodcastCloudRegistryEntry(
      subscriptionUUID: uuid, fingerprint: fingerprint, normalizedURL: url,
      canonicalizationVersion: 1, generationUUID: generation, isFollowed: isFollowed,
      followStamp: stamp(stampAt))
  }

  // MARK: - The cascade the registry exists to survive

  @Test func registryOutlivesTheFeedCascadeAndKeepsItsDeletionStamp() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    try await store.register(entry())

    // The catalogue row going away is the ordinary unsubscribe path; the identity must not follow
    // it. Deleting every rssFeed row stands in for that cascade.
    try await database.writeAsync { db in try db.execute(sql: "DELETE FROM rssFeed") }
    try await store.retire(subscriptionUUID: "sub-1", stamp: stamp(2_000, 1, mutation: "mutation-2"))

    let retired = try #require(try await store.entry(subscriptionUUID: "sub-1"))
    #expect(retired.isFollowed == false)
    #expect(retired.generationUUID == "gen-1", "unfollow preserves the generation")
    #expect(retired.followStamp.physicalMilliseconds == 2_000)
    #expect(retired.followStamp.mutationUUID == "mutation-2")
    #expect(retired.normalizedURL == "https://example.com/feed")
  }

  @Test func neverFollowedIsDistinguishableFromUnfollowedForever() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    try await store.register(entry(uuid: "sub-1", fingerprint: "fp-1"))
    try await store.retire(subscriptionUUID: "sub-1", stamp: stamp(2_000))

    #expect(try await store.entry(subscriptionUUID: "sub-1")?.isFollowed == false)
    #expect(try await store.entry(subscriptionUUID: "sub-never") == nil)
  }

  @Test func refollowReusesTheUUIDUnderAFreshGeneration() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    try await store.register(entry(generation: "gen-1"))
    try await store.retire(subscriptionUUID: "sub-1", stamp: stamp(2_000))
    try await store.register(entry(generation: "gen-2", stampAt: 3_000))

    let refollowed = try #require(try await store.entry(subscriptionUUID: "sub-1"))
    #expect(refollowed.isFollowed)
    #expect(refollowed.generationUUID == "gen-2")
    #expect(try await store.allEntries().count == 1, "re-follow is the same identity, not a second row")
  }

  @Test func aFingerprintHeldByAnotherUUIDIsACollisionRatherThanASilentCombine() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    try await store.register(entry(uuid: "sub-1", fingerprint: "fp-shared", url: "https://a.example/feed"))

    await #expect(throws: PodcastCloudRegistryError.fingerprintCollision) {
      try await store.register(
        entry(uuid: "sub-2", fingerprint: "fp-shared", url: "https://b.example/feed"))
    }
    #expect(try await store.entry(fingerprint: "fp-shared")?.subscriptionUUID == "sub-1")
  }

  @Test func registryLookupByFingerprintFindsTheSameEntry() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    try await store.register(entry())
    #expect(try await store.entry(fingerprint: "fp-1")?.subscriptionUUID == "sub-1")
  }

  // MARK: - Last accepted stamp

  @Test func theLastAcceptedStampPerEntityRoundTripsAndOverwrites() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)

    try await store.recordAccepted(recordName: "v1.state.a", stamp: stamp(1_000, 1))
    #expect(try await store.acceptedStamp(recordName: "v1.state.a")?.physicalMilliseconds == 1_000)

    try await store.recordAccepted(recordName: "v1.state.a", stamp: stamp(2_000, 4, mutation: "m2"))
    let latest = try #require(try await store.acceptedStamp(recordName: "v1.state.a"))
    #expect(latest.physicalMilliseconds == 2_000)
    #expect(latest.logicalCounter == 4)
    #expect(latest.mutationUUID == "m2")
    #expect(try await store.acceptedStamp(recordName: "v1.state.absent") == nil)
  }

  @Test func theAcceptedPayloadTravelsWithItsStampAndNeverOutlivesIt() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)

    try await store.recordAccepted(
      recordName: "v1.state.a", stamp: stamp(1_000, 1), payload: Data([1, 2, 3]))
    #expect(try await store.acceptedPayload(recordName: "v1.state.a") == Data([1, 2, 3]))

    // A stamp recorded without its value leaves no stale value behind to merge against.
    try await store.recordAccepted(recordName: "v1.state.a", stamp: stamp(2_000, 1, mutation: "m2"))
    #expect(try await store.acceptedPayload(recordName: "v1.state.a") == nil)
    #expect(try await store.acceptedPayload(recordName: "v1.state.absent") == nil)
  }

  // MARK: - Unresolved remote episode state

  @Test func unresolvedStateIsHeldPerGenerationAndClearedWhenResolved() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    let held = PodcastCloudUnresolvedState(
      recordName: "v1.state.a", subscriptionUUID: "sub-1", generationUUID: "gen-1",
      episodeDigest: "digest-a", payload: Data([1, 2, 3]), receivedAt: Date(timeIntervalSince1970: 10))
    try await store.holdUnresolved(held)
    try await store.holdUnresolved(
      PodcastCloudUnresolvedState(
        recordName: "v1.state.b", subscriptionUUID: "sub-1", generationUUID: "gen-2",
        episodeDigest: "digest-b", payload: Data([4]), receivedAt: Date(timeIntervalSince1970: 11)))

    let generationOne = try await store.unresolved(subscriptionUUID: "sub-1", generationUUID: "gen-1")
    #expect(generationOne.map(\.recordName) == ["v1.state.a"])
    #expect(generationOne.first?.payload == Data([1, 2, 3]))

    try await store.resolveUnresolved(recordName: "v1.state.a")
    #expect(try await store.unresolved(subscriptionUUID: "sub-1", generationUUID: "gen-1").isEmpty)
    #expect(try await store.unresolved(subscriptionUUID: "sub-1", generationUUID: "gen-2").count == 1)
  }

  @Test func rehearingTheSameRecordReplacesItRatherThanAccumulating() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    for payload in [Data([1]), Data([2])] {
      try await store.holdUnresolved(
        PodcastCloudUnresolvedState(
          recordName: "v1.state.a", subscriptionUUID: "sub-1", generationUUID: "gen-1",
          episodeDigest: "digest-a", payload: payload, receivedAt: Date(timeIntervalSince1970: 10)))
    }
    let held = try await store.unresolved(subscriptionUUID: "sub-1", generationUUID: "gen-1")
    #expect(held.count == 1)
    #expect(held.first?.payload == Data([2]))
  }

  @Test func pruningKeepsTheNewestAndReportsWhatItRemoved() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    for index in 0..<5 {
      try await store.holdUnresolved(
        PodcastCloudUnresolvedState(
          recordName: "v1.state.\(index)", subscriptionUUID: "sub-1", generationUUID: "gen-1",
          episodeDigest: "digest-\(index)", payload: Data([UInt8(index)]),
          receivedAt: Date(timeIntervalSince1970: TimeInterval(index))))
    }

    let removed = try await store.pruneUnresolved(keeping: 2)
    #expect(removed == 3)
    let remaining = try await store.unresolved(subscriptionUUID: "sub-1", generationUUID: "gen-1")
    #expect(remaining.map(\.recordName) == ["v1.state.3", "v1.state.4"])
  }

  @Test func anEmptyOrOversizedPayloadIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    for payload in [Data(), Data(repeating: 0, count: 65_537)] {
      await #expect(throws: PodcastCloudRegistryError.invalidPayload) {
        try await store.holdUnresolved(
          PodcastCloudUnresolvedState(
            recordName: "v1.state.a", subscriptionUUID: "sub-1", generationUUID: "gen-1",
            episodeDigest: "digest-a", payload: payload, receivedAt: Date()))
      }
    }
  }

  // MARK: - Transaction participation

  @Test func aRegistryWriteRollsBackWithTheMutationItAccompanies() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudRegistryStore(database: database)
    struct Boom: Error {}

    _ = try? await database.writeAsync { db in
      try PodcastCloudRegistryStore.register(in: db, entry: self.entry())
      try PodcastCloudRegistryStore.recordAccepted(
        in: db, recordName: "v1.sub.a", stamp: self.stamp(1_000))
      throw Boom()
    }

    #expect(try await store.entry(subscriptionUUID: "sub-1") == nil)
    #expect(try await store.acceptedStamp(recordName: "v1.sub.a") == nil)
  }
}
