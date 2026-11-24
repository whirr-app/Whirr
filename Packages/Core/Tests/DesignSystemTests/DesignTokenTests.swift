import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Design tokens")
struct DesignTokenTests {

  @Test("type tokens are stable by name")
  func typeTokensAreStableByName() {
    #expect(
      WhirrTypeToken.allCases.map(\.rawValue) == [
        "display", "title", "headline", "body", "subheadline", "caption", "caption2",
      ])
  }

  @Test("type tokens map to distinct fonts")
  func typeTokensMapToDistinctFonts() {
    let fonts = Set(WhirrTypeToken.allCases.map(\.font))
    #expect(fonts.count == WhirrTypeToken.allCases.count)
  }

  @Test("display faces pin the variable font weight axis")
  func displayFacesPinVariableFontWeightAxis() {
    #expect(WhirrDisplayFont.Face.medium.weightAxisValue == 500)
    #expect(WhirrDisplayFont.Face.bold.weightAxisValue == 700)
  }

  @Test("display resolver falls back to the system font when unavailable")
  func displayResolverFallsBackToSystemWhenUnavailable() {
    #expect(
      WhirrDisplayFont.resolve(
        textStyle: .largeTitle, face: .bold, familyAvailable: false
      ) == .system(.largeTitle).weight(.bold))
  }

  @Test("display roles scale relative to their semantic text styles")
  func displayRolesScaleRelativeToTheirSemanticTextStyles() {
    #expect(WhirrTypeToken.display.relativeTextStyle == .title2)
    #expect(WhirrTypeToken.title.relativeTextStyle == .title2)
  }

  @Test("color tokens are stable by name")
  func colorTokensAreStableByName() {
    #expect(
      WhirrColorToken.allCases.map(\.rawValue) == [
        "textPrimary", "textSecondary", "surfacePrimary", "surfaceSecondary", "groupedSurface", "accent",
        "editorialBackground", "brandInk",
      ])
  }

  /// Each token must defer to the system's dynamic color for its role, which is what makes the
  /// appearance follow. A hardcoded dark-mode literal would render light mode as a dark screen.
  /// `WhirrColorTokenAppearanceTests` in the iOS target proves the colors differ per appearance,
  /// since a dynamic color cannot be resolved in this headless host process.
  @Test("color tokens map to the system's dynamic color for their role")
  func colorTokensMapToSystemColors() {
    #expect(WhirrColorToken.textPrimary.color == .primary)
    // `textSecondary` is dynamic but resolves through the app's own literals, not the platform's.
    // `.secondary` is built to recede and tops out around 3.4:1 on white, which cannot reach AA.
    // See `SecondaryTextContrastTests`.
    #expect(WhirrColorToken.textSecondary.color == .absTextSecondary)
    #expect(WhirrColorToken.surfacePrimary.color == .absSystemBackground)
    #expect(WhirrColorToken.surfaceSecondary.color == .absSecondarySystemBackground)
    #expect(WhirrColorToken.groupedSurface.color == .absGroupedSystemBackground)
    #expect(WhirrColorToken.accent.color == .accentColor)
    #expect(WhirrColorToken.editorialBackground.color == .absEditorialBackground)
    #expect(WhirrColorToken.brandInk.color == .absBrandInk)
  }

  @Test("editorial colors use the specified light and dark RGB values")
  func editorialColorsUseSpecifiedRGBValues() {
    #expect(
      WhirrColorToken.editorialBackground.lightRGB
        == WhirrRGBColor(251.0 / 255.0, 251.0 / 255.0, 249.0 / 255.0))
    #expect(
      WhirrColorToken.editorialBackground.darkRGB
        == WhirrRGBColor(11.0 / 255.0, 13.0 / 255.0, 14.0 / 255.0))
    #expect(
      WhirrColorToken.brandInk.lightRGB == WhirrRGBColor(28.0 / 255.0, 42.0 / 255.0, 58.0 / 255.0))
    #expect(
      WhirrColorToken.brandInk.darkRGB == WhirrRGBColor(223.0 / 255.0, 229.0 / 255.0, 238.0 / 255.0))
  }

  @Test("neutral cover accent token is pinned to the shared fallback value")
  func neutralCoverAccentTokenIsPinned() {
    #expect(WhirrColorToken.neutralCoverAccent == WhirrRGBColor(0.92, 0.80, 0.55))
  }

  @Test("grouped surface token maps to the system grouped background")
  func groupedSurfaceTokenIsPinned() {
    #expect(WhirrColorToken.groupedSurface.color == .absGroupedSystemBackground)
  }

  /// A dynamic system color is never equal to a constant one, so this fails the moment any token
  /// is pinned to a fixed value.
  @Test("no color token is a fixed literal", arguments: WhirrColorToken.allCases)
  func colorTokensAreNotFixedLiterals(token: WhirrColorToken) {
    let formerlyPinnedValues: [Color] = [
      Color(red: 0.98, green: 0.98, blue: 0.99),
      Color(red: 0.75, green: 0.76, blue: 0.79),
      Color(red: 0.08, green: 0.08, blue: 0.10),
      Color(red: 0.18, green: 0.18, blue: 0.21),
      Color(red: 0.40, green: 0.68, blue: 1.0),
    ]
    #expect(formerlyPinnedValues.allSatisfy { $0 != token.color })
  }

  @Test("color tokens are distinct from one another")
  func colorTokensAreDistinct() {
    let tokens = WhirrColorToken.allCases
    let colors = tokens.map(\.color)
    for (offset, color) in colors.enumerated() {
      let duplicates = colors.enumerated().filter { $0.offset != offset && $0.element == color }
      #expect(duplicates.isEmpty, "\(tokens[offset].rawValue) duplicates another token")
    }
  }
}

