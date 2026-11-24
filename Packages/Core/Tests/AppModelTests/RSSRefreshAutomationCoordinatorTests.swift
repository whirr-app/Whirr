import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite("RSS refresh automation coordinator")
struct RSSRefreshAutomationCoordinatorTests {
  @Test("a committed feed pass runs automatic selection then retention")
  func successfulPassRunsAutomationInOrder() async {
    let events = RSSAutomationEvents()
    let refresh = FakeRSSAutomationRefresh(
      result: .init(
        attemptedCount: 2, succeededCount: 1, failedCount: 1, hitFeedBudget: false),
      events: events)
    let autoDownload = FakeRSSAutoDownloadRunning(events: events)
    let reaper = FakeRSSAutoDownloadReaping(events: events)
    let coordinator = RSSRefreshAutomationCoordinator(
      refresh: refresh, autoDownload: autoDownload, reaper: reaper,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))

    let result = await coordinator.run(.foreground)

    #expect(result.succeededCount == 1)
    #expect(await events.values == ["refresh", "auto-download", "reap"])
  }

  @Test("a gated or wholly failed refresh does not run automation")
  func unsuccessfulPassSkipsAutomation() async {
    let events = RSSAutomationEvents()
    let refresh = FakeRSSAutomationRefresh(
      result: .init(
        attemptedCount: 1, succeededCount: 0, failedCount: 1, hitFeedBudget: false),
      events: events)
    let coordinator = RSSRefreshAutomationCoordinator(
      refresh: refresh, autoDownload: FakeRSSAutoDownloadRunning(events: events),
      reaper: FakeRSSAutoDownloadReaping(events: events),
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))

    _ = await coordinator.run(.background)

    #expect(await events.values == ["refresh"])
  }

  @Test("toggle off disarms the whole pass and re-enable restores it")
  func toggleDisarmsAndRestores() async {
    let events = RSSAutomationEvents()
    let toggle = FakeNativePodcastSubscriptionsReading(enabled: false)
    let coordinator = RSSRefreshAutomationCoordinator(
      refresh: FakeRSSAutomationRefresh(
        result: .init(
          attemptedCount: 1, succeededCount: 1, failedCount: 0, hitFeedBudget: false),
        events: events),
      autoDownload: FakeRSSAutoDownloadRunning(events: events),
      reaper: FakeRSSAutoDownloadReaping(events: events), nativeSubscriptions: toggle)

    #expect(await coordinator.run(.foreground) == .gated)
    #expect(await events.values.isEmpty)

    toggle.stubEnabled(true)
    _ = await coordinator.run(.foreground)
    #expect(await events.values == ["refresh", "auto-download", "reap"])
  }

  @Test("cancellation cascades to refresh and both automation stages")
  func cancellationCascades() async {
    let refresh = FakeRSSAutomationRefresh(result: .gated, events: RSSAutomationEvents())
    let autoDownload = FakeRSSAutoDownloadRunning(events: RSSAutomationEvents())
    let reaper = FakeRSSAutoDownloadReaping(events: RSSAutomationEvents())
    let coordinator = RSSRefreshAutomationCoordinator(
      refresh: refresh, autoDownload: autoDownload, reaper: reaper,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))

    await coordinator.cancel(.background)

    #expect(await refresh.cancellations == [.background])
    #expect(await autoDownload.cancelCount == 1)
    #expect(await reaper.cancelCount == 1)
  }

  @Test("an explicitly cancelled automation flight cannot be rejoined")
  func cancelledAutomationFlightIsNotJoinable() async {
    let refresh = HoldingRSSAutomationRefresh()
    let coordinator = RSSRefreshAutomationCoordinator(
      refresh: refresh, autoDownload: nil, reaper: nil,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    let oldCaller = Task { await coordinator.run(.foreground) }
    await refresh.waitUntilCallCount(1)

    await coordinator.cancel(.foreground)
    let replacement = Task { await coordinator.run(.foreground) }
    let replacementStarted = await awaitCondition(
      "a replacement automation flight starts before the cancelled flight returns",
      recordingIssue: false
    ) {
      await refresh.callCount == 2
    }
    #expect(replacementStarted.isObserved)

    await refresh.releaseAll()
    _ = await oldCaller.value
    _ = await replacement.value
  }

  @Test("a replacement cannot start while downstream cancellation is still in progress")
  func cancellationReentrancyCannotStartReplacement() async {
    let refresh = ReentrantCancellationRSSAutomationRefresh()
    let coordinator = RSSRefreshAutomationCoordinator(
      refresh: refresh, autoDownload: nil, reaper: nil,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    let oldCaller = Task { await coordinator.run(.foreground) }
    await refresh.waitUntilCallCount(1)
    let cancellation = Task { await coordinator.cancel(.foreground) }
    await refresh.waitUntilCancellationEntered()

    #expect(await coordinator.run(.foreground) == .gated)
    #expect(await refresh.callCount == 1)

    await refresh.releaseCancellation()
    await cancellation.value
    await refresh.releaseFirstCall()
    _ = await oldCaller.value
  }

  /// Automation waits for a committed feed, so failing feeds that hold every slot also hold back
  /// automatic downloads.
  @Test("automation runs once rotation reaches a healthy feed behind failing ones")
  func automationFollowsRotationPastFailingFeeds() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    var failing: [Int64] = []
    for name in ["a", "b", "c", "d", "e"] {
      failing.append(
        try await store.subscribe(
          feedURL: URL(string: "https://example.test/\(name).xml")!, title: name, author: nil,
          synopsis: nil, artworkURL: nil, subscribedAt: Date()))
    }
    let healthy = failing.removeLast()
    try await store.applyChannelMetadata(
      feedId: healthy, title: "e", author: nil, synopsis: nil, language: nil, artworkURL: nil,
      refreshedAt: Date().addingTimeInterval(-86_400))
    let toggle = FakeNativePodcastSubscriptionsReading(enabled: true)
    let refresh = RSSFeedRefreshCoordinator(
      candidates: store,
      refreshing: StoreBackedRSSRefresh(store: store, failingFeedIDs: Set(failing)),
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: toggle,
      policies: .init(background: .init(maxFeedsPerPass: 4, maximumDuration: .seconds(30))))
    let events = RSSAutomationEvents()
    let coordinator = RSSRefreshAutomationCoordinator(
      refresh: refresh, autoDownload: FakeRSSAutoDownloadRunning(events: events),
      reaper: FakeRSSAutoDownloadReaping(events: events), nativeSubscriptions: toggle)

    _ = await coordinator.run(.background)
    #expect(await events.values.isEmpty)

    _ = await coordinator.run(.background)
    #expect(await events.values == ["auto-download", "reap"])
  }
}

