import Foundation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// A concrete color expressed as sRGB components. Backs a `Color` and also lets tests
/// compute WCAG contrast ratios deterministically, with no rendering required.
public struct WhirrRGBColor: Sendable, Equatable {
  public let red: Double
  public let green: Double
  public let blue: Double

  public init(_ red: Double, _ green: Double, _ blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public var color: Color {
    Color(red: red, green: green, blue: blue)
  }

  /// WCAG relative luminance: https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
  public var relativeLuminance: Double {
    func channel(_ component: Double) -> Double {
      component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }
}

/// WCAG contrast ratio between two colors (range 1...21; higher is more contrast).
/// https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
public func contrastRatio(_ a: WhirrRGBColor, _ b: WhirrRGBColor) -> Double {
  let lighter = max(a.relativeLuminance, b.relativeLuminance)
  let darker = min(a.relativeLuminance, b.relativeLuminance)
  return (lighter + 0.05) / (darker + 0.05)
}

/// How far past a requested contrast floor the solvers below land.
///
/// The round trip from a solved colour through `UIColor` and the display's colour space moves its
/// components by around 1e-8, so a solve stopping on the floor ships a value a hair under it about
/// half the time. The margin is fifty times that drift and three orders of magnitude below what an
/// eye or an audit tool distinguishes.
private let contrastSolveMargin = 1e-6

/// Returns the least-shifted version of `preferred` that clears a non-text contrast floor on
/// `background`. The solve moves toward whichever endpoint (black or white) gives the stronger
/// contrast and checks the resulting sRGB colour with the same WCAG arithmetic used by the tests.
public func nonTextContrastColor(
  preferred: WhirrRGBColor,
  on background: WhirrRGBColor,
  minimumRatio: Double = 3.0
) -> WhirrRGBColor {
  let minimumRatio = minimumRatio * (1 + contrastSolveMargin)
  guard minimumRatio > 1, contrastRatio(preferred, background) < minimumRatio else {
    return preferred
  }

  let black = WhirrRGBColor(0, 0, 0)
  let white = WhirrRGBColor(1, 1, 1)
  let target =
    contrastRatio(black, background) >= contrastRatio(white, background) ? black : white

  guard contrastRatio(target, background) >= minimumRatio else {
    return target
  }

  var lower = 0.0
  var upper = 1.0
  for _ in 0..<40 {
    let amount = (lower + upper) / 2
    let candidate = WhirrRGBColor(
      preferred.red + (target.red - preferred.red) * amount,
      preferred.green + (target.green - preferred.green) * amount,
      preferred.blue + (target.blue - preferred.blue) * amount)
    if contrastRatio(candidate, background) >= minimumRatio {
      upper = amount
    } else {
      lower = amount
    }
  }

  return WhirrRGBColor(
    preferred.red + (target.red - preferred.red) * upper,
    preferred.green + (target.green - preferred.green) * upper,
    preferred.blue + (target.blue - preferred.blue) * upper)
}

/// Returns the least opacity for a foreground over a background that clears a non-text contrast
/// floor. Alpha is composited in sRGB, matching the concrete colour representation used by
/// `WhirrRGBColor` and by SwiftUI's opacity rendering for these opaque tokens.
public func nonTextContrastOpacity(
  foreground: WhirrRGBColor,
  over background: WhirrRGBColor,
  minimumRatio: Double = 3.0
) -> Double {
  func composite(_ opacity: Double) -> WhirrRGBColor {
    WhirrRGBColor(
      opacity * foreground.red + (1 - opacity) * background.red,
      opacity * foreground.green + (1 - opacity) * background.green,
      opacity * foreground.blue + (1 - opacity) * background.blue)
  }

  let minimumRatio = minimumRatio * (1 + contrastSolveMargin)
  guard minimumRatio > 1 else { return 0 }
  guard contrastRatio(composite(1), background) >= minimumRatio else { return 1 }

  var lower = 0.0
  var upper = 1.0
  for _ in 0..<40 {
    let midpoint = (lower + upper) / 2
    if contrastRatio(composite(midpoint), background) >= minimumRatio {
      upper = midpoint
    } else {
      lower = midpoint
    }
  }
  return upper
}

/// The ink to lay on a cover accent: whichever of the two pinned inks contrasts with it more.
///
/// A cover accent is whatever the artwork contained, so an assumed foreground is a bet: white on
/// the neutral fallback accent is 1.55:1, well under the 4.5:1 normal text needs.
///
/// Two candidates, not a continuous solve, which would give muddy one-off colours outside the
/// palette. The darkest accent still clears AA against the light ink and the lightest against
/// the dark one, so the winner always passes.
public func legibleForeground(on accent: WhirrRGBColor) -> WhirrRGBColor {
  let dark = WhirrColorToken.onAccentDarkInk
  let light = WhirrColorToken.onAccentLightInk
  return contrastRatio(dark, accent) >= contrastRatio(light, accent) ? dark : light
}

/// A cover accent used as a fill, together with the ink that is legible on it.
public struct WhirrAccentPair: Sendable, Equatable {
  public let fill: WhirrRGBColor
  public let ink: WhirrRGBColor

  public init(fill: WhirrRGBColor, ink: WhirrRGBColor) {
    self.fill = fill
    self.ink = ink
  }
}

/// Resolves an arbitrary cover accent into a fill-and-ink pair that clears `minimumRatio`.
///
/// The better of two inks is not always enough: a mid-grey manages about 4.0:1 against the dark
/// ink and 3.9:1 against white, so the fill moves, as a tint or shade blended away from whichever
/// ink won. That keeps the accent's hue and changes only its lightness. An accent that already
/// clears the floor is returned untouched.
public func legibleAccentPair(
  for accent: WhirrRGBColor, minimumRatio: Double = 4.5
) -> WhirrAccentPair {
  let ink = legibleForeground(on: accent)
  guard contrastRatio(ink, accent) < minimumRatio else {
    return WhirrAccentPair(fill: accent, ink: ink)
  }

  // Away from the ink: a dark ink wants a lighter fill behind it, a light ink a darker one.
  let target: WhirrRGBColor =
    ink == WhirrColorToken.onAccentDarkInk ? WhirrRGBColor(1, 1, 1) : WhirrRGBColor(0, 0, 0)

  // 100 steps of 1% is finer than the eye resolves and always reaches the target, whose own
  // contrast with the opposing ink is 21:1, so the loop cannot fall out without clearing.
  var fill = accent
  for step in 1...100 {
    let amount = Double(step) / 100.0
    fill = WhirrRGBColor(
      accent.red + (target.red - accent.red) * amount,
      accent.green + (target.green - accent.green) * amount,
      accent.blue + (target.blue - accent.blue) * amount)
    if contrastRatio(ink, fill) >= minimumRatio { break }
  }
  return WhirrAccentPair(fill: fill, ink: ink)
}

/// The dynamic-appearance counterpart to `legibleAccentPair`.
///
/// A cover accent arrives as `CoverWash`'s `accentColor`, a mid-dark ink in light appearance and
/// a bright one in dark. Pairing a once-resolved value would fix the ink to the appearance
/// current at build time, so the pairing runs inside the trait closure, once per appearance.
/// Fill and ink are returned together: an ink chosen against another fill is wrong.
#if canImport(UIKit)
  public func legibleAccentColors(
    for accent: Color, minimumRatio: Double = 4.5
  ) -> (fill: Color, ink: Color) {
    func pair(for traits: UITraitCollection) -> WhirrAccentPair {
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      UIColor(accent).resolvedColor(with: traits)
        .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      return legibleAccentPair(
        for: WhirrRGBColor(Double(red), Double(green), Double(blue)),
        minimumRatio: minimumRatio)
    }
    func uiColor(_ component: @escaping (WhirrAccentPair) -> WhirrRGBColor) -> Color {
      Color(
        uiColor: UIColor { traits in
          let value = component(pair(for: traits))
          return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    }
    return (uiColor(\.fill), uiColor(\.ink))
  }
#elseif canImport(AppKit)
  /// AppKit cannot resolve an arbitrary `Color` for an appearance other than the current one,
  /// so this pairs the colour as it resolves right now. The package builds for macOS only to
  /// run its tests; the per-appearance contract is carried by `legibleAccentPair` underneath.
  public func legibleAccentColors(
    for accent: Color, minimumRatio: Double = 4.5
  ) -> (fill: Color, ink: Color) {
    guard let srgb = NSColor(accent).usingColorSpace(.sRGB) else {
      return (accent, WhirrColorToken.onAccentLightInk.color)
    }
    let pair = legibleAccentPair(
      for: WhirrRGBColor(
        Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)),
      minimumRatio: minimumRatio)
    return (pair.fill.color, pair.ink.color)
  }
#endif

/// Semantic color tokens. Stable by name (`rawValue`), and each backed by a dynamic system
/// color rather than a fixed value, so the whole app follows the light/dark/Increase Contrast
/// appearance instead of pinning one scheme. Each token names a role and lets the system
/// supply the value for the current appearance, as the HIG's Color guidance advises.
public enum WhirrColorToken: String, CaseIterable, Sendable {
  case textPrimary
  case textSecondary
  case surfacePrimary
  case surfaceSecondary
  case groupedSurface
  case accent
  case editorialBackground
  case brandInk

  public static let neutralCoverAccent = WhirrRGBColor(0.92, 0.80, 0.55)

  /// The two candidates `legibleForeground(on:)` chooses between. The dark one is `brandInk`'s
  /// light value, so a label on an accent reads as the same ink as the page around it. The
  /// light one is plain white, which a genuinely dark accent needs.
  public static let onAccentDarkInk = WhirrColorToken.brandInk.lightRGB
  public static let onAccentLightInk = WhirrRGBColor(1, 1, 1)

  public var lightRGB: WhirrRGBColor {
    switch self {
    case .editorialBackground: WhirrRGBColor(251.0 / 255.0, 251.0 / 255.0, 249.0 / 255.0)
    case .brandInk: WhirrRGBColor(28.0 / 255.0, 42.0 / 255.0, 58.0 / 255.0)
    // Solved against the darkest light cover wash (blue, at the wash's saturation and brightness
    // clamps), not against paper: a home card is the dimmest ground this ink is drawn on.
    case .textSecondary: WhirrRGBColor(79.0 / 255.0, 86.0 / 255.0, 98.0 / 255.0)
    default: WhirrRGBColor(0, 0, 0)
    }
  }

  public var darkRGB: WhirrRGBColor {
    switch self {
    case .editorialBackground: WhirrRGBColor(11.0 / 255.0, 13.0 / 255.0, 14.0 / 255.0)
    case .brandInk: WhirrRGBColor(223.0 / 255.0, 229.0 / 255.0, 238.0 / 255.0)
    case .textSecondary: WhirrRGBColor(155.0 / 255.0, 165.0 / 255.0, 178.0 / 255.0)
    default: WhirrRGBColor(0, 0, 0)
    }
  }

  /// Increase Contrast variants for the tokens that carry literal values. The paper goes to pure
  /// white and the ink further toward black, since contrast is a property of the pair and
  /// strengthening one side gains little.
  ///
  /// `textSecondary` is here because the platform's secondary label recedes at every setting:
  /// Increase Contrast only moved it from about 3.2:1 to 3.92-4.00:1, still short of AA.
  public var lightHighContrastRGB: WhirrRGBColor {
    switch self {
    case .editorialBackground: WhirrRGBColor(1, 1, 1)
    case .brandInk: WhirrRGBColor(8.0 / 255.0, 14.0 / 255.0, 22.0 / 255.0)
    case .textSecondary: WhirrRGBColor(70.0 / 255.0, 76.0 / 255.0, 87.0 / 255.0)
    default: lightRGB
    }
  }

  public var darkHighContrastRGB: WhirrRGBColor {
    switch self {
    case .editorialBackground: WhirrRGBColor(0, 0, 0)
    case .brandInk: WhirrRGBColor(247.0 / 255.0, 250.0 / 255.0, 253.0 / 255.0)
    case .textSecondary: WhirrRGBColor(184.0 / 255.0, 193.0 / 255.0, 205.0 / 255.0)
    default: darkRGB
    }
  }

  #if canImport(UIKit)
    /// The literal value for a resolved appearance, including Increase Contrast. Only
    /// `editorialBackground`, `brandInk` and `textSecondary` vary; every other token is
    /// system-backed and the platform resolves it.
    func resolved(for traits: UITraitCollection) -> WhirrRGBColor {
      let isDark = traits.userInterfaceStyle == .dark
      let decision = WhirrContrastPolicy.decide(
        prefersIncreasedContrast: traits.prefersIncreasedContrast)
      guard decision.usesStrengthenedInk else {
        return isDark ? darkRGB : lightRGB
      }
      return isDark ? darkHighContrastRGB : lightHighContrastRGB
    }
  #endif

  public var color: Color {
    switch self {
    case .textPrimary: return .primary
    case .textSecondary: return .absTextSecondary
    case .surfacePrimary: return .absSystemBackground
    case .surfaceSecondary: return .absSecondarySystemBackground
    case .groupedSurface: return .absGroupedSystemBackground
    case .accent: return .accentColor
    case .editorialBackground: return .absEditorialBackground
    case .brandInk: return .absBrandInk
    }
  }

}

// No `resolve(in:)`-style component accessor here: resolving an AppKit-backed dynamic color
// blocks indefinitely in a headless test process, so `DesignTokenTests` asserts the mapping by
// identity and the light/dark proof lives in `WhirrTests` (iOS), where `UITraitCollection`
// resolves for real.
extension Color {
  /// The platform's base and second-level view backgrounds. SwiftUI ships cross-platform
  /// semantic colors for content (`.primary`/`.secondary`) but not for backgrounds, so these
  /// bridge to the platform color the system already defines, using the
  /// `#if canImport(UIKit)` escape hatch ARCHITECTURE.md allows for iOS-only APIs below `App`.
  /// Internal, not fileprivate, so the token test can name the same expectation.
  static var absSystemBackground: Color {
    #if canImport(UIKit)
      return Color(uiColor: .systemBackground)
    #else
      return Color(nsColor: .windowBackgroundColor)
    #endif
  }

  static var absSecondarySystemBackground: Color {
    #if canImport(UIKit)
      return Color(uiColor: .secondarySystemBackground)
    #else
      return Color(nsColor: .underPageBackgroundColor)
    #endif
  }

  /// The macOS arm picks a different NSColor from `absSecondarySystemBackground`'s. AppKit has
  /// no grouped-background role, but letting the two collide on the test host would blunt
  /// `colorTokensAreDistinct` for every token.
  static var absGroupedSystemBackground: Color {
    #if canImport(UIKit)
      return Color(uiColor: .systemGroupedBackground)
    #else
      return Color(nsColor: .controlBackgroundColor)
    #endif
  }

  static let absEditorialBackground: Color = {
    #if canImport(UIKit)
      Color(
        uiColor: UIColor { traits in
          let rgb = WhirrColorToken.editorialBackground.resolved(for: traits)
          return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #else
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          let rgb =
            isDark
            ? WhirrColorToken.editorialBackground.darkRGB
            : WhirrColorToken.editorialBackground.lightRGB
          return NSColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #endif
  }()

  /// Supporting text, pinned rather than deferred to `.secondary`.
  ///
  /// The platform's secondary label is `#3C3C43` at 60%, about 3.39:1 on white and 3.15:1 on the
  /// unselected-chip grey, and no appearance or Increase Contrast setting brings it to AA. These
  /// values clear 4.5:1 against the lightest ground the app draws them on while staying well
  /// below `brandInk`, so the hierarchy survives.
  static let absTextSecondary: Color = {
    #if canImport(UIKit)
      Color(
        uiColor: UIColor { traits in
          let rgb = WhirrColorToken.textSecondary.resolved(for: traits)
          return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #else
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          let rgb =
            isDark
            ? WhirrColorToken.textSecondary.darkRGB
            : WhirrColorToken.textSecondary.lightRGB
          return NSColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #endif
  }()

  static let absBrandInk: Color = {
    #if canImport(UIKit)
      Color(
        uiColor: UIColor { traits in
          let rgb = WhirrColorToken.brandInk.resolved(for: traits)
          return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #else
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          let rgb = isDark ? WhirrColorToken.brandInk.darkRGB : WhirrColorToken.brandInk.lightRGB
          return NSColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #endif
  }()

  static let absSecondarySystemFill: Color = {
    #if canImport(UIKit)
      Color(uiColor: .secondarySystemFill)
    #else
      Color(nsColor: .controlBackgroundColor)
    #endif
  }()
}
