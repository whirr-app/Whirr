import Foundation
import Testing

@testable import Whirr

/// The shell's accessory gate reads `isSelecting`. This covers the bookkeeping that answers it,
/// without building any view.
@Suite struct SelectionChromeModelTests {

  @MainActor
  @Test func nothingIsSelectingByDefault() {
    #expect(SelectionChromeModel().isSelecting == false)
  }

  @MainActor
  @Test func oneScreenEnteringAndLeavingSelectionTogglesTheFlag() {
    let chrome = SelectionChromeModel()
    let screen = UUID()

    chrome.setSelecting(true, for: screen)
    #expect(chrome.isSelecting)

    chrome.setSelecting(false, for: screen)
    #expect(chrome.isSelecting == false)
  }

  /// A stack can hold more than one selection-capable screen. The accessory must stay down until
  /// the last of them has left edit mode.
  @MainActor
  @Test func theFlagSurvivesUntilEveryScreenHasLeftSelection() {
    let chrome = SelectionChromeModel()
    let first = UUID()
    let second = UUID()

    chrome.setSelecting(true, for: first)
    chrome.setSelecting(true, for: second)
    chrome.setSelecting(false, for: first)
    #expect(chrome.isSelecting)

    chrome.setSelecting(false, for: second)
    #expect(chrome.isSelecting == false)
  }

  /// The reporter re-reports on every appearance and clears on disappear. Neither repetition may
  /// unbalance the count.
  @MainActor
  @Test func repeatedReportsFromOneScreenAreIdempotent() {
    let chrome = SelectionChromeModel()
    let screen = UUID()

    chrome.setSelecting(true, for: screen)
    chrome.setSelecting(true, for: screen)
    chrome.setSelecting(false, for: screen)
    #expect(chrome.isSelecting == false)

    chrome.setSelecting(false, for: screen)
    #expect(chrome.isSelecting == false)
  }

  /// One screen leaving the hierarchy must not clear another screen's selection.
  @MainActor
  @Test func clearingAnUnknownScreenLeavesOthersSelecting() {
    let chrome = SelectionChromeModel()
    let selecting = UUID()

    chrome.setSelecting(true, for: selecting)
    chrome.setSelecting(false, for: UUID())

    #expect(chrome.isSelecting)
  }
}
