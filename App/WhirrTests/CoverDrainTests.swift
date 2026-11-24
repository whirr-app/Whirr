import DesignSystem
import Foundation
import Testing
import UIKit

@testable import Whirr

/// Pins the drained dark page and its marks. See `CoverAmbientPalette.page(from:mode:increasedContrast:)`.
@Suite struct CoverDrainTests {
  /// The selected clusters of The Shadow of What Was Lost (orange) and Dust (yellow), as
  /// true-colour k-means reads them.
  private static let shadow = WhirrRGBColor(0.937, 0.520, 0.215)
  private static let dust = WhirrRGBColor(0.949, 0.812, 0.110)

  /// Cover hues around the circle.
  private static let hues: [Double] = stride(from: 0.0, to: 360.0, by: 15.0).map { $0 }

  /// Covers too grey for a hue by the card's test, and a cover whose extraction selected no
  /// cluster at all.
  private static let unhued: [WhirrRGBColor?] = [colour(hueDegrees: 82, chroma: 0.004), nil]

  private static func colour(hueDegrees: Double, lightness: Double = 0.7, chroma: Double = 0.1)
    -> WhirrRGBColor
  {
    CoverWashValue(oklabLightness: lightness, chroma: chroma, hueRadians: hueDegrees * .pi / 180)
      .rgbColor
  }

  private static func evidence(_ cluster: WhirrRGBColor?) -> CoverPageEvidence {
    CoverPageEvidence(
      average: cluster ?? WhirrRGBColor(0.3, 0.3, 0.3), cluster: cluster, clusterWeight: 0.5)
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

  /// The hue a cover's dark surfaces are built at: its saturated form's, turned as `DarkWarmBand`
  /// turns it.
  private static func surfaceHueDegrees(_ cover: WhirrRGBColor) -> Double {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(red: cover.red, green: cover.green, blue: cover.blue, alpha: 1)
      .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    let basis = CoverWashValue(hue: Double(hue), saturation: 1, brightness: 1).oklab.hueRadians
    return DarkWarmBand.turned(hueRadians: basis) * 180 / .pi
  }

  private static func darkPage(_ cluster: WhirrRGBColor?) -> CoverWashValue {
    CoverAmbientPalette.page(from: evidence(cluster), mode: .dark)
  }

  private static func darkCanvas(_ cluster: WhirrRGBColor?) -> AmbientCanvas {
    CoverAmbientPalette.palette(fromEvidence: evidence(cluster), accent: nil).ambientAppearance.dark
  }

  /// The card for a cover whose selected cluster this is, from the HSB accent its palette record
  /// stores.
  private static func wash(_ cluster: WhirrRGBColor) -> CoverWash {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(red: cluster.red, green: cluster.green, blue: cluster.blue, alpha: 1)
      .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    return CoverWash.from(
      hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
  }

  private static func isClose(_ a: WhirrRGBColor, _ b: WhirrRGBColor) -> Bool {
    abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
  }

  private static var hued: [WhirrRGBColor] {
    [shadow, dust] + hues.map { colour(hueDegrees: $0) }
  }

  // MARK: - The page

  @Test("every standard dark page is almost black, keeping a trace of the cover's chroma at its hue")
  func drainedPage() {
    for cover in Self.hued {
      let page = Self.darkPage(cover)
      #expect(abs(page.oklabLightness - CoverWash.drainedPageLightness) < 1e-4, "\(cover)")
      #expect(page.oklabChroma <= Self.oklab(cover).chroma * CoverWash.drainedChromaShare + 1e-4)
      #expect(page.oklabChroma > 0.005, "\(cover) should keep a tint, not go neutral")
      #expect(
        Self.hueDrift(page.oklabHueDegrees, from: Self.surfaceHueDegrees(cover)) < 1, "\(cover)")
    }
  }

  @Test("a page with no hue drains too, keeping no more than its own trace of colour")
  func unhuedPagesDrain() {
    for cover in Self.unhued {
      let source = CoverAmbientPalette.pageSource(from: Self.evidence(cover))
      let page = Self.darkPage(cover)
      #expect(abs(page.oklabLightness - CoverWash.drainedPageLightness) < 1e-4)
      #expect(page.oklabChroma <= Self.oklab(source).chroma * CoverWash.drainedChromaShare + 1e-4)
    }
  }

  @Test("Increase Contrast's dark page drains too, with its action ink; light pages do not drain")
  func increasedContrastDrainsAndLightDoesNot() {
    for cover in Self.hued + Self.unhued {
      let evidence = Self.evidence(cover)
      #expect(
        CoverAmbientPalette.page(from: evidence, mode: .dark, increasedContrast: true)
          == Self.darkPage(cover))
      let contrast = CoverAmbientPalette.palette(fromEvidence: evidence, accent: nil)
        .ambientAppearance.darkIncreasedContrast
      #expect(contrast.primaryAction.fill == contrast.inkRGB)
      let light = CoverAmbientPalette.page(from: evidence, mode: .light)
      #expect(light.oklabLightness >= CoverAmbientPalette.lightPageLightnessBand.lowerBound - 1e-4)
    }
  }

