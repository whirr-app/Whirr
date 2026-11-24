import Foundation
import SwiftUI
import Testing

@testable import Whirr

@Suite("Library browse layout presentation")
struct LibraryBrowseLayoutPresentationTests {

  @Test("compact Library browse keeps the native list and index")
  func compactLayoutKeepsNativeListAndIndex() {
    #expect(
      LibraryBrowseLayoutPresentation.resolve(
        for: .titles, horizontalSizeClass: .compact, availableWidth: 802)
        == .singleColumn)
    #expect(
      LibraryBrowseLayoutPresentation.resolve(
        for: .authors, horizontalSizeClass: nil, availableWidth: 898)
        == .singleColumn)
    #expect(
      LibraryBrowseLayoutPresentation.indexOwner(for: .compact) == .nativeList)
  }

  @Test("regular Library browse uses a grid and jump menu")
  func regularLayoutUsesGridAndJumpMenu() {
    #expect(
      LibraryBrowseLayoutPresentation.resolve(
        for: .titles, horizontalSizeClass: .regular, availableWidth: 802)
        == .grid(columns: 5))
    #expect(
      LibraryBrowseLayoutPresentation.indexOwner(for: .regular) == .jumpMenu)
  }

  @Test("regular grids resolve five columns at both iPad widths")
  func regularGridResolvesFiveColumnsAtPortraitAndLandscapeWidths() {
    for width in [802.0 as CGFloat, 898.0] {
      #expect(
        LibraryBrowseLayoutPresentation.resolve(
          for: .titles, horizontalSizeClass: .regular, availableWidth: width)
          == .grid(columns: 5))
    }

    #expect(
      LibraryBrowseLayoutPresentation.tileWidth(forAvailableWidth: 802, columns: 5) == 150)
    #expect(
      LibraryBrowseLayoutPresentation.tileWidth(forAvailableWidth: 898, columns: 5) == 170)
  }

  @Test("accessibility grids resolve three portrait and four landscape columns")
  func accessibilityGridResolvesThreePortraitAndFourLandscapeColumns() {
    #expect(
      LibraryBrowseLayoutPresentation.resolve(
        for: .titles, horizontalSizeClass: .regular, availableWidth: 802,
        isAccessibilitySize: true)
        == .grid(columns: 3))
    #expect(
      LibraryBrowseLayoutPresentation.resolve(
        for: .series, horizontalSizeClass: .regular, availableWidth: 898,
        isAccessibilitySize: true)
        == .grid(columns: 4))
  }

  @Test("the author card outer minimum keeps two columns at both iPad widths")
  func authorCardMinimumKeepsTwoColumnsAtBothIPadWidths() {
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .authors, isAccessibilitySize: false) == 320)
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .authors, isAccessibilitySize: true) == 320)

    for width in [802.0 as CGFloat, 898.0] {
      #expect(
        LibraryBrowseLayoutPresentation.resolve(
          for: .authors, horizontalSizeClass: .regular, availableWidth: width)
          == .grid(columns: 2))
    }
  }

  @Test("regular mode minimums distinguish cover widths from author outer-card width")
  func regularModeMinimumsStayModeSpecific() {
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .titles, isAccessibilitySize: false) == 140)
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .series, isAccessibilitySize: true) == 200)
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .authors, isAccessibilitySize: false) == 320)
    #expect(
      LibraryBrowseLayoutPresentation.indexOwner(for: nil) == .nativeList)
  }

  @Test("an effective query hides the Library index menu")
  func effectiveQueriesHideTheIndexMenu() {
    #expect(LibraryBrowseLayoutPresentation.indexMenuIsVisible(isQueryEffective: true) == false)
    #expect(LibraryBrowseLayoutPresentation.indexMenuIsVisible(isQueryEffective: false))
  }

  @Test("empty letters have no scroll target")
  func emptyLettersHaveNoScrollTarget() {
    #expect(
      LibraryBrowseLayoutPresentation.sectionTargetID(for: "B", in: .titles, hasItems: false) == nil)
    #expect(
      LibraryBrowseLayoutPresentation.sectionTargetID(for: "", in: .titles, hasItems: true) == nil)
  }

  @Test("section target IDs are stable")
  func sectionTargetIDsAreStable() {
    let first = LibraryBrowseLayoutPresentation.sectionTargetID(
      for: "A", in: .titles, hasItems: true)
    let repeated = LibraryBrowseLayoutPresentation.sectionTargetID(
      for: "A", in: .titles, hasItems: true)

    #expect(first == repeated)
    #expect(first == "library-section-titles-A")
    #expect(
      LibraryBrowseLayoutPresentation.sectionTargetID(for: "a", in: .titles, hasItems: true)
        == first)
    #expect(
      LibraryBrowseLayoutPresentation.sectionTargetID(for: "B", in: .titles, hasItems: true)
        != first)
  }

  /// The regression behind the iPad staleness: one lazy container holds every mode's sections, so
  /// a letter that keeps its identity across a mode switch is a cell SwiftUI has no reason to
  /// rebuild. Realized rows kept the previous mode's content until they were scrolled away and
  /// re-created. Distinct identities per mode are what make the switch a replacement.
  @Test("each browse mode owns a distinct scroll target for the same letter")
  func sectionTargetIDsDifferPerMode() {
    let ids = LibraryBrowsePresentation.Mode.allCases.map {
      LibraryBrowseLayoutPresentation.sectionTargetID(for: "A", in: $0, hasItems: true)
    }

    #expect(ids.allSatisfy { $0 != nil })
    #expect(Set(ids).count == LibraryBrowsePresentation.Mode.allCases.count)
    #expect(
      LibraryBrowseLayoutPresentation.sectionTargetID(for: "A", in: .authors, hasItems: true)
        == "library-section-authors-A")
    #expect(
      LibraryBrowseLayoutPresentation.sectionTargetID(for: "A", in: .series, hasItems: true)
        == "library-section-series-A")
  }
}
