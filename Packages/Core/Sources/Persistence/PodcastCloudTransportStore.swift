import Foundation
import GRDB

public enum PodcastCloudTransportError: Error, Equatable, Sendable {
  case invalidPayload
  case invalidNamespace
  case generationExhausted
  case staleNamespace
}

/// A captured send is immutable. Its namespace is an opaque encoding of the complete App-owned
/// container/environment/zone/user/epoch fence, never an ABS account ID.
public struct PodcastCloudPendingSend: Sendable, Equatable {
  public let recordName: String
  public let generation: Int64
  public let namespace: Data
  public let operation: String
  public let payload: Data
  public let systemFields: Data?

  public init(
    recordName: String, generation: Int64, namespace: Data, operation: String, payload: Data,
    systemFields: Data?
  ) {
    self.recordName = recordName
    self.generation = generation
    self.namespace = namespace
    self.operation = operation
    self.payload = payload
    self.systemFields = systemFields
  }

  public var isPhysicalDeletion: Bool { operation == "delete" }
}

/// The durable outbox is authoritative; CKSyncEngine serialization is a discardable cache.
/// Transaction helpers let a source mutation and its pending work commit or roll back together.
/// Record names the outbox still owes the server, without their payloads.
///
/// Rehydration needs names only (a `CKSyncEngine` pending change is a record ID), so this read has
/// no byte ceiling or batching; `pendingSends` clamps because it hands over payloads.
public struct PodcastCloudOutstandingWork: Sendable, Equatable {
  public let saves: [String]
  public let deletions: [String]

  public init(saves: [String], deletions: [String]) {
    self.saves = saves
    self.deletions = deletions
  }

  public var isEmpty: Bool { saves.isEmpty && deletions.isEmpty }
}

