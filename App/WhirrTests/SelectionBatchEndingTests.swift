import Foundation
import Persistence
import Testing

@testable import Whirr

/// One ending on every screen. What succeeded is deselected;
/// what failed, was skipped or was never a target stays selected; edit mode ends once nothing is.
@Suite struct SelectionBatchEndingTests {
  @Test func fullSuccessClearsTheSelectionAndExitsEditMode() {
    let ending = SelectionBatchEnding.apply(selection: ["a", "b"], succeeded: ["a", "b"])
    #expect(ending.selection.isEmpty)
    #expect(ending.exitsEditMode)
  }

  @Test func partialFailureKeepsOnlyWhatFailedSelected() {
    let ending = SelectionBatchEnding.apply(selection: ["a", "b", "c"], succeeded: ["a", "c"])
    #expect(ending.selection == ["b"])
    #expect(ending.exitsEditMode == false)
  }

  @Test func totalFailureKeepsTheWholeSelection() {
    let ending = SelectionBatchEnding.apply(selection: ["a", "b"], succeeded: [])
    #expect(ending.selection == ["a", "b"])
    #expect(ending.exitsEditMode == false)
  }

  @Test func skippedTargetsStaySelected() {
    let ending = SelectionBatchEnding.apply(selection: ["a", "skipped"], succeeded: ["a"])
    #expect(ending.selection == ["skipped"])
    #expect(ending.exitsEditMode == false)
  }

  @Test func selectedRowsTheActionDidNotApplyToStaySelected() {
    let ending = SelectionBatchEnding.apply(selection: ["a", "ineligible"], succeeded: ["a"])
    #expect(ending.selection == ["ineligible"])
    #expect(ending.exitsEditMode == false)
  }

  @Test func anEmptySelectionExitsEditMode() {
    let ending = SelectionBatchEnding.apply(selection: Set<String>(), succeeded: [])
    #expect(ending.selection.isEmpty)
    #expect(ending.exitsEditMode)
  }

  // MARK: - One case per screen

  @Test func savedForLaterKeepsAFailedEpisodeSelected() {
    let saved = SavedShelfIdentity.item(itemID: "book")
    let failed = SavedShelfIdentity.podcastEpisode(itemID: "show", episodeID: "ep")
    let ending = SelectionBatchEnding.apply(selection: [saved, failed], succeeded: [saved])
    #expect(ending.selection == [failed])
    #expect(ending.exitsEditMode == false)
  }

  @Test func homeContinueExitsOnceEveryItemSucceeded() {
    let ending = SelectionBatchEnding.apply(
      selection: ["item-1", "item-2"], succeeded: ["item-1", "item-2"])
    #expect(ending.selection.isEmpty)
    #expect(ending.exitsEditMode)
  }

  /// Exiting on any success would drop selected titles the action never applied to.
  @Test func libraryTitlesStaysInEditModeWithIneligibleTitlesSelected() {
    let ending = SelectionBatchEnding.apply(
      selection: ["downloaded", "not-downloaded"], succeeded: ["downloaded"])
    #expect(ending.selection == ["not-downloaded"])
    #expect(ending.exitsEditMode == false)
  }
}
