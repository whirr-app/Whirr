import SwiftUI
import Testing

@testable import DesignSystem

/// Pins the drained dark wash. See `CoverWash.drainsDark`.
@Suite("Cover wash drain")
struct CoverWashDrainTests {
  /// HSB hues at 5° steps around the circle.
  private static let hues = (0..<72).map { Double($0) / 72 }

  /// Vivid, muted, pale and dim accents, as HSB saturation and brightness.
  private static let accents: [(saturation: Double, brightness: Double)] = [
    (0.8, 0.7), (1, 1), (0.3, 0.3), (0.15, 0.95), (1, 0.25),
  ]

  private static func accent(_ hue: Double, saturation: Double = 0.8, brightness: Double = 0.7)
    -> WhirrRGBColor
  {
    CoverWashValue(hue: hue, saturation: saturation, brightness: brightness).rgbColor
  }

  private static func oklab(_ colour: WhirrRGBColor) -> OKLab {
    OKLab(red: colour.red, green: colour.green, blue: colour.blue)
  }

  private static func hueDrift(_ degrees: Double, from reference: Double) -> Double {
    var drift = (degrees - reference).truncatingRemainder(dividingBy: 360)
    if drift > 180 { drift -= 360 }
    if drift < -180 { drift += 360 }
    return abs(drift)
  }

  /// The dark surfaces' hue: the saturated form of the cover's hue, warm yellows turned towards
  /// copper.
  private static func surfaceHueDegrees(_ hue: Double) -> Double {
    let basis = CoverWashValue(hue: hue, saturation: 1, brightness: 1).oklab.hueRadians
    return DarkWarmBand.turned(hueRadians: basis) * 180 / .pi
  }

