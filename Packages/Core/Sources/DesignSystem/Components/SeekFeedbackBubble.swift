import SwiftUI

/// A caller-positioned, zero-layout-impact label for an already-formatted seek value.
///
/// The bubble is hidden from VoiceOver and hit testing because the timeline owns
/// the single interactive and accessible representation of the seek position.
public struct SeekFeedbackBubble: View {
  public let text: String

  public init(text: String) {
    self.text = text
  }

  public var body: some View {
    Text(text)
      .font(.system(.subheadline, design: .monospaced).weight(.semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: true)
      .padding(.horizontal, PlayerMetric.seekFeedbackHorizontalPadding)
      .padding(.vertical, PlayerMetric.seekFeedbackVerticalPadding)
      // An opaque dark fill rather than a material: a material resolves against the ambient
      // appearance, so a light resolution would put white text on a light capsule. The cover
      // accent is unusable here for the same reason: the palette cannot guarantee contrast.
      .background(Color.black.opacity(0.88), in: bubbleShape)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var bubbleShape: some Shape {
    RoundedRectangle(
      cornerRadius: PlayerMetric.seekFeedbackCornerRadius,
      style: .continuous
    )
  }
}