  // MARK: - The primary action

  @Test("a hued cover's dark page fills its primary action with the cover's colour, labelled in the page")
  func drainedPagePaintsTheCoverColour() {
    // Inside `CoverWash.drainedMarkLightness`, which is where a cover keeps its own colour.
    let covers = [Self.shadow, Self.dust] + Self.hues.map { Self.colour(hueDegrees: $0, lightness: 0.78) }
    for cover in covers {
      let canvas = Self.darkCanvas(cover)
      #expect(Self.isClose(canvas.primaryAction.fill, cover), "\(canvas.primaryAction.fill)")
      #expect(canvas.primaryAction.ink == canvas.backgroundRGB)
    }
  }

  @Test("a grey cover's dark page keeps the ink-filled primary action")
  func unhuedPagesKeepTheInkAction() {
    for cover in Self.unhued {
      let canvas = Self.darkCanvas(cover)
      #expect(canvas.primaryAction.fill == canvas.inkRGB, "\(String(describing: cover))")
      #expect(canvas.coverMark == nil)
    }
  }

  @Test("every cover-coloured action label clears AA on its drained page")
  func actionLabelsClearAA() {
    for hue in stride(from: 0.0, to: 360.0, by: 2.0) {
      for lightness in [0.3, 0.5, 0.7, 0.86, 0.95] {
        let vivid = OKLab.displayableChroma(
          lightness: lightness, hueRadians: hue * .pi / 180, upTo: 0.4)
        let canvas = Self.darkCanvas(
          Self.colour(hueDegrees: hue, lightness: lightness, chroma: vivid))
        #expect(canvas.primaryAction.fill != canvas.inkRGB, "hue \(hue), lightness \(lightness)")
        #expect(
          contrastRatio(canvas.primaryAction.fill, canvas.primaryAction.ink)
            >= CoverAmbientPalette.minimumAmbientInkContrast,
          "hue \(hue), lightness \(lightness)")
        #expect(canvas.metadataLadder == .standard, "hue \(hue), lightness \(lightness)")
      }
    }
  }

  // MARK: - The card

  @Test("a cover with no hue, and the card shown while one loads, take the drained neutral")
  func neutralCardsDrain() {
    #expect(CoverWash.from(hue: nil, saturation: nil, brightness: nil) == .drainedNeutral)
    #expect(CoverWash.from(hue: 0.1, saturation: 0.02, brightness: 0.5) == .drainedNeutral)
  }

  /// One cover, one colour: the mark a drained Home card carries is the colour its page's primary
  /// action takes.
  @Test("a drained card's mark is its page's action colour")
  func cardMarkIsThePageAction() {
    for cover in Self.hued {
      let action = Self.darkCanvas(cover).primaryAction.fill
      guard let mark = Self.wash(cover).darkAccent?.rgbColor else {
        Issue.record("\(cover) should carry a mark")
        continue
      }
      #expect(Self.isClose(mark, action), "\(cover): mark \(mark), action \(action)")
    }
  }
}
