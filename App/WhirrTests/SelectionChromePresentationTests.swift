import Foundation
import Testing

@testable import Whirr

@Suite struct SelectionChromePresentationTests {

  @Test func zeroSelectionUsesEachScreenInvitation() {
    #expect(
      SelectionChromePresentation.Screen.allCases.map(\.invitation) == [
        "Select Titles", "Select Downloads", "Select Saved", "Select Episodes", "Select Items",
        "Select Items",
      ])
    for screen in SelectionChromePresentation.Screen.allCases {
      #expect(
        SelectionChromePresentation.title(screen: screen, selectedCount: 0, isWorking: false)
          == screen.invitation)
    }
  }

  @Test func oneAndManySelectionsUseTheSelectedCount() {
    for screen in SelectionChromePresentation.Screen.allCases {
      #expect(
        SelectionChromePresentation.title(screen: screen, selectedCount: 1, isWorking: false)
          == "1 Selected")
      #expect(
        SelectionChromePresentation.title(screen: screen, selectedCount: 27, isWorking: false)
          == "27 Selected")
    }
  }

  @Test func workingTitleWinsOverEveryCountIncludingZero() {
    for screen in SelectionChromePresentation.Screen.allCases {
      #expect(
        SelectionChromePresentation.title(screen: screen, selectedCount: 0, isWorking: true)
          == "Working…")
      #expect(
        SelectionChromePresentation.title(screen: screen, selectedCount: 27, isWorking: true)
          == "Working…")
    }
  }

  @Test func selectAllTitleReflectsWhetherEverythingIsSelected() {
    #expect(
      SelectionChromePresentation.selectAllTitle(isEverythingSelected: true) == "Deselect All")
    #expect(
      SelectionChromePresentation.selectAllTitle(isEverythingSelected: false) == "Select All")
  }

  @Test func actionSlotsUseTheCanonicalOrder() {
    #expect(
      SelectionChromePresentation.ActionSlot.allCases == [
        .download, .markAsFinished, .more, .destructive,
      ])
  }

  @Test func renderedSlotsPreserveCanonicalOrderForEverySubset() {
    let allSlots = SelectionChromePresentation.ActionSlot.allCases

    #expect(SelectionChromePresentation.renderedSlots(present: []) == [])
    #expect(
      SelectionChromePresentation.renderedSlots(present: [.download, .more])
        == [.download, .more])
    #expect(
      SelectionChromePresentation.renderedSlots(present: Set(allSlots)) == allSlots)
  }

  /// The entry control uses one word on every screen. "Select Saved" would repeat the noun the
  /// navigation bar already shows.
  @Test func everyScreenEntersSelectionUnderTheSameLabel() {
    for screen in SelectionChromePresentation.Screen.allCases {
      #expect(screen.invitation.hasPrefix(SelectionChromePresentation.entryTitle))
      #expect(screen.invitation != SelectionChromePresentation.entryTitle)
    }
  }

  /// The prefix lives here, not on `SelectionToolbar`, so the entry control and the selection bar
  /// root their identifiers in the same place. A screen then has one spelling of its own name.
  @Test func everyScreenRootsItsSelectionIdentifiersOnce() {
    let prefixes = SelectionChromePresentation.Screen.allCases.map(\.accessibilityIdentifierPrefix)
    #expect(prefixes == ["library", "downloads", "saved", "podcast", "homeMore", "libraryCollection"])
    #expect(Set(prefixes).count == prefixes.count)
  }

  @Test func omittingDownloadDoesNotMoveAnyOtherSlot() {
    #expect(
      SelectionChromePresentation.renderedSlots(
        present: [.markAsFinished, .more, .destructive])
        == [.markAsFinished, .more, .destructive])
  }
}
