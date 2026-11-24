import AppModel
import Persistence
import Testing

@testable import Whirr

/// The request → confirm → perform → end sequence every multiselect screen shares. The batch is a
/// closure here, so each case states exactly what the batch reported.
@MainActor @Suite struct BatchSelectionControllerTests {
  private enum Action: Equatable { case confirmed, immediate }
  private typealias Controller = BatchSelectionController<String, Action>

  /// What a `run` closure was handed.
  @MainActor private final class RunLog {
    var calls: [(Action, Set<String>)] = []
    func record(_ action: Action, _ ids: Set<String>) { calls.append((action, ids)) }
  }

  /// What a perform's closures saw, in order.
  @MainActor private final class PerformLog {
    var events: [String] = []
    var batchInput: [String] = []
    var targetInput: [ItemBatchTarget] = []
    var exitCount = 0
    var dismissCount = 0
    var wasPerformingDuringBatch: Bool?
    var innerTask: Task<Void, Never>?
  }

  private static func target(_ itemID: String, episode: String? = nil) -> ItemBatchTarget {
    ItemBatchTarget(
      itemID: itemID, episodeID: episode, category: episode == nil ? .audiobook : .podcast,
      durationSeconds: nil, downloadFormat: nil)
  }

  /// Runs `perform(ids:…)` with a batch that reports `succeeded` and waits for it to end.
  private func perform(
    _ controller: Controller, ids: [String], succeeded: Set<String>, log: PerformLog,
    duringBatch: @escaping @MainActor () -> Void = {}
  ) async {
    let task = controller.perform(
      ids: {
        log.events.append("ids")
        return ids
      },
      dismissError: { log.events.append("dismiss") },
      batch: { input in
        log.events.append("batch")
        log.batchInput = input
        log.wasPerformingDuringBatch = controller.isPerforming
        duringBatch()
        return succeeded
      },
      exitEditMode: { log.exitCount += 1 })
    await task?.value
  }

  // MARK: Request and confirmation

  @Test func requestWhilePerformingDoesNothing() async {
    let controller = Controller()
    let runs = RunLog()
    let log = PerformLog()
    await perform(
      controller, ids: ["a"], succeeded: [], log: log,
      duringBatch: {
        controller.request(.immediate, eligibleIDs: ["a"], requiresConfirmation: false, run: runs.record)
        controller.request(.confirmed, eligibleIDs: ["a"], requiresConfirmation: true, run: runs.record)
      })
    #expect(runs.calls.isEmpty)
    #expect(controller.pending == nil)
  }

  @Test func requestWithNothingEligibleDoesNothing() {
    let controller = Controller()
    let runs = RunLog()
    controller.request(.immediate, eligibleIDs: [], requiresConfirmation: false, run: runs.record)
    controller.request(.confirmed, eligibleIDs: [], requiresConfirmation: true, run: runs.record)
    #expect(runs.calls.isEmpty)
    #expect(controller.pending == nil)
  }

  @Test func requestNeedingConfirmationHoldsItWithoutRunning() {
    let controller = Controller()
    let runs = RunLog()
    controller.request(.confirmed, eligibleIDs: ["a", "b"], requiresConfirmation: true, run: runs.record)
    #expect(runs.calls.isEmpty)
    #expect(controller.pending?.action == .confirmed)
    #expect(controller.pending?.ids == ["a", "b"])
  }

  @Test func requestWithoutConfirmationRunsAtOnce() {
    let controller = Controller()
    let runs = RunLog()
    controller.request(.immediate, eligibleIDs: ["a"], requiresConfirmation: false, run: runs.record)
    #expect(runs.calls.count == 1)
    #expect(runs.calls.first?.0 == .immediate)
    #expect(runs.calls.first?.1 == ["a"])
    #expect(controller.pending == nil)
  }

  /// The confirmation is cleared before the run, so the alert is gone when the batch starts.
  @Test func confirmClearsThePendingRequestThenRunsItsSnapshot() {
    let controller = Controller()
    let runs = RunLog()
    var pendingWasClearedBeforeRun = false
    controller.request(.confirmed, eligibleIDs: ["a", "b"], requiresConfirmation: true, run: runs.record)
    controller.confirmPending { action, ids in
      pendingWasClearedBeforeRun = controller.pending == nil
      runs.record(action, ids)
    }
    #expect(pendingWasClearedBeforeRun)
    #expect(runs.calls.count == 1)
    #expect(runs.calls.first?.0 == .confirmed)
    #expect(runs.calls.first?.1 == ["a", "b"])
    #expect(controller.pending == nil)
  }

  @Test func confirmWithNothingPendingDoesNothing() {
    let controller = Controller()
    let runs = RunLog()
    controller.confirmPending(run: runs.record)
    #expect(runs.calls.isEmpty)
  }

  @Test func cancelClearsThePendingRequest() {
    let controller = Controller()
    let runs = RunLog()
    controller.request(.confirmed, eligibleIDs: ["a"], requiresConfirmation: true, run: runs.record)
    controller.cancelPending()
    #expect(controller.pending == nil)
    #expect(runs.calls.isEmpty)
  }

