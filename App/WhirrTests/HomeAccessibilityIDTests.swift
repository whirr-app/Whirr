import AppModel
import Testing

@testable import Whirr

@MainActor
struct HomeAccessibilityIDTests {
  @Test("every Home section has one stable identifier")
  func everySectionHasAStableIdentifier() {
    let identifiers = HomeMoreSection.allCases.map(HomeAccessibilityID.sectionIdentifier(for:))

    #expect(identifiers == HomeAccessibilityID.sectionOrder)
    #expect(Set(identifiers).count == HomeMoreSection.allCases.count)
  }

  @Test("episodes from one podcast have distinct card identifiers")
  func episodeIdentifiersIncludeEpisodeIdentity() {
    let first = HomeAccessibilityID.episodeCardIdentifier(itemID: "show", episodeID: "one")
    let second = HomeAccessibilityID.episodeCardIdentifier(itemID: "show", episodeID: "two")

    #expect(first != second)
    #expect(first == "home.card.show/one")
  }

  @Test("Continue Listening removal has a stable action identifier")
  func continueListeningRemovalHasStableIdentifier() {
    #expect(
      HomeAccessibilityID.removeFromContinueListeningAction
        == "home.action.removeFromContinueListening")
  }

  @Test func selectionIdentifiersArePinned() {
    #expect(HomeAccessibilityID.selectionDownload == "homeMore.selection.download")
    #expect(HomeAccessibilityID.selectionActions == "homeMore.selection.actions")
    #expect(HomeAccessibilityID.selectionRemoveFromShelf == "homeMore.selection.removeFromShelf")
  }

  /// The toolbar derives `all`/`done`/`begin` from the screen's prefix, so the extras must share it.
  @Test func selectionIdentifiersShareTheToolbarPrefix() {
    let root = SelectionChromePresentation.Screen.homeContinue.accessibilityIdentifierPrefix + ".selection."
    for identifier in [
      HomeAccessibilityID.selectionDownload,
      HomeAccessibilityID.selectionActions,
      HomeAccessibilityID.selectionRemoveFromShelf,
    ] {
      #expect(identifier.hasPrefix(root), Comment(rawValue: identifier))
    }
  }
}