private actor RSSAutomationEvents {
  private(set) var values: [String] = []
  func append(_ value: String) { values.append(value) }
}

private actor FakeRSSAutomationRefresh: RSSFeedRefreshCoordinating {
  let result: RSSFeedRefreshPassResult
  let events: RSSAutomationEvents
  private(set) var cancellations: [RSSFeedRefreshTrigger] = []

  init(result: RSSFeedRefreshPassResult, events: RSSAutomationEvents) {
    self.result = result
    self.events = events
  }

  func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    await events.append("refresh")
    return result
  }

  func cancel(_ trigger: RSSFeedRefreshTrigger) {
    cancellations.append(trigger)
  }
}

private actor HoldingRSSAutomationRefresh: RSSFeedRefreshCoordinating {
  // A held run completes regardless of cancellation: the coordinator cancels its flight's task.
  private nonisolated let gate = TestGate<Void>(
    label: "HoldingRSSAutomationRefresh run", ignoresCancellation: true)
  private(set) var callCount = 0
  private var releasedCount = 0

  init() { gate.hold() }

  func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    _ = trigger
    callCount += 1
    await gate.pass()
    return .gated
  }

  func cancel(_ trigger: RSSFeedRefreshTrigger) {
    _ = trigger
  }

  func waitUntilCallCount(_ count: Int) async {
    _ = await awaitCondition("automation child call count reaches \(count)") {
      self.callCount >= count
    }
  }

  /// Frees every call made so far, once each has parked, and keeps the gate held for later ones.
  func releaseAll() async {
    let target = callCount - releasedCount
    await gate.waitUntilParked(count: target)
    releasedCount += target
    gate.releaseParked()
  }
}

private actor ReentrantCancellationRSSAutomationRefresh: RSSFeedRefreshCoordinating {
  // Both holds complete regardless of cancellation, as the real calls do.
  private nonisolated let firstCallGate = TestGate<Void>(
    label: "ReentrantCancellationRSSAutomationRefresh first run", ignoresCancellation: true)
  private nonisolated let cancellationGate = TestGate<Void>(
    label: "ReentrantCancellationRSSAutomationRefresh cancel", ignoresCancellation: true)
  private(set) var callCount = 0

  init() {
    firstCallGate.hold()
    cancellationGate.hold()
  }

  func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    _ = trigger
    callCount += 1
    if callCount == 1 {
      await firstCallGate.pass()
    }
    return .init(
      attemptedCount: 1, succeededCount: 1, failedCount: 0, hitFeedBudget: false)
  }

  func cancel(_ trigger: RSSFeedRefreshTrigger) async {
    _ = trigger
    await cancellationGate.pass()
  }

  func waitUntilCallCount(_ count: Int) async {
    _ = await awaitCondition("reentrant automation child call count reaches \(count)") {
      self.callCount >= count
    }
  }

  func waitUntilCancellationEntered() async {
    await cancellationGate.waitUntilParked()
  }

  func releaseCancellation() async {
    await cancellationGate.waitUntilParked()
    cancellationGate.release()
  }

  func releaseFirstCall() async {
    await firstCallGate.waitUntilParked()
    firstCallGate.release()
  }
}

private actor FakeRSSAutoDownloadRunning: PodcastAutoDownloadRunning {
  let events: RSSAutomationEvents
  private(set) var cancelCount = 0
  init(events: RSSAutomationEvents) { self.events = events }
  func run() async { await events.append("auto-download") }
  func cancel() { cancelCount += 1 }
}

private actor FakeRSSAutoDownloadReaping: PodcastAutoDownloadReaping {
  let events: RSSAutomationEvents
  private(set) var cancelCount = 0
  init(events: RSSAutomationEvents) { self.events = events }
  func reap() async { await events.append("reap") }
  func cancel() { cancelCount += 1 }
}
