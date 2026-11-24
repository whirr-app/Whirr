import ABSApi
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

@Suite("Cover palette backfill", .timeLimit(.minutes(1)))
@MainActor
struct CoverPaletteBackfillTests {
  // MARK: - Selection

  @Test("a missing, stale or evidence-free row is a candidate; a current row is not")
  func selection() async {
    let items = ["missing", "stale-stamp", "stale-revision", "no-evidence", "current"].map {
      Self.item($0)
    }
    let staleRevision = Self.item("stale-revision", revision: ArtworkRevision("old"))
    let records = FakeCoverPaletteRecordStoring()
    await records.seed(Self.record(for: items[1], identity: "scope|stale-stamp|unversioned|older-stamp"))
    await records.seed(Self.record(for: staleRevision))
    await records.seed(Self.record(for: items[3], evidence: false))
    await records.seed(Self.record(for: items[4]))
    let service = CoverPaletteService(recordStore: records)

    let unsaved = await service.unsaved(items.map { CoverPaletteIdentity($0.key) })

    #expect(unsaved.map(\.itemID) == ["missing", "stale-stamp", "stale-revision", "no-evidence"])
  }

  // MARK: - Running

  @Test("every candidate reaches the deriver once, in item order, with its own key")
  func derivesEveryCandidateOnce() async {
    let items = (0..<5).map { Self.item("item-\($0)") }
    let harness = Harness(items: items)
    let backfill = harness.makeBackfill()

    backfill.trigger()
    _ = await awaitCondition(
      "every item derived", until: { await harness.deriver.calls.count == items.count })
    _ = await awaitCondition("the run ends", until: { backfill.isRunning == false })

    #expect(await harness.deriver.calls == items)
    #expect(await harness.records.storedIDs == Set(items.map(\.itemID)))
  }

  @Test("backgrounding keeps the remaining work, and foregrounding finishes it")
  func suspensionResumes() async {
    let items = (0..<4).map { Self.item("item-\($0)") }
    let harness = Harness(items: items, blockedItemIDs: ["item-1"])
    let backfill = harness.makeBackfill()

    backfill.trigger()
    _ = await awaitCondition("item-1 in flight", until: { await harness.deriver.started.contains("item-1") })

    _ = await awaitCondition(
      "the run observes the lifecycle", until: { harness.lifecycle.lifecycleSubscriberCount > 0 })
    harness.lifecycle.simulateBackground()
    await harness.deriver.unblockAll()
    _ = await awaitCondition("the run stops", until: { backfill.isRunning == false })
    // item-1 was in flight: whether it lands depends on whether the cancellation reached it first.
    // Nothing after it may start in the background.
    let storedInBackground = await harness.records.storedIDs
    #expect(storedInBackground.contains("item-0"))
    #expect(storedInBackground.isDisjoint(with: ["item-2", "item-3"]))

    harness.lifecycle.simulateForeground()
    _ = await awaitCondition(
      "the rest derived", until: { await harness.records.storedIDs.count == items.count })

    // item-0 completed before the suspension and is never derived again.
    let calls = await harness.deriver.calls.map(\.itemID)
    #expect(calls.filter { $0 == "item-0" }.count == 1)
    #expect(Set(calls) == Set(items.map(\.itemID)))
  }

  @Test("an item without cached bytes is skipped and retried on the next trigger")
  func missingBytesRetry() async {
    let item = Self.item("item-0")
    let harness = Harness(items: [item], itemIDsWithoutBytes: ["item-0"])
    let backfill = harness.makeBackfill()

    // No explicit trigger: subscribing to `conditions.changes` replays the current snapshot, as
    // production does, and that is the first trigger. A second one here would race it and, with
    // the item still unsaved, add an attempt.
    _ = await awaitCondition("first attempt", until: { await harness.deriver.calls.count == 1 })
    _ = await awaitCondition("the run ends", until: { backfill.isRunning == false })
    #expect(await harness.records.storedIDs.isEmpty)

    await harness.deriver.provideBytes(for: "item-0")
    harness.coverPasses.yield(())
    _ = await awaitCondition(
      "retried after the cover pass", until: { await harness.records.storedIDs == ["item-0"] })
    #expect(await harness.deriver.calls.count == 2)
  }

  @Test("a trigger during a run does not start a second one")
  func triggerDuringRunCoalesces() async {
    let items = (0..<3).map { Self.item("item-\($0)") }
    let harness = Harness(items: items, blockedItemIDs: ["item-0"])
    let backfill = harness.makeBackfill()

    backfill.trigger()
    _ = await awaitCondition("item-0 in flight", until: { await harness.deriver.started.contains("item-0") })
    backfill.trigger()
    harness.coverPasses.yield(())
    await Task.yield()
    await harness.deriver.unblockAll()

    _ = await awaitCondition(
      "all derived", until: { await harness.records.storedIDs.count == items.count })
    _ = await awaitCondition("the run ends", until: { backfill.isRunning == false })
    #expect(await harness.deriver.highWaterMark == 1)
    #expect(await harness.deriver.calls.count == items.count)
  }