/// Increase Contrast. System-backed tokens are strengthened by the platform, but
/// `editorialBackground`, `brandInk` and the cover washes are literal and need their own policy.
///
/// These assert the policy and palette arithmetic. That a resolved dynamic color follows the trait
/// is proved in `WhirrTests`, where `UITraitCollection` resolves for real (the split
/// `WhirrColorTokenAppearanceTests` documents for light and dark).
@Suite("Increase Contrast policy and palette")
struct WhirrContrastPolicyTests {

  @Test("increased contrast strengthens the ink and stops artwork washes painting")
  func policyDecisions() {
    let standard = WhirrContrastPolicy.decide(prefersIncreasedContrast: false)
    #expect(standard.usesArtworkWash)
    #expect(standard.usesStrengthenedInk == false)

    let increased = WhirrContrastPolicy.decide(prefersIncreasedContrast: true)
    #expect(increased.usesArtworkWash == false)
    #expect(increased.usesStrengthenedInk)
  }

  @Test("the high-contrast pair is strictly higher contrast than the standard pair")
  func strengthenedPaletteRaisesTheRatio() {
    // Contrast is a property of the pair, so the assertion has to be about the pair. Strengthening
    // the ink against an unchanged ground can leave a "high contrast" palette no better.
    let standardLight = contrastRatio(
      WhirrColorToken.brandInk.lightRGB, WhirrColorToken.editorialBackground.lightRGB)
    let increasedLight = contrastRatio(
      WhirrColorToken.brandInk.lightHighContrastRGB,
      WhirrColorToken.editorialBackground.lightHighContrastRGB)
    #expect(increasedLight > standardLight)

    let standardDark = contrastRatio(
      WhirrColorToken.brandInk.darkRGB, WhirrColorToken.editorialBackground.darkRGB)
    let increasedDark = contrastRatio(
      WhirrColorToken.brandInk.darkHighContrastRGB,
      WhirrColorToken.editorialBackground.darkHighContrastRGB)
    #expect(increasedDark > standardDark)
  }

