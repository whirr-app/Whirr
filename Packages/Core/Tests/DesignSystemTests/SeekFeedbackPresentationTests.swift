import CoreGraphics
import Testing

@testable import DesignSystem

@Suite("Seek feedback presentation")
struct SeekFeedbackPresentationTests {

  @Test(
    "skip labels use compact signed durations",
    arguments: [
      (-15.0, "−15 sec"),
      (30.0, "+30 sec"),
      (90.0, "+1:30"),
      (-3900.0, "−1:05:00"),
      (0.0, "0 sec"),
      (3600.0, "+1:00:00"),
      (29.6, "+30 sec"),
      (Double.nan, "0 sec"),
      (Double.infinity, "0 sec"),
    ])
  func skipLabels(delta: Double, expected: String) {
    #expect(SeekFeedbackPresentation.skipLabel(deltaSeconds: delta) == expected)
  }

  @Test("scrub labels match the scoped elapsed clock shape")
  func scrubLabels() {
    #expect(SeekFeedbackPresentation.scrubLabel(targetSeconds: 0) == "00:00")
    #expect(SeekFeedbackPresentation.scrubLabel(targetSeconds: 16 * 60 + 20) == "16:20")
    #expect(SeekFeedbackPresentation.scrubLabel(targetSeconds: 3_844) == "1:04:04")
    #expect(SeekFeedbackPresentation.scrubLabel(targetSeconds: -10) == "00:00")
    #expect(SeekFeedbackPresentation.scrubLabel(targetSeconds: .nan) == "00:00")
  }

  @Test("accumulated treats non-finite operands as zero")
  func accumulation() {
    #expect(SeekFeedbackPresentation.accumulated(existing: 30, adding: 15) == 45)
    #expect(SeekFeedbackPresentation.accumulated(existing: 30, adding: -15) == 15)
    #expect(SeekFeedbackPresentation.accumulated(existing: 30, adding: -30) == 0)
    #expect(SeekFeedbackPresentation.accumulated(existing: .infinity, adding: .nan) == 0)
  }

  @Test("scrub content takes precedence over skip content")
  func resolution() {
    #expect(SeekFeedbackPresentation.resolved(scrub: 12, skip: 30) == .scrub(targetSeconds: 12))
    #expect(SeekFeedbackPresentation.resolved(scrub: nil, skip: -30) == .skip(deltaSeconds: -30))
    #expect(SeekFeedbackPresentation.resolved(scrub: nil, skip: nil) == nil)
  }

  @Test("bubble leading offset clamps its full bounds")
  func bubblePlacement() {
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: 100, bubbleWidth: 20, fraction: 0) == 0)
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: 100, bubbleWidth: 20, fraction: 1) == 80)
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: 100, bubbleWidth: 20, fraction: 0.5) == 40)
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: 100, bubbleWidth: 140, fraction: 0.1) == -20)
  }

  @Test("invalid bubble geometry is inert")
  func invalidBubbleGeometry() {
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: 0, bubbleWidth: 20, fraction: 0.5) == 0)
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: -1, bubbleWidth: 20, fraction: 0.5) == 0)
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: .nan, bubbleWidth: 20, fraction: 0.5) == 0)
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: 100, bubbleWidth: 0, fraction: 0.5) == 0)
    #expect(SeekFeedbackPresentation.bubbleCenter(trackWidth: 100, bubbleWidth: 20, fraction: .nan) == 0)
  }
}