  // MARK: Perform

  @Test func performWhilePerformingTouchesNothing() async {
    let controller = Controller()
    let inner = PerformLog()
    await perform(
      controller, ids: ["a"], succeeded: [], log: PerformLog(),
      duringBatch: {
        inner.innerTask = controller.perform(
          ids: {
            inner.events.append("ids")
            return ["b"]
          },
          dismissError: { inner.events.append("dismiss") },
          batch: { _ in
            inner.events.append("batch")
            return []
          },
          exitEditMode: { inner.exitCount += 1 })
      })
    #expect(inner.innerTask == nil)
    #expect(inner.events.isEmpty)
    #expect(inner.exitCount == 0)
  }

  /// The error is dismissed even when nothing is left to run, as every screen does today.
  @Test func performWithNoTargetsDismissesTheErrorAndStops() async {
    let controller = Controller()
    controller.selected = ["a"]
    let log = PerformLog()
    await perform(controller, ids: [], succeeded: [], log: log)
    #expect(log.events == ["ids", "dismiss"])
    #expect(controller.isPerforming == false)
    #expect(controller.selected == ["a"])
    #expect(log.exitCount == 0)
  }

  @Test func performResolvesThenDismissesThenRunsTheBatch() async {
    let controller = Controller()
    let log = PerformLog()
    await perform(controller, ids: ["a"], succeeded: ["a"], log: log)
    #expect(log.events == ["ids", "dismiss", "batch"])
  }

  @Test func isPerformingHoldsForTheBatchOnly() async {
    let controller = Controller()
    let log = PerformLog()
    await perform(controller, ids: ["a"], succeeded: [], log: log)
    #expect(log.wasPerformingDuringBatch == true)
    #expect(controller.isPerforming == false)
  }

  @Test func batchReceivesIDsInTheOrderResolved() async {
    let controller = Controller()
    let log = PerformLog()
    await perform(controller, ids: ["c", "a", "b"], succeeded: [], log: log)
    #expect(log.batchInput == ["c", "a", "b"])
  }

  // MARK: Ending

  @Test func fullSuccessClearsTheSelectionAndExitsEditModeOnce() async {
    let controller = Controller()
    controller.selected = ["a", "b"]
    let log = PerformLog()
    await perform(controller, ids: ["a", "b"], succeeded: ["a", "b"], log: log)
    #expect(controller.selected.isEmpty)
    #expect(log.exitCount == 1)
  }

  @Test func partialSuccessKeepsFailuresAndNonTargetsSelected() async {
    let controller = Controller()
    controller.selected = ["ok", "failed", "never-a-target"]
    let log = PerformLog()
    await perform(controller, ids: ["ok", "failed"], succeeded: ["ok"], log: log)
    #expect(controller.selected == ["failed", "never-a-target"])
    #expect(log.exitCount == 0)
  }

  @Test func nothingSucceedingKeepsTheSelection() async {
    let controller = Controller()
    controller.selected = ["a", "b"]
    let log = PerformLog()
    await perform(controller, ids: ["a", "b"], succeeded: [], log: log)
    #expect(controller.selected == ["a", "b"])
    #expect(log.exitCount == 0)
  }

  /// A row the listener deselects while the batch runs stays deselected.
  @Test func endingAppliesToTheSelectionAsItIsWhenTheBatchEnds() async {
    let controller = Controller()
    controller.selected = ["a", "b", "c"]
    let log = PerformLog()
    await perform(
      controller, ids: ["a", "b", "c"], succeeded: ["a"], log: log,
      duringBatch: { controller.selected.remove("b") })
    #expect(controller.selected == ["c"])
  }

  // MARK: The ItemBatchTarget form

  @Test func targetFormMapsSucceededTargetsBackToTheirIDs() async {
    let controller = Controller()
    controller.selected = ["first", "second", "third"]
    let first = Self.target("show", episode: "e1")
    let second = Self.target("show", episode: "e2")
    let third = Self.target("book")
    let log = PerformLog()
    let task = controller.perform(
      targets: { [("first", first), ("second", second), ("third", third)] },
      dismissError: { log.dismissCount += 1 },
      batch: { targets in
        log.targetInput = targets
        return [first, third]
      },
      exitEditMode: { log.exitCount += 1 })
    await task?.value
    #expect(log.dismissCount == 1)
    #expect(log.targetInput == [first, second, third])
    #expect(controller.selected == ["second"])
    #expect(log.exitCount == 0)
  }

  @Test func targetFormWithNoTargetsDismissesTheErrorAndStops() async {
    let controller = Controller()
    controller.selected = ["a"]
    let log = PerformLog()
    let task = controller.perform(
      targets: { [] },
      dismissError: { log.dismissCount += 1 },
      batch: { _ in
        log.events.append("batch")
        return []
      },
      exitEditMode: {})
    #expect(task == nil)
    #expect(log.dismissCount == 1)
    #expect(log.events.isEmpty)
    #expect(controller.selected == ["a"])
  }
}