  @Test("the high-contrast pair clears WCAG AAA in both appearances")
  func strengthenedPaletteClearsAAA() {
    #expect(
      contrastRatio(
        WhirrColorToken.brandInk.lightHighContrastRGB,
        WhirrColorToken.editorialBackground.lightHighContrastRGB) >= 7)
    #expect(
      contrastRatio(
        WhirrColorToken.brandInk.darkHighContrastRGB,
        WhirrColorToken.editorialBackground.darkHighContrastRGB) >= 7)
  }

  @Test(
    "system-backed tokens carry no separate high-contrast literal",
    arguments: WhirrColorToken.allCases.filter {
      $0 != .editorialBackground && $0 != .brandInk && $0 != .textSecondary
    })
  func systemBackedTokensAreUnchanged(token: WhirrColorToken) {
    // Their values come from the platform, which already strengthens them. A literal here would
    // mean a token had stopped being system-backed.
    #expect(token.lightHighContrastRGB == token.lightRGB)
    #expect(token.darkHighContrastRGB == token.darkRGB)
  }

  /// Only three tokens need their own literals: the editorial pair is the app's own paper and
  /// ink, and the platform's `textSecondary` cannot reach AA. Pinning the list keeps a fourth
  /// from joining them unnoticed.
  @Test("exactly three tokens carry their own literals")
  func onlyTheIntendedTokensCarryLiterals() {
    let withLiterals = WhirrColorToken.allCases.filter {
      $0.lightHighContrastRGB != $0.lightRGB || $0.darkHighContrastRGB != $0.darkRGB
    }
    #expect(Set(withLiterals) == [.editorialBackground, .brandInk, .textSecondary])
  }
}

/// A cover accent is whatever the artwork contained, so anything laid on it (a label, a glyph)
/// has to be chosen against it rather than assumed. White on the neutral fallback accent is only
/// 1.58:1.
@Suite("Accent foreground legibility")
struct AccentForegroundTests {

  /// Representative extracted accent values and boundary cases, so the pair solver is exercised
  /// where it is hardest.
  private static let accents: [WhirrRGBColor] = [
    WhirrColorToken.neutralCoverAccent,
    WhirrRGBColor(1, 1, 1),
    WhirrRGBColor(0, 0, 0),
    WhirrRGBColor(0.98, 0.95, 0.80),
    WhirrRGBColor(0.55, 0.62, 0.86),
    WhirrRGBColor(0.86, 0.44, 0.38),
    WhirrRGBColor(0.35, 0.55, 0.45),
    WhirrRGBColor(0.50, 0.50, 0.50),
  ]

  @Test("no single ink can clear AA on a mid-luminance accent")
  func aMidLuminanceAccentDefeatsBothInks() {
    // The fill has to move rather than the ink. A mid-grey sits too far from both candidates:
    // ~3.9:1 against white and ~4.0:1 against the dark ink. Picking the better of two inks is
    // not a floor.
    let midGrey = WhirrRGBColor(0.50, 0.50, 0.50)
    #expect(contrastRatio(WhirrColorToken.onAccentLightInk, midGrey) < 4.5)
    #expect(contrastRatio(WhirrColorToken.onAccentDarkInk, midGrey) < 4.5)
  }

