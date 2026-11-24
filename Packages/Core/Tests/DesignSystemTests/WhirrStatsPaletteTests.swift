import SwiftUI
import Testing

@testable import DesignSystem

/// The Stats screen's fixed chart colours. Contrast and hue are proved from the sRGB values, not by
/// resolving a `Color`: an AppKit-backed dynamic colour blocks in a headless test process.
@Suite struct WhirrStatsPaletteTests {

  static let lightCard = WhirrRGBColor(0.955, 0.953, 0.945)
  static let darkCard = CoverWash.neutral.dark.rgbColor

  @Test("the palette is stable by name")
  func paletteIsStableByName() {
    #expect(
      WhirrStatsPalette.allCases.map(\.rawValue) == [
        "tint", "muted", "books", "podcasts",
      ])
  }

  @Test("every light colour clears the non-text floor on the card and the page", arguments: WhirrStatsPalette.allCases)
  func lightContrast(palette: WhirrStatsPalette) {
    let card = contrastRatio(palette.lightRGB, Self.lightCard)
    let page = contrastRatio(palette.lightRGB, WhirrColorToken.editorialBackground.lightRGB)

    #expect(card >= 3, "\(palette) on the light card is \(card)")
    #expect(page >= 3, "\(palette) on the light page is \(page)")
  }

  @Test("every dark colour clears the non-text floor on the page and the card", arguments: WhirrStatsPalette.allCases)
  func darkContrast(palette: WhirrStatsPalette) {
    let page = contrastRatio(palette.darkRGB, WhirrColorToken.editorialBackground.darkRGB)
    let card = contrastRatio(palette.darkRGB, Self.darkCard)

    #expect(page >= 3, "\(palette) on the dark page is \(page)")
    #expect(card >= 3, "\(palette) on the dark card is \(card)")
  }

  /// The split's halves sit side by side in one graphic, and its rows beside tint-coloured marks,
  /// so the distinction cannot rest on lightness alone.
  @Test("the split's colours differ in hue from each other and from the tint")
  func groupHuesSeparate() {
    let groups: [[WhirrStatsPalette]] = [[.books, .podcasts, .tint]]
    for group in groups {
      for (index, first) in group.enumerated() {
        for second in group[(index + 1)...] {
          let light = Self.hueDistance(first.lightRGB, second.lightRGB)
          let dark = Self.hueDistance(first.darkRGB, second.darkRGB)
          #expect(light >= 60, "\(first) and \(second) are \(light) degrees apart in light")
          #expect(dark >= 60, "\(first) and \(second) are \(dark) degrees apart in dark")
        }
      }
    }
  }

  @Test("the tint is the app's navy in light appearance")
  func tintIsBrandNavy() {
    #expect(WhirrStatsPalette.tint.lightRGB == WhirrColorToken.brandInk.lightRGB)
  }

  @Test("heatmap levels rise from empty to full and clamp at the ends")
  func heatLevels() {
    #expect(WhirrStatsPalette.heatLevel(0) == 0)
    #expect(WhirrStatsPalette.heatLevel(4) == 1)
    #expect(WhirrStatsPalette.heatLevel(-3) == 0)
    #expect(WhirrStatsPalette.heatLevel(9) == 1)

    let levels = (0...4).map(WhirrStatsPalette.heatLevel)
    #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 })
  }

  // MARK: - Hue

  static func hueDegrees(_ color: WhirrRGBColor) -> Double {
    let high = max(color.red, color.green, color.blue)
    let low = min(color.red, color.green, color.blue)
    let span = high - low
    guard span > 0 else { return 0 }

    let sector: Double
    switch high {
    case color.red: sector = (color.green - color.blue) / span
    case color.green: sector = (color.blue - color.red) / span + 2
    default: sector = (color.red - color.green) / span + 4
    }
    let degrees = sector * 60
    return degrees < 0 ? degrees + 360 : degrees
  }

  static func hueDistance(_ first: WhirrRGBColor, _ second: WhirrRGBColor) -> Double {
    let difference = abs(hueDegrees(first) - hueDegrees(second))
    return min(difference, 360 - difference)
  }
}
