import Foundation
import Persistence
import Testing

@testable import SyncEngine

/// Record-level merge for conflicts and fetched-versus-pending. The entity merges it is built from
/// have their own algebraic tests in `PodcastCloudValuesTests`; these pin down that the record
/// layer picks the same winner, returns "keep the server" for an echo, and never guesses through
/// a stamp collision.
@Suite struct PodcastCloudRecordMergeTests {
  private static let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private static let stateName =
    "v1.state.0a0a0a0a-0a0a-8a0a-8a0a-0a0a0a0a0a0a.0b0b0b0b-0b0b-8b0b-8b0b-0b0b0b0b0b0b."
    + String(repeating: "c", count: 64)

  private func stamp(_ milliseconds: Int64, mutation: Int = 1) throws -> PodcastCloudMutationStamp {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: milliseconds, logicalCounter: 0, installationUUID: Self.installation,
      mutationUUID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", mutation))!)
  }

  private func state(
    position: Double, epoch: Int64? = nil, write: Int64, mutation: Int = 1
  ) throws -> PodcastCloudRecordFields {
    try PodcastCloudRecordCodec.encode(
      episodeState: try PodcastCloudEpisodeState(
        position: position, isFinished: false, isDismissed: false,
        explicitEpoch: try epoch.map { try stamp($0, mutation: mutation) } ?? .bottom,
        writeStamp: try stamp(write, mutation: mutation)),
      identity: PodcastCloudEpisodeIdentityFields(identityKey: "guid:one"),
      recordName: Self.stateName)
  }

  private func globals(at milliseconds: Int64, keepLatest: Int, mutation: Int = 1) throws
    -> PodcastCloudRecordFields
  {
    try PodcastCloudRecordCodec.encode(
      globalSettings: StampedGlobalSettings(
        autoDownloadEnabled: false, keepLatestCount: keepLatest, deleteAfterPlayed: false,
        allowCellularAutoDownload: false, showOrderMode: "custom",
        writeStamp: try stamp(milliseconds, mutation: mutation)),
      recordName: "v1.globals")
  }

  private func subscription(
    followedAt follow: Int64, isFollowed: Bool, order: (value: Int, at: Int64)?
  ) throws -> PodcastCloudRecordFields {
    let subscriptionUUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    return try PodcastCloudRecordCodec.encode(
      subscription: SubscriptionSnapshot(
        subscriptionUUID: subscriptionUUID, normalizedURL: "https://example.com/feed",
        title: isFollowed ? "Followed" : "Unfollowed",
        lifecycle: PodcastCloudFollowRegister(
          subscriptionUUID: subscriptionUUID,
          generationUUID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
          isFollowed: isFollowed, stamp: try stamp(follow, mutation: 7)),
        customOrder: try order.map {
          StampedCustomOrder(value: $0.value, stamp: try stamp($0.at, mutation: 8))
        }),
      recordName: "v1.sub.33333333-3333-8333-8333-333333333333")
  }

  // MARK: - Echo and LWW

  @Test func anIdenticalRecordKeepsTheServer() throws {
    let record = try globals(at: 1_000, keepLatest: 3)
    #expect(try PodcastCloudRecordMerge.merge(local: record, server: record) == .keepServer)
  }

  @Test func wholeRegistersAreLastWriterWins() throws {
    let older = try globals(at: 1_000, keepLatest: 3)
    let newer = try globals(at: 2_000, keepLatest: 5, mutation: 2)

    #expect(try PodcastCloudRecordMerge.merge(local: newer, server: older) == .publish(newer))
    #expect(try PodcastCloudRecordMerge.merge(local: older, server: newer) == .keepServer)
  }