  @Test("every accent yields a pair that clears AA for normal text")
  func everyAccentPairClearsAA() {
    for accent in Self.accents {
      let pair = legibleAccentPair(for: accent)
      let ratio = contrastRatio(pair.ink, pair.fill)
      #expect(
        ratio >= 4.5,
        "\(accent) resolved to only \(String(format: "%.2f", ratio)):1")
    }
  }

  @Test("a pair that already clears the floor is returned untouched")
  func anAlreadyLegiblePairIsPreserved() {
    // A near-white accent is already fine under the dark ink, so nothing should move. The policy
    // corrects what fails and leaves other covers alone.
    let alreadyFine = WhirrRGBColor(0.98, 0.95, 0.80)
    #expect(contrastRatio(WhirrColorToken.onAccentDarkInk, alreadyFine) >= 4.5)
    #expect(legibleAccentPair(for: alreadyFine).fill == alreadyFine)
  }

  @Test("the derived fill keeps the accent's hue rather than washing to grey")
  func theDerivedFillKeepsItsHue() {
    // A mid blue has to move a long way to clear the floor. It should arrive as a paler blue, not
    // something neutral, because the accent is the cover's identity on the page.
    let blue = WhirrRGBColor(0.35, 0.42, 0.86)
    let pair = legibleAccentPair(for: blue)
    #expect(pair.fill.blue > pair.fill.red)
    #expect(pair.fill.blue > pair.fill.green)
    #expect(contrastRatio(pair.ink, pair.fill) >= 4.5)
  }

  @Test("the neutral fallback accent stops being the 1.58:1 case the audit found")
  func neutralFallbackNoLongerFails() {
    let accent = WhirrColorToken.neutralCoverAccent
    #expect(contrastRatio(WhirrRGBColor(1, 1, 1), accent) < 2.0)
    #expect(contrastRatio(legibleForeground(on: accent), accent) > 7.0)
  }

  @Test("the foreground is one of the two inks, not an arbitrary colour")
  func foregroundIsAPinnedInk() {
    for accent in Self.accents {
      let ink = legibleForeground(on: accent)
      #expect(ink == WhirrColorToken.onAccentDarkInk || ink == WhirrColorToken.onAccentLightInk)
    }
  }

  @Test("a mid-luminance accent takes whichever ink actually wins, not a fixed one")
  func midLuminanceAccentPicksTheBetterInk() {
    let light = legibleForeground(on: WhirrRGBColor(0.95, 0.92, 0.78))
    let dark = legibleForeground(on: WhirrRGBColor(0.18, 0.20, 0.28))
    #expect(light == WhirrColorToken.onAccentDarkInk)
    #expect(dark == WhirrColorToken.onAccentLightInk)
  }
}

@Suite("Non-text contrast")
struct NonTextContrastTests {
  private static let minimumRatio = 3.0

  @Test("the non-text solver moves only as far as the requested floor")
  func solverStopsAtMinimum() {
    let surface = WhirrRGBColor(245.0 / 255.0, 246.0 / 255.0, 244.0 / 255.0)
    let preferred = WhirrRGBColor(201.0 / 255.0, 208.0 / 255.0, 213.0 / 255.0)
    let solved = nonTextContrastColor(
      preferred: preferred, on: surface, minimumRatio: Self.minimumRatio)

    #expect(contrastRatio(solved, surface) >= Self.minimumRatio)
    #expect(contrastRatio(solved, surface) < Self.minimumRatio + 0.01)
  }

