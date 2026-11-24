import SwiftUI

private struct IsOnCoverWashKey: EnvironmentKey {
  static let defaultValue = false
}

private struct DrainedCoverWashKey: EnvironmentKey {
  static let defaultValue: CoverWash? = nil
}

extension EnvironmentValues {
  /// Whether this content is drawn on a cover wash (a card's fill, or the washed top of a page).
  /// Set through `drawnOnCoverWash(_:)`; read by `WashInk` and `PlaybackProgressBar`.
  var isOnCoverWash: Bool {
    get { self[IsOnCoverWashKey.self] }
    set { self[IsOnCoverWashKey.self] = newValue }
  }

  /// The wash this content is drawn on, when that wash is drained; see
  /// `WashInk.drainedMark`. Set alongside `isOnCoverWash`.
  var drainedCoverWash: CoverWash? {
    get { self[DrainedCoverWashKey.self] }
    set { self[DrainedCoverWashKey.self] = newValue }
  }
}

extension View {
  /// Declares that this content is drawn on `wash`, so its `WashInk` resolves on the wash's terms.
  /// Card surfaces declare it for their own content; content on a wash painted behind it (the
  /// washed top of a page) declares it itself. `nil` leaves the environment as it was, so a row
  /// that paints no card never clears a wash painted further out.
  public func drawnOnCoverWash(_ wash: CoverWash?) -> some View {
    transformEnvironment(\.isOnCoverWash) { if wash != nil { $0 = true } }
      .transformEnvironment(\.drainedCoverWash) { if let wash { $0 = wash.drainsDark ? wash : nil } }
  }
}

/// Ink for text drawn on a cover wash.
///
/// Both washes leave the cover's colour to the marks. In the light appearance the wash is a pale
/// tint, so text draws as normal (the grey token, the accent). In the dark appearance text steps
/// back to a near-white set (the grey sits on the 4.5:1 line on the neutral dark card) and the
/// cover's colour goes to the marks; see `drainedMark(colorScheme:wash:increasedContrast:)`.
/// Resolved from the environment at draw time, so a site off a wash or in light is unchanged.
public struct WashInk: ShapeStyle, Sendable {
  private enum Dark: Sendable {
    case secondary
    case color(Color)
  }

  private let standard: Color
  private let dark: Dark

  /// Secondary copy: the grey token, or white at `darkSecondaryOpacity` on a dark wash.
  public static let secondary = WashInk(
    standard: WhirrColorToken.textSecondary.color, dark: .secondary)

  /// A destructive label: system red, or a pale red that still reads as red on a dark wash.
  /// System red falls as low as 3.3:1 on a dark card.
  public static let destructive = WashInk(standard: .red, dark: .color(darkDestructiveRGB.color))

  /// The line above a card's title (a show name, an author). On a dark wash it takes the pale tint
  /// of the cover's hue; a wash with no hue keeps `standard`, the near-white brand ink.
  public static func eyebrow(_ standard: Color, wash: CoverWash?) -> WashInk {
    WashInk(standard: standard, dark: .color(wash?.darkTint?.color ?? standard))
  }

  public func resolve(in environment: EnvironmentValues) -> Color {
    guard
      Self.drawsDarkInk(colorScheme: environment.colorScheme, isOnWash: environment.isOnCoverWash)
    else { return standard }
    switch dark {
    case .secondary:
      return .white.opacity(
        Self.darkSecondaryOpacity(increasedContrast: environment.colorSchemeContrast == .increased))
    case .color(let color):
      return color
    }
  }

  static func drawsDarkInk(colorScheme: ColorScheme, isOnWash: Bool) -> Bool {
    colorScheme == .dark && isOnWash
  }

  /// The cover colour a drained wash hands back to the marks drawn on it, or `nil` where they draw
  /// as normal: in the light appearance, under Increase Contrast (which paints the neutral card in
  /// the wash's place), and on a wash that is not drained or has no hue.
  ///
  /// Only marks take it: the progress bar and the cover's badges. Text keeps the near-white set.
  static func drainedMark(colorScheme: ColorScheme, wash: CoverWash?, increasedContrast: Bool)
    -> CoverWashValue?
  {
    guard colorScheme == .dark, let wash, wash.drainsDark,
      WhirrContrastPolicy.decide(prefersIncreasedContrast: increasedContrast).usesArtworkWash
    else { return nil }
    return wash.darkAccent
  }

  static func darkSecondaryOpacity(increasedContrast: Bool) -> Double {
    increasedContrast ? 0.94 : 0.86
  }

  /// The dark secondary ink as the colour it composites to on `wash`, which is what its contrast
  /// has to be measured against.
  static func darkSecondary(on wash: WhirrRGBColor, increasedContrast: Bool) -> WhirrRGBColor {
    let alpha = darkSecondaryOpacity(increasedContrast: increasedContrast)
    return WhirrRGBColor(
      alpha + (1 - alpha) * wash.red,
      alpha + (1 - alpha) * wash.green,
      alpha + (1 - alpha) * wash.blue)
  }

  static let darkDestructiveRGB: WhirrRGBColor = {
    let (red, green, blue) = OKLab(lightness: 0.82, chroma: 0.10, hueRadians: 25 * .pi / 180).rgb
    return WhirrRGBColor(red, green, blue)
  }()
}
