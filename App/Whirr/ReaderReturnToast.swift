import AppModel
import DesignSystem
import SwiftUI

/// The offer to undo a jump (a rail seek, a contents entry or a search hit): a glass capsule
/// floating above the toolbar that returns to the page left behind. It withdraws itself after a
/// few seconds, except under VoiceOver, where a timed control could vanish before it is reached;
/// the close button covers that case.
struct ReaderReturnToast: View {
  static let visibleDuration: Duration = .seconds(6)

  let returnPoint: ReaderReturnPoint
  let onGoBack: () -> Void
  let onDismiss: () -> Void

  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

  var body: some View {
    GlassContainer(in: Capsule()) {
      HStack(spacing: 0) {
        Button(action: onGoBack) {
          Label(returnPoint.label, systemImage: "arrow.uturn.backward")
            .font(WhirrTypeToken.subheadline.font.weight(.semibold))
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(ReaderAccessibilityID.returnOffer)

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(WhirrTypeToken.caption.font.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(ReaderCopy.dismissReturnOffer)
      }
      .buttonStyle(.plain)
      .lineLimit(1)
      .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    .fixedSize()
    // Keyed on the return point, which changes with every jump, so each jump restarts the clock.
    .task(id: returnPoint) {
      guard voiceOverEnabled == false else { return }
      try? await Task.sleep(for: Self.visibleDuration)
      if Task.isCancelled == false { onDismiss() }
    }
    .onAppear {
      AccessibilityNotification.Announcement(returnPoint.label).post()
    }
  }
}
