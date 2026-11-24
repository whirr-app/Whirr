import Foundation
import SwiftUI
import Testing

@testable import Whirr

/// `AdaptiveListLayout.resolve` is the pure decision behind the storage and resolution-center
/// screens' single-column or grid presentation. Tested directly, without rendering.
@Suite("Storage/resolution adaptive layout")
struct AdaptiveListLayoutTests {

  @Test("compact horizontal size class resolves to a single column")
  func compactResolvesSingleColumn() {
    #expect(AdaptiveListLayout.resolve(horizontalSizeClass: .compact) == .singleColumn)
    #expect(
      AdaptiveListLayout.resolve(
        horizontalSizeClass: .compact,
        availableWidth: 898,
        minimumTileWidth: 140,
        spacing: 12) == .singleColumn)
  }

  @Test("an unknown (nil) horizontal size class resolves to a single column")
  func unknownResolvesSingleColumn() {
    #expect(AdaptiveListLayout.resolve(horizontalSizeClass: nil) == .singleColumn)
    #expect(
      AdaptiveListLayout.resolve(
        horizontalSizeClass: nil,
        availableWidth: 898,
        minimumTileWidth: 140,
        spacing: 12) == .singleColumn)
  }

  @Test("regular horizontal size class resolves to a two-column grid")
  func regularResolvesTwoColumnGrid() {
    #expect(AdaptiveListLayout.resolve(horizontalSizeClass: .regular) == .grid(columns: 2))
    #expect(
      AdaptiveListLayout.resolve(
        horizontalSizeClass: .regular,
        availableWidth: nil,
        minimumTileWidth: 140,
        spacing: 12) == .grid(columns: 2))
  }

  @Test("a regular measured podcast width resolves to one bounded reading column")
  func measuredRegularWidthResolvesToMeasuredSingleColumn() {
    #expect(
      AdaptiveListLayout.resolve(horizontalSizeClass: .regular, measure: 760)
        == .measuredSingleColumn(maxWidth: 760))
  }

  @Test("compact and unknown measured podcast widths remain a single column")
  func measuredCompactAndUnknownWidthsRemainSingleColumn() {
    #expect(
      AdaptiveListLayout.resolve(horizontalSizeClass: .compact, measure: 760) == .singleColumn)
    #expect(
      AdaptiveListLayout.resolve(horizontalSizeClass: nil, measure: 760) == .singleColumn)
  }

  @Test("invalid measured podcast widths fall back to a single column")
  func invalidMeasuredWidthsFallBackToSingleColumn() {
    let invalidMeasures: [CGFloat] = [0, -1, .infinity, -.infinity, .nan]
    for measure in invalidMeasures {
      #expect(
        AdaptiveListLayout.resolve(horizontalSizeClass: .regular, measure: measure)
          == .singleColumn)
    }
  }

  @Test("a measured regular width resolves three columns across the Split View range")
  func splitViewWidthResolvesThreeColumns() {
    for width in [444.0 as CGFloat, 468.0] {
      #expect(
        AdaptiveListLayout.resolve(
          horizontalSizeClass: .regular,
          availableWidth: width,
          minimumTileWidth: 140,
          spacing: 12) == .grid(columns: 3))
    }
  }

  @Test("a measured landscape content width resolves five columns")
  func landscapeWidthResolvesFiveColumns() {
    for width in [874.0 as CGFloat, 898.0] {
      #expect(
        AdaptiveListLayout.resolve(
          horizontalSizeClass: .regular,
          availableWidth: width,
          minimumTileWidth: 140,
          spacing: 12) == .grid(columns: 5))
    }
  }

  @Test("column thresholds include the inter-column spacing")
  func columnThresholdsAreMeasuredByOccupiedWidth() {
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 747, minimumTileWidth: 140, spacing: 12) == 4)
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 748, minimumTileWidth: 140, spacing: 12) == 5)
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 899, minimumTileWidth: 140, spacing: 12) == 5)
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 900, minimumTileWidth: 140, spacing: 12) == 6)
  }

  @Test("accessibility minimums reduce the measured column count")
  func accessibilityMinimumReducesColumns() {
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 874, minimumTileWidth: 140, spacing: 12) == 5)
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 874, minimumTileWidth: 200, spacing: 12) == 4)
    #expect(
      AdaptiveListLayout.resolve(
        horizontalSizeClass: .regular,
        availableWidth: 874,
        minimumTileWidth: 200,
        spacing: 12) == .grid(columns: 4))
  }

  @Test("invalid measured inputs fall back to one column")
  func invalidInputsResolveSafely() {
    let invalidWidths: [CGFloat] = [0, -1, .infinity, -.infinity, .nan]
    for width in invalidWidths {
      #expect(
        AdaptiveListLayout.columnCount(
          forContentWidth: width, minimumTileWidth: 140, spacing: 12) == 1)
      #expect(
        AdaptiveListLayout.resolve(
          horizontalSizeClass: .regular,
          availableWidth: width,
          minimumTileWidth: 140,
          spacing: 12) == .grid(columns: 1))
    }

    let invalidMinimums: [CGFloat] = [0, -1, .infinity, -.infinity, .nan]
    for minimum in invalidMinimums {
      #expect(
        AdaptiveListLayout.columnCount(
          forContentWidth: 874, minimumTileWidth: minimum, spacing: 12) == 1)
    }

    let invalidSpacings: [CGFloat] = [0, -1, .infinity, -.infinity, .nan]
    for spacing in invalidSpacings {
      #expect(
        AdaptiveListLayout.columnCount(
          forContentWidth: 874, minimumTileWidth: 140, spacing: spacing) == 1)
    }
  }

  @Test("tile width accounts for gaps and never exceeds content width")
  func tileWidthFitsContentAndSpacing() {
    let tileWidth = AdaptiveListLayout.tileWidth(
      forContentWidth: 898, columns: 5, spacing: 12)
    #expect(tileWidth == 170)
    #expect(tileWidth <= 898)
    #expect(tileWidth * 5 + 12 * 4 <= 898)

    let fractionalTileWidth = AdaptiveListLayout.tileWidth(
      forContentWidth: 874, columns: 5, spacing: 12)
    #expect(fractionalTileWidth == 165)
    #expect(fractionalTileWidth <= 874)
    #expect(fractionalTileWidth * 5 + 12 * 4 <= 874)

    #expect(
      AdaptiveListLayout.tileWidth(forContentWidth: 10, columns: 2, spacing: 12) >= 0)
    #expect(
      AdaptiveListLayout.tileWidth(forContentWidth: 100, columns: 0, spacing: 12) >= 0)
    #expect(
      AdaptiveListLayout.tileWidth(forContentWidth: .nan, columns: 1, spacing: 12) >= 0)
    #expect(
      AdaptiveListLayout.tileWidth(forContentWidth: 100, columns: 1, spacing: .nan) >= 0)
  }
}
