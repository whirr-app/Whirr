import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite("RSS all-feeds refresh")
struct RSSFeedRefreshCoordinatorTests {
  @Test("refresh uses the typed RSS source identity encoding")
  func refreshUsesTypedRSSIdentityEncoding() async throws {
    let feedID: Int64 = 42
    let child = makeRecordingRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [feedID]),
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true))

    _ = await coordinator.run(.foreground)

    guard let received = child.refreshedItemIDs.first else {
      Issue.record("The refreshing fake did not receive an item id")
      return
    }
    let expectedItemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
    #expect(received == expectedItemID)
    guard let decoded = PodcastSourceIdentity(itemId: received) else {
      Issue.record("The refreshing fake received an item id that does not decode")
      return
    }
    #expect(decoded.source == .rss(feedId: feedID))
  }

  @Test("foreground refresh is feed-bounded and isolates one feed failure")
  func foregroundBudgetAndFailureIsolation() async {
    let candidates = StubRSSRefreshCandidates(feedIDs: [1, 2, 3])
    let child = makeRecordingRefresh(failingFeedIDs: [1])
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: candidates,
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      policies: .init(
        foreground: .init(maxFeedsPerPass: 2, maximumDuration: .seconds(5)),
        background: .init(maxFeedsPerPass: 1, maximumDuration: .seconds(1))))

    let result = await coordinator.run(.foreground)

    #expect(child.refreshedItemIDs == ["rss:1", "rss:2"])
    #expect(result == .init(attemptedCount: 2, succeededCount: 1, failedCount: 1, hitFeedBudget: true))
  }

  @Test("low power and constrained paths gate the pass before the feed query")
  func networkConditionsGateBeforeCandidates() async {
    for network in [
      FakeNetworkConditions(isLowPowerMode: true),
      FakeNetworkConditions(isConstrainedOrCellular: true),
    ] {
      let candidates = StubRSSRefreshCandidates(feedIDs: [1])
      let child = makeRecordingRefresh()
      let coordinator = RSSFeedRefreshCoordinator(
        candidates: candidates,
        refreshing: child,
        networkConditions: network,
        nativeSubscriptions: makeNativePreference(enabled: true))

      #expect(await coordinator.run(.foreground) == .gated)
      #expect(await candidates.fetchCount == 0)
      #expect(await candidates.attempts.isEmpty)
      #expect(child.refreshedItemIDs.isEmpty)
    }
  }

  @Test("concurrent callers coalesce onto one pass")
  func concurrentCallersCoalesce() async {
    let candidates = StubRSSRefreshCandidates(feedIDs: [1])
    let child = makeSuspendedRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: candidates,
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true))

    async let first = coordinator.run(.foreground)
    await child.gate.waitUntilParked()
    async let second = coordinator.run(.foreground)
    child.gate.release(.success(.complete))

    let results = await [first, second]
    #expect(results[0] == results[1])
    #expect(await candidates.fetchCount == 1)
    #expect(child.calls.count == 1)
    #expect(await coordinator.joinedFlightCount == 1)
  }

  @Test("cancelling the only caller cancels its internal flight")
  func soleCallerCancellationCancelsInternalFlight() async {
    let child = ControlledCancellationRSSRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]),
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true))
    let caller = Task { await coordinator.run(.foreground) }
    await child.waitUntilEntered()

    caller.cancel()
    let cancellation = await awaitCondition(
      "the last waiter's cancellation reaches the child refresh", recordingIssue: false
    ) {
      await child.observedCancellation
    }
    if cancellation.isObserved == false { await child.release() }

    #expect(cancellation.isObserved)
    #expect(await caller.value == .gated)
  }

  @Test("cancelling one coalesced caller preserves the shared flight")
  func coalescedCallerCancellationPreservesSharedFlight() async {
    let child = ControlledCancellationRSSRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]),
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true))
    let first = Task { await coordinator.run(.foreground) }
    await child.waitUntilEntered()
    let second = Task { await coordinator.run(.foreground) }
    _ = await awaitCondition("the second caller joins the active flight") {
      await coordinator.joinedFlightCount == 1
    }

    first.cancel()
    await child.release()

    #expect(await first.value == .gated)
    #expect(await second.value.succeededCount == 1)
    #expect(await child.cancellationCount == 0)
    #expect(await child.callCount == 1)
  }

  @Test("an explicitly cancelled flight cannot be rejoined or clear its replacement")
  func cancelledFlightIsNotJoinableAndCannotClearReplacement() async {
    let child = SequencedHoldingRSSRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]),
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true))
    let oldCaller = Task { await coordinator.run(.foreground) }
    await child.waitUntilCallCount(1)

    await coordinator.cancel(.foreground)
    let replacement = Task { await coordinator.run(.foreground) }
    let replacementStarted = await awaitCondition(
      "a replacement flight starts before the cancelled flight returns", recordingIssue: false
    ) {
      await child.callCount == 2
    }
    #expect(replacementStarted.isObserved)

    guard replacementStarted.isObserved else {
      await child.release(call: 1)
      _ = await oldCaller.value
      _ = await replacement.value
      return
    }

    await child.release(call: 1)
    _ = await oldCaller.value
    let joinsBefore = await coordinator.joinedFlightCount
    let replacementJoiner = Task { await coordinator.run(.foreground) }
    _ = await awaitCondition("a third caller joins the replacement flight") {
      await coordinator.joinedFlightCount == joinsBefore + 1
    }

    #expect(await child.callCount == 2)
    await child.release(call: 2)
    #expect(await replacement.value.succeededCount == 1)
    #expect(await replacementJoiner.value.succeededCount == 1)
  }

  @Test("the background deadline cooperatively cancels before another feed starts")
  func backgroundDeadlineCancelsBetweenFeeds() async {
    let candidates = StubRSSRefreshCandidates(feedIDs: [1, 2, 3])
    let child = CancellationObservingRSSRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: candidates,
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      policies: .init(
        foreground: .init(maxFeedsPerPass: 20, maximumDuration: .seconds(5)),
        background: .init(maxFeedsPerPass: 2, maximumDuration: .milliseconds(20))))

    let result = await coordinator.run(.background)
    let cancellation = await awaitCondition(
      "the expired pass cancellation reaches the in-progress child", recordingIssue: false
    ) {
      await child.observedCancellation
    }

    #expect(result.timedOut)
    #expect(result.attemptedCount == 0)
    #expect(await child.calls == ["rss:1"])
    #expect(cancellation.isObserved)
    // The cut-off feed was stamped before its fetch, so the next pass starts behind it; the
    // feed the deadline never reached keeps its place.
    #expect(await candidates.attempts == [1])
  }

  @Test("a failed attempt stamp still refreshes the feed")
  func failedStampStillRefreshes() async {
    let candidates = StubRSSRefreshCandidates(feedIDs: [1, 2], failsToRecordAttempts: true)
    let child = makeRecordingRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: candidates,
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true))

    let result = await coordinator.run(.foreground)

    #expect(child.refreshedItemIDs == ["rss:1", "rss:2"])
    #expect(result.succeededCount == 2)
  }

  @Test("each attempt is stamped with the injected clock before its refresh")
  func attemptsAreStampedBeforeRefresh() async {
    let stampedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let candidates = StubRSSRefreshCandidates(feedIDs: [1, 2])
    let child = makeRecordingRefresh(failingFeedIDs: [1])
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: candidates,
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      now: { stampedAt })

    _ = await coordinator.run(.foreground)

    #expect(await candidates.attempts == [1, 2])
    #expect(await candidates.attemptDates == [stampedAt, stampedAt])
  }

  @Test("the deadline includes candidate loading")
  func deadlineIncludesCandidateLoading() async {
    let candidates = SuspendedRSSRefreshCandidates(feedIDs: [1])
    let child = makeRecordingRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: candidates,
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      policies: .init(
        foreground: .init(maxFeedsPerPass: 20, maximumDuration: .milliseconds(20)),
        background: .init(maxFeedsPerPass: 4, maximumDuration: .milliseconds(20))))
    let result = RSSRefreshResultRecorder()
    let caller = Task { await result.record(coordinator.run(.foreground)) }
    await candidates.waitUntilEntered()

    let returned = await awaitCondition(
      "the refresh returns while candidate loading remains suspended", recordingIssue: false
    ) {
      await result.value != nil
    }
    let cancelled = await awaitCondition(
      "candidate loading observes the expired pass cancellation", recordingIssue: false
    ) {
      await candidates.observedCancellation
    }
    await candidates.release()
    await caller.value

    #expect(returned.isObserved)
    #expect(cancelled.isObserved)
    #expect(await result.value?.timedOut == true)
    #expect(child.refreshedItemIDs.isEmpty)
  }

  @Test("a cancellation-insensitive child cannot hold the pass past its deadline")
  func cancellationInsensitiveChildCannotHoldPastDeadline() async {
    let child = DeadlineIgnoringRSSRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]),
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      policies: .init(
        foreground: .init(maxFeedsPerPass: 20, maximumDuration: .milliseconds(20)),
        background: .init(maxFeedsPerPass: 4, maximumDuration: .milliseconds(20))))
    let result = RSSRefreshResultRecorder()
    let caller = Task { await result.record(coordinator.run(.foreground)) }
    await child.waitUntilEntered()

    let returned = await awaitCondition(
      "the refresh returns while its cancelled child remains suspended", recordingIssue: false
    ) {
      await result.value != nil
    }
    let cancelled = await awaitCondition(
      "the suspended child observes cancellation", recordingIssue: false
    ) {
      await child.observedCancellation
    }
    await child.release()
    await caller.value

    #expect(returned.isObserved)
    #expect(cancelled.isObserved)
    #expect(await result.value?.timedOut == true)
    #expect(await child.callCount == 1)
  }

  @Test("a held notification scheduler is compensated after the background deadline")
  func backgroundDeadlineCompensatesLateNotificationCommit() async {
    let ledger = HeldNotificationLedger()
    let scheduler = HeldNotificationScheduler()
    let completion = RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler)
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]),
      refreshing: makeRecordingRefresh(),
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      notificationIntent: FakeRSSNotificationIntentReading(enabled: true),
      backgroundCompletion: completion,
      policies: .init(
        foreground: .init(maxFeedsPerPass: 20, maximumDuration: .seconds(5)),
        background: .init(maxFeedsPerPass: 4, maximumDuration: .milliseconds(500))))
    let result = RSSRefreshResultRecorder()
    let caller = Task { await result.record(coordinator.run(.background)) }
    await scheduler.waitUntilScheduleEntered()

    let returned = await awaitCondition(
      "the background pass returns while notification scheduling remains held", recordingIssue: false
    ) {
      await result.value != nil
    }
    #expect(returned.isObserved)
    #expect(await result.value?.timedOut == true)
    #expect(await scheduler.committedRequestCount == 0)

    await scheduler.releaseSchedule()
    let compensated = await awaitCondition(
      "the late notification commit is cancelled after the expired pass", recordingIssue: false
    ) {
      let state = await scheduler.commitState
      return state.committedCount == 1 && state.pendingCount == 0
    }
    await caller.value

    #expect(compensated.isObserved)
    #expect(await ledger.markedRequestIDs.isEmpty)
  }

  @Test("disabled native subscriptions disarm every trigger")
  func disabledPreferenceDisarmsEveryTrigger() async {
    for trigger in RSSFeedRefreshTrigger.allCases {
      let candidates = StubRSSRefreshCandidates(feedIDs: [1])
      let child = makeRecordingRefresh()
      let coordinator = RSSFeedRefreshCoordinator(
        candidates: candidates,
        refreshing: child,
        networkConditions: FakeNetworkConditions(),
        nativeSubscriptions: makeNativePreference(enabled: false))

      #expect(await coordinator.run(trigger) == .gated)
      #expect(await candidates.fetchCount == 0)
      #expect(await candidates.attempts.isEmpty)
      #expect(child.refreshedItemIDs.isEmpty)
    }
  }

  @Test("background classification and completion stay inside the existing pass")
  func notificationWorkUsesBackgroundPass() async {
    let child = ContextRecordingRSSRefresh()
    let completion = RecordingBackgroundCompletion()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]), refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      notificationIntent: FakeRSSNotificationIntentReading(enabled: true),
      backgroundCompletion: completion)

    _ = await coordinator.run(.background)

    #expect(await child.contexts.map(\.source) == [.background])
    #expect(await child.contexts.map(\.globalEnabled) == [true])
    #expect(await completion.count == 1)
  }

  @Test("an overnight pass is bounded by its own budget, not the background one")
  func overnightUsesItsOwnBudget() async {
    let child = makeRecordingRefresh()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1, 2, 3, 4]),
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      policies: .init(
        foreground: .init(maxFeedsPerPass: 1, maximumDuration: .seconds(5)),
        background: .init(maxFeedsPerPass: 1, maximumDuration: .seconds(5)),
        overnight: .init(maxFeedsPerPass: 3, maximumDuration: .seconds(5))))

    let result = await coordinator.run(.overnight)

    #expect(child.refreshedItemIDs == ["rss:1", "rss:2", "rss:3"])
    #expect(result == .init(attemptedCount: 3, succeededCount: 3, failedCount: 0, hitFeedBudget: true))
  }

  @Test("the default overnight budget is wider than the background one")
  func overnightDefaultIsWiderThanBackground() {
    let overnight = RSSFeedRefreshPassPolicy.overnight
    let background = RSSFeedRefreshPassPolicy.background
    #expect(overnight.maxFeedsPerPass > background.maxFeedsPerPass)
    #expect(overnight.maximumDuration > background.maximumDuration)
    #expect(RSSFeedRefreshPolicies().policy(for: .overnight) == overnight)
  }

  @Test("an overnight pass classifies and completes as a system-scheduled pass")
  func overnightDeliversLikeBackground() async {
    let child = ContextRecordingRSSRefresh()
    let completion = RecordingBackgroundCompletion()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]), refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      notificationIntent: FakeRSSNotificationIntentReading(enabled: true),
      backgroundCompletion: completion)

    _ = await coordinator.run(.overnight)

    #expect(await child.contexts.map(\.source) == [.background])
    #expect(await child.contexts.map(\.globalEnabled) == [true])
    #expect(await completion.count == 1)
  }

  @Test("foreground never invokes notification delivery")
  func foregroundDoesNotDeliver() async {
    let completion = RecordingBackgroundCompletion()
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: StubRSSRefreshCandidates(feedIDs: [1]), refreshing: ContextRecordingRSSRefresh(),
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      notificationIntent: FakeRSSNotificationIntentReading(enabled: true),
      backgroundCompletion: completion)
    _ = await coordinator.run(.foreground)
    #expect(await completion.count == 0)
  }

  /// Ordering by last success leaves feeds that always fail at the head of every bounded pass, so
  /// a four-feed background pass never reaches the rest.
  @Test("permanently failing feeds rotate behind a healthy feed within two passes")
  func failingFeedsDoNotStarveTheBackgroundBudget() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    var failing: [Int64] = []
    for name in ["a", "b", "c", "d"] {
      failing.append(try await Self.subscribe(store, name))
    }
    let healthy = try await Self.subscribe(store, "e")
    let yesterday = Date().addingTimeInterval(-86_400)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET lastRefreshedAt = ? WHERE id = ?", arguments: [yesterday, healthy])
    }
    let child = StoreBackedRSSRefresh(store: store, failingFeedIDs: Set(failing))
    let coordinator = RSSFeedRefreshCoordinator(
      candidates: store,
      refreshing: child,
      networkConditions: FakeNetworkConditions(),
      nativeSubscriptions: makeNativePreference(enabled: true),
      policies: .init(background: .init(maxFeedsPerPass: 4, maximumDuration: .seconds(30))))

    let first = await coordinator.run(.background)
    #expect(await child.attempted == failing)
    #expect(first.succeededCount == 0)

    let second = await coordinator.run(.background)
    #expect(await child.attempted.dropFirst(4).contains(healthy))
    #expect(second.succeededCount == 1)
    let refreshedAt = try #require(try await store.fetchFeed(feedId: healthy)?.lastRefreshedAt)
    #expect(refreshedAt > yesterday)
  }

  private static func subscribe(_ store: RSSFeedStore, _ name: String) async throws -> Int64 {
    try await store.subscribe(
      feedURL: URL(string: "https://example.test/\(name).xml")!, title: name, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }
}

