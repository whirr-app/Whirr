import Testing

@testable import Whirr

@Suite("Saved for Later identifiers")
struct SavedAccessibilityIDTests {
  @Test func selectionIdentifiersArePinned() {
    #expect(SavedAccessibilityID.selectionDownload == "saved.selection.download")
    #expect(SavedAccessibilityID.selectionActions == "saved.selection.actions")
    #expect(SavedAccessibilityID.selectionRemove == "saved.selection.remove")
  }

  /// The toolbar derives `all`/`done`/`begin` from the screen's prefix, so the extras must share it.
  @Test func selectionIdentifiersShareTheToolbarPrefix() {
    let root = SelectionChromePresentation.Screen.savedForLater.accessibilityIdentifierPrefix + ".selection."
    for identifier in [
      SavedAccessibilityID.selectionDownload,
      SavedAccessibilityID.selectionActions,
      SavedAccessibilityID.selectionRemove,
    ] {
      #expect(identifier.hasPrefix(root), Comment(rawValue: identifier))
    }
  }
}
