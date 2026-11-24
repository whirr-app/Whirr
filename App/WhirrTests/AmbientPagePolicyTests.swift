import DesignSystem
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// The properties the ambient page treatment promises (the page is the artwork's colour and the
/// ink on it is legible), asserted as properties, not fixtures, wherever the promise is universal.
@Suite struct AmbientPagePolicyTests {

  private static let hueSweep = stride(from: 0.0, to: 360.0, by: 5.0)

  /// A page at `lightness` and this hue, with as much chroma as sRGB will hold. This is the worst
  /// case for contrast, because chroma pushes a channel toward the ink.
  private static func saturatedPage(lightness: Double, hueDegrees: Double) -> WhirrRGBColor {
    let hue = hueDegrees * .pi / 180
    let chroma = OKLab.displayableChroma(lightness: lightness, hueRadians: hue, upTo: 0.4)
    return CoverWashValue(oklabLightness: lightness, chroma: chroma, hueRadians: hue).rgbColor
  }

  /// The appearance a single flat source resolves to, the way every page in this suite builds one.
  private static func appearance(for source: WhirrRGBColor) -> AmbientAppearance {
    CoverAmbientPalette.palette(
      from: CoverPaletteSamples(
        average: CoverRGBA(red: source.red, green: source.green, blue: source.blue),
        dominant: [CoverRGBA(red: source.red, green: source.green, blue: source.blue, weight: 1)])
    ).ambientAppearance
  }

  /// The canvas's page lightness, read back out of sRGB. The clamp itself is exact; the encode and
  /// decode round trip lands within a few parts per billion, which is why every assertion on it
  /// carries a tolerance rather than testing for equality.
  private static func pageLightness(of canvas: AmbientCanvas) -> Double {
    OKLab(
      red: canvas.backgroundRGB.red, green: canvas.backgroundRGB.green,
      blue: canvas.backgroundRGB.blue
    ).lightness
  }

  private static func floorRungContrast(
    page: WhirrRGBColor, ink: WhirrRGBColor, opacity: Double = WhirrMetadataProminence.floor
  ) -> Double {
    let composited = WhirrRGBColor(
      opacity * ink.red + (1 - opacity) * page.red,
      opacity * ink.green + (1 - opacity) * page.green,
      opacity * ink.blue + (1 - opacity) * page.blue)
    return contrastRatio(composited, page)
  }

