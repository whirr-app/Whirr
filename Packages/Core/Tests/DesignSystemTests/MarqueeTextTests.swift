import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Marquee text geometry")
struct MarqueeTextTests {

  /// A faded, unellipsized line that stayed centred would hide its start, which is the part that
  /// identifies it. Text that fits must keep the caller's requested alignment.
  @Test
  func overflowingTextStartsAtTheLeadingEdgeAndFittingTextKeepsItsAlignment() {
    #expect(MarqueeTextGeometry.restingAlignment(for: .center, isOverflowing: true) == .leading)
    #expect(MarqueeTextGeometry.restingAlignment(for: .trailing, isOverflowing: true) == .leading)
    #expect(MarqueeTextGeometry.restingAlignment(for: .center, isOverflowing: false) == .center)
    #expect(MarqueeTextGeometry.restingAlignment(for: .leading, isOverflowing: false) == .leading)
  }

  @Test
  func edgeFadeWidthIsZeroWhenTextFitsOrOverflowIsWithinEpsilon() {
    #expect(MarqueeTextGeometry.edgeFadeWidth(overflow: 0, availableWidth: 100) == 0)
    #expect(MarqueeTextGeometry.edgeFadeWidth(overflow: 0.5, availableWidth: 100) == 0)
  }

  @Test
  func edgeFadeWidthIsZeroForNonFiniteOverflow() {
    #expect(MarqueeTextGeometry.edgeFadeWidth(overflow: .nan, availableWidth: 100) == 0)
    #expect(MarqueeTextGeometry.edgeFadeWidth(overflow: .infinity, availableWidth: 100) == 0)
  }

