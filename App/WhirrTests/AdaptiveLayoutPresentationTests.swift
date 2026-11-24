import Foundation
import Testing

@testable import Whirr

@Suite("Adaptive layout presentation")
struct AdaptiveLayoutPresentationTests {
  @Test("reading width is capped at the shared measure")
  func readingWidthUsesTheSharedMeasure() {
    #expect(AdaptiveLayoutPresentation.readableWidth(forAvailableWidth: 802) == 640)
    #expect(AdaptiveLayoutPresentation.readableWidth(forAvailableWidth: 898) == 640)
  }

  @Test("a narrow Split View reading width passes through uncapped")
  func narrowReadingWidthPassesThrough() {
    #expect(AdaptiveLayoutPresentation.readableWidth(forAvailableWidth: 468) == 468)
  }

  @Test("standard primary controls use the 480 point ceiling")
  func standardPrimaryControlsUseStandardCeiling() {
    #expect(
      AdaptiveLayoutPresentation.primaryControlWidth(
        forAvailableWidth: 802, isAccessibilitySize: false) == 480)
    #expect(
      AdaptiveLayoutPresentation.primaryControlWidth(
        forAvailableWidth: 320, isAccessibilitySize: false) == 320)
  }

  @Test("accessibility primary controls use the reading measure without exceeding the pane")
  func accessibilityPrimaryControlsUseAccessibilityCeiling() {
    #expect(
      AdaptiveLayoutPresentation.primaryControlWidth(
        forAvailableWidth: 802, isAccessibilitySize: true) == 640)
    #expect(
      AdaptiveLayoutPresentation.primaryControlWidth(
        forAvailableWidth: 600, isAccessibilitySize: true) == 600)
  }

  @Test("zero and invalid widths resolve to zero")
  func invalidWidthsResolveSafely() {
    let invalidWidths: [CGFloat] = [0, -1, .infinity, -.infinity, .nan]
    for width in invalidWidths {
      #expect(AdaptiveLayoutPresentation.readableWidth(forAvailableWidth: width) == 0)
      #expect(
        AdaptiveLayoutPresentation.primaryControlWidth(
          forAvailableWidth: width, isAccessibilitySize: false) == 0)
      #expect(
        AdaptiveLayoutPresentation.primaryControlWidth(
          forAvailableWidth: width, isAccessibilitySize: true) == 0)
    }
  }
}
