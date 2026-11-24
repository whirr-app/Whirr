import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// One normalized cover wash expressed in HSB, with a concrete color for use by SwiftUI.
public struct CoverWashValue: Sendable, Equatable {
  public let hue: Double
  public let saturation: Double
  public let brightness: Double
  fileprivate let red: Double
  fileprivate let green: Double
  fileprivate let blue: Double

  public init(hue: Double, saturation: Double, brightness: Double) {
    self.hue = hue
    self.saturation = saturation
    self.brightness = brightness
    (red, green, blue) = Self.rgb(hue: hue, saturation: saturation, brightness: brightness)
  }

  /// Builds a value from OKLCh: perceptual lightness, chroma, and hue angle in radians. The HSB
  /// components are back-derived as a readout, not the input: across the hue circle a single OKLCh
  /// pair yields HSB brightnesses from 0.09 to 0.14, the non-uniformity this initializer sidesteps.
  public init(oklabLightness: Double, chroma: Double, hueRadians: Double) {
    (red, green, blue) =
      OKLab(
        lightness: oklabLightness, a: chroma * cos(hueRadians), b: chroma * sin(hueRadians)
      ).rgb
    (hue, saturation, brightness) = Self.hsb(red: red, green: green, blue: blue)
  }

  private init(red: Double, green: Double, blue: Double) {
    self.hue = 0
    self.saturation = 0
    self.brightness = 0
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// A concrete color that is safe to use in SwiftUI and preserves the neutral fallback exactly.
  public var color: Color { Color(red: red, green: green, blue: blue) }

  /// The same colour as sRGB components, so contrast can be measured without rendering.
  public var rgbColor: WhirrRGBColor { WhirrRGBColor(red, green, blue) }

  fileprivate static func neutral(red: Double, green: Double, blue: Double) -> Self {
    Self(red: red, green: green, blue: blue)
  }

  /// The colour's OKLab coordinates, the basis the dark wash is specified in. It is the only basis
  /// where "the same amount of colour" means the same for an orange and a blue.
  public var oklab: OKLab { OKLab(red: red, green: green, blue: blue) }
  public var oklabLightness: Double { oklab.lightness }
  public var oklabChroma: Double { oklab.chroma }
  public var oklabHueDegrees: Double { oklab.hueRadians * 180 / .pi }

  private static func hsb(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
    let high = max(red, green, blue)
    let low = min(red, green, blue)
    let span = high - low
    guard span > 0 else { return (0, 0, high) }

    let sector: Double
    switch high {
    case red: sector = (green - blue) / span
    case green: sector = (blue - red) / span + 2
    default: sector = (red - green) / span + 4
    }
    let hue = (sector / 6).truncatingRemainder(dividingBy: 1)
    return (hue < 0 ? hue + 1 : hue, high == 0 ? 0 : span / high, high)
  }

  private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
    guard saturation > 0 else { return (brightness, brightness, brightness) }
    let sector = hue * 6
    let channel = sector - floor(sector)
    let p = brightness * (1 - saturation)
    let q = brightness * (1 - saturation * channel)
    let t = brightness * (1 - saturation * (1 - channel))
    switch Int(floor(sector)).modulo(6) {
    case 0: return (brightness, t, p)
    case 1: return (q, brightness, p)
    case 2: return (p, brightness, t)
    case 3: return (p, q, brightness)
    case 4: return (t, p, brightness)
    default: return (brightness, p, q)
    }
  }
}

extension Int {
  fileprivate func modulo(_ divisor: Int) -> Int { (self % divisor + divisor) % divisor }
}