/// Records each refresh and fails the named feeds every time.
private func makeRecordingRefresh(failingFeedIDs: Set<Int64> = []) -> FakePodcastRefreshing {
  let refresh = FakePodcastRefreshing()
  for feedID in failingFeedIDs {
    refresh.stub(.failure(RSSRefreshTestError.failed), itemID: "rss:\(feedID)")
  }
  return refresh
}

/// Parks every refresh until the test releases the gate.
private func makeSuspendedRefresh() -> FakePodcastRefreshing {
  let refresh = FakePodcastRefreshing()
  refresh.gate.hold()
  return refresh
}

/// A preference whose observation ends at once, as a device with no change to report.
private func makeNativePreference(enabled: Bool) -> FakeNativePodcastSubscriptionsReading {
  let preference = FakeNativePodcastSubscriptionsReading(enabled: enabled)
  preference.finishObservations()
  return preference
}

// Kept: it writes through the real store inside `refresh`, a per-call hook that
// `FakePodcastRefreshing` does not have.
/// Fails the named feeds every time; refreshes any other feed the way a 304 does, through the
/// store, so the real candidate order sees the outcome.
actor StoreBackedRSSRefresh: PodcastRefreshing {
  private let store: RSSFeedStore
  private let failingFeedIDs: Set<Int64>
  private(set) var attempted: [Int64] = []

  init(store: RSSFeedStore, failingFeedIDs: Set<Int64>) {
    self.store = store
    self.failingFeedIDs = failingFeedIDs
  }

  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    let feedID = try #require(PodcastSourceIdentity(itemId: itemID)?.rssFeedId)
    attempted.append(feedID)
    guard failingFeedIDs.contains(feedID) == false else { throw RSSRefreshTestError.failed }
    try await store.applyChannelMetadata(
      feedId: feedID, title: nil, author: nil, synopsis: nil, language: nil, artworkURL: nil,
      refreshedAt: Date())
    return .complete
  }
}