  @Test("every derived wash is drained; only the plain neutral wash is not")
  func everyDerivedWashDrains() {
    for hue in Self.hues {
      for accent in Self.accents {
        #expect(
          CoverWash.from(hue: hue, saturation: accent.saturation, brightness: accent.brightness)
            .drainsDark)
      }
    }
    #expect(!CoverWash.neutral.drainsDark)
  }

  @Test("a drained card is near-black, lifted a step over the drained page")
  func drainedCardLift() {
    #expect(abs(CoverWash.drainedCardLightness - 0.27) < 1e-9)
    #expect(abs(CoverWash.drainedCardLightness - CoverWash.drainedPageLightness - 0.07) < 1e-9)
    #expect(abs(CoverWash.drainedCardChromaCeiling - 0.04) < 1e-9)
    #expect(abs(CoverWash.drainedCardChromaShare - 0.5) < 1e-9)
  }

  @Test("a drained card keeps half the cover's chroma, up to its ceiling, at the surfaces' hue")
  func drainedCard() {
    for hue in Self.hues {
      let drained = CoverWash.from(hue: hue, saturation: 0.8, brightness: 0.7)
      let coverChroma = Self.oklab(Self.accent(hue)).chroma
      let requested = min(
        CoverWash.drainedCardChromaCeiling, coverChroma * CoverWash.drainedCardChromaShare)

      #expect(drained.drainsDark)
      #expect(abs(drained.dark.oklabLightness - CoverWash.drainedCardLightness) < 0.005)
      #expect(drained.dark.oklabChroma <= requested + 0.001)
      #expect(
        drained.dark.oklabChroma
          >= OKLab.displayableChroma(
            lightness: CoverWash.drainedCardLightness,
            hueRadians: drained.dark.oklab.hueRadians, upTo: requested) - 0.002,
        "hue \(hue) should take what sRGB holds of its request")
      #expect(drained.dark.oklabChroma > 0.015, "hue \(hue) should read as tinted, not grey")
      #expect(
        Self.hueDrift(drained.dark.oklabHueDegrees, from: Self.surfaceHueDegrees(hue)) < 1,
        "hue \(hue)")
    }
  }

  /// Gilead's cover is a near-grey; its card should stay near-grey rather than be pushed to the
  /// ceiling a vivid cover reaches.
  @Test("a near-grey cover's drained card stays near-grey")
  func drainedCardNearGrey() {
    let drained = CoverWash.from(hue: 0.1, saturation: 0.08, brightness: 0.6)
    let coverChroma = Self.oklab(Self.accent(0.1, saturation: 0.08, brightness: 0.6)).chroma

    #expect(coverChroma < 0.03)
    #expect(abs(drained.dark.oklabChroma - coverChroma * CoverWash.drainedCardChromaShare) < 0.002)
    #expect(drained.dark.oklabChroma < 0.015)
  }

  @Test("a drained page is almost black, keeping a trace of the cover's chroma at the surfaces' hue")
  func drainedPage() {
    for hue in Self.hues {
      let drained = CoverWash.from(hue: hue, saturation: 0.8, brightness: 0.7)
      let coverChroma = Self.oklab(Self.accent(hue)).chroma

      #expect(abs(drained.darkPage.oklabLightness - CoverWash.drainedPageLightness) < 0.005)
      #expect(drained.darkPage.oklabChroma <= coverChroma * CoverWash.drainedChromaShare + 0.001)
      #expect(drained.darkPage.oklabChroma > 0.005, "hue \(hue) should keep a tint")
      #expect(
        Self.hueDrift(drained.darkPage.oklabHueDegrees, from: Self.surfaceHueDegrees(hue)) < 1,
        "hue \(hue)")
    }
  }

  /// The colour leaves the drained card for its marks, as it does on the light card: the mark is
  /// the cover's own colour, the same one the drained page's primary action takes.
  @Test("a drained wash's mark is the cover's own colour")
  func drainedMarkIsTheCoversColour() {
    let band = CoverWash.drainedMarkLightness
    for hue in Self.hues {
      for accent in Self.accents {
        let cover = Self.accent(
          hue, saturation: accent.saturation, brightness: accent.brightness)
        let drained = CoverWash.from(
          hue: hue, saturation: accent.saturation, brightness: accent.brightness)
        guard let mark = drained.darkAccent else {
          Issue.record("a hued drained wash carries a mark")
          continue
        }
        #expect(mark == CoverWash.drainedMark(for: cover))
        #expect(mark.oklabLightness >= band.lowerBound - 1e-6)
        #expect(mark.oklabLightness <= band.upperBound + 1e-6)
      }
    }
  }

  @Test("the drained mark keeps the cover's lightness inside its band, and the cover's hue")
  func drainedMarkClampsLightness() {
    let band = CoverWash.drainedMarkLightness
    for (lightness, expected) in [(0.45, band.lowerBound), (0.78, 0.78), (0.95, band.upperBound)] {
      // Inside sRGB at all three lightnesses; a pale amber holds little more.
      let cover = CoverWashValue(
        oklabLightness: lightness, chroma: 0.03, hueRadians: 70 * .pi / 180
      ).rgbColor
      let mark = CoverWash.drainedMark(for: cover)
      #expect(abs(mark.oklabLightness - expected) < 1e-3, "cover lightness \(lightness)")
      #expect(Self.hueDrift(mark.oklabHueDegrees, from: 70) < 1, "cover lightness \(lightness)")
    }
  }

  /// A drained shelf is still one surface: a card with no hue sits where a tinted one does, so the
  /// two separate from the page on lightness alone.
  @Test("a cover with no hue drains to the drained neutral, at the tinted cards' weight")
  func drainedNeutral() {
    #expect(
      CoverWash.from(hue: nil, saturation: nil, brightness: nil)
        == .drainedNeutral)
    #expect(CoverWash.from(hue: 0.8, saturation: 0.049, brightness: 0.5) == .drainedNeutral)

    let neutral = CoverWash.drainedNeutral
    #expect(neutral.drainsDark)
    #expect(neutral.light == CoverWash.neutral.light)
    #expect(neutral.darkPage == neutral.dark)
    #expect(neutral.lightAccent == nil)
    #expect(neutral.darkAccent == nil)
    #expect(neutral.darkTint == nil)
    #expect(neutral.dark.oklabChroma < 0.01)
    for hue in Self.hues {
      let tinted = CoverWash.from(hue: hue, saturation: 0.8, brightness: 0.7)
      #expect(abs(tinted.dark.oklabLightness - neutral.dark.oklabLightness) < 0.005)
    }
  }

  /// The mark is also a badge's disc, with the card's colour as its glyph, so one ratio covers the
  /// progress bar, the badge and any eyebrow solved against the card.
  @Test("the mark and the card's ink clear AA on every drained card")
  func drainedCardContrast() {
    for hue in Self.hues {
      for accent in Self.accents {
        let wash = CoverWash.from(
          hue: hue, saturation: accent.saturation, brightness: accent.brightness)
        let card = wash.dark.rgbColor

        #expect(contrastRatio(WhirrRGBColor(1, 1, 1), card) >= 7)
        for increasedContrast in [false, true] {
          let secondary = WashInk.darkSecondary(on: card, increasedContrast: increasedContrast)
          #expect(contrastRatio(secondary, card) >= 4.5)
        }
        if let mark = wash.darkAccent {
          #expect(contrastRatio(mark.rgbColor, card) >= 5, "hue \(hue), \(accent)")
        }
        if let tint = wash.darkTint {
          #expect(contrastRatio(tint.rgbColor, card) >= 4.5)
        }
      }
    }
  }

  @Test("a drained wash lends its mark only in the standard dark appearance")
  func drainedMarkScope() {
    let drained = CoverWash.from(hue: 0.08, saturation: 0.8, brightness: 0.7)

    #expect(
      WashInk.drainedMark(colorScheme: .dark, wash: drained, increasedContrast: false)
        == drained.darkAccent)
    #expect(WashInk.drainedMark(colorScheme: .light, wash: drained, increasedContrast: false) == nil)
    // Increase Contrast paints the neutral card instead, which has no colour to give its marks.
    #expect(WashInk.drainedMark(colorScheme: .dark, wash: drained, increasedContrast: true) == nil)
    #expect(WashInk.drainedMark(colorScheme: .dark, wash: .neutral, increasedContrast: false) == nil)
    #expect(
      WashInk.drainedMark(colorScheme: .dark, wash: .drainedNeutral, increasedContrast: false)
        == nil)
    #expect(WashInk.drainedMark(colorScheme: .dark, wash: nil, increasedContrast: false) == nil)
  }

  @Test("the progress bar keeps the tint it is given on a drained dark wash")
  @MainActor
  func progressBarKeepsItsTint() {
    let mark = CoverWash.from(hue: 0.08, saturation: 0.8, brightness: 0.7)
      .darkAccent
    let given = Color.orange

    #expect(
      PlaybackProgressBar.resolvedTint(
        given, colorScheme: .dark, isOnWash: true, drainedMark: mark) == given)
    // With no drained mark to take (the plain neutral wash) the bar steps back to the shared tint.
    #expect(
      PlaybackProgressBar.resolvedTint(
        given, colorScheme: .dark, isOnWash: true, drainedMark: nil)
        == PlaybackProgressBar.progressTint)
    #expect(
      PlaybackProgressBar.resolvedTint(
        given, colorScheme: .light, isOnWash: true, drainedMark: nil) == given)
    #expect(
      PlaybackProgressBar.resolvedTint(
        given, colorScheme: .dark, isOnWash: false, drainedMark: nil) == given)
  }
}