  /// The justification for the lightness clamp: if this fails, the dimmest credits on some covers
  /// are illegible. Measured at the canvas's own ladder, not the standard floor: the light band
  /// reaches below where the standard ladder clears AA and lifts its floor there (`ADR 0007`).
  @Test("The dimmest rung clears AA at every hue across the light band, with no scrim")
  func floorRungClearsAAAcrossTheLightBand() {
    let band = CoverAmbientPalette.lightPageLightnessBand
    for lightness in [band.lowerBound, (band.lowerBound + band.upperBound) / 2, band.upperBound] {
      for hueDegrees in Self.hueSweep {
        let page = Self.saturatedPage(lightness: lightness, hueDegrees: hueDegrees)
        let canvas = CoverAmbientPalette.canvas(
          page: CoverAmbientPalette.page(from: page, mode: .light), mode: .light)
        let ratio = Self.floorRungContrast(
          page: canvas.backgroundRGB, ink: AmbientAppearanceMode.light.ink,
          opacity: canvas.metadataLadder.floor)
        #expect(
          ratio >= CoverAmbientPalette.minimumAmbientInkContrast,
          "L \(lightness), hue \(hueDegrees) measured \(ratio)")
      }
    }
  }

  /// The lift is only paid where the standard ladder cannot go. A light page at its ceiling gets
  /// `.standard` back untouched.
  @Test("Pages the standard ladder can carry are not lifted")
  func standardLadderIsKeptWhereItClears() {
    let lightness = CoverAmbientPalette.lightPageLightnessBand.upperBound
    for hueDegrees in Self.hueSweep {
      let page = Self.saturatedPage(lightness: lightness, hueDegrees: hueDegrees)
      let canvas = CoverAmbientPalette.canvas(
        page: CoverAmbientPalette.page(from: page, mode: .light), mode: .light)
      #expect(
        canvas.metadataLadder == .standard,
        "hue \(hueDegrees) lifted to \(canvas.metadataLadder.floor)")
    }
  }

  /// The light band's floor is where the lift stops being cheap, not where it stops being
  /// possible. Fully opaque black clears the wall only from 0.60; the floor is set well above it
  /// so the worst hue's lift stays mild and the hierarchy keeps its rungs apart.
  @Test("The light band's floor keeps the ladder lift mild at every hue")
  func lightBandFloorKeepsTheLiftMild() {
    let floor = CoverAmbientPalette.lightPageLightnessBand.lowerBound
    for hueDegrees in Self.hueSweep {
      let page = Self.saturatedPage(lightness: floor, hueDegrees: hueDegrees)
      let canvas = CoverAmbientPalette.canvas(
        page: CoverAmbientPalette.page(from: page, mode: .light), mode: .light)
      #expect(
        canvas.metadataLadder.floor <= 0.78,
        "hue \(hueDegrees) lifted to \(canvas.metadataLadder.floor)")
    }
  }

  /// The light band's ceiling is a glare limit, and this property enforces it.
  ///
  /// Stated in emitted light rather than lightness, because emitted light is what the ceiling
  /// bounds. Swept at 1 degree at the maximum chroma the ceiling admits, the worst hue reaches
  /// relative luminance 0.521. The bound below is that worst case plus a hair.
  @Test("A light page's emitted light is bounded by the band's ceiling, at every hue")
  func lightPageEmittedLightIsBounded() {
    let ceiling = CoverAmbientPalette.lightPageLightnessBand.upperBound

    for sourceLightness in [0.80, 0.88, 0.97] {
      for hueDegrees in Self.hueSweep {
        let source = Self.saturatedPage(lightness: sourceLightness, hueDegrees: hueDegrees)
        let page = CoverAmbientPalette.page(from: source, mode: .light)

        #expect(
          page.oklabLightness <= ceiling + 1e-6,
          "hue \(hueDegrees) from L \(sourceLightness) reached \(page.oklabLightness)")
        #expect(
          page.rgbColor.relativeLuminance <= 0.53,
          "hue \(hueDegrees) emitted \(page.rgbColor.relativeLuminance)")
      }
    }
  }

  /// The ceiling only takes brightness off covers over it. A cover inside the band keeps its own
  /// lightness, so the light pole does not collapse to one colour.
  @Test("A light cover already inside the band keeps its own lightness")
  func lightCoverInsideTheBandIsUntouched() {
    let band = CoverAmbientPalette.lightPageLightnessBand
    let inside = (band.lowerBound + band.upperBound) / 2

    for hueDegrees in Self.hueSweep {
      let source = Self.saturatedPage(lightness: inside, hueDegrees: hueDegrees)
      let page = CoverAmbientPalette.page(from: source, mode: .light)
      #expect(abs(page.oklabLightness - inside) < 1e-6)
    }
  }

  /// Increase Contrast is the one caller that ignores the glare ceiling, and must keep ignoring
  /// it. On the light pole contrast is bought with brightness, so a comfort limit here would take
  /// ratio from the readers who asked for the opposite trade.
  @Test("Increase Contrast lifts a light page above the glare ceiling")
  func increasedContrastIgnoresTheGlareCeiling() {
    #expect(
      CoverAmbientPalette.lightPageIncreasedContrastLightness
        > CoverAmbientPalette.lightPageLightnessBand.upperBound)

    for hueDegrees in Self.hueSweep {
      let source = Self.saturatedPage(lightness: 0.97, hueDegrees: hueDegrees)
      let strengthened = CoverAmbientPalette.page(
        from: source, mode: .light, increasedContrast: true)
      let ratio = Self.floorRungContrast(page: strengthened.rgbColor, ink: WhirrRGBColor(0, 0, 0))
      #expect(ratio >= 6.0, "hue \(hueDegrees) measured \(ratio)")
    }
  }

  /// Asserted as a property, so a change that reintroduces a mid-lightness page fails here.
  ///
  /// Between the poles neither ink at the metadata floor guarantees AA across all hues. White ink
  /// stops clearing it above 0.4032, and the light band starts at 0.65. A dark page drains well
  /// below that edge (`CoverWash.drainedPageLightness`), and a light page stays in its band.
  @Test("No lightness between the poles is legible for either ink")
  func theDeadZoneIsReal() {
    let lower = 0.40
    #expect(CoverWash.drainedPageLightness < lower)
    let upper = CoverAmbientPalette.lightPageLightnessBand.lowerBound
    #expect(lower < upper)

    for lightness in stride(from: lower + 0.02, to: upper, by: 0.02) {
      let worstWhite =
        Self.hueSweep.map {
          Self.floorRungContrast(
            page: Self.saturatedPage(lightness: lightness, hueDegrees: $0), ink: WhirrRGBColor(1, 1, 1))
        }.min() ?? 0
      let worstBlack =
        Self.hueSweep.map {
          Self.floorRungContrast(
            page: Self.saturatedPage(lightness: lightness, hueDegrees: $0), ink: WhirrRGBColor(0, 0, 0))
        }.min() ?? 0
      #expect(worstWhite < CoverAmbientPalette.minimumAmbientInkContrast)
      #expect(worstBlack < CoverAmbientPalette.minimumAmbientInkContrast)
    }
  }

  /// The page requests a set chroma, as the card does, so muted and vivid covers of one hue carry
  /// the same weight; only the sRGB gamut may reduce it. Reachability is measured at the page's
  /// built hue, not the source's OKLab hue: `page(from:mode:)` re-derives it, moving the sRGB cap.
  /// Dark pages drain instead.
  @Test("A muted cover and a vivid one both carry the chroma request, gamut permitting")
  func pageChromaMeetsTheRequest() {
    for hueDegrees in Self.hueSweep {
      for sourceChroma in [0.03, 0.14] {
        let source = CoverWashValue(
          oklabLightness: 0.72, chroma: sourceChroma, hueRadians: hueDegrees * .pi / 180
        ).rgbColor
        for increasedContrast in [false, true] {
          let page = CoverAmbientPalette.page(
            from: source, mode: .light, increasedContrast: increasedContrast)
          let expected = OKLab.displayableChroma(
            lightness: page.oklabLightness, hueRadians: page.oklab.hueRadians,
            upTo: CoverAmbientPalette.pageChromaRequest)
          #expect(
            abs(page.oklabChroma - expected) < 0.003,
            "contrast \(increasedContrast) hue \(hueDegrees) source \(sourceChroma): \(page.oklabChroma) against \(expected)"
          )
        }
      }
    }
  }

  /// Regression for the gold-tinted cover of Call of the Kiwi, whose average is olive-khaki. The
  /// page must come from the dominant cluster, not the average, and must be recognisably gold.
  /// The clusters are the retail cover as true-colour k-means reads it.
  @Test("A gold-and-green cover yields a gold page, not the olive its average would give")
  func goldAndGreenCoverIsNotOlive() throws {
    let gold = CoverRGBA(red: 0.82, green: 0.76, blue: 0.30, weight: 0.357)
    let average = CoverRGBA(red: 0.72, green: 0.67, blue: 0.33)

    let palette = CoverAmbientPalette.palette(
      from: CoverPaletteSamples(average: average, dominant: Self.callOfTheKiwi(gold: gold)))
    let source = CoverAmbientPalette.pageSource(from: palette.ambientAppearance.evidence)
    #expect(source == WhirrRGBColor(gold.red, gold.green, gold.blue))

    let goldHueRadians = OKLab(red: gold.red, green: gold.green, blue: gold.blue).hueRadians
    for canvas in [palette.ambientAppearance.dark, palette.ambientAppearance.light] {
      let page = canvas.backgroundRGB
      let lab = OKLab(red: page.red, green: page.green, blue: page.blue)
      let hueDegrees = lab.hueRadians * 180 / .pi
      #expect(abs(hueDegrees - Self.expectedPageHueDegrees(goldHueRadians, mode: canvas.mode)) < 15)
      // Dark pages drain to a trace of the cover's chroma.
      if canvas.mode == .light { #expect(lab.chroma >= 0.06) }
    }
  }

  /// The page and the Home card are one colour for one cover. The card uses the selected cluster
  /// whatever its weight, so the page does too. A weight floor would send a light-covering accent
  /// back to the average, leaving the page a different colour from its card.
  @Test("The card's cluster paints the page however little of the cover it covers")
  func pageUsesTheCardsClusterAtAnyWeight() {
    let speck = CoverRGBA(red: 0.95, green: 0.05, blue: 0.05, weight: 0.02)
    let average = CoverRGBA(red: 0.30, green: 0.31, blue: 0.33)
    let palette = CoverAmbientPalette.palette(
      from: CoverPaletteSamples(average: average, dominant: [speck]))
    let speckOnly = Self.appearance(for: WhirrRGBColor(speck.red, speck.green, speck.blue))

    #expect(palette.rawAccentHSB != nil)
    #expect(
      CoverAmbientPalette.pageSource(from: palette.ambientAppearance.evidence)
        == WhirrRGBColor(speck.red, speck.green, speck.blue))
    #expect(palette.ambientAppearance.dark == speckOnly.dark)
    #expect(palette.ambientAppearance.light == speckOnly.light)
  }

  /// With no cluster the card is neutral, so the page must not boost the average into a colour.
  @Test("A cover with no cluster keeps its average's own chroma")
  func noClusterIsNotBoosted() {
    let average = CoverRGBA(red: 0.36, green: 0.30, blue: 0.24)
    let appearance = CoverAmbientPalette.palette(
      from: CoverPaletteSamples(average: average, dominant: [])
    ).ambientAppearance
    let averageLab = OKLab(red: average.red, green: average.green, blue: average.blue)

    #expect(appearance.evidence.cluster == nil)
    for canvas in [appearance.dark, appearance.light] {
      let page = OKLab(
        red: canvas.backgroundRGB.red, green: canvas.backgroundRGB.green,
        blue: canvas.backgroundRGB.blue)
      #expect(page.chroma <= averageLab.chroma + 0.005, "\(canvas.mode) chroma \(page.chroma)")
    }
  }

  /// `CoverWash.from` sends an accent under the saturation floor to the neutral card; a page that
  /// boosted the same cover to full colour would disagree with its own card.
  @Test("A cover with no hue is not boosted")
  func greyCoverIsNotBoosted() {
    let grey = CoverWashValue(oklabLightness: 0.6, chroma: 0.004, hueRadians: 250 * .pi / 180)
      .rgbColor
    for mode in [AmbientAppearanceMode.light, .dark] {
      #expect(CoverAmbientPalette.page(from: grey, mode: mode).oklabChroma < 0.01)
    }
  }

  /// The standard dark page drains to one lightness, under its drained card: drained, a page goes
  /// almost to black rather than being seen as a region.
  @Test("Every standard dark page sits at one lightness, under its card")
  func darkPageHoldsOneLightness() {
    for hueDegrees in Self.hueSweep {
      for sourceLightness in [0.10, 0.30, 0.55, 0.90] {
        let source = Self.saturatedPage(lightness: sourceLightness, hueDegrees: hueDegrees)
        let page = Self.appearance(for: source).dark
        #expect(
          abs(Self.pageLightness(of: page) - CoverWash.drainedPageLightness) < 1e-6,
          "hue \(hueDegrees) from L \(sourceLightness)")
      }
    }
    #expect(CoverWash.drainedPageLightness < CoverWash.drainedCardLightness)
  }

  @Test("App appearance selects a mandatory pale or deep canvas")
  func appAppearanceSelectsTheCanvas() {
    for lightness in stride(from: 0.05, through: 0.98, by: 0.05) {
      for hueDegrees in stride(from: 0.0, to: 360.0, by: 30.0) {
        let appearance = Self.appearance(
          for: Self.saturatedPage(lightness: lightness, hueDegrees: hueDegrees))
        let light = appearance.canvas(for: .light)
        let dark = appearance.canvas(for: .dark)
        #expect(light.mode == .light)
        #expect(dark.mode == .dark)
        #expect(Self.pageLightness(of: light) >= CoverAmbientPalette.lightPageLightnessBand.lowerBound - 1e-6)
        #expect(Self.pageLightness(of: light) <= CoverAmbientPalette.lightPageLightnessBand.upperBound + 1e-6)
        #expect(abs(Self.pageLightness(of: dark) - CoverWash.drainedPageLightness) < 1e-6)
      }
    }
  }

  @Test("Neutral entry fallbacks match appearance and retain readable metadata")
  func neutralFallbacksMatchAppearance() {
    for scheme in [ColorScheme.light, .dark] {
      for increased in [false, true] {
        let canvas = CoverAmbientPalette.fallbackCanvas(for: scheme, increasedContrast: increased)
        #expect(canvas.mode.colorScheme == scheme)
        #expect(canvas.inkRGB == (scheme == .light ? WhirrRGBColor(0, 0, 0) : WhirrRGBColor(1, 1, 1)))
        #expect(
          Self.floorRungContrast(
            page: canvas.backgroundRGB, ink: canvas.inkRGB,
            opacity: canvas.metadataLadder.floor) >= CoverAmbientPalette.minimumAmbientInkContrast)
      }
    }
  }

  /// Every page the app can put on screen carries a ladder whose dimmest rung is legible on it.
  @Test("Every resolved canvas carries a ladder that clears AA on it")
  func everyCanvasCarriesALegibleLadder() {
    for lightness in stride(from: 0.05, through: 0.98, by: 0.03) {
      for hueDegrees in stride(from: 0.0, to: 360.0, by: 15.0) {
        let appearance = Self.appearance(
          for: Self.saturatedPage(lightness: lightness, hueDegrees: hueDegrees))
        for scheme in [ColorScheme.light, .dark] {
          for increased in [false, true] {
            let canvas = appearance.canvas(for: scheme, increasedContrast: increased)
            let ratio = Self.floorRungContrast(
              page: canvas.backgroundRGB, ink: canvas.inkRGB,
              opacity: canvas.metadataLadder.floor)
            #expect(
              ratio >= CoverAmbientPalette.minimumAmbientInkContrast,
              "L \(lightness) hue \(hueDegrees) \(scheme) increased \(increased): \(ratio)")
          }
        }
      }
    }
  }

  /// The inline Up Next queue sits on the ambient page, so each of its rungs is measured on every
  /// canvas at that canvas's own ladder, not the standard one.
  @Test("Every Up Next rung clears AA on every canvas")
  func upNextRungsClearAAOnEveryCanvas() {
    let roles: [WhirrMetadataProminence] = [
      .playerByline, .queueRowSubtitle, .queueRowLabel,
    ]
    for lightness in stride(from: 0.05, through: 0.98, by: 0.03) {
      for hueDegrees in stride(from: 0.0, to: 360.0, by: 15.0) {
        let appearance = Self.appearance(
          for: Self.saturatedPage(lightness: lightness, hueDegrees: hueDegrees))
        for scheme in [ColorScheme.light, .dark] {
          for increased in [false, true] {
            let canvas = appearance.canvas(for: scheme, increasedContrast: increased)
            for role in roles {
              let ratio = Self.floorRungContrast(
                page: canvas.backgroundRGB, ink: canvas.inkRGB,
                opacity: canvas.metadataLadder.opacity(for: role))
              #expect(
                ratio >= CoverAmbientPalette.minimumAmbientInkContrast,
                "\(role) L \(lightness) hue \(hueDegrees) \(scheme) increased \(increased): \(ratio)"
              )
            }
          }
        }
      }
    }
  }

  /// The disc and the Resume capsule fill with the ink, and their label takes the page colour. The
  /// destination-out glyph needs no separate contrast check: disc against canvas is ink against
  /// page, the ratio the ladder already guarantees at its brightest rung.
  @Test("The primary action fills with the ink and labels with the page")
  func primaryActionIsNeutral() {
    for mode in [AmbientAppearanceMode.light, .dark] {
      let page = CoverAmbientPalette.page(
        from: WhirrRGBColor(0.83, 0.62, 0.13), mode: mode)
      let canvas = CoverAmbientPalette.canvas(page: page, mode: mode)

      #expect(canvas.primaryAction.fill == mode.ink)
      #expect(canvas.primaryAction.ink == canvas.backgroundRGB)
      #expect(
        contrastRatio(canvas.primaryAction.fill, canvas.primaryAction.ink)
          >= CoverAmbientPalette.minimumAmbientInkContrast)
    }
  }

  @Test("Window chrome follows the app preference")
  func windowSchemeFollowsTheAppPreference() {
    #expect(CoverAmbientPresentation.windowColorScheme(appPreference: .light) == .light)
    #expect(CoverAmbientPresentation.windowColorScheme(appPreference: .dark) == .dark)
    #expect(CoverAmbientPresentation.windowColorScheme(appPreference: nil) == nil)
  }

  @Test("Bright and dark artwork use the requested appearance")
  func artworkUsesTheAppAppearance() {
    let brightCover = CoverPaletteSamples(
      average: CoverRGBA(red: 0.78, green: 0.70, blue: 0.28),
      dominant: [CoverRGBA(red: 0.94, green: 0.82, blue: 0.16, weight: 0.62)])
    let darkCover = CoverPaletteSamples(
      average: CoverRGBA(red: 0.12, green: 0.14, blue: 0.22),
      dominant: [CoverRGBA(red: 0.10, green: 0.12, blue: 0.20, weight: 0.85)])

    for samples in [brightCover, darkCover] {
      let canvas = CoverAmbientPalette.palette(from: samples)
        .ambientAppearance.canvas(for: .light)
      #expect(canvas.mode == .light)
      #expect(canvas.inkRGB == AmbientAppearanceMode.light.ink)
      #expect(CoverAmbientPalette.palette(from: samples).ambientAppearance.canvas(for: .dark).mode == .dark)
    }
  }

  /// Neither ambient page resolves its canvas against a literal appearance.
  ///
  /// A source assertion: the guarded thing is a call made inside a private computed property that
  /// no test can reach. The pages must pass the effective app appearance through to their held
  /// palette. The ban on a literal appearance is a source rule (`chrome.toml`).
  @Test("Both ambient pages resolve their canvas against the app appearance they were handed")
  func ambientPagesResolveAgainstTheAppAppearance() throws {
    // Each page is read as one text across the files that declare it.
    for paths in [
      [
        "App/Whirr/Views/Player/ExpandedPlayerView.swift",
        "App/Whirr/Views/Player/ExpandedPlayerView+Ambient.swift",
      ],
      ["App/Whirr/Views/ItemDetail/ItemDetailView.swift"],
    ] {
      let path = paths[0]
      let source = try paths.map { try #require(Self.source(at: $0)) }.joined(separator: "\n")
      #expect(
        source.contains("appearance: effectiveAppColorScheme"),
        "\(path) does not resolve its canvas from effectiveAppColorScheme")
    }
  }

  /// No ambient surface fills itself from the artwork. The environment tint item detail publishes
  /// is the page's ink, so everything inheriting it (the segmented control, the toolbar bubble, the
  /// cover badges) is neutral without being checked individually.
  @Test("The tint an ambient page publishes is its ink, not a colour sampled from the cover")
  func publishedTintIsTheInk() {
    let vivid = CoverPaletteSamples(
      average: CoverRGBA(red: 0.55, green: 0.30, blue: 0.10),
      dominant: [CoverRGBA(red: 0.83, green: 0.62, blue: 0.13, weight: 0.60)])
    let appearance = CoverAmbientPalette.palette(from: vivid).ambientAppearance

    for scheme in [ColorScheme.light, .dark] {
      let canvas = appearance.canvas(for: scheme)
      #expect(canvas.accent == canvas.ink)
      #expect(canvas.inkRGB == canvas.mode.ink)
    }
  }

  /// Increase Contrast on an ambient page. `CoverWash` answers this for cards by dropping the
  /// artwork colour. These pages drive lightness to the band edge instead, because on a full page
  /// lightness carries contrast and chroma is nearly free. A dark page drains whether or not it is
  /// asked for, already below the band, so there it is unchanged and never has less contrast.
  @Test("Increase Contrast raises the floor rung at every hue without discarding the colour")
  func increasedContrastPinsLightnessNotChroma() {
    for hueDegrees in Self.hueSweep {
      // A mid-lightness source, so the standard page lands inside its band and the two differ.
      let source = Self.saturatedPage(lightness: 0.50, hueDegrees: hueDegrees)

      #expect(
        CoverAmbientPalette.page(from: source, mode: .dark, increasedContrast: true)
          == CoverAmbientPalette.page(from: source, mode: .dark))

      let mode = AmbientAppearanceMode.light
      let standard = CoverAmbientPalette.page(from: source, mode: mode)
      let strengthened = CoverAmbientPalette.page(
        from: source, mode: mode, increasedContrast: true)

      // Strictly more contrast than the page it replaces, never less.
      let standardRatio = Self.floorRungContrast(page: standard.rgbColor, ink: mode.ink)
      let strengthenedRatio = Self.floorRungContrast(
        page: strengthened.rgbColor, ink: mode.ink)
      #expect(strengthenedRatio > standardRatio)
      #expect(strengthenedRatio >= CoverAmbientPalette.minimumAmbientInkContrast)

      // Still the artwork's colour: same hue, chroma kept. Cards substitute neutral instead.
      #expect(abs(strengthened.oklabHueDegrees - standard.oklabHueDegrees) < 1)
      #expect(strengthened.oklabChroma > 0.02)
    }
  }

  /// Contrast requests use the stronger variant without changing the requested ink.
  @Test("Increase Contrast reaches its lightness target and retains the requested ink")
  func increasedContrastUsesItsTarget() {
    for lightness in stride(from: 0.05, through: 0.98, by: 0.03) {
      for hueDegrees in stride(from: 0.0, to: 360.0, by: 45.0) {
        let source = Self.saturatedPage(lightness: lightness, hueDegrees: hueDegrees)
        let appearance = CoverAmbientPalette.palette(
          from: CoverPaletteSamples(
            average: CoverRGBA(red: source.red, green: source.green, blue: source.blue),
            dominant: [
              CoverRGBA(red: source.red, green: source.green, blue: source.blue, weight: 1)
            ])
        ).ambientAppearance

        for scheme in [ColorScheme.light, .dark] {
          let standard = appearance.canvas(for: scheme)
          let strengthened = appearance.canvas(for: scheme, increasedContrast: true)
          let expected =
            scheme == .light
            ? CoverAmbientPalette.lightPageIncreasedContrastLightness
            : CoverWash.drainedPageLightness
          #expect(abs(Self.pageLightness(of: strengthened) - expected) < 1e-6)
          #expect(strengthened.mode == standard.mode)
          #expect(strengthened.inkRGB == standard.inkRGB)
        }
      }
    }
  }

  // MARK: - The reference corpus

  /// Reference covers, the numeric half of the device acceptance. Built to the described colours,
  /// not sampled from screenshots (not in the repository), so they guard the policy (a teal cover
  /// gives a teal page, chroma limited only by the gamut) and are no evidence about real covers.
  private struct ReferenceCover {
    let name: String
    let samples: CoverPaletteSamples
  }

  private static let referenceCorpus: [ReferenceCover] = [
    // Teal, dominant and saturated.
    ReferenceCover(
      name: "teal",
      samples: CoverPaletteSamples(
        average: CoverRGBA(red: 0.20, green: 0.36, blue: 0.38),
        dominant: [
          CoverRGBA(red: 0.09, green: 0.42, blue: 0.45, weight: 0.55),
          CoverRGBA(red: 0.86, green: 0.87, blue: 0.84, weight: 0.20),
        ])),
    // Saturated yellow. A dark page must hold it without turning brown, and the light pole must
    // not wash it out to cream.
    ReferenceCover(
      name: "yellow",
      samples: CoverPaletteSamples(
        average: CoverRGBA(red: 0.78, green: 0.70, blue: 0.28),
        dominant: [
          CoverRGBA(red: 0.94, green: 0.82, blue: 0.16, weight: 0.62),
          CoverRGBA(red: 0.16, green: 0.15, blue: 0.14, weight: 0.18),
        ])),
    // Call of the Kiwi's gold-tinted cover, whose average is khaki.
    ReferenceCover(
      name: "gold and green",
      samples: CoverPaletteSamples(
        average: CoverRGBA(red: 0.72, green: 0.67, blue: 0.33),
        dominant: callOfTheKiwi(gold: CoverRGBA(red: 0.82, green: 0.76, blue: 0.30, weight: 0.357)))),
  ]

  /// Call of the Kiwi's retail cover as true-colour k-means reads it, around its gold field.
  private static func callOfTheKiwi(gold: CoverRGBA) -> [CoverRGBA] {
    [
      CoverRGBA(red: 0.42, green: 0.31, blue: 0.18, weight: 0.086),
      CoverRGBA(red: 0.92, green: 0.89, blue: 0.51, weight: 0.294),
      gold,
      CoverRGBA(red: 0.22, green: 0.18, blue: 0.13, weight: 0.050),
      CoverRGBA(red: 0.64, green: 0.60, blue: 0.29, weight: 0.163),
      CoverRGBA(red: 0.03, green: 0.03, blue: 0.03, weight: 0.050),
    ]
  }

  /// The cover's hue in degrees as the page should carry it: turned towards copper by the warm
  /// band on a dark page, untouched on a light one.
  private static func expectedPageHueDegrees(_ hueRadians: Double, mode: AmbientAppearanceMode)
    -> Double
  {
    guard mode == .dark else { return hueRadians * 180 / .pi }
    return DarkWarmBand.turned(hueRadians: hueRadians) * 180 / .pi
  }

  @Test("Each reference cover's page keeps its cover's hue and all the chroma sRGB will hold")
  func referenceCoversKeepTheirColour() {
    for cover in Self.referenceCorpus {
      let appearance = CoverAmbientPalette.palette(from: cover.samples).ambientAppearance
      let source = CoverAmbientPalette.pageSource(from: appearance.evidence)
      let sourceLab = OKLab(red: source.red, green: source.green, blue: source.blue)

      for canvas in [appearance.dark, appearance.light] {
        let page = OKLab(
          red: canvas.backgroundRGB.red, green: canvas.backgroundRGB.green,
          blue: canvas.backgroundRGB.blue)

        // Hue is carried through, less the dark page's warm-band turn. The 15 degree tolerance
        // covers the re-derivation of hue from the source's saturated form, which moves the angle.
        let expected = Self.expectedPageHueDegrees(sourceLab.hueRadians, mode: canvas.mode)
        var hueDelta = abs(page.hueRadians * 180 / .pi - expected)
          .truncatingRemainder(dividingBy: 360)
        if hueDelta > 180 { hueDelta = 360 - hueDelta }
        #expect(hueDelta < 15, "\(cover.name) \(canvas.mode) hue moved \(hueDelta) degrees")

        // Dark pages drain to a trace of the cover's chroma.
        guard canvas.mode == .light else { continue }

        // Chroma is the page's request, limited by the gamut at the page's lightness and by
        // nothing else.
        let reachable = OKLab.displayableChroma(
          lightness: page.lightness, hueRadians: page.hueRadians,
          upTo: CoverAmbientPalette.pageChromaRequest)
        #expect(
          page.chroma >= reachable - 0.02,
          "\(cover.name) \(canvas.mode) chroma \(page.chroma) below reachable \(reachable)")

        // The page is a colour, not a near-neutral. The old muted policy would have failed this.
        #expect(page.chroma >= 0.05, "\(cover.name) \(canvas.mode) chroma \(page.chroma)")
      }
    }
  }

  /// The grayscale control has no colour to carry, so the page must be neutral rather than pick up
  /// a hue from float noise. It must still resolve a pole and stay legible.
  @Test("A grayscale cover yields a neutral page that still resolves a pole")
  func grayscaleCoverYieldsANeutralPage() {
    let grayscale = CoverPaletteSamples(
      average: CoverRGBA(red: 0.52, green: 0.52, blue: 0.52),
      dominant: [
        CoverRGBA(red: 0.34, green: 0.34, blue: 0.34, weight: 0.48),
        CoverRGBA(red: 0.88, green: 0.88, blue: 0.88, weight: 0.30),
      ])
    let appearance = CoverAmbientPalette.palette(from: grayscale).ambientAppearance

    for canvas in [appearance.dark, appearance.light] {
      let page = OKLab(
        red: canvas.backgroundRGB.red, green: canvas.backgroundRGB.green,
        blue: canvas.backgroundRGB.blue)
      #expect(page.chroma < 0.005)
      #expect(
        Self.floorRungContrast(
          page: canvas.backgroundRGB, ink: canvas.mode.ink, opacity: canvas.metadataLadder.floor)
          >= CoverAmbientPalette.minimumAmbientInkContrast)
    }
  }

  private static func source(at repositoryRelativePath: String) -> String? {
    var directory = URL(fileURLWithPath: #filePath)
    while directory.pathComponents.count > 1 {
      directory.deleteLastPathComponent()
      let candidate = directory.appendingPathComponent(repositoryRelativePath)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return try? String(contentsOf: candidate, encoding: .utf8)
      }
    }
    return nil
  }
}
