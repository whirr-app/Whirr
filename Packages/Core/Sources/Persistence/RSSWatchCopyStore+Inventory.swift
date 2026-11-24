import Foundation
import GRDB

extension RSSWatchCopyStore {
  /// Reconciles one inventory with the desired set. Rules, in order: a late sequence for the same
  /// install is ignored; a different install replaces the set; capabilities and budget are
  /// stored; entries matching a row's revision move it (`ready` → `delivered`, `receiving` →
  /// `sending`, `declined`, `removed`); a Watch that takes no copies (signed out) holds none,
  /// so every row it could have held waits for it, and the first inventory that takes copies again
  /// releases them; otherwise a copy in flight or delivered that is missing from an inventory
  /// acknowledging the current generation goes back to `wanted`, because the Watch asks for what it
  /// lacks.
  public func applyInventory(
    _ inventory: RSSWatchInventory, now: Date
  ) async throws -> RSSWatchCopyInventoryOutcome {
    try await database.writeAsync { db in
      guard var context = try ApplyContext.fence(inventory, now: now, in: db) else {
        return RSSWatchCopyInventoryOutcome(changedEpisodeIds: [], installReplaced: false)
      }
      try context.installReplacement(in: db)
      context.storeSetColumns()
      try context.applyEntries(in: db)
      try context.settleOmissions(in: db)
      return try context.commit(in: db)
    }
  }

  /// One inventory's moves against the set row and the rows, inside the caller's transaction.
  /// `set` is the live record: the omission rule reads the generation after the entry moves have
  /// bumped it, never a value captured earlier.
  private struct ApplyContext {
    let inventory: RSSWatchInventory
    let now: Date
    let incomingSequence: Int64
    let replaced: Bool
    var set: RSSWatchCopySetRecord
    var byID: [Int64: RSSWatchCopy]
    var changedIDs: [Int64] = []
    var changed: Set<Int64> = []
    var membershipChanged = false

    /// Reads the set row and applies the fence. A late sequence from the install already stored
    /// returns `nil` before anything is deleted or moved.
    static func fence(
      _ inventory: RSSWatchInventory, now: Date, in db: Database
    ) throws -> ApplyContext? {
      let set =
        try RSSWatchCopySetRecord.fetchOne(db, key: RSSWatchCopySetRecord.singletonID)
        ?? RSSWatchCopySetRecord()
      let incomingSequence = WatchCopyArithmetic.saturated(inventory.sequence)
      let replaced =
        set.watchInstallID != nil && set.watchInstallID != inventory.watchInstallID

      if replaced == false, set.watchInstallID == inventory.watchInstallID,
        incomingSequence <= set.inventorySequence
      {
        return nil
      }
      return ApplyContext(
        inventory: inventory, now: now, incomingSequence: incomingSequence, replaced: replaced,
        set: set, byID: [:])
    }

    /// A different install has no copies of ours: every row goes, and the generation moves on so
    /// the new Watch cannot apply an offer issued to the old one.
    mutating func installReplacement(in db: Database) throws {
      guard replaced else { return }
      let previous = try Int64.fetchAll(db, sql: "SELECT episodeId FROM rssWatchCopy")
      for episodeId in previous {
        noteChanged(episodeId)
      }
      try db.execute(sql: "DELETE FROM rssWatchCopy")
      set.generation += 1
    }

    mutating func storeSetColumns() {
      set.watchInstallID = inventory.watchInstallID
      set.inventorySequence = incomingSequence
      // The publisher re-offers while this is behind `generation`.
      set.acknowledgedGeneration = WatchCopyArithmetic.saturated(inventory.acknowledgedGeneration)
      // A Watch cannot acknowledge a generation the phone never issued, so a higher value means the
      // phone's database was reset while the same Watch install kept its copies. The phone's set is
      // authoritative, so it steps past what the Watch applied; otherwise every offer would be
      // ignored as stale and the Watch would keep copies the phone no longer wants.
      if set.acknowledgedGeneration > set.generation {
        set.generation = WatchCopyArithmetic.incremented(set.acknowledgedGeneration)
      }
      set.acceptsCopies = inventory.acceptsCopies
      set.budgetTotalBytes = inventory.budgetTotalBytes
      set.budgetUsedBytes = inventory.budgetUsedBytes
      set.lastInventoryAt = inventory.observedAt
    }

