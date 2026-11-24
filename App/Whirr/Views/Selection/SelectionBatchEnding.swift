/// How every multiselect screen's selection ends after an `ItemActionsModel.performBatch`.
///
/// What succeeded is deselected; a target that failed or was skipped, and a selected row the
/// action never applied to, stays selected so the selection left behind is exactly what to retry.
/// Edit mode ends once nothing is selected.
nonisolated enum SelectionBatchEnding {
  static func apply<ID: Hashable>(
    selection: Set<ID>, succeeded: Set<ID>
  ) -> (selection: Set<ID>, exitsEditMode: Bool) {
    let remaining = selection.subtracting(succeeded)
    return (remaining, remaining.isEmpty)
  }
}
