import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The Stats screen's fixed palette for its charts, bars and heatmap.
///
/// Deliberately not cover-derived: a cover accent says nothing about which series it marks, and a
/// podcast that keeps accruing time would keep painting the page its own colour. One tint carries
/// every measure of progress, `muted` is the comparison or remainder beside it, and only the
/// books/podcasts split needs two hues of its own, kept dusty so they sit with the navy. Light
/// values are dark enough, and dark values light enough, to clear the 3:1 non-text floor against
/// the page and the card; `WhirrStatsPaletteTests` holds that.
public enum WhirrStatsPalette: String, CaseIterable, Sendable {
  /// Whirr's navy, the tint of the app's switches and setup flow (`AppChrome.brandTint`).
  case tint
  case muted
  case books
  case podcasts

  public var lightRGB: WhirrRGBColor {
    switch self {
    case .tint: WhirrColorToken.brandInk.lightRGB
    case .muted: WhirrRGBColor(124.0 / 255.0, 133.0 / 255.0, 146.0 / 255.0)
    case .books: WhirrRGBColor(160.0 / 255.0, 86.0 / 255.0, 59.0 / 255.0)
    case .podcasts: WhirrRGBColor(122.0 / 255.0, 74.0 / 255.0, 120.0 / 255.0)
    }
  }

  public var darkRGB: WhirrRGBColor {
    switch self {
    // `AppChrome.brandTint`'s dark navy (88, 120, 154) blended 12% toward white: that navy is
    // 2.56:1 on the dark card, short of the 3:1 a chart mark needs.
    case .tint: WhirrRGBColor(108.0 / 255.0, 136.0 / 255.0, 166.0 / 255.0)
    case .muted: WhirrRGBColor(128.0 / 255.0, 138.0 / 255.0, 151.0 / 255.0)
    case .books: WhirrRGBColor(217.0 / 255.0, 154.0 / 255.0, 126.0 / 255.0)
    case .podcasts: WhirrRGBColor(199.0 / 255.0, 155.0 / 255.0, 196.0 / 255.0)
    }
  }

  /// A colour that follows the light/dark appearance, resolved by the platform like the app's
  /// other dynamic tokens rather than pinned to whichever appearance was current at launch.
  public var color: Color {
    #if canImport(UIKit)
      return Color(
        uiColor: UIColor { traits in
          let rgb = traits.userInterfaceStyle == .dark ? darkRGB : lightRGB
          return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #elseif canImport(AppKit)
      return Color(
        nsColor: NSColor(name: nil) { appearance in
          let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkRGB : lightRGB
          return NSColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    #else
      return lightRGB.color
    #endif
  }

  /// The heatmap's fill opacity for a level. Level 0 is the empty cell, which the App draws as a
  /// faint neutral instead, so it returns nothing. Out-of-range levels clamp to the ends.
  public static func heatLevel(_ level: Int) -> Double {
    switch level {
    case ...0: 0
    case 1: 0.22
    case 2: 0.45
    case 3: 0.7
    default: 1
    }
  }
}
