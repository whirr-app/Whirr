/// Semantic accessibility identifiers for the Saved for Later screen. The string values are an
/// external contract for UI automation, so they stay fixed even when the Swift names move.
///
/// Rows keep `HomeAccessibilityID.moreItemRowPrefix`/`morePodcastRowPrefix`, as on Home More.
enum SavedAccessibilityID {
  /// Saved for Later's own `MediaFilterPicker`.
  static let filterPicker = "saved.filterPicker"

  static let selectionDownload = "saved.selection.download"
  static let selectionActions = "saved.selection.actions"
  static let selectionRemove = "saved.selection.remove"
}
