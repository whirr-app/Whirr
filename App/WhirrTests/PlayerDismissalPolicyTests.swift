import CoreGraphics
import Foundation
import Testing

@testable import Whirr

@Suite("Player dismissal policy")
struct PlayerDismissalPolicyTests {

  @Test("downward vertically dominant motion begins dismissal")
  func downwardVerticallyDominantMotionBeginsDismissal() {
    #expect(PlayerDismissalPolicy.shouldBegin(velocity: CGPoint(x: 20, y: 100)))
    #expect(PlayerDismissalPolicy.shouldBegin(velocity: CGPoint(x: 80, y: 100)))
  }

  @Test("upward or horizontally dominant motion does not begin dismissal")
  func upwardOrHorizontallyDominantMotionDoesNotBeginDismissal() {
    #expect(!PlayerDismissalPolicy.shouldBegin(velocity: CGPoint(x: 20, y: -100)))
    #expect(!PlayerDismissalPolicy.shouldBegin(velocity: CGPoint(x: 100, y: 20)))
  }

  @Test("non-finite velocity does not begin dismissal")
  func nonFiniteVelocityDoesNotBeginDismissal() {
    #expect(!PlayerDismissalPolicy.shouldBegin(velocity: CGPoint(x: CGFloat.nan, y: 100)))
    #expect(!PlayerDismissalPolicy.shouldBegin(velocity: CGPoint(x: 20, y: CGFloat.infinity)))
  }

