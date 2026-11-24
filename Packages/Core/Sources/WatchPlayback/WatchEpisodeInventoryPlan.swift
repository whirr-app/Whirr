import Foundation
import WatchProtocol

/// Builds the Watch's authoritative inventory from its received-episode entries. The phone reads an
/// omitted `ready` entry as "not on the Watch" and offers the episode again, so trimming is a last
/// resort: only a set that cannot fit the wire cap at all loses entries, and `ready`/`removed` go
/// after the queued, downloading, failed and declined ones.
///
/// A signed-out Watch reports no copies and acknowledges generation 0, so the phone parks the set as
/// "Waiting for your Watch" and re-offers it after sign-in rather than reading a decline as a full
/// or broken Watch. It reports no Audiobookshelf half either.
///
/// The Audiobookshelf half shares the 100-row and byte caps, and one tier table trims across both
/// lists.
public enum WatchEpisodeInventoryPlan {
  public static func make(
    installID: String,
    sequence: UInt64,
    acknowledgedGeneration: UInt64,
    acceptsCopies: Bool,
    entries: [WatchReceivedEpisode],
    abs: WatchABSInventoryHalf? = nil,
    totalBytes: Int64,
    usedBytes: Int64,
    observedAt: Date
  ) throws -> WatchEpisodeInventory {
    try WatchInstallIdentity.validate(installID)

    var rows = Rows()
    if acceptsCopies {
      rows.rss = try entries.map { try inventoryEntry(for: $0) }
    }
    let generation = acceptsCopies ? acknowledgedGeneration : 0
    let abs = acceptsCopies ? abs : nil
    rows.abs = abs?.entries ?? []
    let shape = Shape(
      installID: installID, sequence: sequence, generation: generation, acceptsCopies: acceptsCopies, abs: abs,
      totalBytes: totalBytes, usedBytes: usedBytes, observedAt: observedAt)

    while rows.count > WatchEpisodeSendLimits.maxInventoryEntries || fits(rows, shape) == false {
      guard rows.trimOne() else { break }
    }

    return try inventory(rows, shape)
  }

  /// Everything but the rows, which the trim loop changes.
  private struct Shape {
    let installID: String
    let sequence: UInt64
    let generation: UInt64
    let acceptsCopies: Bool
    let abs: WatchABSInventoryHalf?
    let totalBytes: Int64
    let usedBytes: Int64
    let observedAt: Date
  }

  /// Both lists, trimmed as one: the tail of the lowest tier goes first, wherever it is, so the
  /// head of each store's order survives.
  private struct Rows {
    var rss: [WatchEpisodeInventoryEntry] = []
    var abs: [WatchABSInventoryEntry] = []

    var count: Int { rss.count + abs.count }

    mutating func trimOne() -> Bool {
      let tiers =
        rss.map { WatchEpisodeInventoryPlan.dropTier($0.state) }
        + abs.map { WatchEpisodeInventoryPlan.dropTier($0.state) }
      guard let lowest = tiers.min(), let index = tiers.lastIndex(of: lowest) else { return false }
      if index >= rss.count {
        abs.remove(at: index - rss.count)
      } else {
        rss.remove(at: index)
      }
      return true
    }
  }

  private static func inventoryEntry(
    for entry: WatchReceivedEpisode
  ) throws -> WatchEpisodeInventoryEntry {
    switch entry.state {
    case .receiving:
      return try WatchEpisodeInventoryEntry(
        selection: entry.selection, revision: entry.revision, state: .receiving)
    case .downloading:
      return try WatchEpisodeInventoryEntry(
        selection: entry.selection, revision: entry.revision, state: .downloading,
        progress: entry.progress)
    case .waitingForNetwork:
      return try WatchEpisodeInventoryEntry(
        selection: entry.selection, revision: entry.revision, state: .waitingForNetwork)
    case .ready:
      // A ready entry always carries its measured size; the reservation is the same promise when
      // an entry was hand-built rather than loaded from the store.
      return try WatchEpisodeInventoryEntry(
        selection: entry.selection, revision: entry.revision, state: .ready,
        committedBytes: entry.committedBytes ?? entry.reservedBytes)
    case .failed:
      return try WatchEpisodeInventoryEntry(
        selection: entry.selection, revision: entry.revision, state: .failed,
        failureReason: entry.failureReason ?? .invalidResponse)
    case .declined:
      return try WatchEpisodeInventoryEntry(
        selection: entry.selection, revision: entry.revision, state: .declined,
        declineReason: entry.declineReason ?? .invalid)
    case .removed:
      return try WatchEpisodeInventoryEntry(
        selection: entry.selection, revision: entry.revision, state: .removed)
    }
  }

  private static func inventory(_ rows: Rows, _ shape: Shape) throws -> WatchEpisodeInventory {
    try WatchEpisodeInventory(
      watchInstallID: shape.installID, sequence: shape.sequence, acknowledgedGeneration: shape.generation,
      acceptsCopies: shape.acceptsCopies,
      entries: rows.rss, budgetTotalBytes: max(0, shape.totalBytes), budgetUsedBytes: max(0, shape.usedBytes),
      observedAt: shape.observedAt, absEntries: shape.abs.map { _ in rows.abs },
      absAcknowledgedGeneration: shape.abs?.acknowledgedGeneration, absAccountStamp: shape.abs?.accountStamp)
  }

  private static func fits(_ rows: Rows, _ shape: Shape) -> Bool {
    guard let inventory = try? inventory(rows, shape) else { return false }
    return (try? WatchWireCodec.encode(inventory)) != nil
  }

  /// The tier an entry may be dropped in. Higher numbers are kept longer: a declined entry asks the
  /// phone for different copy, a failed one only for a retry and a receiving one is simply
  /// re-offered, while a removed tombstone is the listener's own choice and a ready copy costs a
  /// whole download to replace.
  private static func dropTier(_ state: WatchEpisodeInventoryEntry.State) -> Int {
    switch state {
    case .declined: return 0
    case .failed: return 1
    case .receiving: return 2
    case .waitingForNetwork: return 3
    case .downloading: return 4
    case .removed: return 5
    case .ready: return 6
    }
  }
}
