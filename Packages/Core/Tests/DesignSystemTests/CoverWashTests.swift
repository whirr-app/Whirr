import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Cover wash")
struct CoverWashTests {
  @Test("preserves hue for saturated red and blue accents", arguments: [0.0, 2.0 / 3.0])
  func preservesHue(_ hue: Double) {
    let wash = CoverWash.from(hue: hue, saturation: 1, brightness: 1)
    let source = CoverWashValue(hue: hue, saturation: 1, brightness: 1)

    #expect(abs(wash.light.oklabHueDegrees - source.oklabHueDegrees) < 0.5)
    // The light and dark washes are built in OKLCh, so they carry the accent's perceptual hue
    // rather than its HSB one. Half a degree of drift is the round trip through sRGB.
    #expect(abs(wash.dark.oklabHueDegrees - source.oklabHueDegrees) < 0.5)
  }

  /// The light card is built in OKLCh so every hue reads at one strength. In HSB a fixed saturation
  /// is a vivid green and a grey-blue, and the blue sat closest to the secondary ink's AA line.
  @Test("light card lightness stays in its band at every hue", arguments: [(2.0, 2.0), (0.05, 0.0)])
  func lightCardStaysInItsBand(_ input: (saturation: Double, brightness: Double)) {
    for step in 0..<72 {
      let wash = CoverWash.from(
        hue: Double(step) / 72, saturation: input.saturation, brightness: input.brightness)
      #expect((0.859...0.941).contains(wash.light.oklabLightness), "hue step \(step)")
      #expect(wash.light.oklabChroma <= 0.0705, "hue step \(step)")
    }
  }

  /// Strong enough to read as the cover's colour rather than a grey with a hint of it.
  @Test("light card carries the cover's colour at every hue")
  func lightCardCarriesColour() {
    for step in 0..<72 {
      let hue = Double(step) / 72
      let vivid = CoverWash.from(hue: hue, saturation: 0.75, brightness: 0.75)
      let faint = CoverWash.from(hue: hue, saturation: 0.1, brightness: 0.6)

      #expect(vivid.light.oklabChroma >= 0.0449, "hue step \(step): \(vivid.light.oklabChroma)")
      #expect(faint.light.oklabChroma >= 0.04, "hue step \(step): \(faint.light.oklabChroma)")
      #expect(faint.light.oklabChroma <= vivid.light.oklabChroma + 1e-6)
    }
  }

  /// Yellows keep their brightness: a dark yellow is khaki, so lightness follows the hue's own.
  @Test("light card follows the hue's own lightness")
  func lightCardFollowsHueLightness() {
    let yellow = CoverWash.from(hue: 60.0 / 360, saturation: 0.75, brightness: 0.75)
    let blue = CoverWash.from(hue: 240.0 / 360, saturation: 0.75, brightness: 0.75)
    #expect(yellow.light.oklabLightness > blue.light.oklabLightness + 0.05)
  }

  @Test("derives punched accents inside both accent bands")
  func derivesAccentsInsideBands() {
    let loud = CoverWash.from(hue: 0.4, saturation: 2, brightness: 2)
    let faint = CoverWash.from(hue: 0.4, saturation: 0.05, brightness: 0)

    for wash in [loud, faint] {
      #expect(wash.lightAccent?.hue == 0.4)
      #expect(wash.lightAccent.map { (0.55...0.75).contains($0.saturation) } == true)
      #expect(wash.lightAccent.map { (0.45...0.58).contains($0.brightness) } == true)
      #expect(wash.accentColor != nil)
    }
  }

  @Test("neutral wash carries no accent")
  func neutralCarriesNoAccent() {
    #expect(CoverWash.neutral.lightAccent == nil)
    #expect(CoverWash.neutral.darkAccent == nil)
    #expect(CoverWash.neutral.accentColor == nil)
  }

  @Test("uses the drained neutral wash for grayscale and missing accents")
  func usesNeutralFallback() {
    #expect(CoverWash.from(hue: 0.8, saturation: 0.049, brightness: 0.5) == .drainedNeutral)
    #expect(CoverWash.from(hue: nil, saturation: nil, brightness: nil) == .drainedNeutral)
    #expect(CoverWash.neutral.light.color == SwiftUI.Color(red: 0.955, green: 0.953, blue: 0.945))
  }

  @Test("exposes a dynamic card color for the neutral wash")
  func exposesCardColor() {
    #expect(CoverWash.neutral.cardColor != SwiftUI.Color.clear)
  }

  /// A light page wash has no edge at all (it is the page), and on near-white paper the card
  /// band's saturation is present but not legible, so the page variant carries more colour.
  /// A dark page drains below the card instead (`CoverWashDrainTests`).
  @Test("the light page wash carries more colour than the light card")
  func lightPageWashOutweighsTheCardWash() {
    for step in 0..<72 {
      let wash = CoverWash.from(hue: Double(step) / 72, saturation: 0.8, brightness: 0.7)

      #expect(wash.lightPage.oklabChroma > wash.light.oklabChroma, "step \(step)")
      #expect(wash.lightPage.saturation >= 0.16)
    }
  }

  /// The navigation title and the header's labels sit directly on the page wash with no scrim, so
  /// its lightness is the whole safety argument. The header's secondary ink on the dark variant
  /// is `WashInk`'s, pinned in `WashInkTests`.
  @Test("page wash keeps label contrast far above AA at every hue")
  func pageWashKeepsLabelContrast() {
    for step in 0..<72 {
      let wash = CoverWash.from(hue: Double(step) / 72, saturation: 0.9, brightness: 0.8)

      #expect(contrastRatio(wash.darkPage.rgbColor, WhirrRGBColor(1, 1, 1)) > 8)
      #expect(contrastRatio(wash.lightPage.rgbColor, WhirrRGBColor(0, 0, 0)) > 8)
    }
  }

  /// The neutral wash paints no page region at all, so its page variant is simply its own colour.
  /// Keeping them equal lets a caller read `pageColor` without a neutral special case.
  @Test("neutral wash's page variant is its own colour")
  func neutralPageMatchesNeutral() {
    #expect(CoverWash.neutral.lightPage == CoverWash.neutral.light)
    #expect(CoverWash.neutral.darkPage == CoverWash.neutral.dark)
  }

  /// The dark surfaces take the same copper turn as the full-screen dark page: towards black sRGB
  /// holds little chroma from orange through mustard, so without it every warm cover's card and
  /// show page would flatten into one brown-gold.
  @Test("dark card and page turn warm hues towards copper")
  func darkSurfacesTurnWarmHues() {
    for step in 0..<72 {
      let hue = Double(step) / 72
      let wash = CoverWash.from(hue: hue, saturation: 0.8, brightness: 0.7)
      let basis = CoverWashValue(hue: hue, saturation: 1, brightness: 1).oklab.hueRadians
      let expected = DarkWarmBand.turned(hueRadians: basis) * 180 / .pi

      for surface in [wash.dark, wash.darkPage] {
        var drift = surface.oklabHueDegrees - expected
        if drift > 180 { drift -= 360 }
        if drift < -180 { drift += 360 }
        #expect(abs(drift) < 0.5, "hue \(hue)")
      }
    }
  }

  @Test("derivation is deterministic")
  func isDeterministic() {
    let first = CoverWash.from(hue: 0.23, saturation: 0.71, brightness: 0.42)
    let second = CoverWash.from(hue: 0.23, saturation: 0.71, brightness: 0.42)

    #expect(first == second)
  }
}