  @Test("the scroll view is eligible at its top and within one point of it")
  func scrollViewIsEligibleAtTopAndWithinOnePoint() {
    #expect(
      PlayerDismissalPolicy.isAtScrollTop(contentOffsetY: -20, adjustedContentInsetTop: 20))
    #expect(
      PlayerDismissalPolicy.isAtScrollTop(contentOffsetY: -19, adjustedContentInsetTop: 20))
    #expect(
      !PlayerDismissalPolicy.isAtScrollTop(contentOffsetY: 20, adjustedContentInsetTop: 20))
  }

  @Test("non-finite scroll boundary inputs are not eligible")
  func nonFiniteScrollBoundaryInputsAreNotEligible() {
    #expect(
      !PlayerDismissalPolicy.isAtScrollTop(
        contentOffsetY: .nan, adjustedContentInsetTop: 20))
    #expect(
      !PlayerDismissalPolicy.isAtScrollTop(
        contentOffsetY: -20, adjustedContentInsetTop: .infinity))
  }

  @Test("progress clamps negative, oversized, and mid-travel translations")
  func progressClampsNegativeOversizedAndMidTravelTranslations() {
    #expect(PlayerDismissalPolicy.progress(translationY: -20, containerHeight: 800) == 0)
    #expect(PlayerDismissalPolicy.progress(translationY: 1_000, containerHeight: 800) == 1)
    #expect(PlayerDismissalPolicy.progress(translationY: 200, containerHeight: 800) == 0.25)
  }

  @Test("invalid progress inputs resolve to zero")
  func invalidProgressInputsResolveToZero() {
    #expect(PlayerDismissalPolicy.progress(translationY: .nan, containerHeight: 800) == 0)
    #expect(PlayerDismissalPolicy.progress(translationY: 200, containerHeight: .infinity) == 0)
    #expect(PlayerDismissalPolicy.progress(translationY: 200, containerHeight: 0) == 0)
  }

  @Test("a short slow release cancels")
  func shortSlowReleaseCancels() {
    #expect(
      PlayerDismissalPolicy.completion(progress: 0.1, velocityY: 50, containerHeight: 800)
        == .cancel)
  }

  @Test("a release past the distance threshold finishes")
  func releasePastDistanceThresholdFinishes() {
    #expect(
      PlayerDismissalPolicy.completion(progress: 0.2, velocityY: 0, containerHeight: 800)
        == .finish)
  }

  @Test("a short release with a strong downward flick finishes")
  func shortReleaseWithStrongDownwardFlickFinishes() {
    #expect(
      PlayerDismissalPolicy.completion(progress: 0.05, velocityY: 800, containerHeight: 800)
        == .finish)
  }

  @Test("a fast upward release does not finish on velocity")
  func fastUpwardReleaseDoesNotFinishOnVelocity() {
    #expect(
      PlayerDismissalPolicy.completion(progress: 0.05, velocityY: -1_000, containerHeight: 800)
        == .cancel)
  }

  @Test("non-finite completion inputs cancel safely")
  func nonFiniteCompletionInputsCancelSafely() {
    #expect(
      PlayerDismissalPolicy.completion(progress: .nan, velocityY: 0, containerHeight: 800)
        == .cancel)
    #expect(
      PlayerDismissalPolicy.completion(progress: 0, velocityY: .infinity, containerHeight: 800)
        == .cancel)
    #expect(
      PlayerDismissalPolicy.completion(progress: 0, velocityY: 0, containerHeight: .infinity)
        == .cancel)
  }

  @Test("completion duration follows remaining travel and stays within bounds")
  func completionDurationFollowsRemainingTravelAndStaysWithinBounds() {
    let finishDuration = PlayerDismissalPolicy.completionDuration(
      progress: 0.5, velocityY: 100, containerHeight: 800, completion: .finish)
    let cancelDuration = PlayerDismissalPolicy.completionDuration(
      progress: 0.5, velocityY: 100, containerHeight: 800, completion: .cancel)

    // 400pt of remaining travel at the 100pt/s floor wants four seconds; the ceiling holds it.
    #expect(finishDuration == PlayerDismissalPolicy.maximumCompletionDuration)
    #expect(cancelDuration == PlayerDismissalPolicy.maximumCompletionDuration)
    expectDurationIsBounded(finishDuration)
    expectDurationIsBounded(cancelDuration)
  }

  @Test("release velocity is the finger's speed over the remaining travel, signed toward the end")
  func releaseVelocityIsNormalisedAndSignedTowardTheEndState() {
    // Half way down an 800pt page, moving down at 400pt/s: one remaining travel per second.
    let finish = PlayerDismissalPolicy.releaseVelocity(
      progress: 0.5, velocityY: 400, containerHeight: 800, completion: .finish)
    #expect(finish == 1)

    // The same release on a cancel is heading away from rest, so the spring starts negative.
    let cancel = PlayerDismissalPolicy.releaseVelocity(
      progress: 0.5, velocityY: 400, containerHeight: 800, completion: .cancel)
    #expect(cancel == -1)

    // A finger lifting while moving back up helps the cancel along.
    let upwardCancel = PlayerDismissalPolicy.releaseVelocity(
      progress: 0.5, velocityY: -200, containerHeight: 800, completion: .cancel)
    #expect(upwardCancel == 0.5)
  }

  @Test("release velocity is clamped and never non-finite")
  func releaseVelocityIsClampedAndFinite() {
    // A hard flick with almost nothing left to travel would otherwise ask for a huge spring kick.
    let nearEnd = PlayerDismissalPolicy.releaseVelocity(
      progress: 0.99, velocityY: 3000, containerHeight: 800, completion: .finish)
    #expect(nearEnd == PlayerDismissalPolicy.releaseVelocityCeiling)

    let nearStartCancel = PlayerDismissalPolicy.releaseVelocity(
      progress: 0.01, velocityY: 3000, containerHeight: 800, completion: .cancel)
    #expect(nearStartCancel == -PlayerDismissalPolicy.releaseVelocityCeiling)

    // Nothing left to travel, or garbage in, is a standing start rather than a trap.
    #expect(
      PlayerDismissalPolicy.releaseVelocity(
        progress: 1, velocityY: 500, containerHeight: 800, completion: .finish) == 0)
    #expect(
      PlayerDismissalPolicy.releaseVelocity(
        progress: 0, velocityY: 500, containerHeight: 800, completion: .cancel) == 0)
    #expect(
      PlayerDismissalPolicy.releaseVelocity(
        progress: 0.5, velocityY: .nan, containerHeight: 800, completion: .finish) == 0)
    #expect(
      PlayerDismissalPolicy.releaseVelocity(
        progress: 0.5, velocityY: 500, containerHeight: 0, completion: .finish) == 0)
  }

  @Test("a hard fling is paced by the velocity ceiling, not by its own speed")
  func aHardFlingIsPacedByTheVelocityCeilingNotByItsOwnSpeed() {
    // Two flings that differ only in how hard they were thrown, both from the top of the page.
    let fastDuration = PlayerDismissalPolicy.completionDuration(
      progress: 0.1, velocityY: 2400, containerHeight: 800, completion: .finish)
    let violentDuration = PlayerDismissalPolicy.completionDuration(
      progress: 0.1, velocityY: 9000, containerHeight: 800, completion: .finish)

    // Above the ceiling the page leaves at one pace, so a harder throw cannot cut the animation
    // shorter and shorter until it reads as the page being clipped away.
    #expect(fastDuration == violentDuration)
    expectDurationIsBounded(fastDuration)

    // A release below the ceiling is still timed by its own speed.
    let gentleDuration = PlayerDismissalPolicy.completionDuration(
      progress: 0.1, velocityY: 1200, containerHeight: 800, completion: .finish)
    #expect(gentleDuration > fastDuration)
    expectDurationIsBounded(gentleDuration)
  }

  @Test("invalid completion duration inputs return the minimum safely")
  func invalidCompletionDurationInputsReturnMinimumSafely() {
    let durations = [
      PlayerDismissalPolicy.completionDuration(
        progress: .nan, velocityY: 0, containerHeight: 800, completion: .finish),
      PlayerDismissalPolicy.completionDuration(
        progress: .infinity, velocityY: 0, containerHeight: 800, completion: .finish),
      PlayerDismissalPolicy.completionDuration(
        progress: 0, velocityY: .infinity, containerHeight: 800, completion: .cancel),
      PlayerDismissalPolicy.completionDuration(
        progress: 0, velocityY: 0, containerHeight: .infinity, completion: .finish),
      PlayerDismissalPolicy.completionDuration(
        progress: 0, velocityY: 0, containerHeight: 0, completion: .finish),
    ]

    for duration in durations {
      #expect(duration == PlayerDismissalPolicy.minimumCompletionDuration)
      expectDurationIsBounded(duration)
    }
  }

  private func expectDurationIsBounded(_ duration: TimeInterval) {
    #expect(duration.isFinite)
    #expect(duration >= PlayerDismissalPolicy.minimumCompletionDuration)
    #expect(duration <= PlayerDismissalPolicy.maximumCompletionDuration)
  }
}
