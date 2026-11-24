import Foundation
import GRDB

/// The signed-in account's desired set of Audiobookshelf titles for the active Watch, and the
/// Audiobookshelf half of the shared set row (ADR 0021).
///
/// Bound to one account: every read and write names its `accountId`, and the rows cascade away with
/// the account. The set row's Audiobookshelf columns describe the Watch and outlive the account;
/// only `inventoryAccountHash` is cleared at the account boundary, so no offer leaves for the next
/// account until the Watch reports under it.
public struct ABSWatchCopyStore: Sendable {
  private let database: AppDatabase
  public let accountId: Int64

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
  }

  // MARK: - Requests

  /// The listener sent this title, so it enters the offer as `wanted`. A terminal row is
  /// re-requested at a new revision; an active one keeps its revision and its place.
  @discardableResult
  public func request(
    _ key: ABSWatchCopyKey, title: String, subtitle: String?, declaredBytes: Int64?, now: Date
  ) async throws -> ABSWatchCopy {
    let accountId = accountId
    return try await database.writeAsync { db in
      if var existing = try Self.fetch(db, accountId: accountId, key: key) {
        guard WatchCopyArithmetic.isTerminal(existing.state) else { return existing }
        existing.revision = WatchCopyArithmetic.incremented(existing.revision)
        existing.state = .wanted
        existing.removedBy = nil
        existing.removalGeneration = nil
        existing.declineReason = nil
        existing.failureReason = nil
        existing.sourceBytes = nil
        existing.failedAt = nil
        existing.title = title
        existing.subtitle = subtitle
        existing.declaredBytes = declaredBytes
        existing.requestedAt = now
        existing.updatedAt = now
        try existing.update(db)
        _ = try Self.bumpGeneration(in: db)
        return existing
      }
      let record = ABSWatchCopy(
        accountId: accountId, key: key, title: title, subtitle: subtitle, state: .wanted,
        declaredBytes: declaredBytes, requestedAt: now, updatedAt: now)
      try record.insert(db)
      _ = try Self.bumpGeneration(in: db)
      return record
    }
  }

  /// Phone-initiated removal, for a title the phone sent or one the Watch downloaded itself. Either
  /// way the next offers name it in `removals` until an inventory acknowledges the generation that
  /// first did. A removal still waiting for that acknowledgement is left as it is; one
  /// already acknowledged is sent again, because the title is listed only when the Watch has it
  /// once more, downloaded again on the wrist.
  @discardableResult
  public func removeFromWatch(
    _ key: ABSWatchCopyKey, title: String, subtitle: String?, now: Date
  ) async throws -> ABSWatchCopy? {
    let accountId = accountId
    return try await database.writeAsync { db in
      if var copy = try Self.fetch(db, accountId: accountId, key: key) {
        guard copy.state != .removed || copy.removalGeneration == nil else { return copy }
        copy.state = .removed
        copy.removedBy = .phone
        copy.declineReason = nil
        copy.failureReason = nil
        copy.failedAt = nil
        copy.updatedAt = now
        copy.removalGeneration = try Self.bumpGeneration(in: db)
        try copy.update(db)
        return copy
      }
      var removal = ABSWatchCopy(
        accountId: accountId, key: key, title: title, subtitle: subtitle, state: .removed,
        removedBy: .phone, requestedAt: now, updatedAt: now)
      removal.removalGeneration = try Self.bumpGeneration(in: db)
      try removal.insert(db)
      return removal
    }
  }

  // MARK: - Inventory

  /// Reconciles one inventory, already matched to this account, with the desired set. Rules, in
  /// order: a late sequence from the same install is ignored; a different install replaces the set;
  /// the acknowledgement, sequence and account are stored, and a generation the phone never issued
  /// is stepped past; phone-origin entries at a row's revision move it, and ones with no row are
  /// re-adopted; an acknowledged removal stops being sent; and a copy in
  /// flight or delivered that an acknowledging inventory omits goes back to `wanted`.
  public func applyInventory(
    _ inventory: ABSWatchInventory, now: Date
  ) async throws -> ABSWatchCopyInventoryOutcome {
    let accountId = accountId
    return try await database.writeAsync { db in
      var set = try SetColumns.fetch(db)
      let sequence = WatchCopyArithmetic.saturated(inventory.sequence)
      let replaced = set.installID != nil && set.installID != inventory.watchInstallID
      if replaced == false, set.installID == inventory.watchInstallID, sequence <= set.sequence {
        return ABSWatchCopyInventoryOutcome(applied: false, changedKeys: [], installReplaced: false)
      }
      var changes = Changes()
      if replaced {
        for copy in try Self.fetchAll(db, accountId: accountId) { changes.note(copy.key) }
        try db.execute(sql: "DELETE FROM absWatchCopy WHERE accountId = ?", arguments: [accountId])
        set.generation = WatchCopyArithmetic.incremented(set.generation)
      }
      set.installID = inventory.watchInstallID
      set.sequence = sequence
      set.accountHash = inventory.accountIdentityHash
      set.acknowledged = WatchCopyArithmetic.saturated(inventory.acknowledgedGeneration)
      // A Watch cannot acknowledge a generation this phone never issued, so a higher one means the
      // phone's database was reset while the Watch kept its downloads. The phone steps past it, or
      // the Watch would ignore every offer as stale.
      if set.acknowledged > set.generation { set.generation = WatchCopyArithmetic.incremented(set.acknowledged) }

      var rows = Dictionary(
        uniqueKeysWithValues: try Self.fetchAll(db, accountId: accountId).map { ($0.key, $0) })
      var context = ApplyContext(
        accountId: accountId, installID: inventory.watchInstallID, now: now)
      for entry in inventory.entries {
        if try context.apply(entry, to: &rows, in: db) { changes.note(entry.key) }
      }
      if context.membershipChanged { set.generation = WatchCopyArithmetic.incremented(set.generation) }
      for key in try context.settle(
        rows: &rows, inventory: inventory, acknowledged: set.acknowledged,
        generation: set.generation, in: db)
      {
        changes.note(key)
      }
      try set.save(db)
      return ABSWatchCopyInventoryOutcome(
        applied: true, changedKeys: changes.ordered, installReplaced: replaced)
    }
  }

  /// The account boundary: the next account sends nothing until the Watch reports
  /// under it. The generation, the Watch's identity and its sequence describe the Watch and stay.
  public func forgetInventoryAccount() async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssWatchCopySet SET absInventoryAccountHash = NULL WHERE id = 1")
    }
  }

  // MARK: - Reads

  /// Every row of this account, newest request first: the order the next offer lists them in.
  public func copies() async throws -> [ABSWatchCopy] {
    let accountId = accountId
    return try await database.readAsync { db in try Self.fetchAll(db, accountId: accountId) }
  }

  public func copy(_ key: ABSWatchCopyKey) async throws -> ABSWatchCopy? {
    let accountId = accountId
    return try await database.readAsync { db in try Self.fetch(db, accountId: accountId, key: key) }
  }

  /// What the next offer lists as entries: everything not removed or declined.
  public func desired() async throws -> [ABSWatchCopy] {
    try await copies().filter { $0.state != .removed && $0.state != .declined }
  }

  /// What the next offer lists as removals: the phone's removals no inventory has acknowledged.
  public func pendingRemovals() async throws -> [ABSWatchCopy] {
    try await copies().filter { $0.removalGeneration != nil }
  }

  public func setState() async throws -> ABSWatchCopySetState {
    try await database.readAsync { db in try SetColumns.fetch(db).state }
  }

  /// This account's rows and the set state, newest request first. Unchanged values are
  /// suppressed, so a write that leaves both equal does not wake the UI.
  public func observe() -> AsyncStream<ABSWatchCopyObservation> {
    let accountId = accountId
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          ABSWatchCopyObservation(
            copies: try Self.fetchAll(db, accountId: accountId), set: try SetColumns.fetch(db).state)
        }
        .removeDuplicates())
  }

  // MARK: - Internals

  static func fetchAll(_ db: Database, accountId: Int64) throws -> [ABSWatchCopy] {
    try ABSWatchCopy.fetchAll(
      db,
      sql: """
        SELECT * FROM absWatchCopy WHERE accountId = ?
        ORDER BY requestedAt DESC, itemId DESC, episodeId DESC
        """,
      arguments: [accountId])
  }

  static func fetch(_ db: Database, accountId: Int64, key: ABSWatchCopyKey) throws -> ABSWatchCopy? {
    try ABSWatchCopy.fetchOne(
      db,
      sql: "SELECT * FROM absWatchCopy WHERE accountId = ? AND itemId = ? AND episodeId = ?",
      arguments: [accountId, key.itemId, key.storedEpisodeId])
  }

  /// Moves the generation on and returns the new value.
  static func bumpGeneration(in db: Database) throws -> Int64 {
    try db.execute(sql: "UPDATE rssWatchCopySet SET absGeneration = absGeneration + 1 WHERE id = 1")
    return try SetColumns.fetch(db).generation
  }

  /// The keys an inventory changed, in the order it first touched them.
  private struct Changes {
    private(set) var ordered: [ABSWatchCopyKey] = []
    private var seen: Set<ABSWatchCopyKey> = []

    mutating func note(_ key: ABSWatchCopyKey) {
      if seen.insert(key).inserted { ordered.append(key) }
    }
  }
}
