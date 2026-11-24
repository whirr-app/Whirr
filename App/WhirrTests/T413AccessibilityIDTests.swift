import Testing

@testable import Whirr

@Suite("Downloads identifiers")
struct ScreenAccessibilityIDTests {
  @Test func selectionIdentifiersArePinned() {
    #expect(ScreenAccessibilityID.storageSelectionRemove == "downloads.selection.remove")
  }

  /// The toolbar derives `all`/`done`/`begin` from the screen's prefix, so the extras must share it.
  @Test func selectionIdentifiersShareTheToolbarPrefix() {
    let root = SelectionChromePresentation.Screen.downloads.accessibilityIdentifierPrefix + ".selection."
    #expect(ScreenAccessibilityID.storageSelectionRemove.hasPrefix(root))
  }
}
