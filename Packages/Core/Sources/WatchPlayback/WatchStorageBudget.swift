import Synchronization

/// One ledger for the storage the Watch allows, shared by the Audiobookshelf download store and the
/// received-episode store. Each store records only its own reservation; a claim is checked against
/// the sum over every owner, so neither store can push the pair past `totalBytes`.
///
/// The stores keep their own quota checks as well: this ledger is the cross-store ceiling, not a
/// replacement for a store's internal accounting. A reservation is a promise about bytes that will
/// exist later, so it is claimed when work is admitted, not when a file finishes.
public final class WatchStorageBudget: Sendable {
  public enum Owner: Hashable, Sendable {
    case audiobookshelf
    case receivedEpisodes
  }

  public let totalBytes: Int64

  private let reservations: Mutex<[Owner: Int64]>

  /// A non-positive total is a programmer error: every claim would fail and the Watch could never
  /// store anything. Negative reservations are clamped to zero rather than trapped, because they
  /// can only come from arithmetic on a partly-known file size and must not crash a launch.
  public init(totalBytes: Int64 = 2_000_000_000) {
    precondition(totalBytes > 0, "WatchStorageBudget requires a positive total")
    self.totalBytes = totalBytes
    self.reservations = Mutex([:])
  }

  /// Sets `owner`'s reservation to `reservedBytes` when the resulting total stays within
  /// `totalBytes`. A request at or below the owner's current reservation always succeeds, so
  /// releasing space never fails and a store that is already over the total can still shrink.
  /// Returns `false` and changes nothing when the claim would exceed the total.
  @discardableResult
  public func claim(_ reservedBytes: Int64, for owner: Owner) -> Bool {
    let requested = max(0, reservedBytes)
    return reservations.withLock { state in
      let current = state[owner] ?? 0
      if requested <= current {
        state[owner] = requested
        return true
      }
      let otherOwners = state.reduce(Int64(0)) { total, entry in
        entry.key == owner ? total : total + entry.value
      }
      guard otherOwners <= totalBytes - requested else { return false }
      state[owner] = requested
      return true
    }
  }

  /// Sets `owner`'s reservation without a total check. Load and rollback use this so the ledger
  /// mirrors what a store actually holds even when the Watch was already over its total before
  /// either store opened.
  public func record(_ reservedBytes: Int64, for owner: Owner) {
    let value = max(0, reservedBytes)
    reservations.withLock { $0[owner] = value }
  }

  public func reservedBytes(for owner: Owner) -> Int64 {
    reservations.withLock { $0[owner] ?? 0 }
  }

  public var usedBytes: Int64 {
    reservations.withLock { $0.values.reduce(Int64(0), +) }
  }
}
