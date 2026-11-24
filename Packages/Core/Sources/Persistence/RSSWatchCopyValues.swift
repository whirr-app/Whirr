import Foundation

public enum RSSWatchCopyStoreError: Error, Equatable, Sendable {
  case episodeNotFound
}

/// The active Watch's set state, as the offer and the UI read it.
public struct RSSWatchCopySetState: Sendable, Equatable {
  public let watchInstallID: String?
  /// Bumps whenever membership, a revision or a removal changes.
  public let generation: Int64
  public let acknowledgedGeneration: Int64
  public let inventorySequence: Int64
  public let acceptsCopies: Bool?
  public let budgetTotalBytes: Int64?
  public let budgetUsedBytes: Int64?
  public let lastInventoryAt: Date?

  public init(
    watchInstallID: String? = nil,
    generation: Int64 = 0,
    acknowledgedGeneration: Int64 = 0,
    inventorySequence: Int64 = 0,
    acceptsCopies: Bool? = nil,
    budgetTotalBytes: Int64? = nil,
    budgetUsedBytes: Int64? = nil,
    lastInventoryAt: Date? = nil
  ) {
    self.watchInstallID = watchInstallID
    self.generation = generation
    self.acknowledgedGeneration = acknowledgedGeneration
    self.inventorySequence = inventorySequence
    self.acceptsCopies = acceptsCopies
    self.budgetTotalBytes = budgetTotalBytes
    self.budgetUsedBytes = budgetUsedBytes
    self.lastInventoryAt = lastInventoryAt
  }

  init(_ record: RSSWatchCopySetRecord) {
    self.init(
      watchInstallID: record.watchInstallID, generation: record.generation,
      acknowledgedGeneration: record.acknowledgedGeneration,
      inventorySequence: record.inventorySequence, acceptsCopies: record.acceptsCopies,
      budgetTotalBytes: record.budgetTotalBytes, budgetUsedBytes: record.budgetUsedBytes,
      lastInventoryAt: record.lastInventoryAt)
  }
}