public struct PodcastCloudTransportStore: Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  /// Call after the user's account/merge decision. This closes the bootstrap barrier even when
  /// resuming the same namespace. Existing work from a different namespace stays quarantined.
  ///
  /// Zone establishment survives re-activating the same namespace and is cleared for a different
  /// one: it is a fact about one account's container, and carrying it across would make another
  /// account's first `zoneNotFound` look like a deleted zone. Every right-hand side reads the
  /// row's pre-update values, so the comparison sees the old namespace.
  public func activate(namespace: Data) async throws {
    guard !namespace.isEmpty, namespace.count <= 4096 else {
      throw PodcastCloudTransportError.invalidNamespace
    }
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE podcastCloudTransport SET
            zoneEstablished = CASE WHEN namespace = ? THEN zoneEstablished ELSE 0 END,
            namespace = ?, bootstrapComplete = 0, engineState = NULL
          WHERE id = 1
          """, arguments: [namespace, namespace])
    }
  }

  public func completeBootstrap(namespace: Data, engineState: Data) async throws {
    try await database.writeAsync { db in
      guard try Self.currentNamespace(in: db) == namespace else {
        throw PodcastCloudTransportError.staleNamespace
      }
      try db.execute(
        sql: """
          UPDATE podcastCloudTransport SET bootstrapComplete = 1, engineState = ? WHERE id = 1
          """, arguments: [engineState])
    }
  }

  public func discardEngineState(namespace: Data) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE podcastCloudTransport SET bootstrapComplete = 0, engineState = NULL
          WHERE id = 1 AND namespace = ?
          """, arguments: [namespace])
    }
  }

  public func engineState(namespace: Data) async throws -> Data? {
    try await database.readAsync { db in
      try Data.fetchOne(
        db,
        sql: """
          SELECT engineState FROM podcastCloudTransport WHERE id = 1 AND namespace = ?
          """, arguments: [namespace])
    }
  }

  @discardableResult
  public func enqueue(recordName: String, payload: Data, isPhysicalDeletion: Bool = false) async throws -> Int64 {
    try await database.writeAsync { db in
      try Self.enqueue(in: db, recordName: recordName, payload: payload, isPhysicalDeletion: isPhysicalDeletion)
    }
  }

  /// Logical unfollow and Saved removal are saves carrying durable registers. Physical deletion
  /// is reserved for inactive-generation maintenance and is never inferred from an empty payload.
  @discardableResult
  public static func enqueue(
    in db: Database, recordName: String, payload: Data, isPhysicalDeletion: Bool = false
  ) throws -> Int64 {
    guard !recordName.isEmpty, recordName.utf8.count <= 255, !recordName.hasPrefix("_"),
      recordName.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }), payload.count <= 65_536
    else { throw PodcastCloudTransportError.invalidPayload }
    let previous = try Int64.fetchOne(db, sql: "SELECT nextGeneration FROM podcastCloudTransport WHERE id = 1") ?? 0
    guard previous < Int64.max else { throw PodcastCloudTransportError.generationExhausted }
    let generation = previous + 1
    let namespace = try currentNamespace(in: db)
    try db.execute(sql: "UPDATE podcastCloudTransport SET nextGeneration = ? WHERE id = 1", arguments: [generation])
    try db.execute(
      sql: """
        INSERT INTO podcastCloudOutbox (recordName, generation, namespace, operation, payload)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(recordName) DO UPDATE SET generation = excluded.generation,
          namespace = excluded.namespace, operation = excluded.operation, payload = excluded.payload
        """, arguments: [recordName, generation, namespace, isPhysicalDeletion ? "delete" : "save", payload])
    return generation
  }

  /// Everything outstanding in the active namespace, for re-adding to a freshly constructed
  /// engine's pending set.
  ///
  /// Gated like `pendingSends`: a stale namespace and a closed bootstrap barrier both answer
  /// "nothing", since an engine built while the barrier is closed must not be told work is waiting.
  public func outstandingWork(namespace: Data) async throws -> PodcastCloudOutstandingWork {
    try await database.readAsync { db in
      guard !namespace.isEmpty,
        try Self.currentNamespace(in: db) == namespace,
        try Bool.fetchOne(db, sql: "SELECT bootstrapComplete FROM podcastCloudTransport WHERE id = 1") == true
      else { return PodcastCloudOutstandingWork(saves: [], deletions: []) }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT work.recordName, work.operation FROM podcastCloudOutbox AS work
          WHERE work.namespace = ? AND \(Self.notHeld)
          ORDER BY work.recordName
          """, arguments: [namespace])
      var saves: [String] = []
      var deletions: [String] = []
      for row in rows {
        let recordName: String = row["recordName"]
        if row["operation"] == "delete" {
          deletions.append(recordName)
        } else {
          saves.append(recordName)
        }
      }
      return PodcastCloudOutstandingWork(saves: saves, deletions: deletions)
    }
  }

  public func pendingSends(
    namespace: Data, maximumRecords: Int = 200, maximumBytes: Int = 1_048_576
  ) async throws -> [PodcastCloudPendingSend] {
    try await database.readAsync { db in
      guard !namespace.isEmpty,
        try Self.currentNamespace(in: db) == namespace,
        try Bool.fetchOne(db, sql: "SELECT bootstrapComplete FROM podcastCloudTransport WHERE id = 1") == true
      else { return [] }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT work.*, fields.archive FROM podcastCloudOutbox AS work
          LEFT JOIN podcastCloudSystemFields AS fields
            ON fields.namespace = work.namespace AND fields.recordName = work.recordName
          WHERE work.namespace = ? AND \(Self.notHeld)
          ORDER BY CASE
            WHEN work.recordName = 'v1.globals' THEN 0
            WHEN work.recordName LIKE 'v1.sub.%' THEN 1
            WHEN work.recordName LIKE 'v1.settings.%' THEN 2
            WHEN work.recordName LIKE 'v1.identity.%' THEN 3
            ELSE 4 END, work.recordName
          LIMIT ?
          """, arguments: [namespace, max(0, min(maximumRecords, 200))])
      var result: [PodcastCloudPendingSend] = []
      var bytes = 0
      for row in rows {
        let payload: Data = row["payload"]
        guard payload.count <= max(0, min(maximumBytes, 1_048_576)) - bytes else { break }
        bytes += payload.count
        result.append(
          PodcastCloudPendingSend(
            recordName: row["recordName"], generation: row["generation"], namespace: namespace,
            operation: row["operation"], payload: payload, systemFields: row["archive"]))
      }
      return result
    }
  }

  public func acknowledge(_ send: PodcastCloudPendingSend, systemFields: Data) async throws {
    try await database.writeAsync { db in
      guard try Self.currentNamespace(in: db) == send.namespace else { return }
      // Retain the archive after deleting an acknowledged outbox row, and rebase a newer local
      // mutation. An older, reordered ACK must not replace the base of a later acknowledged send.
      try db.execute(
        sql: """
          INSERT INTO podcastCloudSystemFields (namespace, recordName, generation, archive)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(namespace, recordName) DO UPDATE SET
            generation = excluded.generation, archive = excluded.archive
          WHERE excluded.generation >= podcastCloudSystemFields.generation
          """, arguments: [send.namespace, send.recordName, send.generation, systemFields])
      try db.execute(
        sql: """
          DELETE FROM podcastCloudOutbox WHERE recordName = ? AND generation = ? AND namespace = ?
          """, arguments: [send.recordName, send.generation, send.namespace])
      // The service took the record, so whatever an earlier generation was held for is over.
      try Self.release(in: db, namespace: send.namespace, recordName: send.recordName)
    }
  }

  /// An outbox row held at its current generation is not offered for sending or rehydration. A
  /// newer local mutation of the same record has a newer generation and is offered again.
  static let notHeld = """
    NOT EXISTS (
      SELECT 1 FROM podcastCloudHeldRecord AS held
      WHERE held.namespace = work.namespace AND held.recordName = work.recordName
        AND held.generation = work.generation)
    """

  static func currentNamespace(in db: Database) throws -> Data? {
    try Data.fetchOne(db, sql: "SELECT namespace FROM podcastCloudTransport WHERE id = 1")
  }
}
