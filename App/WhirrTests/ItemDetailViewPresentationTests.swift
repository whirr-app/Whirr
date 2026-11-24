import Foundation
import SwiftUI
import Testing

@testable import Whirr

@Suite("Item detail sheet presentation")
struct ItemDetailViewPresentationTests {
  /// The Duration row and the "min left" beside the bar describe the same seconds: 230 s read as
  /// "3m" beside "4 min left" before any listening. Both round to the nearest minute.
  @Test("the duration rounds to the nearest minute, as the remainder does")
  func durationRoundsLikeTheRemainder() {
    #expect(ItemDetailViewPresentation.formattedDuration(230) == "4m")
    #expect(ItemDetailViewPresentation.formattedDuration(209) == "3m")
    #expect(ItemDetailViewPresentation.formattedDuration(7_170) == "2h")
    #expect(ItemDetailViewPresentation.formattedDuration(26_760) == "7h 26m")
  }

  @Test("chapter and history sheets share the same width policy")
  func chapterAndHistorySheetsShareTheSameWidthPolicy() {
    let sizeClasses: [UserInterfaceSizeClass?] = [.compact, .regular, nil]
    for sizeClass in sizeClasses {
      let expected: SheetViewPresentation.Mode =
        sizeClass == .regular ? .regularForm : .compactDetents
      #expect(
        SheetViewPresentation.mode(for: sizeClass, role: .form) == expected,
        Comment(rawValue: "size class: \(String(describing: sizeClass))"))
    }
  }
}
