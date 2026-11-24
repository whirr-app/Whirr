import Foundation
import GRDB

/// The four ordering components of a mutation stamp, as stored. `SyncEngine` owns the comparable
/// domain type and its algebra; this is the transport shape, so `Persistence` keeps no dependency
/// on the layer above it. Values are opaque ordering tokens here and are never compared.
public struct PodcastCloudStampFields: Sendable, Equatable {
  public let physicalMilliseconds: Int64
  public let logicalCounter: Int64
  public let installationUUID: String
  public let mutationUUID: String

  public init(
    physicalMilliseconds: Int64, logicalCounter: Int64, installationUUID: String, mutationUUID: String
  ) {
    self.physicalMilliseconds = physicalMilliseconds
    self.logicalCounter = logicalCounter
    self.installationUUID = installationUUID
    self.mutationUUID = mutationUUID
  }
}

/// A subscription's durable cloud identity. It outlives the `rssFeed` row: unfollowing sets
/// `isFollowed = false` and keeps the generation, so a later re-follow is a new generation rather
/// than a resurrection, and a remote child arriving for the old generation stays invisible.
public struct PodcastCloudRegistryEntry: Sendable, Equatable {
  public let subscriptionUUID: String
  public let fingerprint: String
  public let normalizedURL: String
  public let canonicalizationVersion: Int
  public let generationUUID: String
  public let isFollowed: Bool
  public let followStamp: PodcastCloudStampFields

  public init(
    subscriptionUUID: String, fingerprint: String, normalizedURL: String,
    canonicalizationVersion: Int, generationUUID: String, isFollowed: Bool,
    followStamp: PodcastCloudStampFields
  ) {
    self.subscriptionUUID = subscriptionUUID
    self.fingerprint = fingerprint
    self.normalizedURL = normalizedURL
    self.canonicalizationVersion = canonicalizationVersion
    self.generationUUID = generationUUID
    self.isFollowed = isFollowed
    self.followStamp = followStamp
  }
}

/// Remote episode state held because the identity it names has not been resolved against a feed.
public struct PodcastCloudUnresolvedState: Sendable, Equatable {
  public let recordName: String
  public let subscriptionUUID: String
  public let generationUUID: String
  public let episodeDigest: String
  public let payload: Data
  public let receivedAt: Date

  public init(
    recordName: String, subscriptionUUID: String, generationUUID: String, episodeDigest: String,
    payload: Data, receivedAt: Date
  ) {
    self.recordName = recordName
    self.subscriptionUUID = subscriptionUUID
    self.generationUUID = generationUUID
    self.episodeDigest = episodeDigest
    self.payload = payload
    self.receivedAt = receivedAt
  }
}

public enum PodcastCloudRegistryError: Error, Equatable, Sendable {
  case fingerprintCollision
  case invalidPayload
}

