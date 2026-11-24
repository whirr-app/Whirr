import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Reader components")
@MainActor
struct ReaderComponentTests {

  @Test("the dark reading theme's page is true black so an OLED panel switches those pixels off")
  func darkReadingPageIsTrueBlack() {
    #expect(ReaderThemePalette.dark.background == WhirrRGBColor(0, 0, 0))
  }

  @Test("reader search result row keeps the supplied snippet boundaries")
  func readerSearchResultRowKeepsSuppliedSnippetBoundaries() {
    let row = ReaderSearchResultRow(
      chapterTitle: "Chapter 2",
      before: "before ",
      highlight: "résumé",
      after: " after",
      theme: .dark
    )

    #expect(String(row.attributedSnippet.characters) == "before résumé after")
    #expect(row.chapterTitleColorRole == row.theme.palette.secondaryForeground)
    #expect(row.snippetColorRole == row.theme.palette.foreground)
    #expect(row.highlightColorRole == row.theme.palette.accent)
  }

  // MARK: - Progress rail

  @Test("reader progress rail forwards adjustments and seeks with the caller's copy")
  func readerProgressRailForwardsAdjustmentsAndSeeks() {
    var adjustments: [PlaybackScrubber.AdjustmentDirection] = []
    var seekedFraction: Double?
    let rail = ReaderProgressRail(
      progressFraction: 0.42,
      accessibilityLabel: "Reading progress",
      accessibilityValue: "Reading progress, 42 percent, Page 42 of 336",
      theme: .dark,
      onAdjust: { adjustments.append($0) },
      onSeek: { seekedFraction = $0 }
    )

    #expect(rail.progressFraction == 0.42)
    #expect(rail.accessibilityLabel == "Reading progress")
    #expect(rail.accessibilityValue == "Reading progress, 42 percent, Page 42 of 336")

    rail.onAdjust(.increment)
    rail.onAdjust(.decrement)
    rail.onSeek?(0.7)
    #expect(adjustments == [.increment, .decrement])
    #expect(seekedFraction == 0.7)
  }

  @Test("reader progress rail keeps the thin rail style and reader palette roles")
  func readerProgressRailKeepsTheThinRailStyle() {
    let rail = ReaderProgressRail(
      progressFraction: 0.42, accessibilityLabel: "", accessibilityValue: "", theme: .dark,
      onAdjust: { _ in })
    let palette = ReaderTheme.dark.palette

    #expect(rail.trackHeight == 1)
    #expect(rail.thumbDiameter >= 6)
    #expect(rail.thumbDiameter <= 8)
    #expect(rail.hitTargetHeight >= WhirrMetric.minimumTouchTarget)
    #expect(rail.trackColor == palette.track)
    #expect(rail.fillColor == palette.accent)
  }
}
