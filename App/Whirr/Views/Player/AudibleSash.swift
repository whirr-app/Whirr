import DesignSystem
import Foundation

/// Audible's "Only from Audible" sash: a yellow band laid diagonally across the bottom-right corner
/// of its covers. Saturated enough to outscore a muted cover's own colour in
/// `CoverAccentSelection`, so the corner is blanked before colours are picked. Positions are
/// fractions of width and height from the top left; the band lies between two values of `x + y`,
/// about 1.6 to 1.82 on the covers measured.
nonisolated enum AudibleSash {
  /// The band's middle, clear of its edges at any analysis size, where it must read as yellow.
  static let probe: ClosedRange<Double> = 1.64...1.78
  /// Everything from here to the corner is blanked: the band with a margin, and the corner beyond
  /// it, which is too small to carry a cover's colour.
  static let maskStart = 1.54
  /// The share of `probe` that must be sash yellow. Some of the band is the lettering on it.
  static let minimumYellowShare = 0.8
  /// The fewest pixels `probe` must hold for the test to mean anything.
  static let minimumProbePixels = 8
  /// OKLCh hue, in degrees, and least chroma of the sash's yellow.
  static let yellowHueDegrees: ClosedRange<Double> = 85...125
  static let minimumYellowChroma = 0.08

  /// Whether a top-row-first RGBA float bitmap of a cover carries the sash.
  static func isPresent(inRGBAf bitmap: [Float], width: Int, height: Int) -> Bool {
    guard width > 0, height > 0, bitmap.count >= width * height * 4 else { return false }
    var probed = 0
    var yellow = 0
    for row in 0..<height {
      for column in 0..<width where probe.contains(position(column, row, width, height)) {
        probed += 1
        let offset = (row * width + column) * 4
        if isSashYellow(
          red: Double(bitmap[offset]), green: Double(bitmap[offset + 1]),
          blue: Double(bitmap[offset + 2]))
        {
          yellow += 1
        }
      }
    }
    return probed >= minimumProbePixels
      && Double(yellow) >= Double(probed) * minimumYellowShare
  }

  /// The bitmap with everything from `maskStart` to the corner opaque black, which every cluster
  /// score treats as neutral.
  static func masked(_ bitmap: [Float], width: Int, height: Int) -> [Float] {
    var masked = bitmap
    for row in 0..<height {
      for column in 0..<width where position(column, row, width, height) >= maskStart {
        let offset = (row * width + column) * 4
        masked[offset] = 0
        masked[offset + 1] = 0
        masked[offset + 2] = 0
        masked[offset + 3] = 1
      }
    }
    return masked
  }

  static func isSashYellow(red: Double, green: Double, blue: Double) -> Bool {
    let oklab = OKLab(red: red, green: green, blue: blue)
    var degrees = oklab.hueRadians * 180 / .pi
    if degrees < 0 { degrees += 360 }
    return oklab.chroma >= minimumYellowChroma && yellowHueDegrees.contains(degrees)
  }

  /// A pixel's centre as `x + y`, each a fraction of its side.
  private static func position(_ column: Int, _ row: Int, _ width: Int, _ height: Int) -> Double {
    (Double(column) + 0.5) / Double(width) + (Double(row) + 0.5) / Double(height)
  }
}
