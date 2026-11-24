import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Seek feedback bubble")
@MainActor
struct SeekFeedbackBubbleTests {

  @Test("skip feedback window is the named 900 millisecond token")
  func skipFeedbackWindow() {
    #expect(PlayerMetric.seekFeedbackSkipWindow == .milliseconds(900))
  }

  @Test("bubble geometry is compact and clears the visual track")
  func geometryIsPositiveAndClear() {
    #expect(PlayerMetric.seekFeedbackCornerRadius > 0)
    #expect(PlayerMetric.seekFeedbackHorizontalPadding > 0)
    #expect(PlayerMetric.seekFeedbackVerticalPadding > 0)
    #expect(PlayerMetric.seekFeedbackTrackGap > 0)
    #expect(PlayerMetric.seekFeedbackTrackGap < PlayerMetric.scrubberHitTargetHeight)
  }

  @Test("seek feedback animation is disabled under Reduce Motion")
  func animationRespectsReduceMotion() {
    #expect(PlayerMotion.seekFeedbackAnimation(reduceMotion: true) == nil)
    #expect(PlayerMotion.seekFeedbackAnimation(reduceMotion: false) != nil)
  }

  @Test("bubble preserves caller text and is constructible")
  func bubblePreservesText() {
    let bubble = SeekFeedbackBubble(text: "+30 sec")
    #expect(bubble.text == "+30 sec")
  }

  @Test("bubble body disables interaction and accessibility")
  func bubbleBodyIsNonInteractiveAndHidden() {
    let bubble = SeekFeedbackBubble(text: "+30 sec")
    var dumped = ""
    dump(bubble.body, to: &dumped)
    #expect(dumped.contains("_AllowsHitTestingModifier"))
    #expect(dumped.contains("AccessibilityAttachmentModifier"))
  }
}