/// The light and dark cover washes derived from an extracted artwork accent.
public struct CoverWash: Sendable, Equatable {
  public let light: CoverWashValue
  public let dark: CoverWashValue
  /// The cover's colour for small emphasis marks and filled controls: the card's eyebrow and
  /// progress bar, its badges, a play disc, a selected chip, the marks on the show page. The light
  /// accent is the hue pushed into a vivid band; the dark accent is the cover's own colour at its
  /// own lightness (`drainedMark(for:)`), since the drained fill no longer carries it. Nil on the
  /// neutral wash: with no hue to punch up, emphasis falls back to the shared tint.
  public let lightAccent: CoverWashValue?
  public let darkAccent: CoverWashValue?
  /// Companions to the washes for painting a page rather than a card. A light page wash has no
  /// edge (it is the surface itself, fading over a few hundred points), so at the card's strength
  /// it would read as nothing: it takes the same hue, more of it. In dark the page drains below the
  /// card instead (`drainedPageLightness`).
  public let lightPage: CoverWashValue
  public let darkPage: CoverWashValue
  /// The cover's hue as a pale label colour for a dark wash; see `WashInk.eyebrow`. Nil on the
  /// neutral wash, which has no hue to tint with.
  public let darkTint: CoverWashValue?
  /// Whether the dark card and page are drained: almost black, keeping a share of the cover's
  /// chroma, with the cover's own colour moved to the dark accent for the card's marks to carry.
  /// Towards black a little colour is a shade, and a shade of the warm arc is brown, so an
  /// undrained dark fill reads brown-black for every warm cover. Every wash
  /// `from(hue:saturation:brightness:)` derives is drained, as is `drainedNeutral`; only
  /// `neutral` is not. The light appearance is unaffected. Increase Contrast still paints the
  /// neutral surfaces.
  public let drainsDark: Bool

  /// Where the neutral wash's dark card sits: the plain cards of Search, Library and Downloads'
  /// storage panel, and every card under Increase Contrast. The grey secondary ink is on the 4.5:1
  /// line here (4.53 at worst), so the card cannot go higher. A cover's own dark card drains below
  /// it; see `drainedCardLightness`.
  private static let darkWashLightness = 0.34

  /// Where a light page wash sits. On near-white paper a wash reads as tint, so brightness stays
  /// near white and the saturation band widens. Black labels keep at least 9.3:1 across the
  /// circle, and the band reaches 0.30 so the page carries more colour than the light card at
  /// every hue. Bounded panels only: an ambient full-page canvas has nothing to be a tint of.
  private static let lightPageSaturation = 0.16...0.30

  /// The light card's lightness, from a dark hue's end to a light hue's. Built in OKLCh because an
  /// HSB band is not one strength: at a fixed saturation green is vivid, blue is grey, and blue
  /// is darkest so it alone limited the band. The floor keeps the grey secondary ink above 4.5:1
  /// (4.8 at worst); the ceiling lets a yellow stay yellow (pulled down to a blue's lightness it
  /// is khaki).
  private static let lightCardLightness = 0.86...0.94
  /// The light card's chroma: a share of the cover's, inside a band. The floor is what makes a
  /// muted cover still read as a colour; the ceiling keeps a row of mixed covers from turning
  /// into a sweet shop.
  private static let lightCardChroma = 0.045...0.07
  private static let lightCardChromaShare = 0.4

  private static func lightCard(coverChroma: Double, hue: Double, hueRadians: Double)
    -> CoverWashValue
  {
    // Where this hue's own fully saturated colour sits: blue around 0.45, yellow near 0.97.
    let ownLightness = CoverWashValue(hue: hue, saturation: 1, brightness: 1).oklabLightness
    let share = ((ownLightness - 0.45) / (0.97 - 0.45)).clamped(to: 0...1)
    let lightness =
      lightCardLightness.lowerBound
      + (lightCardLightness.upperBound - lightCardLightness.lowerBound) * share
    let chroma = OKLab.displayableChroma(
      lightness: lightness, hueRadians: hueRadians,
      upTo: (coverChroma * lightCardChromaShare).clamped(to: lightCardChroma))
    return CoverWashValue(oklabLightness: lightness, chroma: chroma, hueRadians: hueRadians)
  }
  private static let lightPageBrightness = 0.93...0.95

  /// The dark eyebrow's tint. Lightness 0.93 keeps at least 9.3:1 on the dark card at every hue;
  /// 0.06 is enough chroma to name the hue without turning into a colour that competes with the
  /// fill.
  private static let darkTintLightness = 0.93
  private static let darkTintChroma = 0.06

