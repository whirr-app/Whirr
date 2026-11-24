import Foundation
import Persistence

@testable import Whirr

/// An in-memory `CoverPaletteRecordStoring` that behaves as `CoverPaletteRecordStore` does: a write
/// is seen by every observer of its row, and an observer first hears the rows as they are now.
/// Suites that need no more than that share it rather than each keeping its own copy.
actor FakeCoverPaletteRecordStoring: CoverPaletteRecordStoring {
  private var records: [String: CoverPaletteRecord] = [:]
  private var single: [UUID: (itemID: String, continuation: AsyncStream<CoverPaletteRecord?>.Continuation)] = [:]
  private var batch: [UUID: (itemIDs: Set<String>, continuation: AsyncStream<[CoverPaletteRecord]>.Continuation)] = [:]
  private(set) var fetchCount = 0
  private(set) var batchFetchCount = 0
  private(set) var upserted: [CoverPaletteRecord] = []

  init(_ seeded: CoverPaletteRecord...) {
    for record in seeded { records[record.itemId] = record }
  }

  var storedIDs: Set<String> { Set(records.keys) }

  /// How many several-row observers are open: the Home wash follows through these.
  var batchObserverCount: Int { batch.count }

  /// Stores `record` without notifying observers, as a row written before they subscribed.
  func seed(_ record: CoverPaletteRecord) { records[record.itemId] = record }

  func record(for itemID: String) -> CoverPaletteRecord? { records[itemID] }

  private var removalHeld = false
  private var removalStarted: CheckedContinuation<Void, Never>?
  private var removalRelease: CheckedContinuation<Void, Never>?
  private var isRemoving = false

  /// Makes the next `removeAll` stop after it starts and before it removes anything, until
  /// `releaseRemoval`, so a test can act while a clear is still in progress.
  func holdNextRemoval() { removalHeld = true }

  func waitUntilRemovalStarted() async {
    if isRemoving { return }
    await withCheckedContinuation { removalStarted = $0 }
  }

  func releaseRemoval() {
    removalHeld = false
    removalRelease?.resume()
    removalRelease = nil
  }

  /// Every row gone, as the artwork clear's record clearer does, with each observer told.
  func removeAll() async {
    isRemoving = true
    removalStarted?.resume()
    removalStarted = nil
    if removalHeld {
      await withCheckedContinuation { removalRelease = $0 }
    }
    records.removeAll()
    isRemoving = false
    for observer in single.values { observer.continuation.yield(nil) }
    for observer in batch.values { observer.continuation.yield([]) }
  }

  func fetch(itemId: String) async throws -> CoverPaletteRecord? {
    fetchCount += 1
    return records[itemId]
  }

  func fetch(itemIds: [String]) async throws -> [CoverPaletteRecord] {
    batchFetchCount += 1
    return itemIds.compactMap { records[$0] }
  }

  func upsert(_ record: CoverPaletteRecord) async throws {
    upserted.append(record)
    records[record.itemId] = record
    for observer in single.values where observer.itemID == record.itemId {
      observer.continuation.yield(record)
    }
    for observer in batch.values where observer.itemIDs.contains(record.itemId) {
      observer.continuation.yield(rows(observer.itemIDs))
    }
  }

  nonisolated func observe(itemId: String) -> AsyncStream<CoverPaletteRecord?> {
    let (stream, continuation) = AsyncStream<CoverPaletteRecord?>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    Task { await self.addSingle(id: id, itemID: itemId, continuation: continuation) }
    continuation.onTermination = { _ in Task { await self.removeSingle(id: id) } }
    return stream
  }

  nonisolated func observe(itemIds: [String]) -> AsyncStream<[CoverPaletteRecord]> {
    let (stream, continuation) = AsyncStream<[CoverPaletteRecord]>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    Task { await self.addBatch(id: id, itemIDs: Set(itemIds), continuation: continuation) }
    continuation.onTermination = { _ in Task { await self.removeBatch(id: id) } }
    return stream
  }

  private func rows(_ itemIDs: Set<String>) -> [CoverPaletteRecord] {
    itemIDs.sorted().compactMap { records[$0] }
  }

  private func addSingle(
    id: UUID, itemID: String, continuation: AsyncStream<CoverPaletteRecord?>.Continuation
  ) {
    single[id] = (itemID, continuation)
    continuation.yield(records[itemID])
  }

  private func addBatch(
    id: UUID, itemIDs: Set<String>, continuation: AsyncStream<[CoverPaletteRecord]>.Continuation
  ) {
    batch[id] = (itemIDs, continuation)
    continuation.yield(rows(itemIDs))
  }

  private func removeSingle(id: UUID) { single[id] = nil }
  private func removeBatch(id: UUID) { batch[id] = nil }
}
