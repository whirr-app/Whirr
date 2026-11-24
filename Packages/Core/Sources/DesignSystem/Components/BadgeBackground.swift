import SwiftUI

/// What a badge is drawn on: a flat translucent tone, light in light mode and dark in dark mode, so
/// a badge's default foreground and a tinted mark both read on it.
///
/// Never a material: badges repeat (up to two per cover in a grid) and each material costs the
/// render server an offscreen blur pass. On a 13-inch iPad the Library's covers came to about 120
/// passes a frame, holding scrolling at about 80 fps; a flat fill gives 120.
struct BadgeFill: Equatable, Sendable {
  /// Grey level of the fill, 0 black to 1 white.
  let white: Double
  let opacity: Double

  static func decide(
    colorScheme: ColorScheme, reduceTransparency: Bool, increasedContrast: Bool
  ) -> BadgeFill {
    let white = colorScheme == .dark ? 0.12 : 1.0
    let opacity: Double =
      if reduceTransparency {
        1
      } else if increasedContrast {
        0.9
      } else {
        colorScheme == .dark ? 0.6 : 0.75
      }
    return BadgeFill(white: white, opacity: opacity)
  }
}

private struct BadgeBackground<Fill: Shape>: View {
  let shape: Fill

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let fill = BadgeFill.decide(
      colorScheme: colorScheme, reduceTransparency: reduceTransparency,
      increasedContrast: contrast == .increased)
    shape.fill(Color(white: fill.white).opacity(fill.opacity))
  }
}

extension View {
  /// Draws `shape` behind the view in the shared badge fill. Use this, not a material, for any
  /// small mark that repeats across a grid or list.
  public func badgeBackground<Fill: Shape>(in shape: Fill) -> some View {
    background(BadgeBackground(shape: shape))
  }
}
