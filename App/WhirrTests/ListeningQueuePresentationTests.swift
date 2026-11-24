import SwiftUI
import Testing

@testable import Whirr

/// The listening queue sheet's presentation policy: style, detents, transition and glass fallback.
/// Each is a pure function of horizontal size class or an accessibility flag. Like
/// `AdaptiveListLayoutTests`, no view is constructed in this suite.
@Suite("Listening queue presentation")
struct ListeningQueuePresentationTests {

  // MARK: - Style

  @Test("compact horizontal size class resolves to a sheet")
  func compactResolvesSheet() {
    #expect(ListeningQueuePresentation.style(horizontalSizeClass: .compact) == .sheet)
  }

  @Test("an unknown (nil) horizontal size class resolves to a sheet")
  func unknownResolvesSheet() {
    #expect(ListeningQueuePresentation.style(horizontalSizeClass: nil) == .sheet)
  }

  @Test("regular horizontal size class resolves to a form sheet, not a popover (A2)")
  func regularResolvesFormSheet() {
    #expect(ListeningQueuePresentation.style(horizontalSizeClass: .regular) == .formSheet)
  }

  // MARK: - Detents

  @Test("the compact sheet offers medium and large detents, starting at medium")
  func sheetDetentsAreMediumAndLarge() {
    #expect(ListeningQueuePresentation.detents(for: .sheet) == [.medium, .large])
  }

  @Test("the regular-width form sheet offers no resizable detents")
  func formSheetHasNoDetents() {
    #expect(ListeningQueuePresentation.detents(for: .formSheet) == [])
  }

  @Test("regular queue uses fitted form sizing while compact keeps its selected detent")
  func regularQueueUsesFormSizing() {
    #expect(
      SheetViewPresentation.mode(for: .regular, role: .form) == .regularForm)
    #expect(ListeningQueuePresentation.style(horizontalSizeClass: .regular) == .formSheet)
    #expect(ListeningQueuePresentation.detents(for: .formSheet).isEmpty)
  }
}