  @Test("Low Power Mode pauses the run and leaving it resumes")
  func lowPowerPauses() async {
    let items = (0..<2).map { Self.item("item-\($0)") }
    let harness = Harness(items: items, lowPowerMode: true)
    let backfill = harness.makeBackfill()

    backfill.trigger()
    await Task.yield()
    await Task.yield()
    #expect(await harness.deriver.calls.isEmpty)

    _ = await awaitCondition(
      "the run observes the conditions", until: { harness.conditions.subscriberCount > 0 })
    harness.conditions.simulateChange(isLowPowerMode: false)
    _ = await awaitCondition(
      "derived after Low Power Mode ends",
      until: { await harness.records.storedIDs.count == items.count })
  }

  @Test("a serious thermal state stops the run before the next item")
  func thermalStateStops() async {
    let items = (0..<3).map { Self.item("item-\($0)") }
    let harness = Harness(items: items, blockedItemIDs: ["item-0"])
    let backfill = harness.makeBackfill()

    backfill.trigger()
    _ = await awaitCondition("item-0 in flight", until: { await harness.deriver.started.contains("item-0") })
    harness.thermal.isConstrained = true
    await harness.deriver.unblockAll()
    _ = await awaitCondition("the run stops", until: { backfill.isRunning == false })
    #expect(await harness.deriver.calls.map(\.itemID) == ["item-0"])

    harness.thermal.isConstrained = false
    backfill.trigger()
    _ = await awaitCondition(
      "the rest derived", until: { await harness.records.storedIDs.count == items.count })
  }

  // MARK: - Fixtures

  nonisolated static let scope = ArtworkAccountScope("scope")

  nonisolated static func item(
    _ id: String, revision: ArtworkRevision = .unversioned
  ) -> CoverPaletteBackfill.Item {
    CoverPaletteBackfill.Item(
      itemID: id,
      key: ArtworkKey(
        accountScope: scope, itemID: id, variant: .libraryThumbnail(pixelWidth: 132),
        revision: revision))
  }

  nonisolated static func record(
    for item: CoverPaletteBackfill.Item, identity: String? = nil, evidence: Bool = true
  ) -> CoverPaletteRecord {
    CoverPaletteRecord(
      itemId: item.itemID,
      artworkKey: identity ?? CoverPaletteWriter.recordIdentity(for: item.key),
      accentHue: nil,
      accentSaturation: nil,
      accentBrightness: nil,
      clusterWeight: evidence ? 0 : nil,
      averageRed: evidence ? 0.2 : nil,
      averageGreen: evidence ? 0.3 : nil,
      averageBlue: evidence ? 0.4 : nil,
      extractedAt: Date())
  }
}

@MainActor
private final class Harness {
  let items: [CoverPaletteBackfill.Item]
  let records = FakeCoverPaletteRecordStoring()
  let deriver: BackfillDeriver
  let lifecycle = FakeAppLifecycle()
  let conditions: FakeNetworkConditions
  let thermal = BackfillThermal()
  let coverPasses: AsyncStream<Void>.Continuation
  private let coverPassStream: AsyncStream<Void>

  init(
    items: [CoverPaletteBackfill.Item],
    blockedItemIDs: Set<String> = [],
    itemIDsWithoutBytes: Set<String> = [],
    lowPowerMode: Bool = false
  ) {
    self.items = items
    deriver = BackfillDeriver(
      records: records, blocked: blockedItemIDs, withoutBytes: itemIDsWithoutBytes)
    conditions = FakeNetworkConditions(isLowPowerMode: lowPowerMode)
    (coverPassStream, coverPasses) = AsyncStream<Void>.makeStream()
  }

  func makeBackfill() -> CoverPaletteBackfill {
    let items = items
    let deriver = deriver
    let thermal = thermal
    return CoverPaletteBackfill(
      items: { items },
      service: CoverPaletteService(recordStore: records),
      save: { item in try await deriver.derive(item) },
      lifecycle: lifecycle,
      conditions: conditions,
      isThermallyConstrained: { thermal.isConstrained },
      coverPassCompletions: coverPassStream)
  }
}

/// Stands in for `CoverPaletteService.save`: writes a current row unless the item has no bytes,
/// optionally holding an item until released so a test can act while it is in flight.
private actor BackfillDeriver {
  private let records: FakeCoverPaletteRecordStoring
  private var blocked: Set<String>
  private var withoutBytes: Set<String>
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var active = 0
  private(set) var highWaterMark = 0
  private(set) var calls: [CoverPaletteBackfill.Item] = []
  private(set) var started: Set<String> = []

  init(records: FakeCoverPaletteRecordStoring, blocked: Set<String>, withoutBytes: Set<String>) {
    self.records = records
    self.blocked = blocked
    self.withoutBytes = withoutBytes
  }

  func derive(_ item: CoverPaletteBackfill.Item) async throws {
    calls.append(item)
    started.insert(item.itemID)
    active += 1
    highWaterMark = max(highWaterMark, active)
    defer { active -= 1 }
    if blocked.contains(item.itemID) {
      await withCheckedContinuation { waiters.append($0) }
    }
    try Task.checkCancellation()
    guard withoutBytes.contains(item.itemID) == false else { return }
    try await records.upsert(CoverPaletteBackfillTests.record(for: item))
  }

  func unblockAll() {
    blocked.removeAll()
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }

  func provideBytes(for itemID: String) {
    withoutBytes.remove(itemID)
  }
}

nonisolated private final class BackfillThermal: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isConstrained: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}