  @Test("the expanded player scrubber track clears the ambient surface floor")
  func expandedPlayerScrubberTrackClearsAmbientSurface() {
    let darkSurface = WhirrRGBColor(0.055, 0.06, 0.075)
    let darkTrack = Self.whiteOverlay(PlaybackScrubber.defaultTrackOpacity, over: darkSurface)
    #expect(contrastRatio(darkTrack, darkSurface) >= Self.minimumRatio)

    let lightSurface = WhirrColorToken.editorialBackground.lightRGB
    let lightTrack = Self.blackOverlay(PlaybackScrubber.defaultTrackOpacity, over: lightSurface)
    #expect(contrastRatio(lightTrack, lightSurface) >= Self.minimumRatio)
    #expect(
      PlaybackScrubber.defaultTrackOpacity
        == nonTextContrastOpacity(
          foreground: WhirrRGBColor(0, 0, 0),
          over: WhirrColorToken.editorialBackground.lightRGB))
  }

  @Test("the cover progress badge mark clears its accent disc")
  func coverProgressBadgeMarkClearsAccentDisc() {
    let accent = WhirrColorToken.neutralCoverAccent
    let mark = nonTextContrastColor(
      preferred: WhirrRGBColor(1, 1, 1), on: accent, minimumRatio: Self.minimumRatio)

    #expect(contrastRatio(mark, accent) >= Self.minimumRatio)
  }

  @Test("the Continue Reading ring track clears the reader chrome")
  func continueReadingRingTrackClearsReaderChrome() {
    for theme in ReaderTheme.allCases {
      let palette = theme.palette
      let track = nonTextContrastColor(
        preferred: palette.accent, on: palette.chromeBackground, minimumRatio: Self.minimumRatio)
      #expect(
        contrastRatio(track, palette.chromeBackground) >= Self.minimumRatio,
        "\(theme.rawValue) ring track misses 3:1")
    }
  }

  @Test("reader scrubber tracks clear their docked chrome surfaces")
  func readerScrubberTracksClearTheirChromeSurfaces() {
    for theme in ReaderTheme.allCases {
      let palette = theme.palette
      #expect(
        contrastRatio(palette.track, palette.chromeBackground) >= Self.minimumRatio,
        "\(theme.rawValue) scrubber track misses 3:1")
    }
  }

  @Test("reader idle fills clear their chrome surfaces")
  func readerIdleFillsClearTheirChromeSurfaces() {
    for theme in ReaderTheme.allCases {
      let palette = theme.palette
      #expect(
        contrastRatio(palette.controlFill, palette.chromeBackground) >= Self.minimumRatio,
        "\(theme.rawValue) idle fill misses 3:1")
    }
  }

  /// The selected control fill answers to two surfaces at once, and solving for one can undo the
  /// other. Solving against the chrome alone can land exactly on the grayscale floor.
  @Test("the selected control fill clears the chrome and the idle fill it replaces")
  func selectedControlFillClearsBothOfItsSurfaces() {
    for theme in ReaderTheme.allCases {
      let palette = theme.palette
      #expect(
        contrastRatio(palette.selectedControlFill, palette.chromeBackground) >= Self.minimumRatio,
        "\(theme.rawValue) selected fill misses 3:1 on the chrome")
      #expect(
        contrastRatio(palette.selectedControlFill, palette.controlFill) >= 1.5,
        "\(theme.rawValue) selected fill is not distinguishable from the idle fill")
    }
  }

  @Test("reader dividers and swatch borders clear the surface they touch")
  func readerDividersAndSwatchBordersClearTheirSurfaces() {
    for theme in ReaderTheme.allCases {
      let palette = theme.palette
      #expect(
        contrastRatio(palette.divider, palette.chromeBackground) >= Self.minimumRatio,
        "\(theme.rawValue) chrome divider misses 3:1")
      #expect(
        contrastRatio(palette.divider, palette.background) >= Self.minimumRatio,
        "\(theme.rawValue) content divider misses 3:1")
      for swatchTheme in ReaderTheme.allCases {
        let border = nonTextContrastColor(
          preferred: palette.divider,
          on: swatchTheme.palette.background,
          minimumRatio: Self.minimumRatio)
        #expect(
          contrastRatio(border, swatchTheme.palette.background) >= Self.minimumRatio,
          "\(theme.rawValue) border on \(swatchTheme.rawValue) misses 3:1")
      }
    }
  }

  private static func blackOverlay(_ opacity: Double, over background: WhirrRGBColor) -> WhirrRGBColor {
    WhirrRGBColor(
      background.red * (1 - opacity),
      background.green * (1 - opacity),
      background.blue * (1 - opacity))
  }

  private static func whiteOverlay(_ opacity: Double, over background: WhirrRGBColor) -> WhirrRGBColor {
    WhirrRGBColor(
      opacity + (1 - opacity) * background.red,
      opacity + (1 - opacity) * background.green,
      opacity + (1 - opacity) * background.blue)
  }
}

/// SwiftUI's `.secondary` is designed to recede and never reaches AA on a light ground: bylines,
/// timestamps, durations and unselected filter chips measure between 3.15:1 and 3.44:1, and
/// Increase Contrast only lifts some of them to about 4:1. The grounds below are the ones the
/// token is actually drawn on.
@Suite("Secondary text contrast")
struct SecondaryTextContrastTests {

