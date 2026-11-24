import AppModel
import DesignSystem
import Persistence
import SwiftUI
import UIKit

/// The finished mark on the item-detail hero artwork: a solid disc with a contrasting check in the
/// cover's bottom-trailing corner, as the system's media apps mark a played title.
///
/// The disc uses `\.coverAccent` (the ambient page's ink), not an artwork colour that would vanish
/// into the cover; the ring and shadow keep it legible over a light or busy cover.
struct FinishedCoverBadge: View {
  @Environment(\.coverAccent) private var accent
  let size: CGFloat

  private var scale: CGFloat { size / 40 }

  var body: some View {
    Image(systemName: "checkmark")
      .font(.system(size: 20 * scale, weight: .bold))
      .foregroundStyle(coverBadgeMarkColor(for: accent))
      .frame(width: size, height: size)
      .background(accent, in: Circle())
      .overlay {
        Circle().stroke(coverBadgeMarkColor(for: accent), lineWidth: 2 * scale)
      }
      .shadow(color: .black.opacity(0.35), radius: 8 * scale, y: 3 * scale)
      .accessibilityElement()
      .accessibilityLabel(ItemFinishedCopy.badgeLabel)
  }
}

/// The badge's disc is the surface immediately behind its outline. Resolved once to keep the quiet
/// badge treatment while guaranteeing the 3:1 non-text contrast floor for pale cover accents.
func coverBadgeMarkColor(for accent: Color) -> Color { coverBadgeMarkRGB(for: accent).color }

private func coverBadgeMarkRGB(for accent: Color) -> WhirrRGBColor {
  nonTextContrastColor(preferred: WhirrRGBColor(1, 1, 1), on: coverBadgeDiscRGB(for: accent))
}

private func coverBadgeDiscRGB(for accent: Color) -> WhirrRGBColor {
  var red: CGFloat = 0
  var green: CGFloat = 0
  var blue: CGFloat = 0
  var alpha: CGFloat = 0
  UIColor(accent).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
  return WhirrRGBColor(Double(red), Double(green), Double(blue))
}
