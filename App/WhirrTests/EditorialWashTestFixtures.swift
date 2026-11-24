import ABSApi
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

@MainActor
final class EditorialWashTestFixtures {
  let accountScope = ArtworkAccountScope("test-account")
  let itemID = "show-1"
  let sampleData: Data
  let records = EditorialWashTestRecordStore()
  let bytes: EditorialWashTestBytes
  let pipeline = EditorialWashTestPipeline()
  let extraction: CoverPaletteService.Extraction
  let extractionCalls = EditorialWashTestCallCounter()
  let extractionGate: EditorialWashTestExtractionGate?

  /// The scale at which a 140 point home card is the palette source. A card at any other width
  /// cannot stand in for it, so its wash never joins the artwork arrival.
  static var cardScale: CGFloat {
    CGFloat(CoverPaletteSource.cardPixelWidth) / HomeView.cardCoverSize
  }

  init(gatedExtraction: Bool = false) {
    let data = Data([0x01, 0x02, 0x03])
    sampleData = data
    bytes = EditorialWashTestBytes(defaultData: data)
    let gate = gatedExtraction ? EditorialWashTestExtractionGate() : nil
    extractionGate = gate
    let calls = extractionCalls
    extraction = .init(samples: { data in
      await calls.increment()
      if let gate {
        await gate.enter()
        await gate.waitForRelease()
        await gate.markCompleted()
      }
      return data.isEmpty ? nil : EditorialWashTestSamples.value
    })
  }

  var canonicalKey: String { canonicalKey(for: .unversioned) }

  func canonicalKey(for revision: ArtworkRevision) -> String {
    canonicalKey(for: itemID, revision: revision)
  }

  func canonicalKey(for itemID: String, revision: ArtworkRevision = .unversioned) -> String {
    CoverPaletteWriter.recordIdentity(accountScope: accountScope, itemID: itemID, revision: revision)
  }

  /// The wash `warmRecord(for:)` persists; distinct from what the fixture's extraction derives.
  var warmWash: CoverWash {
    CoverWash.from(hue: 0.1, saturation: 0.5, brightness: 0.5)
  }

  func warmRecord(for itemID: String) -> CoverPaletteRecord {
    CoverPaletteRecord(
      itemId: itemID, artworkKey: canonicalKey(for: itemID),
      accentHue: 0.1, accentSaturation: 0.5, accentBrightness: 0.5,
      averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date())
  }

  func service() -> CoverPaletteService {
    CoverPaletteService(
      accountScope: accountScope,
      artwork: .init(reader: bytes, joiner: pipeline),
      extraction: extraction,
      recordStore: records)
  }
}

actor EditorialWashTestCallCounter {
  private(set) var value = 0

  func increment() { value += 1 }
}

