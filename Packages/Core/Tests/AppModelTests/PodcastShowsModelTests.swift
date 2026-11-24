import Foundation
import Observation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `PodcastShowsModel` combines the ordering store's already-ordered snapshot with the aggregate
/// sync status. It never re-sorts a custom order and never optimistically claims a durable order
/// it failed to write.
@Suite(.timeLimit(.minutes(1))) struct PodcastShowsModelTests {

  @MainActor
  @Test("a snapshot plus a settled sync status is the loaded state, in the store's order")
  func snapshotAndSyncStatusProduceLoadedState() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)
    let snapshot = Self.snapshot(.custom, ["b", "a"])

    library.pushSyncStatus(Self.settled)
    ordering.push(snapshot)
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded(snapshot))
    #expect(model.shows.map(\.serverItemId) == ["b", "a"])
    #expect(model.sortMode == .custom)
  }

  @MainActor
  @Test("a running sync is the partially-synced state, still in the store's order")
  func runningSyncProducesPartiallySyncedOrderedShows() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)
    let snapshot = Self.snapshot(.custom, ["c", "a", "b"])

    ordering.push(snapshot)
    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))
    await waitUntil { model.state != .loading }

    #expect(model.state == .partiallySynced(snapshot))
    #expect(model.shows.map(\.serverItemId) == ["c", "a", "b"])
  }

  @MainActor
  @Test("an incomplete last run with a freshly synced cache keeps the loaded state")
  func recentFailedSyncKeepsLoadedState() async {
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000_000))
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(
      ordering: ordering, library: library, clock: clock, staleAfter: 3600)
    let snapshot = Self.snapshot(.alphabetical, ["a"])

    ordering.push(snapshot)
    library.pushSyncStatus(
      LibrarySyncStatus(
        isRunning: false, lastRunIncomplete: true,
        lastCompletedAt: Date(timeIntervalSince1970: 1_000_000 - 30)))
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded(snapshot))
    #expect(model.isEditingAllowed)
  }

  @MainActor
  @Test("an incomplete last run over a stale cache is the stale-offline state, still editable")
  func oldFailedSyncProducesStaleOfflineState() async {
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000_000))
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(
      ordering: ordering, library: library, clock: clock, staleAfter: 60)
    let snapshot = Self.snapshot(.custom, ["a", "b"])

    ordering.push(snapshot)
    library.pushSyncStatus(
      LibrarySyncStatus(
        isRunning: false, lastRunIncomplete: true,
        lastCompletedAt: Date(timeIntervalSince1970: 1_000_000 - 120)))
    await waitUntil { model.state != .loading }

    #expect(model.state == .staleOffline(snapshot))
    #expect(model.isEditingAllowed)
    #expect(model.state.copyText.isEmpty == false)

    library.pushSyncStatus(Self.settled)
    await waitUntil { model.state == .loaded(snapshot) }
  }

  @MainActor
  @Test("an empty snapshot with no sync activity is the empty state, with copy")
  func emptySnapshotProducesEmptyState() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)

    library.pushSyncStatus(Self.settled)
    ordering.push(Self.snapshot(.alphabetical, []))
    await waitUntil { model.state != .loading }

    #expect(model.state == .empty)
    #expect(model.shows.isEmpty)
    #expect(model.sortMode == .alphabetical)
    #expect(model.state.copyText.isEmpty == false)
    #expect(model.isEditingAllowed == false)
  }

  @MainActor
  @Test("preview truncates to the requested count without reordering")
  func previewReturnsAtMostRequestedCountInOrder() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)

    library.pushSyncStatus(Self.settled)
    ordering.push(Self.snapshot(.custom, ["d", "c", "b", "a"]))
    await waitUntil { model.state != .loading }

    #expect(model.preview(limit: 2).map(\.serverItemId) == ["d", "c"])
    #expect(model.preview(limit: 10).map(\.serverItemId) == ["d", "c", "b", "a"])
    #expect(model.preview(limit: 0).isEmpty)
  }

  @MainActor
  @Test("a move relocates the named id, not an index, and clamps its destination")
  func moveReordersByStableItemIdentity() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)

    library.pushSyncStatus(Self.settled)
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.state != .loading }

    await model.move(itemID: "c", to: 0)
    #expect(ordering.replacements == [["c", "a", "b"]])

    await model.move(itemID: "a", to: 99)
    #expect(ordering.replacements.last == ["b", "c", "a"])

    await model.move(itemID: "missing", to: 0)
    #expect(ordering.replacements.count == 2, "an unknown id is not a reorder")
  }

  @MainActor
  @Test("a move persists the whole visible sequence, not just the moved id")
  func movePersistsFullVisibleSequence() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)

    library.pushSyncStatus(Self.settled)
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c", "d"]))
    await waitUntil { model.state != .loading }

    await model.move(itemID: "b", to: 2)

    #expect(ordering.replacements == [["a", "c", "b", "d"]])
  }

  @MainActor
  @Test("a move that lands where it started writes nothing")
  func movingToSamePositionIsNoOp() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)

    library.pushSyncStatus(Self.settled)
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.state != .loading }

    await model.move(itemID: "b", to: 1)
    await model.apply(order: ["a", "b", "c"])

    #expect(ordering.replacements.isEmpty)
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("a failed move leaves the observed order alone and surfaces an action error")
  func failedMoveKeepsObservedOrderAndShowsActionError() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)
    let snapshot = Self.snapshot(.alphabetical, ["a", "b", "c"])

    library.pushSyncStatus(Self.settled)
    ordering.push(snapshot)
    await waitUntil { model.state != .loading }

    ordering.failNext()
    await model.move(itemID: "c", to: 0)

    #expect(model.state == .loaded(snapshot))
    #expect(model.shows.map(\.serverItemId) == ["a", "b", "c"])
    #expect(model.actionErrorMessage == PodcastShowsCopy.reorderFailed)

    model.dismissActionError()
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("editing is unavailable while the aggregate sync is running")
  func partiallySyncedStateDisablesEditing() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)

    ordering.push(Self.snapshot(.custom, ["a", "b"]))
    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: nil))
    await waitUntil { model.state != .loading }

    #expect(model.isEditingAllowed == false)

    library.pushSyncStatus(Self.settled)
    await waitUntil { model.isEditingAllowed }
  }

  @MainActor
  @Test("reset forwards to the ordering store exactly once")
  func resetForwardsToStore() async {
    let ordering = FakePodcastShowOrdering()
    let model = Self.makeModel(ordering: ordering, library: FakeLibraryReading())

    await model.resetToAlphabetical()

    #expect(ordering.resetCount == 1)
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("a failed reset surfaces its own action error")
  func failedResetShowsActionError() async {
    let ordering = FakePodcastShowOrdering()
    let model = Self.makeModel(ordering: ordering, library: FakeLibraryReading())

    ordering.failNext()
    await model.resetToAlphabetical()

    #expect(model.actionErrorMessage == PodcastShowsCopy.resetFailed)
  }

  /// The generation gate: cancelling a stream task stops new suspension but cannot un-deliver a
  /// value already in flight, so a superseded subscription's late emission must be dropped.
  @MainActor
  @Test("a superseded subscription's late snapshot never lands")
  func lateObservationFromSupersededGenerationIsIgnored() async {
    let ordering = FakePodcastShowOrdering()
    let library = FakeLibraryReading()
    let model = Self.makeModel(ordering: ordering, library: library)
    let recorder = PodcastShowsStateRecorder(model)
    let first = Self.snapshot(.custom, ["a", "b"])

    library.pushSyncStatus(Self.settled)
    ordering.push(first)
    await waitUntil { model.state == .loaded(first) }

    model.subscribe()
    ordering.push(Self.snapshot(.custom, ["stale"]), toStream: 0)
    library.pushSyncStatus(Self.settled)

    let second = Self.snapshot(.custom, ["b", "a"])
    ordering.push(second)
    await waitUntil { model.state == .loaded(second) }
    await waitUntil { recorder.states.contains(.loaded(second)) }

    #expect(
      recorder.states.contains(.loaded(Self.snapshot(.custom, ["stale"]))) == false,
      "the superseded snapshot must not reach the new generation")
    #expect(model.state == .loaded(second))
  }

  @MainActor
  @Test("refresh forwards to SyncCoordinating.refresh()")
  func refreshForwardsToSyncCoordinator() async {
    let sync = FakeSyncCoordinating()
    let model = Self.makeModel(
      ordering: FakePodcastShowOrdering(), library: FakeLibraryReading(), sync: sync)

    await model.refresh()

    #expect(sync.refreshCount == 1)
  }

  // MARK: - Helpers

  private static let settled = LibrarySyncStatus(
    isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date())

  @MainActor
  private static func makeModel(
    ordering: FakePodcastShowOrdering,
    library: FakeLibraryReading,
    sync: FakeSyncCoordinating = FakeSyncCoordinating(),
    clock: any SyncClock = SystemSyncClock(),
    staleAfter: TimeInterval = AppModelStaleness.defaultStaleAfter
  ) -> PodcastShowsModel {
    PodcastShowsModel(
      ordering: ordering, library: library, sync: sync, clock: clock, staleAfter: staleAfter)
  }

  private static func snapshot(
    _ mode: PodcastShowSortMode, _ ids: [String]
  ) -> PodcastShowsSnapshot {
    PodcastShowsSnapshot(
      mode: mode,
      shows: ids.map {
        ItemSummary(
          serverItemId: $0, mediaKind: "podcast", title: "Show \($0)", author: nil,
          durationSeconds: nil, category: .podcast)
      })
  }
}