  @Test
  func edgeFadeWidthUsesTheFixedWidthForNormalOverflow() {
    #expect(
      MarqueeTextGeometry.edgeFadeWidth(overflow: 40, availableWidth: 100)
        == MarqueeTextGeometry.defaultEdgeFadeWidth
    )
  }

  @Test
  func edgeFadeWidthIsCappedAtAThirdOfANarrowColumn() {
    #expect(MarqueeTextGeometry.edgeFadeWidth(overflow: 40, availableWidth: 40) == CGFloat(40) / 3)
  }

  @Test
  func isOverflowingDetectsRealOverflow() {
    #expect(
      MarqueeTextGeometry.isOverflowing(
        contentWidth: 140, availableWidth: 100, isAccessibilitySize: false
      )
    )
  }

  @Test
  func isOverflowingIsFalseWithinRoundingEpsilon() {
    #expect(
      MarqueeTextGeometry.isOverflowing(
        contentWidth: 100.5, availableWidth: 100, isAccessibilitySize: false
      ) == false
    )
  }

  @Test
  func isOverflowingIsFalseAtAccessibilitySizes() {
    #expect(
      MarqueeTextGeometry.isOverflowing(
        contentWidth: 140, availableWidth: 100, isAccessibilitySize: true
      ) == false
    )
  }

  @Test
  func isOverflowingIsFalseForUnresolvedWidths() {
    let unresolvedWidths: [CGFloat] = [0, -1, .infinity, .nan]

    for width in unresolvedWidths {
      #expect(
        MarqueeTextGeometry.isOverflowing(
          contentWidth: 140, availableWidth: width, isAccessibilitySize: false
        ) == false
      )
      #expect(
        MarqueeTextGeometry.isOverflowing(
          contentWidth: width, availableWidth: 100, isAccessibilitySize: false
        ) == false
      )
    }
  }

  /// Visual fading is independent of Reduce Motion: motion policy affects the keyframe pass, not
  /// whether a resting overflowing line should be softened at its trailing edge.
  @Test
  func isOverflowingRemainsTrueUnderTheReduceMotionContract() {
    #expect(
      MarqueeTextGeometry.isOverflowing(
        contentWidth: 140, availableWidth: 100, isAccessibilitySize: false
      )
    )
  }

  @Test
  func suspendedMarqueeStaysAtRestEvenWhenTextOverflows() {
    #expect(
      MarqueeTextGeometry.shouldScroll(
        contentWidth: 240, availableWidth: 100, reduceMotion: false, isSuspended: true) == false)
    #expect(
      MarqueeTextGeometry.shouldScroll(
        contentWidth: 240, availableWidth: 100, reduceMotion: false, isSuspended: false))
  }

  @Test
  func accessibilitySizeDoesNotScrollEvenWhenTextOverflows() {
    #expect(
      MarqueeTextGeometry.shouldScroll(
        contentWidth: 240,
        availableWidth: 100,
        reduceMotion: false,
        isAccessibilitySize: true
      ) == false
    )
  }

  @Test
  func accessibilitySizeResolvesToTwoLinesAndStandardSizeRemainsSingleLine() {
    #expect(MarqueeTextGeometry.resolvedLineLimit(isAccessibilitySize: true) == 2)
    #expect(MarqueeTextGeometry.resolvedLineLimit(isAccessibilitySize: false) == 1)
  }

  @Test
  func doesNotScrollWhenTextFitsAvailableWidth() {
    #expect(
      MarqueeTextGeometry.shouldScroll(
        contentWidth: 100, availableWidth: 100, reduceMotion: false
      ) == false
    )
  }

  @Test
  func doesNotScrollWhenOverflowIsWithinRoundingEpsilon() {
    #expect(
      MarqueeTextGeometry.shouldScroll(
        contentWidth: 100.25, availableWidth: 100, reduceMotion: false
      ) == false
    )
  }

  @Test
  func scrollsWhenTextExceedsAvailableWidth() {
    #expect(
      MarqueeTextGeometry.shouldScroll(
        contentWidth: 140, availableWidth: 100, reduceMotion: false
      )
    )
  }

  @Test
  func doesNotScrollUnderReduceMotion() {
    #expect(
      MarqueeTextGeometry.shouldScroll(
        contentWidth: 140, availableWidth: 100, reduceMotion: true
      ) == false
    )
  }

  @Test
  func doesNotScrollWhenAvailableWidthIsUnresolved() {
    let unresolvedWidths: [CGFloat] = [0, -1, .infinity, .nan]

    for availableWidth in unresolvedWidths {
      #expect(
        MarqueeTextGeometry.shouldScroll(
          contentWidth: 140, availableWidth: availableWidth, reduceMotion: false
        ) == false
      )
    }
  }

  @Test
  func scrollDistanceIsTheOverflowBeyondAvailableWidth() {
    #expect(MarqueeTextGeometry.scrollDistance(contentWidth: 140, availableWidth: 100) == 40)
  }

  @Test
  func scrollDistanceIsZeroWhenTextFits() {
    #expect(MarqueeTextGeometry.scrollDistance(contentWidth: 90, availableWidth: 100) == 0)
  }

  @Test
  func travelDurationScalesWithDistance() {
    let shorter = MarqueeTextGeometry.travelDuration(distance: 60, pointsPerSecond: 30)
    let longer = MarqueeTextGeometry.travelDuration(distance: 120, pointsPerSecond: 30)

    #expect(shorter == 2)
    #expect(longer == shorter * 2)
  }

  @Test
  func travelDurationHasAFloorForShortOverflows() {
    #expect(
      MarqueeTextGeometry.travelDuration(distance: 3, pointsPerSecond: 30)
        == MarqueeTextGeometry.minimumTravelSeconds
    )
  }

  @Test
  func cycleDurationCoversBothTravelsAndBothDwells() {
    let distance: CGFloat = 60
    let pointsPerSecond: CGFloat = 30
    let expected = MarqueeTextGeometry.cycleSchedule(
      distance: distance, pointsPerSecond: pointsPerSecond
    ).reduce(0) { $0 + $1.duration }

    #expect(
      MarqueeTextGeometry.cycleDuration(distance: distance, pointsPerSecond: pointsPerSecond)
        == expected
    )
  }

  /// The cycle is a round trip, not a reveal-and-reset: the line dwells, travels out, dwells, and
  /// travels back at the same speed, so the view can loop it without ever snapping the text home.
  @Test
  func cycleScheduleDwellsTravelsOutDwellsAndTravelsBack() {
    let distance: CGFloat = 60
    let pointsPerSecond: CGFloat = 30
    let travel = MarqueeTextGeometry.travelDuration(
      distance: distance, pointsPerSecond: pointsPerSecond)

    #expect(
      MarqueeTextGeometry.cycleSchedule(distance: distance, pointsPerSecond: pointsPerSecond)
        == [
          MarqueePassStep(
            phase: .atStart, offset: 0, duration: MarqueeTextGeometry.dwellSeconds, animated: false),
          MarqueePassStep(phase: .travelling, offset: -distance, duration: travel, animated: true),
          MarqueePassStep(
            phase: .atEnd, offset: -distance, duration: MarqueeTextGeometry.dwellSeconds, animated: false),
          MarqueePassStep(phase: .travelling, offset: 0, duration: travel, animated: true),
        ]
    )
  }

  @Test
  func cycleScheduleEndsWhereItBeginsSoItCanRepeatWithoutASnap() {
    let schedule = MarqueeTextGeometry.cycleSchedule(distance: 60, pointsPerSecond: 30)

    #expect(schedule.first?.offset == schedule.last?.offset)
    #expect(schedule.last?.animated == true)
    #expect(schedule.allSatisfy { $0.duration > 0 })
  }

  @Test
  func edgeFadesFollowThePassPhase() {
    let expectedWidth = MarqueeTextGeometry.defaultEdgeFadeWidth

    #expect(
      MarqueeTextGeometry.edgeFades(phase: .atStart, distance: 40, availableWidth: 100)
        == (leading: 0, trailing: expectedWidth)
    )
    #expect(
      MarqueeTextGeometry.edgeFades(phase: .travelling, distance: 40, availableWidth: 100)
        == (leading: expectedWidth, trailing: expectedWidth)
    )
    #expect(
      MarqueeTextGeometry.edgeFades(phase: .atEnd, distance: 40, availableWidth: 100)
        == (leading: expectedWidth, trailing: 0)
    )
  }

  @Test(arguments: [CGFloat.zero, .nan, .infinity, -.infinity])
  func zeroOrNonFiniteDistanceDoesNotAnimate(distance: CGFloat) {
    let schedule = MarqueeTextGeometry.cycleSchedule(distance: distance, pointsPerSecond: 30)

    #expect(schedule.allSatisfy { $0.animated == false })
  }
}
