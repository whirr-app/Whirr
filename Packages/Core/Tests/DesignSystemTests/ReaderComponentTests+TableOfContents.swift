import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

@MainActor
extension ReaderComponentTests {
  // MARK: - Table of contents

  @Test("reader TOC row preserves an optional caller-supplied page label")
  func readerTOCRowPreservesAnOptionalCallerSuppliedPageLabel() {
    let withPageLabel = ReaderTOCRow(
      title: "Chapter 3",
      pageLabel: "42",
      depth: 0,
      accessibilityValue: "Current chapter",
      isCurrent: true,
      currentIndicatorSystemImage: "checkmark",
      theme: .dark,
      onSelect: {}
    )
    let withoutPageLabel = ReaderTOCRow(
      title: "Chapter 4",
      depth: 0,
      accessibilityValue: "Chapter",
      isCurrent: false,
      currentIndicatorSystemImage: "checkmark",
      theme: .dark,
      onSelect: {}
    )

    #expect(withPageLabel.pageLabel == "42")
    #expect(withoutPageLabel.pageLabel == nil)
  }

  @Test("reader TOC current row uses the accent role for title and page label")
  func readerTOCRowCurrentStateUsesAccentRoleForTitleAndPageLabel() {
    let current = ReaderTOCRow(
      title: "Chapter 3",
      pageLabel: "42",
      depth: 0,
      accessibilityValue: "Current chapter",
      isCurrent: true,
      currentIndicatorSystemImage: "checkmark",
      theme: .dark,
      onSelect: {}
    )
    let nonCurrent = ReaderTOCRow(
      title: "Chapter 4",
      pageLabel: "43",
      depth: 0,
      accessibilityValue: "Chapter",
      isCurrent: false,
      currentIndicatorSystemImage: "checkmark",
      theme: .dark,
      onSelect: {}
    )

    #expect(current.titleColorRole == current.theme.palette.accent)
    #expect(current.pageLabelColorRole == .some(current.theme.palette.accent))
    #expect(nonCurrent.titleColorRole != nonCurrent.theme.palette.accent)
    #expect(nonCurrent.pageLabelColorRole != .some(nonCurrent.theme.palette.accent))
  }

  @Test("reader TOC current row keeps selection and an accessible indicator")
  func readerTOCRowCurrentStateKeepsSelectionAndAccessibleIndicator() {
    let row = ReaderTOCRow(
      title: "Chapter 3",
      pageLabel: "42",
      depth: 0,
      accessibilityValue: "Current chapter",
      isCurrent: true,
      currentIndicatorSystemImage: "checkmark",
      theme: .dark,
      onSelect: {}
    )

    #expect(row.accessibilityTraits.contains(.isSelected))
    #expect(row.indicatorAccessibilityHidden)
    #expect(row.currentIndicatorSystemImage == "checkmark")
  }

  @Test("reader TOC row has no rounded selected background")
  func readerTOCRowHasNoRoundedSelectedBackground() {
    let row = ReaderTOCRow(
      title: "Chapter 3",
      depth: 0,
      accessibilityValue: "Current chapter",
      isCurrent: true,
      currentIndicatorSystemImage: "checkmark",
      theme: .dark,
      onSelect: {}
    )

    #expect(row.selectedBackgroundCornerRadius == nil)
  }

  @Test("reader TOC divider uses the palette role and remains full width at every depth")
  func readerTOCRowDividerUsesPaletteRoleAndRemainsFullWidthAtEveryDepth() {
    let shallow = ReaderTOCRow(
      title: "Part 1",
      depth: 0,
      accessibilityValue: "Part",
      isCurrent: false,
      currentIndicatorSystemImage: "checkmark",
      theme: .sepia,
      onSelect: {}
    )
    let deep = ReaderTOCRow(
      title: "Chapter 3",
      depth: 3,
      accessibilityValue: "Chapter",
      isCurrent: false,
      currentIndicatorSystemImage: "checkmark",
      theme: .sepia,
      onSelect: {}
    )

    #expect(contrastRatio(shallow.dividerRole, shallow.theme.palette.background) >= 3)
    #expect(contrastRatio(deep.dividerRole, deep.theme.palette.background) >= 3)
    #expect(shallow.dividerSpansFullWidth)
    #expect(deep.dividerSpansFullWidth)
    #expect(shallow.dividerLeadingInset == 0)
    #expect(deep.dividerLeadingInset == 0)
  }

