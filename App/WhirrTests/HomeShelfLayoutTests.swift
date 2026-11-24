import CoreGraphics
import DesignSystem
import SwiftUI
import Testing

@testable import Whirr

@Suite("Home shelf layout")
struct HomeShelfLayoutTests {
  @Test("a shelf's content width is its viewport less the inset on each edge")
  func shelfContentWidthSubtractsBothInsets() {
    #expect(
      HomeViewPresentation.shelfContentWidth(viewportWidth: 834, horizontalInset: WhirrSpacing.medium)
        == 834 - 2 * WhirrSpacing.medium)
    #expect(HomeViewPresentation.shelfContentWidth(viewportWidth: 1_400, horizontalInset: 100) == 1_200)
  }

  @Test("an unmeasured or invalid shelf viewport has no content width")
  func shelfContentWidthRejectsInvalidViewports() {
    #expect(HomeViewPresentation.shelfContentWidth(viewportWidth: 0, horizontalInset: 16) == 0)
    #expect(HomeViewPresentation.shelfContentWidth(viewportWidth: -10, horizontalInset: 16) == 0)
    #expect(HomeViewPresentation.shelfContentWidth(viewportWidth: .infinity, horizontalInset: 16) == 0)
    #expect(HomeViewPresentation.shelfContentWidth(viewportWidth: .nan, horizontalInset: 16) == 0)
    #expect(HomeViewPresentation.shelfContentWidth(viewportWidth: 20, horizontalInset: 16) == 0)
  }

  @Test("regular Home shelves fit four standard cards at the portrait interior")
  func portraitInteriorFitsFourStandardCards() {
    let layout = Self.layout(width: 802)

    #expect(layout.minimumCoverWidth == 140)
    #expect(layout.outerCardWidth == 164)
    #expect(layout.capacity == 4)
    #expect(layout.cardWidth == 191)
  }

  @Test("regular Home shelves fit five standard cards at the landscape interior")
  func landscapeInteriorFitsFiveStandardCards() {
    let layout = Self.layout(width: 898)

    #expect(layout.capacity == 5)
    #expect(layout.cardWidth == 170)
  }

  @Test("accessibility Home shelves fit three cards at both regular interiors")
  func accessibilityInteriorsFitThreeCards() {
    let portrait = Self.layout(width: 802, isAccessibilitySize: true)
    let landscape = Self.layout(width: 898, isAccessibilitySize: true)

    #expect(portrait.minimumCoverWidth == 200)
    #expect(portrait.outerCardWidth == 224)
    #expect(portrait.capacity == 3)
    #expect(portrait.cardWidth == 259)
    #expect(landscape.capacity == 3)
    #expect(landscape.cardWidth == 291)
  }

  @Test("compact Home shelves keep the existing 164-point card")
  func compactKeepsExistingCardWidth() {
    let compact = Self.layout(width: 802, horizontalSizeClass: .compact)
    let unknown = Self.layout(width: 802, horizontalSizeClass: nil)

    #expect(compact.capacity == nil)
    #expect(compact.cardWidth == 164)
    #expect(unknown.capacity == nil)
    #expect(unknown.cardWidth == 164)
  }

  @Test("resolved Home shelf card width never exceeds content width")
  func cardWidthNeverExceedsContentWidth() {
    for width in [802.0 as CGFloat, 898.0, 160.0] {
      let layout = Self.layout(width: width)
      #expect(layout.cardWidth <= width)
    }
  }

  @Test("one item and a full shelf use the same viewport card width without an item-count input")
  func sparseAndFullShelvesUseSameViewportWidth() {
    let oneItemShelf = Self.layout(width: 802)
    let fullShelf = Self.layout(width: 802)

    #expect(oneItemShelf.cardWidth == fullShelf.cardWidth)
    #expect(oneItemShelf.capacity == fullShelf.capacity)
  }

  @Test("accessibility text wraps while standard Home text keeps two and one line limits")
  func textPolicyUsesNamedLineLimits() {
    let standard = Self.layout(width: 802)
    let accessibility = Self.layout(width: 802, isAccessibilitySize: true)

    #expect(standard.textPolicy.titleLineLimit == 2)
    #expect(standard.textPolicy.subtitleLineLimit == 1)
    #expect(accessibility.textPolicy.titleLineLimit == nil)
    #expect(accessibility.textPolicy.subtitleLineLimit == nil)
  }

  @Test("a regular shelf holds the minimum card until its first measurement")
  func unmeasuredRegularShelfHoldsTheMinimumCard() {
    let unmeasured = Self.layout(width: 0)
    let invalid = Self.layout(width: .nan)

    #expect(unmeasured.cardWidth == 164)
    #expect(invalid.cardWidth == 164)
    #expect(Self.layout(width: 0, isAccessibilitySize: true).cardWidth == 224)
  }

  @Test("the drawn cover is the resolved card less its two insets")
  func drawnCoverIsTheCardLessItsInsets() {
    let layout = Self.layout(width: 802)

    #expect(layout.drawnCoverWidth == layout.cardWidth - 2 * WhirrSpacing.small)
    #expect(layout.drawnCoverWidth == 167)
    #expect(Self.layout(width: 802, horizontalSizeClass: .compact).drawnCoverWidth == 140)
  }

  private static func layout(
    width: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass? = .regular,
    isAccessibilitySize: Bool = false
  ) -> HomeViewPresentation.ShelfLayout {
    HomeViewPresentation.ShelfLayout.resolve(
      horizontalSizeClass: horizontalSizeClass,
      availableWidth: width,
      isAccessibilitySize: isAccessibilitySize)
  }
}