/// Local bookkeeping for cloud sync. Every method a user mutation participates in takes a
/// `Database`, so the caller can commit the mutation and its outbox row in one transaction. The
/// async wrappers are for readers and callers with no wider transaction.
public struct PodcastCloudRegistryStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  // MARK: - Subscription registry

  /// Registers a first follow, or re-follows an existing identity under a new generation. The
  /// fingerprint is the uniqueness key: two normalized URLs that fingerprint alike are the same
  /// subscription, and a fingerprint already held by a different UUID is a collision the caller
  /// must surface ("Sync needs attention") rather than silently combine.
  public static func register(
    in db: Database, entry: PodcastCloudRegistryEntry
  ) throws {
    let existing = try String.fetchOne(
      db, sql: "SELECT subscriptionUUID FROM podcastCloudSubscriptionRegistry WHERE fingerprint = ?",
      arguments: [entry.fingerprint])
    if let existing, existing != entry.subscriptionUUID {
      throw PodcastCloudRegistryError.fingerprintCollision
    }
    try db.execute(
      sql: """
        INSERT INTO podcastCloudSubscriptionRegistry (
          subscriptionUUID, fingerprint, normalizedURL, canonicalizationVersion, generationUUID,
          isFollowed, followPhysicalMilliseconds, followLogicalCounter, followInstallationUUID,
          followMutationUUID)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (subscriptionUUID) DO UPDATE SET
          fingerprint = excluded.fingerprint,
          normalizedURL = excluded.normalizedURL,
          canonicalizationVersion = excluded.canonicalizationVersion,
          generationUUID = excluded.generationUUID,
          isFollowed = excluded.isFollowed,
          followPhysicalMilliseconds = excluded.followPhysicalMilliseconds,
          followLogicalCounter = excluded.followLogicalCounter,
          followInstallationUUID = excluded.followInstallationUUID,
          followMutationUUID = excluded.followMutationUUID
        """,
      arguments: [
        entry.subscriptionUUID, entry.fingerprint, entry.normalizedURL, entry.canonicalizationVersion,
        entry.generationUUID, entry.isFollowed, entry.followStamp.physicalMilliseconds,
        entry.followStamp.logicalCounter, entry.followStamp.installationUUID,
        entry.followStamp.mutationUUID,
      ])
  }

  public func register(_ entry: PodcastCloudRegistryEntry) async throws {
    try await database.writeAsync { db in try Self.register(in: db, entry: entry) }
  }

  /// Unfollow keeps the row, the UUID and the generation, and records the stamp that retired it.
  /// This is the deletion stamp. There is no tombstone table, because a never-followed
  /// subscription and an unfollowed one must stay distinguishable forever.
  public static func retire(
    in db: Database, subscriptionUUID: String, stamp: PodcastCloudStampFields
  ) throws {
    try db.execute(
      sql: """
        UPDATE podcastCloudSubscriptionRegistry SET
          isFollowed = 0, followPhysicalMilliseconds = ?, followLogicalCounter = ?,
          followInstallationUUID = ?, followMutationUUID = ?
        WHERE subscriptionUUID = ?
        """,
      arguments: [
        stamp.physicalMilliseconds, stamp.logicalCounter, stamp.installationUUID,
        stamp.mutationUUID, subscriptionUUID,
      ])
  }

  public func retire(subscriptionUUID: String, stamp: PodcastCloudStampFields) async throws {
    try await database.writeAsync { db in
      try Self.retire(in: db, subscriptionUUID: subscriptionUUID, stamp: stamp)
    }
  }

  public static func entry(in db: Database, subscriptionUUID: String) throws -> PodcastCloudRegistryEntry? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM podcastCloudSubscriptionRegistry WHERE subscriptionUUID = ?",
      arguments: [subscriptionUUID]
    ).map(Self.entry(from:))
  }

  public func entry(subscriptionUUID: String) async throws -> PodcastCloudRegistryEntry? {
    try await database.readAsync { db in try Self.entry(in: db, subscriptionUUID: subscriptionUUID) }
  }

  public func entry(fingerprint: String) async throws -> PodcastCloudRegistryEntry? {
    try await database.readAsync { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM podcastCloudSubscriptionRegistry WHERE fingerprint = ?",
        arguments: [fingerprint]
      ).map(Self.entry(from:))
    }
  }

  public func allEntries() async throws -> [PodcastCloudRegistryEntry] {
    try await database.readAsync { db in try Self.allEntries(in: db) }
  }

  public static func allEntries(in db: Database) throws -> [PodcastCloudRegistryEntry] {
    try Row.fetchAll(
      db, sql: "SELECT * FROM podcastCloudSubscriptionRegistry ORDER BY subscriptionUUID"
    ).map(entry(from:))
  }

  private static func entry(from row: Row) -> PodcastCloudRegistryEntry {
    PodcastCloudRegistryEntry(
      subscriptionUUID: row["subscriptionUUID"], fingerprint: row["fingerprint"],
      normalizedURL: row["normalizedURL"], canonicalizationVersion: row["canonicalizationVersion"],
      generationUUID: row["generationUUID"], isFollowed: row["isFollowed"],
      followStamp: PodcastCloudStampFields(
        physicalMilliseconds: row["followPhysicalMilliseconds"],
        logicalCounter: row["followLogicalCounter"],
        installationUUID: row["followInstallationUUID"],
        mutationUUID: row["followMutationUUID"]))
  }

  // MARK: - Last accepted stamp per entity

  /// Records the stamp, and the encoded record it governs when the caller has one. Writing a stamp
  /// without a payload clears any earlier payload: a value that no longer matches its stamp is
  /// worse than none, because admission would merge against it.
  public static func recordAccepted(
    in db: Database, recordName: String, stamp: PodcastCloudStampFields, payload: Data? = nil
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO podcastCloudEntityStamp (
          recordName, physicalMilliseconds, logicalCounter, installationUUID, mutationUUID, payload)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (recordName) DO UPDATE SET
          physicalMilliseconds = excluded.physicalMilliseconds,
          logicalCounter = excluded.logicalCounter,
          installationUUID = excluded.installationUUID,
          mutationUUID = excluded.mutationUUID,
          payload = excluded.payload
        """,
      arguments: [
        recordName, stamp.physicalMilliseconds, stamp.logicalCounter, stamp.installationUUID,
        stamp.mutationUUID, payload,
      ])
  }

  public func recordAccepted(
    recordName: String, stamp: PodcastCloudStampFields, payload: Data? = nil
  ) async throws {
    try await database.writeAsync { db in
      try Self.recordAccepted(in: db, recordName: recordName, stamp: stamp, payload: payload)
    }
  }

  /// The encoded record last accepted under `recordName`, when one was recorded with its stamp.
  public static func acceptedPayload(in db: Database, recordName: String) throws -> Data? {
    try Data.fetchOne(
      db, sql: "SELECT payload FROM podcastCloudEntityStamp WHERE recordName = ?",
      arguments: [recordName])
  }

  public func acceptedPayload(recordName: String) async throws -> Data? {
    try await database.readAsync { db in try Self.acceptedPayload(in: db, recordName: recordName) }
  }

  public func acceptedStamp(recordName: String) async throws -> PodcastCloudStampFields? {
    try await database.readAsync { db in try Self.acceptedStamp(in: db, recordName: recordName) }
  }

  /// The same read inside a caller's transaction, so a remote apply can compare and record in one
  /// write.
  public static func acceptedStamp(in db: Database, recordName: String) throws
    -> PodcastCloudStampFields?
  {
    try Row.fetchOne(
      db, sql: "SELECT * FROM podcastCloudEntityStamp WHERE recordName = ?", arguments: [recordName]
    ).map {
      PodcastCloudStampFields(
        physicalMilliseconds: $0["physicalMilliseconds"], logicalCounter: $0["logicalCounter"],
        installationUUID: $0["installationUUID"], mutationUUID: $0["mutationUUID"])
    }
  }

  // MARK: - Unresolved remote episode state

  public static func holdUnresolved(in db: Database, _ state: PodcastCloudUnresolvedState) throws {
    guard state.payload.count <= 65536, !state.payload.isEmpty else {
      throw PodcastCloudRegistryError.invalidPayload
    }
    try db.execute(
      sql: """
        INSERT INTO podcastCloudUnresolvedEpisodeState (
          recordName, subscriptionUUID, generationUUID, episodeDigest, payload, receivedAt)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (recordName) DO UPDATE SET
          subscriptionUUID = excluded.subscriptionUUID,
          generationUUID = excluded.generationUUID,
          episodeDigest = excluded.episodeDigest,
          payload = excluded.payload,
          receivedAt = excluded.receivedAt
        """,
      arguments: [
        state.recordName, state.subscriptionUUID, state.generationUUID, state.episodeDigest,
        state.payload, state.receivedAt,
      ])
  }

  public func holdUnresolved(_ state: PodcastCloudUnresolvedState) async throws {
    try await database.writeAsync { db in try Self.holdUnresolved(in: db, state) }
  }

  public func unresolved(subscriptionUUID: String, generationUUID: String) async throws
    -> [PodcastCloudUnresolvedState]
  {
    try await database.readAsync { db in
      try Self.unresolved(in: db, subscriptionUUID: subscriptionUUID, generationUUID: generationUUID)
    }
  }

  /// Rows are matched on whatever the writer stored in these two columns. The cloud writer
  /// (`PodcastCloudHoldingApplier`) stores the keyed record-name components, because a state
  /// record's body does not name its subscription. Resolution recomputes the keyed form of a
  /// local subscription to query them.
  public static func unresolved(
    in db: Database, subscriptionUUID: String, generationUUID: String
  ) throws -> [PodcastCloudUnresolvedState] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM podcastCloudUnresolvedEpisodeState
        WHERE subscriptionUUID = ? AND generationUUID = ? ORDER BY receivedAt, recordName
        """,
      arguments: [subscriptionUUID, generationUUID]
    ).map {
      PodcastCloudUnresolvedState(
        recordName: $0["recordName"], subscriptionUUID: $0["subscriptionUUID"],
        generationUUID: $0["generationUUID"], episodeDigest: $0["episodeDigest"],
        payload: $0["payload"], receivedAt: $0["receivedAt"])
    }
  }

  public static func resolveUnresolved(in db: Database, recordName: String) throws {
    try db.execute(
      sql: "DELETE FROM podcastCloudUnresolvedEpisodeState WHERE recordName = ?",
      arguments: [recordName])
  }

  public func resolveUnresolved(recordName: String) async throws {
    try await database.writeAsync { db in try Self.resolveUnresolved(in: db, recordName: recordName) }
  }

  /// Caps unresolved history. The oldest entries go first, since a remote state whose identity has
  /// not arrived in that long is the least likely to resolve.
  @discardableResult
  public func pruneUnresolved(keeping limit: Int) async throws -> Int {
    try await database.writeAsync { db in try Self.pruneUnresolved(in: db, keeping: limit) }
  }

  @discardableResult
  public static func pruneUnresolved(in db: Database, keeping limit: Int) throws -> Int {
    let removed =
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM podcastCloudUnresolvedEpisodeState") ?? 0
    try db.execute(
      sql: """
        DELETE FROM podcastCloudUnresolvedEpisodeState WHERE recordName NOT IN (
          SELECT recordName FROM podcastCloudUnresolvedEpisodeState
          ORDER BY receivedAt DESC, recordName DESC LIMIT ?)
        """,
      arguments: [max(0, limit)])
    let remaining =
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM podcastCloudUnresolvedEpisodeState") ?? 0
    return removed - remaining
  }
}
