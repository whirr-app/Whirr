import Foundation
import GRDB

/// Sole owner of `podcastCloudInstallation`; `PodcastCloudRegistryStore` owns the migration's
/// other three tables. The clock lives apart because resolving the identity needs the durable
/// anchor and nothing else in the registry does.
///
/// The anchor lives outside the SQLite file so a database restored from another device's backup
/// does not adopt that device's identity. Two installations sharing a UUID break the stamp
/// tie-break in `(physicalMilliseconds, logicalCounter, installationUUID, mutationUUID)` and can
/// silently resolve a genuine conflict the wrong way.
public struct PodcastCloudInstallationStore: Sendable {
  private let database: AppDatabase
  private let anchor: any PodcastCloudInstallationAnchor
  private let newIdentity: @Sendable () -> UUID

  public init(
    database: AppDatabase, anchor: any PodcastCloudInstallationAnchor,
    newIdentity: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.database = database
    self.anchor = anchor
    self.newIdentity = newIdentity
  }

  /// Resolves row and anchor together:
  ///
  /// | DB row  | Anchor     | Action                                             |
  /// |---------|------------|----------------------------------------------------|
  /// | absent  | absent     | mint (first run)                                   |
  /// | absent  | present    | mint, overwriting the anchor (reinstall)           |
  /// | present | matches    | adopt (ordinary launch)                            |
  /// | present | absent     | re-mint (the restore signature)                    |
  /// | present | mismatch   | re-mint (a different installation wrote the anchor) |
  /// | any     | unreadable | refuse: throw, mint nothing, adopt nothing          |
  ///
  /// With `mint: true` the result is never `nil`. With `mint: false` nothing is written and only
  /// the adopt case returns a value (a row whose anchor disagrees is an identity this installation
  /// has not accepted).
  ///
  /// A refusal persists nothing, so a transient Keychain outage resolves on the next call. Must
  /// run before any `CKSyncEngine` is constructed: a re-mint closes the bootstrap barrier, and an
  /// engine built earlier would hold pending changes stamped under the old identity.
  @discardableResult
  public func clock(mint: Bool = true) async throws -> PodcastCloudClockFields? {
    guard mint else {
      let anchored = try readAnchor()
      return try await database.readAsync { db in
        guard let stored = try Self.stored(in: db),
          stored.installationIdentity == anchored
        else { return nil }
        return stored
      }
    }
    // The anchor write happens inside the transaction so a Keychain failure rolls the row back.
    // The surviving window is a successful anchor write followed by a failed commit, which the
    // next call resolves as "mint, overwrite the anchor" or "re-mint". Both are safe and neither
    // adopts a foreign identity. The reverse order would leave row-present/anchor-absent, which
    // reads as the restore signature and would re-mint on every subsequent launch.
    return try await database.writeAsync { db in
      let stored = try Self.stored(in: db)
      // Read inside the transaction, before anything is written: a throw here aborts the whole
      // resolution rather than leaving the row and the anchor disagreeing.
      let anchored = try self.readAnchor()
      let resolved: PodcastCloudClockFields
      let isReMint: Bool
      switch (stored, anchored) {
      case (nil, _):
        resolved = PodcastCloudClockFields(
          installationUUID: self.newIdentity().uuidString.lowercased())
        isReMint = false
      case (let stored?, let anchored?) where stored.installationIdentity == anchored:
        return stored
      case (let stored?, _):
        resolved = stored.carryingForward(self.newIdentity())
        isReMint = true
      }
      try Self.upsert(resolved, in: db)
      guard let identity = resolved.installationIdentity else {
        throw PodcastCloudInstallationError.invalidRecord
      }
      try self.anchor.write(identity)
      if isReMint { try Self.quarantineTransport(in: db) }
      return resolved
    }
  }

  /// Persists an advanced clock. Every `generate`, `observe` and `repair` result must be written
  /// back here in the same transaction as the outbox enqueue it stamps: saved later, a backup
  /// could capture the row behind the outbox and the restored device would re-emit a stamp the
  /// source already published.
  ///
  /// A mismatched identity throws: a silent no-op would drop a clock advance while the caller
  /// believed its stamp durable.
  public static func advance(in db: Database, clock: PodcastCloudClockFields) throws {
    guard let stored = try stored(in: db) else { throw PodcastCloudInstallationError.absent }
    guard stored.installationUUID == clock.installationUUID else {
      throw PodcastCloudInstallationError.identityChanged
    }
    // A repair is the one sanctioned backwards move: it sets `physical = max(wall,
    // lastAdmittedPhysical)`, and no stamp can have been produced while the clock was quarantined
    // because `generate` throws throughout that interval.
    if stored.repairRequired == false {
      let moved =
        (clock.physicalMilliseconds, clock.logicalCounter)
        < (stored.physicalMilliseconds, stored.logicalCounter)
      guard moved == false else { throw PodcastCloudInstallationError.nonMonotonicAdvance }
    }
    try upsert(clock, in: db)
  }

