import Foundation
import GRDB

/// The transport row as one value, for the coordinator's launch decision: resume a completed
/// bootstrap in the same namespace, or run the barrier again.
public struct PodcastCloudTransportState: Sendable, Equatable {
  public let namespace: Data?
  public let bootstrapComplete: Bool
  public let zoneEstablished: Bool
  public let engineState: Data?
  public let status: String?
  public let statusRetryAfter: Date?

  public init(
    namespace: Data?, bootstrapComplete: Bool, zoneEstablished: Bool, engineState: Data?,
    status: String?, statusRetryAfter: Date?
  ) {
    self.namespace = namespace
    self.bootstrapComplete = bootstrapComplete
    self.zoneEstablished = zoneEstablished
    self.engineState = engineState
    self.status = status
    self.statusRetryAfter = statusRetryAfter
  }
}

/// A record held as `Sync needs attention`. The category is an opaque token `SyncEngine` owns;
/// nothing here carries a payload, a title or a URL.
public struct PodcastCloudHeldRecord: Sendable, Equatable {
  public let recordName: String
  public let generation: Int64?
  public let category: String
  public let observedAt: Date

  public init(recordName: String, generation: Int64?, category: String, observedAt: Date) {
    self.recordName = recordName
    self.generation = generation
    self.category = category
    self.observedAt = observedAt
  }
}

/// Every write that must commit together with a remote apply or a merge has a `Database`-taking
/// form, so the coordinator can put the accepted stamp, the system fields, the outbox change and
/// the local projection in one transaction. Remote apply, system fields and fetch progress commit
/// before an engine serialisation checkpoint is accepted.
extension PodcastCloudTransportStore {
  /// The bound on held records per namespace. Held records are diagnostics, not user data, and
  /// the newest are the useful ones.
  public static let heldRecordLimit = 500

  public func state() async throws -> PodcastCloudTransportState {
    try await database.readAsync { db in try Self.state(in: db) }
  }

  public static func state(in db: Database) throws -> PodcastCloudTransportState {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM podcastCloudTransport WHERE id = 1")
    else {
      return PodcastCloudTransportState(
        namespace: nil, bootstrapComplete: false, zoneEstablished: false, engineState: nil,
        status: nil, statusRetryAfter: nil)
    }
    return PodcastCloudTransportState(
      namespace: row["namespace"], bootstrapComplete: row["bootstrapComplete"],
      zoneEstablished: row["zoneEstablished"], engineState: row["engineState"],
      status: row["status"], statusRetryAfter: row["statusRetryAfter"])
  }

