import ABSApi
import CoreGraphics
import DesignSystem
import SwiftUI
import Testing

@testable import Whirr

@Suite("Podcast responsive layout")
struct PodcastResponsiveLayoutTests {
  @Test("show-grid minimums are 140 points standard and 200 points at accessibility sizes")
  func showGridMinimumsUseAccessibilityOverride() {
    #expect(PodcastsViewPresentation.showGridMinimumWidth(isAccessibilitySize: false) == 140)
    #expect(PodcastsViewPresentation.showGridMinimumWidth(isAccessibilitySize: true) == 200)
  }

  @Test("show-grid tile widths add both editorial insets")
  func showGridTileWidthsIncludeBothInsets() {
    #expect(PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: false) == 164)
    #expect(PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: true) == 224)
  }

  @Test("portrait and landscape interiors fit four and five standard show tiles")
  func showGridCapacityUsesSharedColumnArithmetic() {
    let minimumTileWidth = PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: false)
    let spacing = WhirrSpacing.small

    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 802,
        minimumTileWidth: minimumTileWidth,
        spacing: spacing) == 4)
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 898,
        minimumTileWidth: minimumTileWidth,
        spacing: spacing) == 5)
  }

  @Test("podcast episode content uses the named 760-point reading measure")
  func episodeContentCapsAtReadingMeasure() {
    #expect(
      PodcastsViewPresentation.boundedContentWidth(
        availableWidth: 802, horizontalSizeClass: .regular) == 760)
    #expect(
      PodcastsViewPresentation.boundedContentWidth(
        availableWidth: 898, horizontalSizeClass: .regular) == 760)
  }

  @Test("compact episode content never exceeds its available width, even below the cap")
  func compactContentRemainsWithinAvailableWidth() {
    #expect(
      PodcastsViewPresentation.boundedContentWidth(
        availableWidth: 700, horizontalSizeClass: .compact) == 700)
    #expect(
      PodcastsViewPresentation.boundedContentWidth(
        availableWidth: 400, horizontalSizeClass: .compact) == 400)
    #expect(
      PodcastsViewPresentation.boundedContentWidth(
        availableWidth: 400, horizontalSizeClass: nil) == 400)
  }

  @Test("header artwork is 240 in a regular window, 200 at accessibility sizes, else 120")
  func headerArtworkUsesSizeClassesAndAccessibilityPolicy() {
    #expect(
      PodcastsViewPresentation.headerArtworkSize(
        horizontalSizeClass: .regular, verticalSizeClass: .regular,
        isAccessibilitySize: false) == 240)
    #expect(
      PodcastsViewPresentation.headerArtworkSize(
        horizontalSizeClass: .regular, verticalSizeClass: .regular,
        isAccessibilitySize: true) == 200)
    for vertical: UserInterfaceSizeClass? in [nil, .compact, .regular] {
      for accessibility in [false, true] {
        #expect(
          PodcastsViewPresentation.headerArtworkSize(
            horizontalSizeClass: .compact, verticalSizeClass: vertical,
            isAccessibilitySize: accessibility) == 120)
      }
    }
  }

  /// An iPhone Duo reports the phone idiom but opens to a regular-width, regular-height window,
  /// so it takes the iPad header there.
  @Test("an opened foldable phone gets the regular header and request")
  func regularPhoneWindowGetsRegularHeader() {
    #expect(
      PodcastsViewPresentation.headerArtworkSize(
        horizontalSizeClass: .regular, verticalSizeClass: .regular,
        isAccessibilitySize: false) == 240)
    #expect(
      PodcastsViewPresentation.headerArtworkRequestSize(
        horizontalSizeClass: .regular, verticalSizeClass: .regular) == 240)
  }

  /// A Plus or Pro Max iPhone in landscape is regular width but compact height; a 240 pt cover
  /// would fill its height, so it keeps the card header and the shared card request.
  @Test("a compact-height regular window keeps the card header and request")
  func compactHeightKeepsCardHeader() {
    for accessibility in [false, true] {
      #expect(
        PodcastsViewPresentation.headerArtworkSize(
          horizontalSizeClass: .regular, verticalSizeClass: .compact,
          isAccessibilitySize: accessibility) == 120)
    }
    #expect(
      PodcastsViewPresentation.headerArtworkRequestSize(
        horizontalSizeClass: .regular, verticalSizeClass: .compact) == 140)
  }

  @Test("compact windows share the 140 pt card request")
  func compactWindowsShareCardRequest() {
    for vertical: UserInterfaceSizeClass? in [nil, .compact, .regular] {
      #expect(
        PodcastsViewPresentation.headerArtworkRequestSize(
          horizontalSizeClass: .compact, verticalSizeClass: vertical) == 140)
    }
  }

  @Test("the request always covers the drawn header")
  func headerRequestCoversEveryLayout() {
    let classes: [UserInterfaceSizeClass?] = [nil, .compact, .regular]
    for horizontal in classes {
      for vertical in classes {
        let request = PodcastsViewPresentation.headerArtworkRequestSize(
          horizontalSizeClass: horizontal, verticalSizeClass: vertical)
        for accessibility in [false, true] {
          let drawn = PodcastsViewPresentation.headerArtworkSize(
            horizontalSizeClass: horizontal, verticalSizeClass: vertical,
            isAccessibilitySize: accessibility)
          #expect(drawn <= request)
        }
      }
    }
    #expect(ArtworkVariant.homeCard(displaySize: 240, displayScale: 2).pixelWidth == 480)
  }

}