  /// The stored clock, read inside the caller's transaction, without minting or anchor checking.
  ///
  /// The anchor comparison belongs to `clock(mint:)`, which runs once before any engine exists; a
  /// mutation being stamped is past that gate, on a database whose identity was resolved at
  /// activation. Re-reading the Keychain per progress tick would put a syscall in a transaction
  /// for nothing. `advance` still refuses a clock whose identity does not match the row.
  ///
  /// `nil` means no identity has been minted: sync has never been enabled on this installation.
  public static func clock(in db: Database) throws -> PodcastCloudClockFields? {
    try stored(in: db)
  }

  public func advance(_ clock: PodcastCloudClockFields) async throws {
    try await database.writeAsync { db in try Self.advance(in: db, clock: clock) }
  }

  /// A re-mint is evidence that the transport state in this file belongs to another device. Close
  /// the bootstrap barrier so the next enable fetches before uploading, and strand the outbox.
  ///
  /// Clearing the transport namespace alone would not strand it: a same-account restore can
  /// re-enable into an identical fence and republish another installation's mutations. A `NULL`
  /// namespace never equals the non-empty one `pendingSends` requires, so the rows stay for
  /// diagnostics and are never selected.
  ///
  /// `podcastCloudSystemFields` is retained: those archives describe the account's server state
  /// and remain the right base for `serverRecordChanged`. `nextGeneration` is retained because it
  /// is monotonic and reuse would confuse an in-flight acknowledgement.
  private static func quarantineTransport(in db: Database) throws {
    try db.execute(sql: "UPDATE podcastCloudOutbox SET namespace = NULL")
    try db.execute(
      sql: "UPDATE podcastCloudTransport SET bootstrapComplete = 0, engineState = NULL WHERE id = 1")
  }

  private func readAnchor() throws -> UUID? {
    do { return try anchor.read() } catch { throw PodcastCloudInstallationError.anchorUnreadable }
  }

  static func stored(in db: Database) throws -> PodcastCloudClockFields? {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM podcastCloudInstallation WHERE id = 1")
    else { return nil }
    let text: String = row["installationUUID"]
    guard UUID(uuidString: text) != nil else {
      throw PodcastCloudInstallationError.invalidRecord
    }
    return PodcastCloudClockFields(
      installationUUID: text, physicalMilliseconds: row["physicalMilliseconds"],
      logicalCounter: row["logicalCounter"],
      anchorServerMilliseconds: row["anchorServerMilliseconds"],
      lastAdmittedPhysicalMilliseconds: row["lastAdmittedPhysicalMilliseconds"],
      lastAdmittedLogicalCounter: row["lastAdmittedLogicalCounter"],
      repairRequired: row["repairRequired"])
  }

  private static func upsert(_ clock: PodcastCloudClockFields, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO podcastCloudInstallation
          (id, installationUUID, physicalMilliseconds, logicalCounter, anchorServerMilliseconds,
           lastAdmittedPhysicalMilliseconds, lastAdmittedLogicalCounter, repairRequired)
        VALUES (1, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          installationUUID = excluded.installationUUID,
          physicalMilliseconds = excluded.physicalMilliseconds,
          logicalCounter = excluded.logicalCounter,
          anchorServerMilliseconds = excluded.anchorServerMilliseconds,
          lastAdmittedPhysicalMilliseconds = excluded.lastAdmittedPhysicalMilliseconds,
          lastAdmittedLogicalCounter = excluded.lastAdmittedLogicalCounter,
          repairRequired = excluded.repairRequired
        """,
      arguments: [
        clock.installationUUID, clock.physicalMilliseconds, clock.logicalCounter,
        clock.anchorServerMilliseconds, clock.lastAdmittedPhysicalMilliseconds,
        clock.lastAdmittedLogicalCounter, clock.repairRequired,
      ])
  }
}