  /// Persists an engine checkpoint without touching the barrier. A stale namespace writes nothing:
  /// the serialization belongs to an engine that has already been fenced off.
  public func saveEngineState(namespace: Data, engineState: Data) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudTransport SET engineState = ? WHERE id = 1 AND namespace = ?",
        arguments: [engineState, namespace])
    }
  }

  public func markZoneEstablished(namespace: Data) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudTransport SET zoneEstablished = 1 WHERE id = 1 AND namespace = ?",
        arguments: [namespace])
    }
  }

  /// After a zone is lost or deleted: the barrier closes, the engine cache goes, and the namespace
  /// no longer counts as having a zone. System-field archives for the namespace go too, as they
  /// describe records that no longer exist and a conditional save against them would fail.
  /// The outbox is untouched: it is the user's unsent intent, and whether it is sent into a
  /// recreated zone is the user's choice, not this method's.
  public func forgetZone(namespace: Data) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE podcastCloudTransport SET zoneEstablished = 0, bootstrapComplete = 0,
            engineState = NULL
          WHERE id = 1 AND namespace = ?
          """, arguments: [namespace])
      try db.execute(
        sql: "DELETE FROM podcastCloudSystemFields WHERE namespace = ?", arguments: [namespace])
    }
  }

  /// Strands every outbox row of a namespace the account has left, as a re-mint does
  /// (`PodcastCloudInstallationStore.quarantineTransport`): a `NULL` namespace can never match.
  /// Old-account payloads are never sent implicitly.
  public func quarantine(namespace: Data) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudOutbox SET namespace = NULL WHERE namespace = ?",
        arguments: [namespace])
      try db.execute(
        sql: """
          UPDATE podcastCloudTransport SET bootstrapComplete = 0, engineState = NULL
          WHERE id = 1 AND namespace = ?
          """, arguments: [namespace])
    }
  }

  public func setStatus(_ status: String?, retryAfter: Date?, namespace: Data) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE podcastCloudTransport SET status = ?, statusRetryAfter = ?
          WHERE id = 1 AND namespace = ?
          """, arguments: [status, retryAfter, namespace])
    }
  }

  // MARK: - Outbox rows and system fields inside a caller's transaction

  /// The one outstanding row for a record in the current namespace, with its archive.
  public static func pendingSend(
    in db: Database, namespace: Data, recordName: String
  ) throws -> PodcastCloudPendingSend? {
    guard try currentNamespace(in: db) == namespace else { return nil }
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT work.*, fields.archive FROM podcastCloudOutbox AS work
          LEFT JOIN podcastCloudSystemFields AS fields
            ON fields.namespace = work.namespace AND fields.recordName = work.recordName
          WHERE work.namespace = ? AND work.recordName = ?
          """, arguments: [namespace, recordName])
    else { return nil }
    return PodcastCloudPendingSend(
      recordName: row["recordName"], generation: row["generation"], namespace: namespace,
      operation: row["operation"], payload: row["payload"], systemFields: row["archive"])
  }

  /// The archive for a record, whether or not anything is pending for it.
  public static func systemFields(
    in db: Database, namespace: Data, recordName: String
  ) throws -> Data? {
    try Data.fetchOne(
      db,
      sql: "SELECT archive FROM podcastCloudSystemFields WHERE namespace = ? AND recordName = ?",
      arguments: [namespace, recordName])
  }

  /// Stores the server's current archive for a record: a fetched record, a conflict's server
  /// record, or an acknowledgement that arrived with no in-flight send to match.
  ///
  /// Always overwrites the archive (each is the newest server state seen) but never lowers the
  /// stored generation, keeping `acknowledge`'s rule that a reordered older ACK cannot replace a
  /// later base.
  public static func recordSystemFields(
    in db: Database, namespace: Data, recordName: String, archive: Data
  ) throws {
    guard try currentNamespace(in: db) == namespace else { return }
    try db.execute(
      sql: """
        INSERT INTO podcastCloudSystemFields (namespace, recordName, generation, archive)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(namespace, recordName) DO UPDATE SET archive = excluded.archive
        """, arguments: [namespace, recordName, archive])
  }

  /// A remote physical deletion. Only the archive goes: deletion is never read as a user
  /// mutation, because every user deletion in this schema is a register.
  public static func forgetSystemFields(in db: Database, namespace: Data, recordName: String) throws {
    try db.execute(
      sql: "DELETE FROM podcastCloudSystemFields WHERE namespace = ? AND recordName = ?",
      arguments: [namespace, recordName])
  }

  /// Drops an outbox row only if it is still the generation the caller merged. A newer local
  /// mutation written in the meantime survives, as in `acknowledge`.
  public static func supersede(
    in db: Database, namespace: Data, recordName: String, generation: Int64
  ) throws {
    try db.execute(
      sql: """
        DELETE FROM podcastCloudOutbox WHERE namespace = ? AND recordName = ? AND generation = ?
        """, arguments: [namespace, recordName, generation])
  }

  /// A confirmed physical deletion: the row goes if its generation still matches, and so does the
  /// archive, which now describes a record that does not exist.
  public func acknowledgeDeletion(_ send: PodcastCloudPendingSend) async throws {
    try await database.writeAsync { db in
      guard try Self.currentNamespace(in: db) == send.namespace else { return }
      try Self.supersede(
        in: db, namespace: send.namespace, recordName: send.recordName, generation: send.generation)
      try Self.forgetSystemFields(in: db, namespace: send.namespace, recordName: send.recordName)
      try Self.release(in: db, namespace: send.namespace, recordName: send.recordName)
    }
  }

  // MARK: - Held records

  public static func hold(
    in db: Database, namespace: Data, recordName: String, generation: Int64?, category: String,
    observedAt: Date
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO podcastCloudHeldRecord (namespace, recordName, generation, category, observedAt)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(namespace, recordName) DO UPDATE SET
          generation = excluded.generation, category = excluded.category,
          observedAt = excluded.observedAt
        """, arguments: [namespace, recordName, generation, category, observedAt])
    try db.execute(
      sql: """
        DELETE FROM podcastCloudHeldRecord WHERE namespace = ? AND recordName NOT IN (
          SELECT recordName FROM podcastCloudHeldRecord WHERE namespace = ?
          ORDER BY observedAt DESC, recordName DESC LIMIT ?)
        """, arguments: [namespace, namespace, heldRecordLimit])
  }

  public func hold(
    namespace: Data, recordName: String, generation: Int64?, category: String, observedAt: Date
  ) async throws {
    try await database.writeAsync { db in
      try Self.hold(
        in: db, namespace: namespace, recordName: recordName, generation: generation,
        category: category, observedAt: observedAt)
    }
  }

  public static func release(in db: Database, namespace: Data, recordName: String) throws {
    try db.execute(
      sql: "DELETE FROM podcastCloudHeldRecord WHERE namespace = ? AND recordName = ?",
      arguments: [namespace, recordName])
  }

  /// Releases the hold on a record that arrived and was admitted. An outbox hold stays: it is
  /// about a send, and only a send that succeeds, or the next retry, answers it.
  public static func releaseFetchedHold(in db: Database, namespace: Data, recordName: String) throws {
    try db.execute(
      sql: """
        DELETE FROM podcastCloudHeldRecord
        WHERE namespace = ? AND recordName = ? AND generation IS NULL
        """, arguments: [namespace, recordName])
  }

  /// Releases every outbox hold of a namespace, so each held send is offered once more, and
  /// returns how many there were. A send the service still refuses is simply held again.
  public func releaseOutboxHolds(namespace: Data) async throws -> Int {
    try await database.writeAsync { db in
      try db.execute(
        sql: "DELETE FROM podcastCloudHeldRecord WHERE namespace = ? AND generation IS NOT NULL",
        arguments: [namespace])
      return db.changesCount
    }
  }

  /// Drops the holds of every other namespace. They describe records no session can send or
  /// fetch, and nothing else removes them.
  public func pruneHeldRecords(keeping namespace: Data) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "DELETE FROM podcastCloudHeldRecord WHERE namespace <> ?", arguments: [namespace])
    }
  }

  public func hasHeldRecords(namespace: Data) async throws -> Bool {
    try await database.readAsync { db in
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM podcastCloudHeldRecord WHERE namespace = ?)",
        arguments: [namespace]) ?? false
    }
  }

  public func heldRecords(namespace: Data) async throws -> [PodcastCloudHeldRecord] {
    try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM podcastCloudHeldRecord WHERE namespace = ?
          ORDER BY observedAt DESC, recordName
          """, arguments: [namespace]
      ).map {
        PodcastCloudHeldRecord(
          recordName: $0["recordName"], generation: $0["generation"], category: $0["category"],
          observedAt: $0["observedAt"])
      }
    }
  }
}
