import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NativePodcastShowsModelTests {
  @Test func enabledSnapshotLoadsInPersistenceOrderAndPreviews() async {
    let shows = [Self.show(2, "B"), Self.show(1, "A")]
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(mode: .mostRecent, shows: shows)),
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))

    await TestSupport.waitUntil { model.state != .loading }

    #expect(model.shows == shows)
    #expect(model.sortMode == .mostRecent)
    #expect(model.preview(limit: 1) == [shows[0]])
  }

  @Test func disabledPreferenceSuppressesRetainedRows() async {
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(mode: .custom, shows: [Self.show(1, "A")])),
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: false))

    await TestSupport.waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.shows.isEmpty)
  }

  @Test func recoveryProjectionMarksOnlyTheMatchingNativeShow() async {
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(
          mode: .alphabetical, shows: [Self.show(1, "A"), Self.show(2, "B")])),
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true),
      recoveryReading: StaticFeedRecoveryReading(feedIDs: [2]))

    await TestSupport.waitUntil { model.state != .loading }

    #expect(model.needsAttention(itemID: "rss:1") == false)
    #expect(model.needsAttention(itemID: "rss:2"))
    #expect(model.needsAttention(itemID: "server-show") == false)
  }

  @Test func sortingAndOrderingReachTheInjectedBoundary() async {
    let ordering = RecordingNativeOrdering()
    let shows = [Self.show(1, "A"), Self.show(2, "B")]
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(mode: .alphabetical, shows: shows)),
      ordering: ordering,
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    await TestSupport.waitUntil { model.shows.count == 2 }

    await model.setSortMode(.mostRecent)
    await model.move(showID: "rss:1", to: 1)
    await model.resetToAlphabetical()

    #expect(await ordering.modes == [.mostRecent])
    #expect(await ordering.orders == [["rss:2", "rss:1"]])
    #expect(await ordering.resetCount == 1)
  }

  @Test func orderingFailureSurfacesBoundedCopy() async {
    let ordering = RecordingNativeOrdering(fails: true)
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(
          mode: .alphabetical, shows: [Self.show(1, "A")])),
      ordering: ordering,
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    await TestSupport.waitUntil { model.shows.count == 1 }

    await model.setSortMode(.custom)

    #expect(model.actionErrorMessage == NativePodcastShowsCopy.sortFailed)
    model.dismissActionError()
    #expect(model.actionErrorMessage == nil)
  }

  @Test("unfollow exposes one busy show and rejects overlapping work")
  func unfollowBusyStateIsSingleFlight() async {
    let unfollow = ControlledNativePodcastUnfollow(holds: true)
    let ordering = RecordingNativeOrdering()
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(
          mode: .alphabetical, shows: [Self.show(1, "A"), Self.show(2, "B")])),
      ordering: ordering,
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true),
      unfollowing: unfollow)
    await TestSupport.waitUntil { model.shows.count == 2 }

    let first = Task { @MainActor in await model.unfollow(itemID: "rss:1") }
    await unfollow.waitUntilCalled()

    #expect(model.unfollowingItemID == "rss:1")
    #expect(model.isUnfollowing)
    #expect(await model.unfollow(itemID: "rss:2") == false)
    await model.move(showID: "rss:2", to: 0)
    #expect(await unfollow.itemIDs == ["rss:1"])
    #expect(await ordering.orders.isEmpty)

    await unfollow.release()
    #expect(await first.value)
    #expect(model.unfollowingItemID == nil)
    #expect(model.isUnfollowing == false)
  }

  @Test("unfollow failures keep the show visible and use the existing bounded copy")
  func unfollowFailureKeepsObservedShow() async {
    let unfollow = ControlledNativePodcastUnfollow(
      result: .failure(NativePodcastUnfollowError.playbackStopFailed))
    let show = Self.show(1, "A")
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(mode: .alphabetical, shows: [show])),
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true),
      unfollowing: unfollow)
    await TestSupport.waitUntil { model.shows == [show] }

    #expect(await model.unfollow(itemID: show.serverItemId) == false)
    #expect(model.shows == [show])
    #expect(model.actionErrorMessage == PodcastCopy.unsubscribePlaybackStopFailed)
  }

  @Test("feed deletion failure uses unsubscribe copy and clears busy state")
  func unfollowDeletionFailureCopy() async {
    let unfollow = ControlledNativePodcastUnfollow(
      result: .failure(NativePodcastUnfollowError.unsubscribeFailed))
    let show = Self.show(1, "A")
    let model = NativePodcastShowsModel(
      reading: FakeNativePodcastShowsReading(
        snapshot: NativePodcastShowsSnapshot(mode: .alphabetical, shows: [show])),
      subscriptions: FakeNativePodcastSubscriptionsReading(enabled: true),
      unfollowing: unfollow)
    await TestSupport.waitUntil { model.shows == [show] }

    #expect(await model.unfollow(itemID: show.serverItemId) == false)
    #expect(model.actionErrorMessage == PodcastCopy.unsubscribeFailed)
    #expect(model.unfollowingItemID == nil)
  }

  private static func show(_ id: Int64, _ title: String) -> ItemSummary {
    ItemSummary(
      serverItemId: "rss:\(id)", mediaKind: "podcast", title: title, author: nil,
      durationSeconds: nil, progressSeconds: 0, category: .podcast,
      hasReadableEbook: false)
  }
}

private struct StaticFeedRecoveryReading: NativeFeedRecoveryReading {
  let feedIDs: Set<Int64>
  func observeRecoveryFeedIDs() -> AsyncStream<Set<Int64>> {
    AsyncStream { continuation in
      continuation.yield(feedIDs)
      continuation.finish()
    }
  }
  func recoveryRequired(feedID: Int64) async throws -> Bool { feedIDs.contains(feedID) }
}

private enum NativeOrderingTestError: Error { case failed }

private actor RecordingNativeOrdering: NativePodcastShowOrdering {
  private(set) var modes: [NativePodcastShowSortMode] = []
  private(set) var orders: [[String]] = []
  private(set) var resetCount = 0
  let fails: Bool

  init(fails: Bool = false) { self.fails = fails }

  func setSortMode(_ mode: NativePodcastShowSortMode) async throws {
    if fails { throw NativeOrderingTestError.failed }
    modes.append(mode)
  }

  func replaceCustomOrder(showIDs: [String]) async throws {
    if fails { throw NativeOrderingTestError.failed }
    orders.append(showIDs)
  }

  func resetToAlphabetical() async throws {
    if fails { throw NativeOrderingTestError.failed }
    resetCount += 1
  }
}

private actor ControlledNativePodcastUnfollow: NativePodcastUnfollowing {
  private nonisolated let calls = CallRecorder<String>(
    label: "ControlledNativePodcastUnfollow calls")
  // Stays parked on task cancellation, as the unfollow it stands in for runs to completion.
  private nonisolated let gate = TestGate<Void>(
    label: "ControlledNativePodcastUnfollow unfollow", ignoresCancellation: true)
  var itemIDs: [String] { calls.calls }
  private let result: Result<Void, Error>

  init(result: Result<Void, Error> = .success(()), holds: Bool = false) {
    self.result = result
    if holds { gate.hold() }
  }

  func unfollow(itemID: String) async throws {
    calls.record(itemID)
    await gate.pass()
    try result.get()
  }

  func waitUntilCalled() async {
    await calls.waitUntil(count: 1)
  }

  func release() {
    gate.release()
  }
}