  public static let neutral = CoverWash(
    light: .neutral(red: 0.955, green: 0.953, blue: 0.945),
    dark: CoverWashValue(
      oklabLightness: darkWashLightness,
      chroma: 0.008,
      hueRadians: 250 * .pi / 180))

  private init(
    light: CoverWashValue, dark: CoverWashValue,
    lightAccent: CoverWashValue? = nil, darkAccent: CoverWashValue? = nil,
    lightPage: CoverWashValue? = nil, darkPage: CoverWashValue? = nil,
    darkTint: CoverWashValue? = nil, drainsDark: Bool = false
  ) {
    self.light = light
    self.dark = dark
    self.lightAccent = lightAccent
    self.darkAccent = darkAccent
    // A wash with no hue paints no page region, so its page variant is just itself. Defaulting
    // rather than making it optional is what lets callers read `pageColor` with no neutral case.
    self.lightPage = lightPage ?? light
    self.darkPage = darkPage ?? dark
    self.darkTint = darkTint
    self.drainsDark = drainsDark
  }

  /// A dynamic SwiftUI color that resolves to the pale or deep wash for the current appearance,
  /// and to the neutral wash under Increase Contrast; see `washValue(dark:light:for:)`.
  public var cardColor: Color {
    #if canImport(UIKit)
      return Color(
        uiColor: UIColor { traits in
          let value = Self.washValue(dark: dark, light: light, for: traits)
          return UIColor(
            red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    #elseif canImport(AppKit)
      return Color(
        nsColor: NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: dark.red, green: dark.green, blue: dark.blue, alpha: 1)
            : NSColor(calibratedRed: light.red, green: light.green, blue: light.blue, alpha: 1)
        })
    #else
      return light.color
    #endif
  }

  #if canImport(UIKit)
    /// Resolves a wash region for the current appearance, substituting the neutral wash under
    /// Increase Contrast.
    ///
    /// Only the background regions do this. `accentColor` does not: it marks progress, and a
    /// setting meant to make status easier to see must not remove the mark that carries it.
    fileprivate static func washValue(
      dark: CoverWashValue, light: CoverWashValue, for traits: UITraitCollection
    ) -> CoverWashValue {
      let isDark = traits.userInterfaceStyle == .dark
      let decision = WhirrContrastPolicy.decide(
        prefersIncreasedContrast: traits.prefersIncreasedContrast)
      guard decision.usesArtworkWash else {
        return isDark ? CoverWash.neutral.dark : CoverWash.neutral.light
      }
      return isDark ? dark : light
    }
  #endif

  /// A dynamic SwiftUI color for painting a whole page region rather than a card. See `lightPage`.
  public var pageColor: Color {
    #if canImport(UIKit)
      return Color(
        uiColor: UIColor { traits in
          let value = Self.washValue(dark: darkPage, light: lightPage, for: traits)
          return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    #elseif canImport(AppKit)
      return Color(
        nsColor: NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: darkPage.red, green: darkPage.green, blue: darkPage.blue, alpha: 1)
            : NSColor(
              calibratedRed: lightPage.red, green: lightPage.green, blue: lightPage.blue, alpha: 1)
        })
    #else
      return lightPage.color
    #endif
  }

  /// A dynamic SwiftUI color for the punched-up accent, or nil for the neutral wash.
  public var accentColor: Color? {
    guard let lightAccent, let darkAccent else { return nil }
    #if canImport(UIKit)
      return Color(
        uiColor: UIColor { traits in
          let value = traits.userInterfaceStyle == .dark ? darkAccent : lightAccent
          return UIColor(
            red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    #elseif canImport(AppKit)
      return Color(
        nsColor: NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(
              calibratedRed: darkAccent.red, green: darkAccent.green, blue: darkAccent.blue,
              alpha: 1)
            : NSColor(
              calibratedRed: lightAccent.red, green: lightAccent.green, blue: lightAccent.blue,
              alpha: 1)
        })
    #else
      return lightAccent.color
    #endif
  }

  /// Which wash a mark is laid on. The page wash carries more saturation at the same brightness,
  /// so the two grounds are not equally light and the floor is solved against the one behind the
  /// mark.
  public enum AccentGround: Sendable { case card, page }

  /// The accent as a mark on one of the washes, moved only as far as a contrast floor requires.
  ///
  /// `accentColor` is placed for weight and hue uniformity, not contrast. Swept at 5° it bottoms
  /// out at 2.70:1 on the light card and 2.67:1 on the light page, under the 4.5:1 the show-title
  /// eyebrow needs as text and the 3:1 a progress bar owes SC 1.4.11. The drained dark mark
  /// already clears both (`drainedMarkLightness`), so in practice only light appearance moves.
  ///
  /// Solved against the ground actually painted: Increase Contrast swaps the tinted wash for the
  /// neutral one.
  public func accentColor(on ground: AccentGround, minimumRatio: Double) -> Color? {
    guard lightAccent != nil, darkAccent != nil else { return nil }
    #if canImport(UIKit)
      return Color(
        uiColor: UIColor { traits in
          let value = self.solvedAccent(on: ground, minimumRatio: minimumRatio, for: traits)
          return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
    #else
      let mark = nonTextContrastColor(
        preferred: lightAccent!.rgbColor,
        on: ground == .card ? light.rgbColor : lightPage.rgbColor,
        minimumRatio: minimumRatio)
      return mark.color
    #endif
  }

  #if canImport(UIKit)
    private func solvedAccent(
      on ground: AccentGround, minimumRatio: Double, for traits: UITraitCollection
    ) -> WhirrRGBColor {
      let isDark = traits.userInterfaceStyle == .dark
      let mark = (isDark ? darkAccent : lightAccent) ?? light
      let surface: CoverWashValue
      switch ground {
      case .card: surface = Self.washValue(dark: dark, light: light, for: traits)
      case .page: surface = Self.washValue(dark: darkPage, light: lightPage, for: traits)
      }
      return nonTextContrastColor(
        preferred: mark.rgbColor, on: surface.rgbColor, minimumRatio: minimumRatio)
    }
  #endif

  /// Derives normalized washes from the extractor's optional HSB accent. The dark surfaces are
  /// drained; see `drainsDark`.
  public static func from(hue: Double?, saturation: Double?, brightness: Double?) -> Self {
    guard let hue, let saturation, let brightness, saturation >= 0.05 else {
      return .drainedNeutral
    }

    // The dark surfaces and tint take their hue angle from the fully saturated form of the
    // extracted hue. A dim or washed-out accent has an unstable OKLab hue angle (a black accent's
    // is `atan2(0, 0)`, which would tint every dark cover red) that drifts up to 25° near that
    // corner; the saturated form is defined for every hue.
    let hueBasis = CoverWashValue(hue: hue, saturation: 1, brightness: 1).oklab.hueRadians
    // The dark surfaces bend warm yellows towards copper, as the full-screen dark page does; the
    // tint is a mark and keeps the cover's own hue. See `DarkWarmBand`.
    let surfaceHue = DarkWarmBand.turned(hueRadians: hueBasis)
    let cover = CoverWashValue(
      hue: hue, saturation: saturation.clamped(to: 0...1),
      brightness: brightness.clamped(to: 0...1)
    ).rgbColor
    let coverChroma = OKLab(red: cover.red, green: cover.green, blue: cover.blue).chroma

    return Self(
      light: lightCard(coverChroma: coverChroma, hue: hue, hueRadians: hueBasis),
      dark: drainedCard(coverChroma: coverChroma, hueRadians: surfaceHue),
      lightAccent: CoverWashValue(
        hue: hue, saturation: saturation.clamped(to: 0.55...0.75),
        brightness: brightness.clamped(to: 0.45...0.58)),
      darkAccent: drainedMark(for: cover),
      lightPage: CoverWashValue(
        hue: hue, saturation: saturation.clamped(to: lightPageSaturation),
        brightness: brightness.clamped(to: lightPageBrightness)),
      darkPage: drainedPage(coverChroma: coverChroma, hueRadians: surfaceHue),
      darkTint: CoverWashValue(
        oklabLightness: darkTintLightness,
        chroma: OKLab.displayableChroma(
          lightness: darkTintLightness, hueRadians: hueBasis, upTo: darkTintChroma),
        hueRadians: hueBasis),
      drainsDark: true)
  }
}

// MARK: - The drained dark wash

extension CoverWash {
  /// OKLab lightness of a drained card: 0.07 over the drained page, so an unstarted card, which has
  /// only its badge to carry the cover's colour, still lifts off the page.
  public static let drainedCardLightness = 0.27
  /// OKLab lightness of a drained page, shared by show and item pages so they drain alike. It sits
  /// under the drained card: a drained page should go almost to black, not read as a region.
  public static let drainedPageLightness = 0.20
  /// The share of the cover's own OKLab chroma a drained page keeps, after Material's dark
  /// surfaces, whose neutral palette keeps an eighth of its source's chroma.
  public static let drainedChromaShare = 1.0 / 8
  /// The share of the cover's own OKLab chroma a drained card asks for, up to
  /// `drainedCardChromaCeiling`. A card is small and bounded, so it holds more of the cover than a
  /// page can before it stops reading as near-black; a near-grey cover stays near-grey.
  public static let drainedCardChromaShare = 1.0 / 2
  /// The most OKLab chroma a drained card asks for, which a vivid cover reaches.
  public static let drainedCardChromaCeiling = 0.04
  /// The band a drained wash's mark keeps the cover's lightness in. The floor keeps the mark above
  /// 5:1 on a drained card, and a label in a drained page's colour above 5:1 on the mark, at every
  /// hue; the ceiling stops a pale cover's colour reading as white.
  public static let drainedMarkLightness: ClosedRange<Double> = 0.72...0.86

  /// The neutral wash drained, so a cover with no hue sits at a drained shelf's weight. Its cast is
  /// the neutral wash's.
  public static let drainedNeutral = CoverWash(
    light: neutral.light,
    dark: CoverWashValue(
      oklabLightness: drainedCardLightness, chroma: neutral.dark.oklabChroma,
      hueRadians: neutral.dark.oklab.hueRadians),
    drainsDark: true)

  /// A drained page at this hue, keeping `drainedChromaShare` of the cover's chroma where sRGB
  /// holds it.
  public static func drainedPage(coverChroma: Double, hueRadians: Double) -> CoverWashValue {
    CoverWashValue(
      oklabLightness: drainedPageLightness,
      chroma: OKLab.displayableChroma(
        lightness: drainedPageLightness, hueRadians: hueRadians,
        upTo: coverChroma * drainedChromaShare),
      hueRadians: hueRadians)
  }

  /// A drained card at this hue; see `drainedCardChromaShare`.
  static func drainedCard(coverChroma: Double, hueRadians: Double) -> CoverWashValue {
    CoverWashValue(
      oklabLightness: drainedCardLightness,
      chroma: OKLab.displayableChroma(
        lightness: drainedCardLightness, hueRadians: hueRadians,
        upTo: min(drainedCardChromaCeiling, coverChroma * drainedCardChromaShare)),
      hueRadians: hueRadians)
  }

  /// The cover's own colour as a mark: its own hue, its own lightness inside
  /// `drainedMarkLightness`, and as much of its own chroma as that lightness holds.
  public static func drainedMark(for cover: WhirrRGBColor) -> CoverWashValue {
    let lab = OKLab(red: cover.red, green: cover.green, blue: cover.blue)
    let lightness = lab.lightness.clamped(to: drainedMarkLightness)
    return CoverWashValue(
      oklabLightness: lightness,
      chroma: OKLab.displayableChroma(
        lightness: lightness, hueRadians: lab.hueRadians, upTo: lab.chroma),
      hueRadians: lab.hueRadians)
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