    mutating func applyEntries(in db: Database) throws {
      byID = Dictionary(
        uniqueKeysWithValues: try RSSWatchCopy.fetchAll(db).map { ($0.episodeId, $0) })

      // (d) Entries whose revision still matches the row move it. An older or newer revision is
      // ignored: the Watch is describing a copy this phone no longer offers at that revision.
      for entry in inventory.entries {
        guard var copy = byID[entry.episodeId], copy.revision == entry.revision else {
          continue
        }
        switch entry.state {
        case .ready:
          guard copy.state != .delivered, copy.state != .removed,
            copy.state != .declined || RSSWatchCopyStore.isWaitingForRoom(copy)
          else { continue }
          copy.state = .delivered
          copy.declineReason = nil
          // Delivery truth carries the admitted file's byte count, so a delivered row records
          // what the Watch holds.
          copy.sourceBytes = entry.committedBytes ?? copy.sourceBytes
        case .receiving:
          // A delivered row is further along than a partial report.
          // A storage decline the Watch took back once it had room is downloading again.
          guard
            copy.state == .wanted || copy.state == .waitingForWatch
              || copy.state == .sending || RSSWatchCopyStore.isWaitingForRoom(copy)
          else { continue }
          copy.state = .sending
          copy.declineReason = nil
        case .removed:
          guard copy.state != .removed else { continue }
          copy.state = .removed
          copy.removedBy = .watch
          copy.declineReason = nil
          copy.failedAt = nil
          membershipChanged = true
        case .declined:
          let reason = entry.declineReason ?? .invalid
          guard copy.state != .declined || copy.declineReason != reason else { continue }
          copy.state = .declined
          copy.declineReason = reason
          copy.removedBy = nil
          copy.failedAt = nil
          // A storage decline stays in the offer: the Watch keeps it and takes it back once it has
          // room, which an episode left out of the offer would lose. Any other decline leaves.
          if reason != .storageFull { membershipChanged = true }
        }
        copy.updatedAt = now
        copy.watchInstallID = inventory.watchInstallID
        try copy.update(db)
        byID[entry.episodeId] = copy
        noteChanged(entry.episodeId)
      }

      if membershipChanged {
        set.generation += 1
      }
    }

    mutating func settleOmissions(in db: Database) throws {
      let ordered = byID.values.sorted(by: { $0.episodeId < $1.episodeId })
      if inventory.acceptsCopies == false {
        // (e) A signed-out Watch has cleared its copies and acknowledges no generation, so no
        // omission rule can run; every row it could hold waits for it instead.
        for copy in ordered
        where [.wanted, .sending, .delivered, .failed].contains(copy.state) {
          try move(copy, to: .waitingForWatch, in: db)
        }
      } else {
        // (f) `waitingForWatch` means no inventory had taken copies; this one does.
        for copy in ordered where copy.state == .waitingForWatch {
          try move(copy, to: .wanted, in: db)
        }
        // (g) A copy in flight or delivered that an acknowledging inventory omits is gone: the
        // Watch asks for what it lacks. The (f) moves only touched `waitingForWatch` rows,
        // so `ordered` is current for these states.
        if inventory.acknowledgedGeneration >= UInt64(clamping: set.generation) {
          let present = Set(inventory.entries.map(\.episodeId))
          for copy in ordered
          where present.contains(copy.episodeId) == false
            && [.sending, .delivered].contains(copy.state)
          {
            try move(copy, to: .wanted, in: db)
          }
        }
      }
    }

    func commit(in db: Database) throws -> RSSWatchCopyInventoryOutcome {
      try set.update(db)
      return RSSWatchCopyInventoryOutcome(
        changedEpisodeIds: changedIDs.sorted(), installReplaced: replaced)
    }

    private mutating func move(
      _ copy: RSSWatchCopy, to state: RSSWatchCopyState, in db: Database
    ) throws {
      var updated = copy
      updated.state = state
      updated.sourceBytes = nil
      updated.failedAt = nil
      updated.updatedAt = now
      updated.watchInstallID = inventory.watchInstallID
      try updated.update(db)
      byID[copy.episodeId] = updated
      noteChanged(copy.episodeId)
    }

    private mutating func noteChanged(_ episodeId: Int64) {
      if changed.insert(episodeId).inserted {
        changedIDs.append(episodeId)
      }
    }
  }
}
