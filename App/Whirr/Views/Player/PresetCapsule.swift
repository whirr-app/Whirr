import DesignSystem
import SwiftUI

/// One preset in a row of capsules, as the speed card draws its speeds. Selected is
/// solid ink inverted against the colour scheme, unselected the tertiary fill, so the selection
/// stays neutral over any artwork-themed player.
struct PresetCapsule: View {
  let title: String
  let isSelected: Bool
  /// A fixed width, as the speed card's grid uses; nil fills the width offered, so a row of
  /// capsules shares it equally.
  var width: CGFloat? = nil
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @ScaledMetric(relativeTo: .body) private var height: CGFloat = WhirrMetric.minimumTouchTarget

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.body.weight(isSelected ? .semibold : .regular))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // Explicit white/black, not `Color.primary`: on a popover's glass a primary fill is drawn
        // vibrant and translucent, reading as a dim grey capsule closer to disabled than chosen.
        .foregroundStyle(isSelected ? inverseInk : Color.primary)
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(Capsule().fill(isSelected ? ink : Color(uiColor: .tertiarySystemFill)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var ink: Color { colorScheme == .dark ? .white : .black }
  private var inverseInk: Color { colorScheme == .dark ? .black : .white }
}
