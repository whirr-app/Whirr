import Persistence

/// `StorageReading`'s fake. Mirrors `FakeDownloadReading`'s per-item live-continuation shape, plus
/// one account-wide stream.
public final class FakeStorageReading: StorageReading, @unchecked Sendable {
  public init(
    accountTotals: StorageTotals? = nil,
    completedDownloadBytes: Int64? = 0,
    breakdown: StorageBreakdown? = nil
  ) {
    breakdownBox = Locked(breakdown)
    accountTotalsBox = Locked(accountTotals)
    completedDownloadBytesBox = Locked(completedDownloadBytes)
  }

  private let accountTotalsBox: Locked<StorageTotals?>
  private let accountContinuations = Locked<[AsyncStream<StorageTotals>.Continuation]>([])
  private let accountObservationCallCountBox = Locked(0)
  private let activeAccountObservationCountBox = Locked(0)
  private let itemContinuations = Locked<[String: [AsyncStream<StorageTotals>.Continuation]]>([:])
  private let downloadedItemContinuations = Locked<[AsyncStream<[DownloadedItemTotals]>.Continuation]>([])
  private let completedDownloadBytesBox: Locked<Int64?>
  private let completedDownloadContinuations = Locked<[AsyncStream<Int64>.Continuation]>([])
  private let completedObservationCallCountBox = Locked(0)
  private let activeCompletedObservationCountBox = Locked(0)
  private let breakdownBox: Locked<StorageBreakdown?>
  private let breakdownContinuations = Locked<[AsyncStream<StorageBreakdown>.Continuation]>([])
  private let breakdownObservationCallCountBox = Locked(0)
  private let activeBreakdownObservationCountBox = Locked(0)

  /// Test-only: proves an unlimited ceiling returns before it even subscribes to completed-byte
  /// accounting.
  public var completedObservationCount: Int { completedObservationCallCountBox.value }
  public var accountObservationCount: Int { accountObservationCallCountBox.value }
  public var activeAccountObservationCount: Int { activeAccountObservationCountBox.value }
  public var activeCompletedObservationCount: Int { activeCompletedObservationCountBox.value }
  public var breakdownObservationCount: Int { breakdownObservationCallCountBox.value }
  public var activeBreakdownObservationCount: Int { activeBreakdownObservationCountBox.value }

  private let itemObservationCountBox = Locked(0)
  private let downloadedItemsObservationCountBox = Locked(0)
  /// How many times `observeItemStorageTotals(itemId:)` has been called, consumed or not.
  public var itemObservationCount: Int { itemObservationCountBox.value }
  /// How many times `observeDownloadedItems()` has been called, consumed or not.
  public var downloadedItemsObservationCount: Int { downloadedItemsObservationCountBox.value }

  public func observeAccountStorageTotals() -> AsyncStream<StorageTotals> {
    accountObservationCallCountBox.withValue { $0 += 1 }
    activeAccountObservationCountBox.withValue { $0 += 1 }
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      accountContinuations.withValue { $0.append(continuation) }
      if let accountTotals = accountTotalsBox.value {
        continuation.yield(accountTotals)
      }
      continuation.onTermination = { [weak self] _ in
        self?.activeAccountObservationCountBox.withValue { $0 -= 1 }
      }
    }
  }

  public func observeItemStorageTotals(itemId: String) -> AsyncStream<StorageTotals> {
    itemObservationCountBox.withValue { $0 += 1 }
    return AsyncStream { continuation in
      itemContinuations.withValue { $0[itemId, default: []].append(continuation) }
    }
  }

  /// Test-only: simulates `observeAccountStorageTotals()` firing again.
  public func pushAccountTotals(_ totals: StorageTotals) {
    accountTotalsBox.value = totals
    for continuation in accountContinuations.value { continuation.yield(totals) }
  }

  /// Test-only: simulates `observeItemStorageTotals(itemId:)` firing again for `itemId`.
  public func pushItemTotals(_ totals: StorageTotals, itemId: String) {
    for continuation in itemContinuations.value[itemId] ?? [] { continuation.yield(totals) }
  }

  public func observeDownloadedItems() -> AsyncStream<[DownloadedItemTotals]> {
    downloadedItemsObservationCountBox.withValue { $0 += 1 }
    return AsyncStream { continuation in
      downloadedItemContinuations.withValue { $0.append(continuation) }
    }
  }

  public func observeCompletedDownloadTotals() -> AsyncStream<Int64> {
    completedObservationCallCountBox.withValue { $0 += 1 }
    activeCompletedObservationCountBox.withValue { $0 += 1 }
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      completedDownloadContinuations.withValue { $0.append(continuation) }
      if let completedDownloadBytes = completedDownloadBytesBox.value {
        continuation.yield(completedDownloadBytes)
      }
      continuation.onTermination = { [weak self] _ in
        self?.activeCompletedObservationCountBox.withValue { $0 -= 1 }
      }
    }
  }

  public func observeStorageBreakdown() -> AsyncStream<StorageBreakdown> {
    breakdownObservationCallCountBox.withValue { $0 += 1 }
    activeBreakdownObservationCountBox.withValue { $0 += 1 }
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      breakdownContinuations.withValue { $0.append(continuation) }
      if let breakdown = breakdownBox.value {
        continuation.yield(breakdown)
      }
      continuation.onTermination = { [weak self] _ in
        self?.activeBreakdownObservationCountBox.withValue { $0 -= 1 }
      }
    }
  }

  /// Test-only: simulates the breakdown observation firing again.
  public func pushStorageBreakdown(_ breakdown: StorageBreakdown) {
    breakdownBox.value = breakdown
    for continuation in breakdownContinuations.value { continuation.yield(breakdown) }
  }

  /// Test-only: simulates a completed-byte observation firing again.
  public func pushCompletedDownloadTotals(_ bytes: Int64) {
    completedDownloadBytesBox.value = bytes
    for continuation in completedDownloadContinuations.value { continuation.yield(bytes) }
  }

  /// Short alias for focused coordinator tests.
  public func pushCompletedTotals(_ bytes: Int64) {
    pushCompletedDownloadTotals(bytes)
  }

  /// Test-only: simulates `observeDownloadedItems()` firing again with a whole new row set.
  public func pushDownloadedItems(_ items: [DownloadedItemTotals]) {
    for continuation in downloadedItemContinuations.value { continuation.yield(items) }
  }
}
