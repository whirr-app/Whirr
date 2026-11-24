import Foundation
import GRDB

extension ABSWatchCopyStore {
  /// The Audiobookshelf columns of the shared `rssWatchCopySet` row, plus the storage figure the RSS
  /// half stores for both. Read and written by column, so neither store's record overwrites the
  /// other's half.
  struct SetColumns {
    var installID: String?
    var generation: Int64 = 0
    var acknowledged: Int64 = 0
    var sequence: Int64 = 0
    var accountHash: String?
    var budgetTotalBytes: Int64?
    var budgetUsedBytes: Int64?
    var lastInventoryAt: Date?

    static func fetch(_ db: Database) throws -> SetColumns {
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT absWatchInstallID, absGeneration, absAcknowledgedGeneration,
              absInventorySequence, absInventoryAccountHash, budgetTotalBytes, budgetUsedBytes,
              lastInventoryAt
            FROM rssWatchCopySet WHERE id = 1
            """)
      else { return SetColumns() }
      return SetColumns(
        installID: row["absWatchInstallID"], generation: row["absGeneration"],
        acknowledged: row["absAcknowledgedGeneration"], sequence: row["absInventorySequence"],
        accountHash: row["absInventoryAccountHash"], budgetTotalBytes: row["budgetTotalBytes"],
        budgetUsedBytes: row["budgetUsedBytes"], lastInventoryAt: row["lastInventoryAt"])
    }

    func save(_ db: Database) throws {
      try db.execute(sql: "INSERT OR IGNORE INTO rssWatchCopySet (id) VALUES (1)")
      try db.execute(
        sql: """
          UPDATE rssWatchCopySet
          SET absWatchInstallID = ?, absGeneration = ?, absAcknowledgedGeneration = ?,
            absInventorySequence = ?, absInventoryAccountHash = ?
          WHERE id = 1
          """,
        arguments: [installID, generation, acknowledged, sequence, accountHash])
    }

    var state: ABSWatchCopySetState {
      ABSWatchCopySetState(
        watchInstallID: installID, generation: generation, acknowledgedGeneration: acknowledged,
        inventorySequence: sequence, inventoryAccountHash: accountHash,
        budgetTotalBytes: budgetTotalBytes, budgetUsedBytes: budgetUsedBytes,
        lastInventoryAt: lastInventoryAt)
    }
  }

  /// One inventory's moves against the account's rows.
  struct ApplyContext {
    let accountId: Int64
    let installID: String
    let now: Date
    /// A row joined or left the offer, so the generation moves on.
    private(set) var membershipChanged = false

    init(accountId: Int64, installID: String, now: Date) {
      self.accountId = accountId
      self.installID = installID
      self.now = now
    }

    /// `true` when the entry changed a row. A Watch-origin entry never does: the phone shows it
    /// from the live projection and never adopts it.
    mutating func apply(
      _ entry: ABSWatchInventory.Entry, to rows: inout [ABSWatchCopyKey: ABSWatchCopy],
      in db: Database
    ) throws -> Bool {
      guard let revision = entry.revision, revision > 0 else { return false }
      guard var copy = rows[entry.key] else {
        guard let adopted = adoption(of: entry, revision: revision) else { return false }
        try adopted.insert(db)
        rows[entry.key] = adopted
        membershipChanged = true
        return true
      }
      // Another revision describes a request this phone no longer makes, and the phone's own
      // removal stands until the Watch drops the group.
      guard copy.revision == revision, copy.removedBy != .phone, move(&copy, for: entry) else {
        return false
      }
      copy.updatedAt = now
      copy.watchInstallID = installID
      try copy.update(db)
      rows[entry.key] = copy
      return true
    }

    /// Acknowledged removals stop being sent, and an acknowledging inventory that omits a copy in
    /// flight or delivered sends it again. Returns the keys it changed.
    ///
    /// A removal is acknowledged by generation alone. The Watch spares a group downloaded on the
    /// wrist after the offer was sent, and repeating the removal with a later `sentAt` would
    /// delete that new download.
    func settle(
      rows: inout [ABSWatchCopyKey: ABSWatchCopy], inventory: ABSWatchInventory,
      acknowledged: Int64, generation: Int64, in db: Database
    ) throws -> [ABSWatchCopyKey] {
      var changed: [ABSWatchCopyKey] = []
      let ordered = rows.values.sorted { ($0.itemId, $0.episodeId) < ($1.itemId, $1.episodeId) }
      for var copy in ordered {
        guard let removal = copy.removalGeneration, acknowledged >= removal else { continue }
        copy.removalGeneration = nil
        copy.updatedAt = now
        try copy.update(db)
        rows[copy.key] = copy
        changed.append(copy.key)
      }
      guard acknowledged >= generation else { return changed }
      let present = Set(inventory.entries.map(\.key))
      for key in ordered.map(\.key) where present.contains(key) == false {
        guard var copy = rows[key], [.sending, .delivered].contains(copy.state) else { continue }
        copy.state = .wanted
        copy.sourceBytes = nil
        copy.updatedAt = now
        copy.watchInstallID = installID
        try copy.update(db)
        rows[copy.key] = copy
        changed.append(copy.key)
      }
      return changed
    }

    private mutating func move(_ copy: inout ABSWatchCopy, for entry: ABSWatchInventory.Entry) -> Bool {
      let active: [RSSWatchCopyState] = [.wanted, .waitingForWatch, .sending, .failed]
      switch entry.state {
      case .ready:
        guard [.delivered, .removed, .declined].contains(copy.state) == false else { return false }
        copy.state = .delivered
        copy.sourceBytes = entry.committedBytes ?? copy.sourceBytes
      case .receiving:
        // The Watch retries a network failure at the same revision, so a failed row can resume.
        guard active.contains(copy.state), copy.state != .sending else { return false }
        copy.state = .sending
      case .removed:
        guard copy.state != .removed else { return false }
        copy.state = .removed
        copy.removedBy = .watch
        copy.removalGeneration = nil
        copy.declineReason = nil
        membershipChanged = true
      case .declined:
        let reason = entry.declineReason ?? .invalid
        guard copy.state != .declined || copy.declineReason != reason else { return false }
        copy.state = .declined
        copy.declineReason = reason
        copy.removedBy = nil
        membershipChanged = true
      case .failed:
        let reason = entry.failureReason ?? .invalidResponse
        guard active.contains(copy.state), copy.state != .failed || copy.failureReason != reason else {
          return false
        }
        copy.state = .failed
        copy.failureReason = reason
        copy.failedAt = now
        return true
      }
      copy.failureReason = nil
      copy.failedAt = nil
      return true
    }

    /// A phone-origin entry the phone has no row for: the listener signed out and back in, or the
    /// phone's database was reset. A removal tombstone has nothing to adopt.
    private func adoption(of entry: ABSWatchInventory.Entry, revision: Int64) -> ABSWatchCopy? {
      let state: RSSWatchCopyState
      switch entry.state {
      case .ready: state = .delivered
      case .receiving: state = .sending
      case .failed: state = .failed
      case .declined: state = .declined
      case .removed: return nil
      }
      return ABSWatchCopy(
        accountId: accountId, key: entry.key, title: entry.title, subtitle: entry.subtitle,
        watchInstallID: installID, revision: revision, state: state,
        declineReason: state == .declined ? entry.declineReason ?? .invalid : nil,
        failureReason: state == .failed ? entry.failureReason ?? .invalidResponse : nil,
        sourceBytes: state == .delivered ? entry.committedBytes : nil, requestedAt: now, updatedAt: now,
        failedAt: state == .failed ? now : nil)
    }
  }
}