private actor StubRSSRefreshCandidates: RSSFeedRefreshCandidateProviding {
  let feedIDs: [Int64]
  private let failsToRecordAttempts: Bool
  private(set) var fetchCount = 0
  private(set) var attempts: [Int64] = []
  private(set) var attemptDates: [Date] = []

  init(feedIDs: [Int64], failsToRecordAttempts: Bool = false) {
    self.feedIDs = feedIDs
    self.failsToRecordAttempts = failsToRecordAttempts
  }

  func refreshFeedIDs() async throws -> [Int64] {
    fetchCount += 1
    return feedIDs
  }

  func recordRefreshAttempt(feedID: Int64, at date: Date) async throws {
    if failsToRecordAttempts { throw RSSRefreshTestError.failed }
    attempts.append(feedID)
    attemptDates.append(date)
  }
}

private actor SuspendedRSSRefreshCandidates: RSSFeedRefreshCandidateProviding {
  private let feedIDs: [Int64]
  // Cancellation is only observed, never a release: the call stays parked until the test says so.
  private nonisolated let gate = TestGate<Void>(
    label: "SuspendedRSSRefreshCandidates refreshFeedIDs", ignoresCancellation: true)
  private(set) var observedCancellation = false

  init(feedIDs: [Int64]) {
    self.feedIDs = feedIDs
    gate.hold()
  }

  func refreshFeedIDs() async throws -> [Int64] {
    await withTaskCancellationHandler {
      await gate.pass()
    } onCancel: {
      Task { await self.recordCancellation() }
    }
    return feedIDs
  }

  func recordRefreshAttempt(feedID _: Int64, at _: Date) async throws {}

  func waitUntilEntered() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.releaseParked()
  }

  private func recordCancellation() {
    observedCancellation = true
  }
}