/// Keeps one continuation per `observeShows()` call so a test can emit from a subscription the
/// model has already superseded, the only way the generation gate is observable.
private final class FakePodcastShowOrdering: PodcastShowOrdering, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncStream<PodcastShowsSnapshot>.Continuation] = []
  private var recordedReplacements: [[String]] = []
  private var resets = 0
  private var shouldFail = false

  var replacements: [[String]] { lock.withLock { recordedReplacements } }
  var resetCount: Int { lock.withLock { resets } }

  func failNext() { lock.withLock { shouldFail = true } }

  func observeShows() -> AsyncStream<PodcastShowsSnapshot> {
    AsyncStream { continuation in
      lock.withLock { continuations.append(continuation) }
    }
  }

  /// `toStream` indexes the `observeShows()` calls, oldest first; the default emits from the
  /// newest subscription.
  func push(_ snapshot: PodcastShowsSnapshot, toStream index: Int? = nil) {
    let continuation = lock.withLock { () -> AsyncStream<PodcastShowsSnapshot>.Continuation? in
      guard let index else { return continuations.last }
      return continuations.indices.contains(index) ? continuations[index] : nil
    }
    continuation?.yield(snapshot)
  }

  func replaceCustomOrder(itemIDs: [String]) async throws {
    try lock.withLock {
      if shouldFail {
        shouldFail = false
        throw ShowOrderingFixtureError.failed
      }
      recordedReplacements.append(itemIDs)
    }
  }

  func resetToAlphabetical() async throws {
    try lock.withLock {
      if shouldFail {
        shouldFail = false
        throw ShowOrderingFixtureError.failed
      }
      resets += 1
    }
  }
}

private enum ShowOrderingFixtureError: Error { case failed }

@MainActor
private final class PodcastShowsStateRecorder {
  private let model: PodcastShowsModel
  private(set) var states: [PodcastShowsModel.State]

  init(_ model: PodcastShowsModel) {
    self.model = model
    states = [model.state]
    observe()
  }

  private func observe() {
    withObservationTracking {
      _ = model.state
    } onChange: { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.states.append(self.model.state)
        self.observe()
      }
    }
  }
}
