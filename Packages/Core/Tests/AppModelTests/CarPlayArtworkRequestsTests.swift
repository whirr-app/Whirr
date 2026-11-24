import Foundation
import TestSupport
import Testing

@testable import AppModel

/// The car's bounded thumbnail working set.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CarPlayArtworkRequestsTests {
  @Test func loadedThumbnailIsDeliveredThenHeld() async {
    let loader = Loader()
    let requests = loader.requests()
    let delivered = Delivered()
    #expect(requests.show([Self.key("a")], deliver: delivered.record).isEmpty)
    await loader.finish("a")
    await waitUntil("thumbnail delivered") { delivered.ids == ["a"] }

    #expect(requests.show([Self.key("a")], deliver: delivered.record) == [Self.key("a"): "a"])
    #expect(loader.started == ["a"])
  }

  @Test func rowWithoutArtworkAsksForNothing() {
    let loader = Loader()
    let requests = loader.requests()
    let none = CarPlayArtworkKey(generation: 1, reference: .none, pixelSize: 90, isDark: false)
    #expect(requests.show([none]) { _, _ in }.isEmpty)
    #expect(requests.inFlightCount == 0)
  }

  @Test func sameThumbnailIsRequestedOnceWhileItLoads() async {
    let loader = Loader()
    let requests = loader.requests()
    requests.show([Self.key("a")]) { _, _ in }
    requests.show([Self.key("a")]) { _, _ in }
    await loader.finish("a")
    #expect(loader.started == ["a"])
  }

  @Test func leavingAPageCancelsItsRequestsAndDropsLateResults() async {
    let loader = Loader()
    let requests = loader.requests()
    let delivered = Delivered()
    requests.show([Self.key("a")], deliver: delivered.record)
    await loader.begun("a")
    requests.show([Self.key("b")], deliver: delivered.record)
    #expect(requests.inFlightCount == 1)

    await loader.finish("a")
    await loader.finish("b")
    await waitUntil("visible thumbnail delivered") { delivered.ids == ["b"] }
    #expect(requests.cachedCount == 1)
  }

  @Test func differentSizeAppearanceOrGraphIsADifferentThumbnail() {
    let base = Self.key("a")
    let variants = [
      CarPlayArtworkKey(generation: 2, reference: base.reference, pixelSize: 90, isDark: false),
      CarPlayArtworkKey(generation: 1, reference: base.reference, pixelSize: 180, isDark: false),
      CarPlayArtworkKey(generation: 1, reference: base.reference, pixelSize: 90, isDark: true),
    ]
    #expect(Set(variants + [base]).count == 4)
  }

  @Test func workingSetIsBoundedAndKeepsWhatIsOnScreen() async {
    let loader = Loader()
    let requests = loader.requests(capacity: 2)
    requests.show([Self.key("a"), Self.key("b")]) { _, _ in }
    await loader.finish("a")
    await loader.finish("b")
    await waitUntil("first page held") { requests.cachedCount == 2 }

    requests.show([Self.key("b"), Self.key("c")]) { _, _ in }
    await loader.finish("c")
    await waitUntil("second page loaded") { requests.inFlightCount == 0 }

    #expect(requests.cachedCount == 2)
    #expect(Set(requests.show([Self.key("b"), Self.key("c")]) { _, _ in }.values) == ["b", "c"])
  }

  @Test func purgeReleasesEverythingAndDeliversNothingLater() async {
    let loader = Loader()
    let requests = loader.requests()
    let delivered = Delivered()
    requests.show([Self.key("a"), Self.key("b")], deliver: delivered.record)
    await loader.finish("a")
    await waitUntil("first thumbnail delivered") { delivered.ids == ["a"] }
    await loader.begun("b")

    requests.purge()
    #expect(requests.cachedCount == 0)
    #expect(requests.inFlightCount == 0)

    await loader.finish("b")
    await awaitQuiescence("late thumbnail dropped") { "\(delivered.ids)|\(requests.cachedCount)" }
    #expect(delivered.ids == ["a"])
    #expect(requests.cachedCount == 0)
  }

  @Test func failedLoadHoldsNothingAndCanBeAskedAgain() async {
    let loader = Loader()
    let requests = loader.requests()
    requests.show([Self.key("a")]) { _, _ in }
    await loader.finish("a", failing: true)
    await waitUntil("failed load finished") { requests.inFlightCount == 0 }
    #expect(requests.cachedCount == 0)

    requests.show([Self.key("a")]) { _, _ in }
    await loader.begun("a", count: 2)
  }

  @Test func failedLoadIsTriedAgainWhileItsRowStaysOnScreen() async {
    let loader = Loader()
    let requests = loader.requests(retryDelays: [.seconds(1), .seconds(5)])
    let delivered = Delivered()
    requests.show([Self.key("a")], deliver: delivered.record)
    await loader.finish("a", failing: true)
    await loader.begun("a", count: 2)
    await loader.finish("a")
    await waitUntil("retried thumbnail delivered") { delivered.ids == ["a"] }

    #expect(loader.slept == [.seconds(1)])
    #expect(requests.inFlightCount == 0)
  }

  @Test func retriesStopWhenTheDelaysRunOut() async {
    let loader = Loader()
    let requests = loader.requests(retryDelays: [.seconds(1)])
    requests.show([Self.key("a")]) { _, _ in }
    await loader.finish("a", failing: true)
    await loader.begun("a", count: 2)
    await loader.finish("a", failing: true)
    await waitUntil("retries exhausted") { requests.inFlightCount == 0 }

    #expect(loader.started == ["a", "a"])
    #expect(requests.cachedCount == 0)
  }

  @Test func leavingThePageWhileWaitingToRetryAsksForNothingMore() async {
    let loader = Loader()
    let requests = CarPlayArtworkRequests<String>(capacity: 8, retryDelays: [.seconds(600)]) { key in
      await loader.load(key)
    }
    requests.show([Self.key("a")]) { _, _ in }
    await loader.finish("a", failing: true)
    requests.show([]) { _, _ in }
    #expect(requests.inFlightCount == 0)

    await awaitQuiescence("no retry after leaving") { "\(loader.started)" }
    #expect(loader.started == ["a"])
  }

  // MARK: - Fixtures

  private static func key(_ id: String) -> CarPlayArtworkKey {
    CarPlayArtworkKey(
      generation: 1, reference: .item(id: id, updatedAt: nil), pixelSize: 90, isDark: false)
  }

  @MainActor private final class Delivered {
    private(set) var ids: [String] = []
    func record(_ key: CarPlayArtworkKey, _ image: String) { ids.append(image) }
  }

  /// Loads that finish when the test says so. The image is the item's id.
  @MainActor private final class Loader {
    private(set) var startedIDs: [String] = []
    private var gates: [String: TestGate<String?>] = [:]

    private(set) var slept: [Duration] = []

    /// Retry waits are recorded and return at once.
    func requests(capacity: Int = 8, retryDelays: [Duration] = []) -> CarPlayArtworkRequests<String> {
      CarPlayArtworkRequests(
        capacity: capacity, retryDelays: retryDelays, sleep: { [self] in await noteSleep($0) },
        load: { [self] key in await load(key) })
    }

    var started: [String] { startedIDs }

    private func noteSleep(_ delay: Duration) { slept.append(delay) }

    func load(_ key: CarPlayArtworkKey) async -> String? {
      guard case .item(let id, _) = key.reference else { return nil }
      startedIDs.append(id)
      return await gate(for: id).pass(otherwise: { nil })
    }

    /// A load runs to completion regardless of cancellation, so a cancelled one stays parked.
    private func gate(for id: String) -> TestGate<String?> {
      if let existing = gates[id] { return existing }
      let gate = TestGate<String?>(label: "Loader load of \(id)", ignoresCancellation: true)
      gate.hold()
      gates[id] = gate
      return gate
    }

    func begun(_ id: String, count: Int = 1) async {
      await waitUntil("load of \(id) began") { self.startedIDs.filter { $0 == id }.count >= count }
    }

    func finish(_ id: String, failing: Bool = false) async {
      let gate = gate(for: id)
      await gate.waitUntilParked()
      gate.releaseParked(failing ? nil : id)
    }
  }
}
