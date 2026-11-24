import Foundation
import PlayerCore
import Testing

@testable import Whirr

/// Select mode in the chapter sheets: chapters queue in the order tapped, and each chosen row
/// shows its place in that order.
@Suite("Chapter Select mode")
struct ChapterSelectionTests {
  private static let rows = ChapterSelectorPresentation.rows(
    chapters: [
      PlaybackChapter(title: "One", start: 0, end: 100),
      PlaybackChapter(title: "Two", start: 100, end: 200),
      PlaybackChapter(title: "Three", start: 200, end: 300),
    ],
    currentTime: nil, isFinished: false)

  @Test("chosen rows queue in the order tapped, and letting one go renumbers the rest")
  func orderFollowsTaps() {
    var selection = ChapterSelection()
    selection.toggle(Self.rows[2].id)
    selection.toggle(Self.rows[0].id)
    selection.toggle(Self.rows[1].id)

    #expect(selection.rows(in: Self.rows).map(\.title) == ["Three", "One", "Two"])
    #expect(selection.number(of: Self.rows[1].id) == 3)

    selection.toggle(Self.rows[2].id)
    #expect(selection.rows(in: Self.rows).map(\.title) == ["One", "Two"])
    #expect(selection.number(of: Self.rows[0].id) == 1)
    #expect(selection.number(of: Self.rows[2].id) == nil)
  }

  @Test("each chosen row shows its number; an unchosen row an empty circle")
  func indicatorShowsTheOrder() {
    #expect(ChapterSelection.indicatorSymbol(number: nil) == "circle")
    #expect(ChapterSelection.indicatorSymbol(number: 2) == "2.circle.fill")
    #expect(ChapterSelection.indicatorSymbol(number: 50) == "50.circle.fill")
    #expect(ChapterSelection.indicatorSymbol(number: 51) == "checkmark.circle.fill")
    #expect(ChapterSelection.accessibilityValue(number: 2) == "Selected, 2 in order")
    #expect(ChapterSelection.accessibilityValue(number: nil) == "Not selected")
  }

  @Test("the add button counts what it will queue")
  func addLabelCounts() {
    #expect(ChapterSelection.addLabel(count: 0) == "Add to Up Next")
    #expect(ChapterSelection.addLabel(count: 3) == "Add 3 to Up Next")
  }
}