  @Test("reader TOC row keeps its standard one-line title and trailing page label")
  func readerTOCRowKeepsItsStandardOneLineTitleAndTrailingPageLabel() {
    let row = ReaderTOCRow(
      title: "A very long chapter title that needs truncation",
      pageLabel: "42",
      depth: 0,
      accessibilityValue: "Chapter",
      isCurrent: false,
      currentIndicatorSystemImage: "checkmark",
      theme: .light,
      onSelect: {}
    )

    let standard = ReaderTOCRowLayoutValues.resolve(isAccessibilitySize: false)
    #expect(
      standard.axis == .horizontal
        && standard.titleLineLimit == 1
        && standard.titleLayoutPriority == 0
        && standard.pageLabelLineLimit == 1
        && standard.pageLabelLayoutPriority == 1
        && standard.pageLabelUsesFixedWidth
        && row.titleLineLimit == 1
        && row.titleLayoutPriority == 0
        && row.pageLabelLineLimit == 1
        && row.pageLabelLayoutPriority == 1
        && row.pageLabelUsesFixedWidth
    )
  }

  @Test("reader TOC row resolves accessibility layout for wrapping and a released page label")
  func readerTOCRowResolvesAccessibilityLayoutForWrappingAndAReleasedPageLabel() {
    let accessibility = ReaderTOCRowLayoutValues.resolve(isAccessibilitySize: true)

    #expect(
      accessibility.axis == .vertical
        && accessibility.titleLineLimit == nil
        && accessibility.titleLayoutPriority > accessibility.pageLabelLayoutPriority
        && accessibility.pageLabelLineLimit == nil
        && accessibility.pageLabelLayoutPriority == 0
        && accessibility.pageLabelUsesFixedWidth == false
    )
  }

  @Test("reader TOC rows reserve the current-chapter indicator whether or not they are current")
  func readerTOCRowsReserveTheCurrentChapterIndicator() {
    func row(isCurrent: Bool) -> ReaderTOCRow {
      ReaderTOCRow(
        title: "Chapter Two — Wintering",
        pageLabel: "41",
        depth: 0,
        accessibilityValue: "Page 41",
        isCurrent: isCurrent,
        currentIndicatorSystemImage: "bookmark.fill",
        theme: .light,
        onSelect: {}
      )
    }

    // The indicator slot is always present (only the glyph appears), so the current row's page
    // number stays aligned with every other row's.
    #expect(row(isCurrent: true).indicatorSlotWidth == row(isCurrent: false).indicatorSlotWidth)
    #expect(row(isCurrent: false).indicatorSlotWidth > 0)
    #expect(row(isCurrent: true).showsCurrentIndicator)
    #expect(row(isCurrent: false).showsCurrentIndicator == false)
    // The page number is the column the eye scans, so it keeps the row's trailing edge and the
    // indicator sits inboard of it.
    #expect(row(isCurrent: true).indicatorPrecedesPageLabel)
  }

  @Test("reader TOC rows keep a margin from the screen edge at every depth", arguments: [0, 1, 3])
  func readerTOCRowsKeepAMarginFromTheScreenEdge(depth: Int) {
    let row = ReaderTOCRow(
      title: "Cover",
      pageLabel: "1",
      depth: depth,
      accessibilityValue: "Page 1",
      isCurrent: false,
      currentIndicatorSystemImage: "bookmark.fill",
      theme: .light,
      onSelect: {}
    )

    // Depth indentation is zero at depth 0, so a top-level title needs its own margin to stay
    // off the sheet edge.
    #expect(row.horizontalInset > 0)
    #expect(row.leadingInset == row.horizontalInset + row.indentation)
  }

  @Test("reader TOC row indents by depth and marks the current chapter")
  func readerTOCRowIndentsByDepthAndMarksCurrentChapter() {
    var selected = false
    let row = ReaderTOCRow(
      title: "Chapter 3",
      depth: 3,
      accessibilityValue: "Current chapter",
      isCurrent: true,
      currentIndicatorSystemImage: "checkmark",
      theme: .dark,
      onSelect: { selected = true }
    )

    #expect(row.depth == 3)
    #expect(row.indentation == 3 * WhirrSpacing.medium)
    #expect(row.isCurrent)
    #expect(row.accessibilityTraits.contains(.isSelected))
    #expect(row.accessibilityTraits.contains(.isButton))
    #expect(row.minimumHitTargetHeight >= WhirrMetric.minimumTouchTarget)

    row.onSelect()
    #expect(selected)
  }

  @Test("reader TOC row semantic snapshot")
  func readerTOCRowSemanticSnapshot() {
    let row = ReaderTOCRow(
      title: "Chapter 3",
      depth: 2,
      accessibilityValue: "Starts at 42 minutes",
      isCurrent: false,
      currentIndicatorSystemImage: "checkmark",
      theme: .sepia,
      onSelect: {}
    )
    assertSnapshot(of: row, as: .dump)
  }

  @Test("reader TOC accessibility layout semantic snapshot")
  func readerTOCRowAccessibilityLayoutSemanticSnapshot() {
    let row = ReaderTOCRow(
      title: "A chapter title that remains readable at accessibility sizes",
      pageLabel: "Page 42",
      depth: 2,
      accessibilityValue: "Starts at page 42",
      isCurrent: false,
      currentIndicatorSystemImage: "checkmark",
      theme: .sepia,
      onSelect: {}
    )
    assertSnapshot(of: row, as: .dump)
  }
}
