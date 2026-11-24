import SwiftUI

/// The Library root writes its selection entry point into this shell-owned model because the
/// toolbar that renders the control belongs to the shell; a control declared below it cannot be
/// ordered by `rootToolbarTrailingOrder`.
@MainActor @Observable
final class LibrarySelectionEntry {
  var editMode: EditMode = .inactive
  /// Whether the Titles list currently has rows to select. This drives enablement only: the
  /// control's presence is `LibraryShellPresentation.showsSelectionEntry`, decided by the shell
  /// from the browse mode. An empty Titles list therefore dims the control instead of removing it,
  /// matching Downloads, Saved for Later and a show's episode list, and a late update to this
  /// flag dims or undims in place without reflowing the trailing group.
  var hasSelectableRows = false
}