// Kept: it records that an in-flight refresh saw cancellation, which `FakePodcastRefreshing` does
// not expose.
private actor CancellationObservingRSSRefresh: PodcastRefreshing {
  private(set) var calls: [String] = []
  private(set) var observedCancellation = false

  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    calls.append(itemID)
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      observedCancellation = true
      throw error
    }
    return .complete
  }
}

// Kept: it holds a refresh that ignores cancellation and records that it was cancelled;
// `FakePodcastRefreshing.gate` is made without `ignoresCancellation` and records no cancellation.
private actor DeadlineIgnoringRSSRefresh: PodcastRefreshing {
  private nonisolated let gate = TestGate<Void>(
    label: "DeadlineIgnoringRSSRefresh refresh", ignoresCancellation: true)
  private(set) var callCount = 0
  private(set) var observedCancellation = false

  init() {
    gate.hold()
  }

  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    _ = itemID
    callCount += 1
    await withTaskCancellationHandler {
      await gate.pass()
    } onCancel: {
      Task { await self.recordCancellation() }
    }
    return .complete
  }

  func waitUntilEntered() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.releaseParked()
  }

  private func recordCancellation() {
    observedCancellation = true
  }
}

private actor RSSRefreshResultRecorder {
  private(set) var value: RSSFeedRefreshPassResult?

  func record(_ value: RSSFeedRefreshPassResult) {
    self.value = value
  }
}

