import ABSApi
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// Pure accent selection and legibility clamping for the player theme. These decide whether a
/// control tint reads on the dark player surface. CoreImage extraction needs a real bitmap, so it
/// is exercised on device.
struct CoverAmbientPaletteTests {
  /// The dark surface player sheets and the ambient page settle toward. The accent must stay
  /// legible on it.
  private static let darkSurface = WhirrRGBColor(0.055, 0.06, 0.075)

  /// The cover badge draws its ring and progress arc on the accent disc, so the disc is the
  /// surface those marks answer to (SC 1.4.11). White on the neutral fallback was 1.15:1, so the
  /// mark was effectively invisible. Sweep the accents the extractor yields, since the failure
  /// depends on the accent.
  @Test(
    "Cover progress marks clear the resolved accent disc",
    arguments: [
      WhirrColorToken.neutralCoverAccent,
      WhirrRGBColor(0.98, 0.95, 0.88),
      WhirrRGBColor(0.55, 0.09, 0.13),
      WhirrRGBColor(0.20, 0.42, 0.65),
      WhirrRGBColor(0.85, 0.86, 0.24),
    ])
  func coverProgressMarksClearAccentDisc(_ accent: WhirrRGBColor) {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(coverBadgeMarkColor(for: accent.color))
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let mark = WhirrRGBColor(Double(red), Double(green), Double(blue))

    #expect(
      contrastRatio(mark, accent) >= 3,
      Comment(rawValue: String(format: "mark reads %.2f:1 on the disc", contrastRatio(mark, accent)))
    )
  }

  @Test("Palette analysis downsamples large covers to a bounded working image")
  func boundedAnalysisExtent() {
    #expect(
      CoverPaletteExtractor.samplingExtent(for: CGRect(x: 0, y: 0, width: 1_140, height: 760))
        == CGSize(width: 64, height: 42.666666666666664))
    #expect(
      CoverPaletteExtractor.samplingExtent(for: CGRect(x: 0, y: 0, width: 32, height: 48))
        == CGSize(width: 32, height: 48))
  }

  @Test("All dominant clusters are decoded from one contiguous RGBA render")
  func decodesDominantColorBuffer() {
    // `[Float]` renders narrow `CoverRGBA` channels, so a `Double` recomputation of a value that is
    // not exact in 32 bits never equals it. Narrow once and compare against that.
    let midGreen = Float(128.0 / 255.0)
    // Weights are narrowed the same way, so they are compared the same way.
    let lightCluster = Float(0.1)
    let heavyCluster = Float(0.7)
    let colors = CoverPaletteExtractor.rgbaColors(
      fromRGBAf: [1, 0, 0, lightCluster, 0, midGreen, 1, heavyCluster])
    #expect(colors.count == 2)
    #expect(colors[0] == CoverRGBA(red: 1, green: 0, blue: 0, weight: Double(lightCluster)))
    #expect(
      colors[1] == CoverRGBA(red: 0, green: Double(midGreen), blue: 1, weight: Double(heavyCluster)))
  }

  /// A k-means centroid's alpha is its cluster weight, not an opacity, and its colour components
  /// can exceed it. Read through a premultiplied 8-bit format, the weight clamped the colour to
  /// grey, so the cover's one strong hue was lost. The weight must not tint the centroid.
  @Test("A low-weight cluster keeps its colour rather than clamping to its weight")
  func decodesLowWeightClusterUnclamped() {
    let clusterShare = Float(0.15)
    let colors = CoverPaletteExtractor.rgbaColors(
      fromRGBAf: [0.86, 0.49, 0.89, clusterShare])
    #expect(colors.count == 1)
    #expect(colors[0].red > 0.8)
    #expect(colors[0].blue > 0.8)
    #expect(colors[0].green < 0.6)
    #expect(colors[0].weight == Double(clusterShare))
  }

  /// The `areaAverage` pixel is opaque with no cluster behind it, so it must not be scored as if
  /// it covered the whole artwork.
  @Test("An averaged colour keeps the unit cluster weight")
  func averagedColorKeepsUnitWeight() {
    let colors = CoverPaletteExtractor.rgbaColors(fromRGBAf: [0.2, 0.3, 0.4, 1])
    #expect(colors.count == 1)
    #expect(colors[0].weight == 1)
  }

  /// End to end from real cover bytes. A mostly black cover with one magenta band produced a
  /// neutral fallback tint on the item-detail resume button instead of the artwork's own colour.
  @Test("A vivid band on a dark cover paints the page, not a neutral fallback")
  func vividCoverYieldsAnArtworkPage() async throws {
    let data = try #require(Self.coverData(band: UIColor(red: 0.85, green: 0.10, blue: 0.75, alpha: 1)))
    let samples = try #require(await CoverPaletteExtractor.shared.samples(from: data))
    let palette = CoverAmbientPalette.palette(from: samples)
    let page = palette.ambientAppearance.light.backgroundRGB
    let pageLab = OKLab(red: page.red, green: page.green, blue: page.blue)
    let source = CoverAmbientPalette.pageSource(from: palette.ambientAppearance.evidence)
    let sourceLab = OKLab(red: source.red, green: source.green, blue: source.blue)

    // The page is the cover's own hue, not a neutral. Magenta sits near 344 degrees.
    let hueDegrees = (pageLab.hueRadians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    #expect(abs(hueDegrees - 344) < 15)
    // Carried at the artwork's own chroma, which is what the clamp preserves.
    #expect(pageLab.chroma >= min(sourceLab.chroma, 0.06))
  }

  /// A dark cover with one saturated band, rendered to JPEG so the extractor decodes real bytes.
  private static func coverData(band: UIColor) -> Data? {
    let side: CGFloat = 512
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
    let image = renderer.image { context in
      UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
      UIColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: side, height: side * 0.2))
      band.setFill()
      context.fill(CGRect(x: 0, y: side * 0.4, width: side, height: side * 0.25))
    }
    return image.jpegData(compressionQuality: 0.9)
  }

  @Test("Perceptual scoring ranks a saturated mid-bright color above gray and near-black")
  func accentScoreRanking() {
    let vivid = CoverRGBA(red: 0.7, green: 0.35, blue: 0.05)
    let gray = CoverRGBA(red: 0.5, green: 0.5, blue: 0.5)
    let nearBlack = CoverRGBA(red: 0.05, green: 0.01, blue: 0.04)

    #expect(CoverAmbientPalette.accentScore(vivid) > CoverAmbientPalette.accentScore(gray))
    #expect(CoverAmbientPalette.accentScore(vivid) > CoverAmbientPalette.accentScore(nearBlack))
  }

  @Test("Accent selection picks the strongest candidate")
  func selectsMostVibrant() {
    let orange = CoverRGBA(red: 0.7, green: 0.35, blue: 0.05)
    let candidates = [
      CoverRGBA(red: 0.2, green: 0.2, blue: 0.2),
      CoverRGBA(red: 0.8, green: 0.8, blue: 0.8),
      orange,
      CoverRGBA(red: 0.6, green: 0.52, blue: 0.48),
    ]
    let picked = CoverAmbientPalette.selectAccent(from: candidates)
    #expect(picked == orange)
  }

  @Test("A tiny vivid speck loses to a large moderate field")
  func largeModerateFieldBeatsTinyVividSpeck() {
    let speck = CoverRGBA(red: 0.95, green: 0.05, blue: 0.85, weight: 0.016)
    let field = CoverRGBA(red: 0.1, green: 0.55, blue: 0.5, weight: 0.38)

    #expect(CoverAmbientPalette.selectAccent(from: [speck, field]) == field)
  }

  @Test("A grayscale palette uses the neutral fallback accent")
  func grayscaleHasNoAccent() {
    let grays = [
      CoverRGBA(red: 0.1, green: 0.1, blue: 0.1),
      CoverRGBA(red: 0.4, green: 0.4, blue: 0.4),
      CoverRGBA(red: 0.9, green: 0.9, blue: 0.9),
    ]
    #expect(CoverAmbientPalette.selectAccent(from: grays) == nil)

    let palette = CoverAmbientPalette.palette(
      from: CoverPaletteSamples(average: grays[1], dominant: grays))
    #expect(palette.rawAccentHSB == nil)
    // No cluster clears the chroma floor, so the page comes from the average and stays neutral.
    let page = palette.ambientAppearance.dark.backgroundRGB
    #expect(OKLab(red: page.red, green: page.green, blue: page.blue).chroma < 0.01)
  }

  /// The readouts are `caption`/`caption2`, 11-12 pt normal text under WCAG, so they must clear
  /// 4.5:1 like every other label on an ambient page, not the large-text 3:1.
  @Test("The timeline readout floor is the ambient ink floor")
  func timelineReadoutFloorMatchesTheAmbientInkFloor() {
    #expect(
      CoverAmbientPalette.minimumTimelineReadoutContrast
        == CoverAmbientPalette.minimumAmbientInkContrast)
  }

  /// The standard dark page drains to `CoverWash.drainedPageLightness`. Increase Contrast's sits
  /// at the band's outer edge. On both, all three readouts keep their base.
  @Test("Timeline readouts keep their base opacity on a dark ambient page where they clear")
  func timelineReadoutLeavesDarkPageUnchanged() {
    let ink = AmbientAppearanceMode.dark.ink
    for increasedContrast in [false, true] {
      let background = CoverAmbientPalette.page(
        from: WhirrRGBColor(0, 0, 0), mode: .dark, increasedContrast: increasedContrast
      ).rgbColor

      #expect(
        CoverAmbientPalette.timelineReadoutOpacity(for: background, ink: ink, isScrubbing: false)
          == 0.64)
      #expect(
        CoverAmbientPalette.timelineReadoutOpacity(for: background, ink: ink, isScrubbing: true)
          == 0.95)

      let centred = CoverAmbientPalette.timelineReadoutOpacity(
        for: background, ink: ink, baseOpacity: 0.5)
      #expect(centred == 0.5)
    }
  }

  /// Scrubbing brightens the readout, and the contrast floor must not erase that. If the floor
  /// drove the regular state up to meet the scrubbing one, the gesture would stop reading as a
  /// state change. The lightness clamp makes this hold: on the brightest page either pole admits,
  /// both keep their base values.
  @Test("Timeline readouts preserve the scrubbing distinction at both poles")
  func timelineReadoutPreservesScrubbingOpacityDistinction() throws {
    for mode in [AmbientAppearanceMode.light, .dark] {
      let page = CoverAmbientPalette.page(from: WhirrRGBColor(1, 1, 1), mode: mode).rgbColor
      let ink = mode.ink
      let regularOpacity = CoverAmbientPalette.timelineReadoutOpacity(
        for: page, ink: ink, isScrubbing: false)
      let scrubbingOpacity = CoverAmbientPalette.timelineReadoutOpacity(
        for: page, ink: ink, isScrubbing: true)

      #expect(scrubbingOpacity == 0.95)
      #expect(regularOpacity == 0.64)
      #expect(scrubbingOpacity > regularOpacity)
    }
  }
}

extension Color {
  /// Test-only bridge from a resolved `Color` to the `WhirrRGBColor` the contrast math consumes.
  fileprivate var absRGB: WhirrRGBColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return WhirrRGBColor(Double(red), Double(green), Double(blue))
  }
}