  /// The chip ground is the worst case and decides the token: anything that clears it clears the
  /// papers above it too.
  private static let lightGrounds: [(String, WhirrRGBColor)] = [
    ("unselected filter chip", WhirrRGBColor(230.0 / 255.0, 230.0 / 255.0, 230.0 / 255.0)),
    ("home card", WhirrRGBColor(244.0 / 255.0, 243.0 / 255.0, 241.0 / 255.0)),
    ("editorial paper", WhirrColorToken.editorialBackground.lightRGB),
    ("system white", WhirrRGBColor(1, 1, 1)),
  ]

  private static let darkGrounds: [(String, WhirrRGBColor)] = [
    ("editorial ground", WhirrColorToken.editorialBackground.darkRGB),
    ("grouped card", WhirrRGBColor(28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0)),
    ("system black", WhirrRGBColor(0, 0, 0)),
  ]

  @Test("secondary text clears AA on every light ground it is drawn on")
  func secondaryClearsAAInLight() {
    for (name, ground) in Self.lightGrounds {
      let ratio = contrastRatio(WhirrColorToken.textSecondary.lightRGB, ground)
      #expect(ratio >= 4.5, "\(name): \(String(format: "%.2f", ratio)):1")
    }
  }

  @Test("secondary text clears AA on every dark ground it is drawn on")
  func secondaryClearsAAInDark() {
    for (name, ground) in Self.darkGrounds {
      let ratio = contrastRatio(WhirrColorToken.textSecondary.darkRGB, ground)
      #expect(ratio >= 4.5, "\(name): \(String(format: "%.2f", ratio)):1")
    }
  }

  /// Home cards sit on the cover's wash once a cover supplies an accent. Maximum saturation at
  /// minimum brightness is the darkest light wash `from` can produce, and blue is darker than pink
  /// there, hence the hue sweep. Increase Contrast swaps every card to the neutral wash, so only
  /// the standard ink is owed. On a dark wash the secondary ink is `WashInk`'s, which the dark
  /// half measures.
  @Test("secondary text clears AA on the darkest cover wash at every hue")
  func secondaryClearsAAOnCoverWashes() {
    for degrees in stride(from: 0, to: 360, by: 5) {
      let wash = CoverWash.from(hue: Double(degrees) / 360, saturation: 1, brightness: 0)
      let light = contrastRatio(WhirrColorToken.textSecondary.lightRGB, wash.light.rgbColor)
      let dark = contrastRatio(
        WashInk.darkSecondary(on: wash.dark.rgbColor, increasedContrast: false),
        wash.dark.rgbColor)
      #expect(light >= 4.5, "light wash at \(degrees)°: \(String(format: "%.2f", light)):1")
      #expect(dark >= 4.5, "dark wash at \(degrees)°: \(String(format: "%.2f", dark)):1")
    }
  }

  @Test("Increase Contrast strengthens secondary text rather than leaving it alone")
  func increaseContrastActuallyIncreasesIt() {
    // A high contrast variant that equals the standard one is a bug, so this asserts movement,
    // not just a threshold.
    let lightGround = Self.lightGrounds[0].1
    let darkGround = Self.darkGrounds[0].1
    #expect(
      contrastRatio(WhirrColorToken.textSecondary.lightHighContrastRGB, lightGround)
        > contrastRatio(WhirrColorToken.textSecondary.lightRGB, lightGround))
    #expect(
      contrastRatio(WhirrColorToken.textSecondary.darkHighContrastRGB, darkGround)
        > contrastRatio(WhirrColorToken.textSecondary.darkRGB, darkGround))
  }

  @Test("secondary stays visibly below primary so the hierarchy survives")
  func secondaryRemainsQuieterThanPrimary() {
    // Fixing contrast by making secondary equal primary would trade one defect for another: a
    // byline should not shout as loud as a title.
    let paper = WhirrColorToken.editorialBackground.lightRGB
    let primary = contrastRatio(WhirrColorToken.brandInk.lightRGB, paper)
    let secondary = contrastRatio(WhirrColorToken.textSecondary.lightRGB, paper)
    #expect(secondary < primary)
    #expect(secondary >= 4.5)
  }
}