// Kept: it counts cancellations of the in-flight refresh and releases itself on cancel, which
// `FakePodcastRefreshing` does not expose.
private actor ControlledCancellationRSSRefresh: PodcastRefreshing {
  // The release on cancel is `cancelAndRelease`, so the gate itself ignores cancellation.
  private nonisolated let gate = TestGate<Void>(
    label: "ControlledCancellationRSSRefresh refresh", ignoresCancellation: true)
  private(set) var callCount = 0
  private(set) var cancellationCount = 0

  var observedCancellation: Bool { cancellationCount > 0 }

  init() {
    gate.hold()
  }

  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    _ = itemID
    callCount += 1
    await withTaskCancellationHandler {
      await gate.pass()
    } onCancel: {
      Task { await self.cancelAndRelease() }
    }
    try Task.checkCancellation()
    return .complete
  }

  func waitUntilEntered() async {
    await gate.waitUntilParked()
  }

  func release() {
    resumeAll()
  }

  private func cancelAndRelease() {
    cancellationCount += 1
    resumeAll()
  }

  private func resumeAll() {
    gate.releaseParked()
  }
}

// Kept: its held refreshes must survive cancellation until released by call number;
// `FakePodcastRefreshing.gate` is made without `ignoresCancellation`.
private actor SequencedHoldingRSSRefresh: PodcastRefreshing {
  private var gates: [Int: TestGate<Void>] = [:]
  private(set) var callCount = 0

  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    _ = itemID
    callCount += 1
    await gate(for: callCount).pass()
    return .complete
  }

  private func gate(for call: Int) -> TestGate<Void> {
    if let existing = gates[call] { return existing }
    let gate = TestGate<Void>(
      label: "SequencedHoldingRSSRefresh call \(call)", ignoresCancellation: true)
    gate.hold()
    gates[call] = gate
    return gate
  }

  func waitUntilCallCount(_ count: Int) async {
    _ = await awaitCondition("child refresh call count reaches \(count)") {
      self.callCount >= count
    }
  }

  func release(call: Int) {
    gate(for: call).release()
  }
}

