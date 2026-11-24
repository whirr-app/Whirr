import AppModel
import Observation

/// One multiselect screen's selection, its pending confirmation, and the guarded run of one batch
/// with the shared ending. Edit mode, eligibility, copy and target building stay with the screen,
/// which passes them in as closures because its `actions` and `playback` are environment values.
@MainActor @Observable
final class BatchSelectionController<ID: Hashable, Action: Equatable> {
  struct Pending {
    let action: Action
    let ids: Set<ID>
  }

  var selected: Set<ID> = []
  private(set) var isPerforming = false
  private(set) var pending: Pending?

  /// Drops the request while a batch runs or when nothing is eligible. Otherwise holds it for the
  /// screen's confirmation alert, or hands it straight to `run`.
  func request(
    _ action: Action, eligibleIDs: Set<ID>, requiresConfirmation: Bool,
    run: (Action, Set<ID>) -> Void
  ) {
    guard !isPerforming, !eligibleIDs.isEmpty else { return }
    if requiresConfirmation {
      pending = Pending(action: action, ids: eligibleIDs)
    } else {
      run(action, eligibleIDs)
    }
  }

  /// The alert's Confirm. The request is cleared before it runs, so the alert is gone when the
  /// batch starts.
  func confirmPending(run: (Action, Set<ID>) -> Void) {
    guard let pending else { return }
    self.pending = nil
    run(pending.action, pending.ids)
  }

  func cancelPending() {
    pending = nil
  }

  /// Resolves the IDs now, so eligibility is re-checked when a confirmed request runs. The error
  /// is dismissed even when nothing is left to run. Returns the batch's task, or `nil` when no
  /// batch started.
  @discardableResult
  func perform(
    ids: () -> [ID],
    dismissError: () -> Void,
    batch: @escaping @MainActor ([ID]) async -> Set<ID>,
    exitEditMode: @escaping @MainActor () -> Void
  ) -> Task<Void, Never>? {
    guard !isPerforming else { return nil }
    let resolved = ids()
    return start(isEmpty: resolved.isEmpty, dismissError: dismissError, exitEditMode: exitEditMode) {
      await batch(resolved)
    }
  }

  /// The `ItemActionsModel.performBatch` form: runs the targets in the order given and maps the
  /// targets that succeeded back to their row IDs.
  @discardableResult
  func perform(
    targets: () -> [(ID, ItemBatchTarget)],
    dismissError: () -> Void,
    batch: @escaping @MainActor ([ItemBatchTarget]) async -> Set<ItemBatchTarget>,
    exitEditMode: @escaping @MainActor () -> Void
  ) -> Task<Void, Never>? {
    guard !isPerforming else { return nil }
    let pairs = targets()
    return start(isEmpty: pairs.isEmpty, dismissError: dismissError, exitEditMode: exitEditMode) {
      let succeeded = await batch(pairs.map(\.1))
      return Set(pairs.filter { succeeded.contains($0.1) }.map(\.0))
    }
  }

  private func start(
    isEmpty: Bool,
    dismissError: () -> Void,
    exitEditMode: @escaping @MainActor () -> Void,
    work: @escaping @MainActor () async -> Set<ID>
  ) -> Task<Void, Never>? {
    dismissError()
    guard !isEmpty else { return nil }
    isPerforming = true
    return Task {
      let succeeded = await work()
      isPerforming = false
      // Applied to the selection as it stands now, so a row deselected mid-run stays deselected.
      let ending = SelectionBatchEnding.apply(selection: selected, succeeded: succeeded)
      selected = ending.selection
      if ending.exitsEditMode { exitEditMode() }
    }
  }
}
