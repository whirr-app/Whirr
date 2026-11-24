import ABSApi
import DesignSystem
import Foundation
import Testing
import UIKit

@testable import Whirr

/// Pins the true-colour cover extraction and the dark page's warm band.
@Suite struct CoverTrueColourPageTests {
  private static let hueSweep = stride(from: 0.0, to: 360.0, by: 15.0)

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

  private static func hueDegrees(_ page: CoverWashValue) -> Double {
    let degrees = page.oklabHueDegrees
    return degrees < 0 ? degrees + 360 : degrees
  }

  /// A flat PNG of one colour, the simplest cover whose true colour is known exactly.
  private static func flatCover(_ colour: WhirrRGBColor) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format)
      .pngData { context in
        UIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
      }
  }

  // MARK: - True colours

  @Test("k-means hands back a cover's true colour, not a lightened one")
  func extractionReturnsTheCoversColour() async throws {
    let yellow = WhirrRGBColor(0.95, 0.79, 0.37)
    let samples = try #require(
      await CoverPaletteExtractor.shared.samples(from: Self.flatCover(yellow)))
    let cluster = try #require(samples.dominant.max { $0.weight < $1.weight })
    #expect(abs(cluster.red - yellow.red) < 0.02)
    #expect(abs(cluster.green - yellow.green) < 0.02)
    #expect(abs(cluster.blue - yellow.blue) < 0.02)
  }

  @Test("the record identity carries the extraction stamp, so older rows re-derive")
  func recordIdentityIsStamped() {
    let identity = CoverPaletteWriter.recordIdentity(
      accountScope: ArtworkAccountScope("account"), itemID: "item", revision: .unversioned)
    #expect(identity.hasSuffix("|" + CoverPaletteWriter.extractionStamp))
  }

  // MARK: - The warm band

  private static func share(degrees: Double) -> Double {
    DarkWarmBand.share(hueRadians: degrees * .pi / 180)
  }

  /// The light page keeps the cover's hue, so it is the reference the dark pages turn from.
  @Test(
    "dark pages turn a warm hue towards copper by the band's share", arguments: [false, true])
  func darkPagesTurnWarmHues(_ increasedContrast: Bool) {
    for hue in Self.hueSweep {
      let evidence = Self.evidence(Self.colour(hueDegrees: hue))
      let light = CoverAmbientPalette.page(from: evidence, mode: .light)
      let page = CoverAmbientPalette.page(
        from: evidence, mode: .dark, increasedContrast: increasedContrast)
      let start = Self.hueDegrees(light)
      var turned = start - Self.hueDegrees(page)
      if turned > 180 { turned -= 360 }
      if turned < -180 { turned += 360 }
      #expect(
        abs(turned - DarkWarmBand.turnDegrees * Self.share(degrees: start))
          < 0.05, "hue \(hue)")
    }
  }

  @Test("the standard dark page keeps its drained lightness through the turn")
  func turnKeepsTheDarkLightness() {
    for hue in Self.hueSweep {
      let page = CoverAmbientPalette.page(
        from: Self.evidence(Self.colour(hueDegrees: hue)), mode: .dark)
      #expect(abs(page.oklabLightness - CoverWash.drainedPageLightness) < 1e-6)
    }
  }

  @Test("a neutral cover stays neutral on the dark page")
  func neutralCoverStaysNeutral() {
    let neutral = Self.evidence(Self.colour(hueDegrees: 82, chroma: 0.004))
    let page = CoverAmbientPalette.page(from: neutral, mode: .dark)
    #expect(page.oklabChroma < 0.01)
  }
}
