import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import Whirr

@Suite("Item detail layout presentation")
struct ItemDetailLayoutPresentationTests {
  @Test("regular width keeps the promoted stack and caps prose at the measure")
  func regularWidthKeepsPromotedStack() {
    for width in [CGFloat(802), CGFloat(898), CGFloat(1178)] {
      let presentation = ItemDetailLayoutPresentation.resolve(
        horizontalSizeClass: .regular,
        isAccessibilitySize: false,
        availableWidth: width)

      #expect(presentation.hero == .promotedStack)
      #expect(presentation.readableWidth == AdaptiveLayoutPresentation.readingMeasure)
      #expect(presentation.readableWidth < presentation.availableWidth)
    }
  }

  @Test("compact width keeps the promoted stack")
  func compactWidthKeepsPromotedStack() {
    let presentation = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: .compact,
      isAccessibilitySize: false,
      availableWidth: 375)

    #expect(presentation.hero == .promotedStack)
  }

  @Test("accessibility overrides a regular hero")
  func accessibilityOverridesRegularHero() {
    let presentation = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: .regular,
      isAccessibilitySize: true,
      availableWidth: 898)

    #expect(presentation.hero == .stackedLeading)
  }

  @Test("no block ever claims more than the pane it is given")
  func noBlockExceedsAvailableWidth() {
    for width in [CGFloat(0), CGFloat(320), CGFloat(704), CGFloat(964), CGFloat(1366)] {
      for isAccessibilitySize in [false, true] {
        let presentation = ItemDetailLayoutPresentation.resolve(
          horizontalSizeClass: .regular,
          isAccessibilitySize: isAccessibilitySize,
          availableWidth: width)

        #expect(presentation.readableWidth <= presentation.availableWidth)
        #expect(presentation.actionWidth <= presentation.availableWidth)
      }
    }
  }

  @Test("action width never exceeds the control ceiling")
  func actionWidthNeverExceedsControlCeiling() {
    let standard = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: .regular,
      isAccessibilitySize: false,
      availableWidth: 802)
    let accessibility = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: .regular,
      isAccessibilitySize: true,
      availableWidth: 898)

    #expect(standard.actionWidth == AdaptiveLayoutPresentation.primaryControlMaxWidth)
    #expect(standard.actionWidth <= AdaptiveLayoutPresentation.primaryControlMaxWidth)
    #expect(
      accessibility.actionWidth
        <= AdaptiveLayoutPresentation.accessibilityPrimaryControlMaxWidth)
    #expect(accessibility.actionWidth <= accessibility.availableWidth)
  }

  /// A geometry callback can report a width that is not a pane, such as a restored snapshot being
  /// re-laid out or an off-screen tab. Honouring one squeezes the action row's capsules until a
  /// later layout displaces one of them, so a sub-floor report must resolve the same as no report.
  @Test("a width too narrow to be a pane is treated as no measurement")
  func subFloorWidthFallsBackToTheReadingMeasure() {
    let unmeasured = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: .compact,
      isAccessibilitySize: false,
      availableWidth: nil)

    for width in [CGFloat(0), CGFloat(1), CGFloat(12), CGFloat(199)] {
      let presentation = ItemDetailLayoutPresentation.resolve(
        horizontalSizeClass: .compact,
        isAccessibilitySize: false,
        availableWidth: width)

      #expect(presentation.availableWidth == unmeasured.availableWidth)
      #expect(presentation.actionWidth == unmeasured.actionWidth)
      #expect(presentation.readableWidth == unmeasured.readableWidth)
      #expect(presentation.actionWidth == AdaptiveLayoutPresentation.primaryControlMaxWidth)
    }
  }

  @Test("a pane as narrow as the app is ever laid out in is honoured")
  func realPaneWidthIsHonoured() {
    // 320pt, the narrowest phone and the iPad slide-over column, less the page's own padding.
    for width in [ItemDetailLayoutPresentation.minimumMeasuredWidth, CGFloat(272), CGFloat(375)] {
      let presentation = ItemDetailLayoutPresentation.resolve(
        horizontalSizeClass: .compact,
        isAccessibilitySize: false,
        availableWidth: width)

      #expect(presentation.availableWidth == width)
      #expect(presentation.actionWidth == width)
    }
  }

  @Test("inline title reveal uses the measured hero height")
  func inlineTitleRevealUsesMeasuredHeroHeight() {
    let short = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: .regular,
      isAccessibilitySize: false,
      availableWidth: 802,
      measuredHeroHeight: 320)
    let tall = ItemDetailLayoutPresentation.resolve(
      horizontalSizeClass: .regular,
      isAccessibilitySize: false,
      availableWidth: 802,
      measuredHeroHeight: 540)

    #expect(short.inlineTitleRevealOffset == 320)
    #expect(tall.inlineTitleRevealOffset == 540)
    #expect(short.shouldRevealInlineTitle(at: 319) == false)
    #expect(short.shouldRevealInlineTitle(at: 321))
    #expect(tall.shouldRevealInlineTitle(at: 321) == false)
  }
}