private enum RSSRefreshTestError: Error {
  case failed
}

private actor HeldNotificationLedger: RSSNotificationLedgerAccess {
  private let candidate = RSSNotificationCandidate(
    feedID: 1, identityKey: "late", showTitle: "Show", episodeTitle: "Episode",
    publishedAt: Date(timeIntervalSince1970: 1_000))
  private(set) var markedRequestIDs: [String] = []

  func eligibleCandidates(globalEnabled: Bool, now: Date, limit: Int) async throws
    -> [RSSNotificationCandidate]
  {
    _ = globalEnabled
    _ = now
    return limit > 0 ? [candidate] : []
  }

  func markScheduled(
    _ candidates: [RSSNotificationCandidate], requestID: String
  ) async throws -> Int {
    markedRequestIDs.append(requestID)
    return candidates.count
  }
}

private actor HeldNotificationScheduler: RSSLocalNotificationScheduling {
  private nonisolated let gate = TestGate<Void>(
    label: "HeldNotificationScheduler schedule", ignoresCancellation: true)
  private var pendingRequestIDs: Set<String> = []
  private(set) var committedRequestCount = 0

  init() {
    gate.hold()
  }

  var commitState: (committedCount: Int, pendingCount: Int) {
    (committedRequestCount, pendingRequestIDs.count)
  }

  func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus { .allowed }

  func schedule(_ request: RSSNotificationRequest) async throws {
    await gate.pass()
    committedRequestCount += 1
    pendingRequestIDs.insert(request.identifier)
  }

  func cancel(requestIDs: [String]) async {
    pendingRequestIDs.subtract(requestIDs)
  }

  func waitUntilScheduleEntered() async {
    await gate.waitUntilParked()
  }

  func releaseSchedule() {
    gate.releaseParked()
  }
}

// Kept: it reads the task-local discovery context inside `refresh`, a per-call hook that
// `FakePodcastRefreshing` does not have.
private actor ContextRecordingRSSRefresh: PodcastRefreshing {
  private(set) var contexts: [RSSNotificationDiscoveryContext] = []
  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    _ = itemID
    if let context = RSSNotificationDiscoveryScope.context { contexts.append(context) }
    return .complete
  }
}

private actor RecordingBackgroundCompletion: RSSBackgroundRefreshCompleting {
  private(set) var count = 0
  func completeBackgroundRefresh(now: Date) async {
    _ = now
    count += 1
  }
}