  @Test func twoValuesUnderOneStampAreACollisionNotAChoice() throws {
    let lhs = try globals(at: 1_000, keepLatest: 3)
    let rhs = try globals(at: 1_000, keepLatest: 5)

    #expect(throws: PodcastCloudRecordMerge.Failure.stampCollision) {
      try PodcastCloudRecordMerge.merge(local: lhs, server: rhs)
    }
  }

  @Test func differentRecordsCannotBeMerged() throws {
    let globals = try globals(at: 1_000, keepLatest: 3)
    let state = try state(position: 1, write: 1_000)

    #expect(throws: PodcastCloudRecordMerge.Failure.recordMismatch) {
      try PodcastCloudRecordMerge.merge(local: globals, server: state)
    }
  }

  // MARK: - Episode state precedence

  @Test func aNewerExplicitEpochBeatsALaterTick() throws {
    let explicit = try state(position: 0, epoch: 2_000, write: 2_000, mutation: 2)
    let staleTick = try state(position: 900, write: 5_000, mutation: 3)

    #expect(try PodcastCloudRecordMerge.merge(local: staleTick, server: explicit) == .keepServer)
    #expect(try PodcastCloudRecordMerge.merge(local: explicit, server: staleTick) == .publish(explicit))
  }

  @Test func ticksUnderTheSameEpochProgress() throws {
    let earlier = try state(position: 10, write: 1_000, mutation: 2)
    let later = try state(position: 20, write: 2_000, mutation: 3)

    #expect(try PodcastCloudRecordMerge.merge(local: later, server: earlier) == .publish(later))
    #expect(try PodcastCloudRecordMerge.merge(local: earlier, server: later) == .keepServer)
  }

  // MARK: - Unsent listening beats a reset

  /// At the pure merge level: a strictly newer remote explicit epoch would
  /// ordinarily win, but `hasUnsentListening` turns that into `.adoptLocalAsExplicit` instead.
  @Test func unsentListeningAgainstANewerExplicitEpochAdoptsLocalAsExplicit() throws {
    let tick = try state(position: 900, epoch: 1_000, write: 5_000, mutation: 3)
    let reset = try state(position: 0, epoch: 6_000, write: 6_000, mutation: 4)

    #expect(
      try PodcastCloudRecordMerge.merge(local: tick, server: reset, hasUnsentListening: true)
        == .adoptLocalAsExplicit(tick))
  }

  /// With no unsent listening asserted, the same pair resolves like any other newer-explicit-epoch
  /// conflict: the server still wins.
  @Test func withoutUnsentListeningTheNewerExplicitEpochStillWins() throws {
    let tick = try state(position: 900, epoch: 1_000, write: 5_000, mutation: 3)
    let reset = try state(position: 0, epoch: 6_000, write: 6_000, mutation: 4)

    #expect(try PodcastCloudRecordMerge.merge(local: tick, server: reset) == .keepServer)
  }

  /// An equal epoch is an ordinary tick race under the same explicit action, decided by write
  /// stamp as always. `hasUnsentListening` never overrides that, only a strictly newer epoch does.
  ///
  /// Both states share `mutation: 2` so their explicit-epoch stamps are byte-for-byte identical
  /// (same time, same mutation UUID), not just equal in milliseconds: `state` derives both stamps'
  /// mutation UUID from `mutation`, so a differing value would tie-break the "equal" epochs apart
  /// and silently become the strictly-newer-epoch case the next test covers.
  @Test func unsentListeningUnderAnEqualEpochStillResolvesByStamp() throws {
    let earlier = try state(position: 10, epoch: 1_000, write: 1_000, mutation: 2)
    let later = try state(position: 20, epoch: 1_000, write: 2_000, mutation: 2)

    #expect(
      try PodcastCloudRecordMerge.merge(local: earlier, server: later, hasUnsentListening: true)
        == .keepServer)
  }

  /// `isUnsentTick`: a tick (explicit epoch strictly older than its write stamp) with a
  /// differing position qualifies; an explicit action, or a tick that already agrees on
  /// position, does not.
  @Test func isUnsentTickOnlyTrueForAPositionChangingTick() throws {
    let tick = try PodcastCloudRecordCodec.decodeEpisodeState(
      try state(position: 900, epoch: 1_000, write: 5_000, mutation: 3)
    ).state
    let sameTickPosition = try PodcastCloudRecordCodec.decodeEpisodeState(
      try state(position: 0, epoch: 1_000, write: 5_000, mutation: 3)
    ).state
    let explicit = try PodcastCloudRecordCodec.decodeEpisodeState(
      try state(position: 0, epoch: 6_000, write: 6_000, mutation: 4)
    ).state
    let server = try PodcastCloudRecordCodec.decodeEpisodeState(try state(position: 0, write: 6_000)).state

    #expect(PodcastCloudRecordMerge.isUnsentTick(local: tick, server: server) == true)
    #expect(PodcastCloudRecordMerge.isUnsentTick(local: sameTickPosition, server: server) == false)
    #expect(PodcastCloudRecordMerge.isUnsentTick(local: explicit, server: server) == false)
  }

  // MARK: - Subscription registers

  @Test func theFollowLifecycleAndCustomOrderMergeIndependently() throws {
    // Local unfollowed later; the server moved the show in the custom order later still.
    let local = try subscription(followedAt: 3_000, isFollowed: false, order: (value: 1, at: 1_000))
    let server = try subscription(followedAt: 1_000, isFollowed: true, order: (value: 4, at: 4_000))

    guard case .publish(let merged) = try PodcastCloudRecordMerge.merge(local: local, server: server)
    else {
      Issue.record("expected a merged record to publish")
      return
    }
    let decoded = try PodcastCloudRecordCodec.decodeSubscription(
      merged, subscriptionUUID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
    #expect(decoded.lifecycle.isFollowed == false)
    #expect(decoded.customOrder?.value == 4)
    #expect(decoded.title == "Unfollowed")
  }

  @Test func aSubscriptionTheServerAlreadyWinsKeepsTheServer() throws {
    let local = try subscription(followedAt: 1_000, isFollowed: true, order: nil)
    let server = try subscription(followedAt: 2_000, isFollowed: false, order: (value: 2, at: 2_000))

    #expect(try PodcastCloudRecordMerge.merge(local: local, server: server) == .keepServer)
  }

  // MARK: - Identity union

  @Test func identityRecordsUnionTheirAliasesAndKeepTheSmallestRepresentative() throws {
    func identity(representative: String, aliases: [String], at: Int64) throws -> PodcastCloudRecordFields {
      var builder = PodcastCloudRecordBuilder(
        type: PodcastCloudRecordLayout.episodeIdentity, recordName: "v1.identity.x")
      try builder.set("representativeDigest", .string(representative))
      try builder.set("aliases", .stringList(aliases))
      try builder.set(stamp: try stamp(at, mutation: Int(at)), prefix: "write")
      return try builder.build()
    }
    let local = try identity(representative: "b", aliases: ["b", "c"], at: 2)
    let server = try identity(representative: "a", aliases: ["a", "b"], at: 1)

    guard case .publish(let merged) = try PodcastCloudRecordMerge.merge(local: local, server: server)
    else {
      Issue.record("expected the union to publish")
      return
    }
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.episodeIdentity, fields: merged)
    #expect(try reader.stringList("aliases") == ["a", "b", "c"])
    #expect(try reader.string("representativeDigest") == "a")

    // Merging the union back against itself is an echo: union is idempotent.
    #expect(try PodcastCloudRecordMerge.merge(local: merged, server: merged) == .keepServer)
  }

  // MARK: - Governing stamp and size

  @Test func theGoverningStampIsTheNewestTheRecordCarries() throws {
    let record = try subscription(followedAt: 1_000, isFollowed: true, order: (value: 1, at: 3_000))
    #expect(try PodcastCloudRecordMerge.governingStamp(of: record) == (try stamp(3_000, mutation: 8)))

    let keyring = try PodcastCloudRecordCodec.encodeKeyring(recordNameKey: Data(repeating: 1, count: 32))
    #expect(try PodcastCloudRecordMerge.governingStamp(of: keyring) == nil)
  }

  @Test func theSizeEstimateGrowsWithContentAndCoversTheOverhead() throws {
    let small = try state(position: 1, write: 1_000)
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.episodeState, recordName: Self.stateName)
    try builder.set("title", .string(String(repeating: "t", count: 1_000)))
    try builder.set(stamp: try stamp(1_000), prefix: "write")
    let large = try builder.build()

    #expect(PodcastCloudRecordMerge.estimatedBytes(of: small) > PodcastCloudRecordMerge.recordOverheadBytes)
    #expect(PodcastCloudRecordMerge.estimatedBytes(of: large) > 1_000 + PodcastCloudRecordMerge.recordOverheadBytes)
  }

  @Test func storedStampsRoundTrip() throws {
    let original = try stamp(1_234, mutation: 9)
    #expect(PodcastCloudMutationStamp(PodcastCloudStampFields(original)) == original)
    #expect(
      PodcastCloudMutationStamp(
        PodcastCloudStampFields(
          physicalMilliseconds: 1, logicalCounter: 0, installationUUID: "nope", mutationUUID: "nope"))
        == nil)
  }
}