actor EditorialWashTestExtractionGate {
  private(set) var calls = 0
  private var started: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  private var completedWaiter: CheckedContinuation<Void, Never>?
  private var isReleased = false
  private var isCompleted = false

  func enter() {
    calls += 1
    started?.resume()
    started = nil
  }

  func waitUntilStarted() async {
    if calls > 0 { return }
    await withCheckedContinuation { started = $0 }
  }

  func waitForRelease() async {
    if isReleased { return }
    await withCheckedContinuation { releaseWaiter = $0 }
  }

  func markCompleted() {
    isCompleted = true
    completedWaiter?.resume()
    completedWaiter = nil
  }

  func waitUntilCompleted() async {
    if isCompleted { return }
    await withCheckedContinuation { completedWaiter = $0 }
  }

  func release() {
    isReleased = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

actor EditorialWashTestRecordStore: CoverPaletteRecordStoring {
  nonisolated func observe(itemId: String) -> AsyncStream<CoverPaletteRecord?> {
    AsyncStream { $0.finish() }
  }

  /// As `CoverPaletteRecordStore` does: the rows present now, then again after each `upsert` to
  /// one of them. `seed` is a row written before anyone looked and notifies no one.
  nonisolated func observe(itemIds: [String]) -> AsyncStream<[CoverPaletteRecord]> {
    let (stream, continuation) = AsyncStream<[CoverPaletteRecord]>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    Task { await self.addObserver(id: id, itemIDs: Set(itemIds), continuation: continuation) }
    continuation.onTermination = { _ in Task { await self.removeObserver(id: id) } }
    return stream
  }

  private(set) var observerCount = 0
  /// Every several-row observation ever opened, closed or not: what following has cost.
  private(set) var observationsStarted = 0
  private var observers: [UUID: (itemIDs: Set<String>, continuation: AsyncStream<[CoverPaletteRecord]>.Continuation)] =
    [:]

  private func addObserver(
    id: UUID, itemIDs: Set<String>, continuation: AsyncStream<[CoverPaletteRecord]>.Continuation
  ) {
    observers[id] = (itemIDs, continuation)
    observerCount = observers.count
    observationsStarted += 1
    continuation.yield(itemIDs.sorted().compactMap { values[$0] })
  }

  private func removeObserver(id: UUID) {
    observers[id] = nil
    observerCount = observers.count
  }

  private var values: [String: CoverPaletteRecord] = [:]
  private(set) var batchFetchCount = 0
  private(set) var singleFetchCount = 0
  private var heldFetchIDs: Set<String> = []
  private var releasedFetchIDs: Set<String> = []
  private var fetchStartedIDs: Set<String> = []
  private var fetchStartedWaiters: [String: CheckedContinuation<Void, Never>] = [:]
  private var fetchReleaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]
  private var fetchGateArmed = false
  private var fetchStarted = false
  private var fetchReleased = false
  private var fetchReturned = false
  private var fetchStartedWaiter: CheckedContinuation<Void, Never>?
  private var fetchReleaseWaiter: CheckedContinuation<Void, Never>?
  private var fetchReturnedWaiter: CheckedContinuation<Void, Never>?
  private var batchFetchGateArmed = false
  private var batchFetchStarted = false
  private var batchFetchReleased = false
  private var batchFetchStartedWaiter: CheckedContinuation<Void, Never>?
  private var batchFetchReleaseWaiter: CheckedContinuation<Void, Never>?

  func fetch(itemId: String) async throws -> CoverPaletteRecord? {
    singleFetchCount += 1
    fetchStartedIDs.insert(itemId)
    fetchStartedWaiters[itemId]?.resume()
    fetchStartedWaiters[itemId] = nil

    if heldFetchIDs.remove(itemId) != nil, releasedFetchIDs.contains(itemId) == false {
      await withCheckedContinuation { fetchReleaseWaiters[itemId] = $0 }
    }

    if fetchGateArmed {
      fetchGateArmed = false
      fetchStarted = true
      fetchStartedWaiter?.resume()
      fetchStartedWaiter = nil
      if fetchReleased == false {
        await withCheckedContinuation { fetchReleaseWaiter = $0 }
      }
      fetchReturned = true
      fetchReturnedWaiter?.resume()
      fetchReturnedWaiter = nil
    }
    return values[itemId]
  }

  func fetch(itemIds: [String]) async throws -> [CoverPaletteRecord] {
    batchFetchCount += 1
    let found = itemIds.compactMap { values[$0] }
    if batchFetchGateArmed {
      batchFetchGateArmed = false
      batchFetchStarted = true
      batchFetchStartedWaiter?.resume()
      batchFetchStartedWaiter = nil
      if batchFetchReleased == false {
        await withCheckedContinuation { batchFetchReleaseWaiter = $0 }
      }
    }
    return found
  }

  func upsert(_ record: CoverPaletteRecord) async throws {
    values[record.itemId] = record
    for observer in observers.values where observer.itemIDs.contains(record.itemId) {
      observer.continuation.yield(observer.itemIDs.sorted().compactMap { values[$0] })
    }
  }

  func seed(_ record: CoverPaletteRecord) { values[record.itemId] = record }

  func removeAll() { values.removeAll() }

  func record(for itemID: String) -> CoverPaletteRecord? { values[itemID] }

  func holdFetch(for itemID: String) {
    heldFetchIDs.insert(itemID)
    releasedFetchIDs.remove(itemID)
    fetchStartedIDs.remove(itemID)
  }

  func waitUntilFetchStarted(for itemID: String) async {
    if fetchStartedIDs.contains(itemID) { return }
    await withCheckedContinuation { fetchStartedWaiters[itemID] = $0 }
  }

  func hasFetchStarted(for itemID: String) -> Bool { fetchStartedIDs.contains(itemID) }

  func releaseFetch(for itemID: String) {
    releasedFetchIDs.insert(itemID)
    fetchReleaseWaiters[itemID]?.resume()
    fetchReleaseWaiters[itemID] = nil
  }

  func holdNextFetch() {
    fetchGateArmed = true
    fetchStarted = false
    fetchReleased = false
    fetchReturned = false
  }

  func waitUntilFetchStarted() async {
    if fetchStarted { return }
    await withCheckedContinuation { fetchStartedWaiter = $0 }
  }

  func releaseFetch() {
    fetchReleased = true
    fetchReleaseWaiter?.resume()
    fetchReleaseWaiter = nil
  }

  func waitUntilFetchReturned() async {
    if fetchReturned { return }
    await withCheckedContinuation { fetchReturnedWaiter = $0 }
  }

  /// Holds the next batch read after it has read its rows, so a clear can land between the read
  /// and its caller's use of the result.
  func holdNextBatchFetch() {
    batchFetchGateArmed = true
    batchFetchStarted = false
    batchFetchReleased = false
  }

  func waitUntilBatchFetchStarted() async {
    if batchFetchStarted { return }
    await withCheckedContinuation { batchFetchStartedWaiter = $0 }
  }

  func releaseBatchFetch() {
    batchFetchReleased = true
    batchFetchReleaseWaiter?.resume()
    batchFetchReleaseWaiter = nil
  }
}

actor EditorialWashTestBytes: CoverPaletteByteReading {
  private var defaultData: Data?
  private var values: [ArtworkKey: Data] = [:]

  init(defaultData: Data? = nil) {
    self.defaultData = defaultData
  }

  private var missingItemIDs: Set<String> = []

  func data(for key: ArtworkKey) async -> Data? {
    guard missingItemIDs.contains(key.itemID) == false else { return nil }
    return values[key] ?? defaultData
  }

  func seed(key: ArtworkKey, data: Data) { values[key] = data }

  /// No cover bytes for `itemID` under any key, as for a cover not yet downloaded.
  func setMissing(_ itemID: String) { missingItemIDs.insert(itemID) }

  func clearDefault() { defaultData = nil }
}

actor EditorialWashTestPipeline: CoverPaletteArtworkJoining {
  private(set) var joinCalls = 0
  private var arrival: (@Sendable (ArtworkKey) async -> Void)?

  func awaitArrival(for key: ArtworkKey) async {
    joinCalls += 1
    await arrival?(key)
  }

  func setArrival(_ arrival: @escaping @Sendable (ArtworkKey) async -> Void) {
    self.arrival = arrival
  }
}

enum EditorialWashTestSamples {
  nonisolated static let value = CoverPaletteSamples(
    average: CoverRGBA(red: 0.2, green: 0.3, blue: 0.4),
    dominant: [CoverRGBA(red: 0.9, green: 0.2, blue: 0.2)])
}

@MainActor
final class EditorialWashBatchObserver {
  private var batches: [[String: CoverWash]] = []
  // An ordered queue, not a dictionary: `Dictionary.keys.first` is unordered, so two concurrent
  // waiters would receive batches in an arbitrary order that changes between runs.
  private var waiters: [(id: UUID, continuation: CheckedContinuation<[String: CoverWash], Never>)] = []
  private var resolved: [String: CoverWash] = [:]
  private(set) var count = 0

  var resolvedCount: Int { resolved.count }
  var resolvedWashes: [String: CoverWash] { resolved }

  func receive(_ batch: [String: CoverWash]) {
    count += 1
    resolved.merge(batch) { _, newWash in newWash }
    if waiters.isEmpty {
      batches.append(batch)
    } else {
      waiters.removeFirst().continuation.resume(returning: batch)
    }
  }

  func nextBatch() async -> [String: CoverWash] {
    if batches.isEmpty == false { return batches.removeFirst() }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      guard Task.isCancelled == false else { return [:] }
      return await withCheckedContinuation { continuation in
        waiters.append((id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor in self.cancelWaiter(id: waiterID) }
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: [:])
  }
}

@MainActor
final class EditorialWashMutationObserver {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
