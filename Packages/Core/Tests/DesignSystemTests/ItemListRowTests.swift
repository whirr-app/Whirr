import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Item list row")
@MainActor
struct ItemListRowTests {

  @Test("title and subtitle are separate rows so badges do not compete for title width")
  func titleAndSubtitleAreSeparateRows() {
    let row = ItemListRow(title: "The Heiress of Linn Hagh", author: "Karen Charlton") {
      Color.clear
    } progress: {
      Image(systemName: "checkmark.circle.fill")
        .frame(width: RowBadgeStyle.iconSlotSize, height: RowBadgeStyle.iconSlotSize)
    }

    #expect(hStackCount(in: row) == 2)
    #expect(layoutTypeName(in: row).contains("_FlexFrameLayout"))
    #expect(row.author == "Karen Charlton")
    #expect(RowBadgeStyle.iconSlotSize <= WhirrMetric.minimumTouchTarget)
  }

  @Test("a taller status glyph does not move the subtitle away from the title")
  func statusGlyphKeepsSubtitleTopAligned() {
    let row = ItemListRow(title: "Catching Fire", author: "Suzanne Collins") {
      Color.clear
    } progress: {
      Image(systemName: "checkmark.circle.fill")
        .frame(width: RowBadgeStyle.iconSlotSize, height: RowBadgeStyle.iconSlotSize)
    }

    #expect(row.subtitleStatusAlignment == .top)
  }

  @Test("subtitle row keeps badges when author is absent")
  func subtitleRowKeepsBadgesWithoutAuthor() {
    let row = ItemListRow(title: "Untitled", author: nil) {
      Color.clear
    } progress: {
      Image(systemName: "arrow.down.circle.fill")
        .frame(width: RowBadgeStyle.iconSlotSize, height: RowBadgeStyle.iconSlotSize)
    }

    #expect(hStackCount(in: row) == 2)
    #expect(row.author == nil)
  }

  private func layoutTypeName<Cover: View, Progress: View>(in row: ItemListRow<Cover, Progress>) -> String {
    String(reflecting: type(of: row.body))
  }

  private func hStackCount<Cover: View, Progress: View>(in row: ItemListRow<Cover, Progress>) -> Int {
    let typeName = layoutTypeName(in: row)
    return typeName.components(separatedBy: "HStack").count - 1
  }
}
