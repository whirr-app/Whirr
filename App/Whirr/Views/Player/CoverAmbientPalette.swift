import CoreImage
import CoreImage.CIFilterBuiltins
import DesignSystem
import SwiftUI
import UIKit

/// The extracted artwork accent, retained for card washes independently of page appearance.
struct CoverAccentHSB: Sendable, Equatable {
  let hue: Double
  let saturation: Double
  let brightness: Double
}

/// The two page treatments selected by the app's effective appearance.
enum AmbientAppearanceMode: Sendable, Equatable {
  /// A light page carrying black ink.
  case light
  /// A dark page carrying white ink.
  case dark

  var colorScheme: ColorScheme {
    switch self {
    case .light: .light
    case .dark: .dark
    }
  }

  /// The one ink every foreground on this page draws in, at whatever rung of the ladder it takes.
  var ink: WhirrRGBColor {
    switch self {
    case .light: WhirrRGBColor(0, 0, 0)
    case .dark: WhirrRGBColor(1, 1, 1)
    }
  }
}

/// The artwork evidence a page colour is derived from, kept so the warm path reproduces the cold
/// one. `cluster` (the dominant colour `selectAccent` chose) paints the page when present, as it
/// paints the card; `average` is used only for a cover with no cluster. Both are persisted.
struct CoverPageEvidence: Sendable, Equatable {
  let average: WhirrRGBColor
  /// The selected cluster's colour, or nil for a cover with no cluster clearing the chroma floor.
  let cluster: WhirrRGBColor?
  /// The selected cluster's share of the analysed cover, 0...1. Zero when there is no cluster.
  /// Persisted and carried, but not read by the page policy: see `pageSource(from:)`.
  let clusterWeight: Double
}

/// Everything a page needs after appearance resolution. The canvas carries concrete sRGB alongside
/// SwiftUI colors so contrast tests and the view render the exact same design decision.
///
/// There is no scrim and no gradient. The page is one flat colour; contrast is bought by where
/// that colour's lightness sits, not by anything composited on top of it.
struct AmbientCanvas: Equatable {
  let mode: AmbientAppearanceMode
  let background: Color
  let backgroundRGB: WhirrRGBColor
  /// The ink, resolved once. Every foreground on the page is this colour at some rung.
  let ink: Color
  let inkRGB: WhirrRGBColor
  /// Fills with the ink, labelled in the page colour; the ladder guarantees ink-vs-page contrast at
  /// its brightest rung, so a destination-out glyph is legible. A standard dark page with a hue
  /// fills it with the cover's own colour instead; see `darkActionFill(from:)`.
  let primaryAction: WhirrAccentPair
  /// Resolved with the canvas so the ticking timeline leaf never runs contrast maths.
  let timelineReadoutStyle: CoverAmbientPalette.TimelineReadoutStyle
  /// The metadata rungs for this page, solved against its own colour. `.standard` wherever the
  /// standard ladder holds (every drained dark page, light pages from 0.7455 up); below that a
  /// light page lifts its floor per page so every hue keeps AA.
  let metadataLadder: WhirrMetadataLadder

  /// The control tint. No control on an ambient page carries the artwork's colour, so this is the
  /// ink. Kept as a name because the surfaces that read it mark emphasis, not a hue.
  var accent: Color { ink }
}

/// The artwork evidence rendered in both app appearance modes.
struct AmbientAppearance: Equatable {
  let evidence: CoverPageEvidence
  let dark: AmbientCanvas
  let light: AmbientCanvas
  /// The same two poles under Increase Contrast. Precomputed with the rest rather than derived at
  /// read time: the trait can change while a page is on screen, and `ambientCanvas` is a computed
  /// property that SwiftUI re-evaluates on every body pass, so resolving a band edge lazily would
  /// put a chroma bisection on the path the playhead ticks down.
  let darkIncreasedContrast: AmbientCanvas
  let lightIncreasedContrast: AmbientCanvas

  /// App appearance selects the ink and brightness; Increase Contrast preserves that mode.
  func canvas(for effectiveAppColorScheme: ColorScheme, increasedContrast: Bool = false)
    -> AmbientCanvas
  {
    if effectiveAppColorScheme == .dark {
      return increasedContrast ? darkIncreasedContrast : dark
    }
    return increasedContrast ? lightIncreasedContrast : light
  }
}

struct CoverPalette: Equatable {
  /// The extracted accent in HSB, untouched by page policy. The card washes derive from this
  /// through `CoverWash`, so nothing above affects them.
  var rawAccentHSB: CoverAccentHSB?
  var ambientAppearance: AmbientAppearance
}

/// The root window follows the app preference, with the reader's independent theme taking priority.
enum CoverAmbientPresentation {
  static func windowColorScheme(
    appPreference: ColorScheme?, presentedReaderTheme: DesignSystem.ReaderTheme? = nil
  ) -> ColorScheme? {
    if let presentedReaderTheme {
      return ReaderPresentation.windowScheme(for: presentedReaderTheme)
    }
    return appPreference
  }
}

nonisolated struct CoverRGBA: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
  /// Share of the analysed cover this cluster covers, 0...1. A k-means centroid's alpha is its
  /// cluster weight rather than an opacity; the averaged colour has no cluster and takes 1.
  let weight: Double

  init(red: Double, green: Double, blue: Double, weight: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.weight = weight
  }

  var uiColor: UIColor {
    UIColor(red: red, green: green, blue: blue, alpha: 1)
  }
}

struct CoverPaletteSamples: Sendable {
  let average: CoverRGBA
  let dominant: [CoverRGBA]
}

/// Owns the expensive decode and Core Image rendering on its own executor. The analysis image is
/// bounded to 64 pixels on its longest edge; six k-means centers are read with one 6×1 render.
actor CoverPaletteExtractor {
  static let shared = CoverPaletteExtractor()
  private static let maximumDimension: CGFloat = 64
  private let context = CIContext(options: [.workingColorSpace: NSNull()])

  func samples(from data: Data) -> CoverPaletteSamples? {
    guard let inputImage = CIImage(data: data) else { return nil }
    let inputExtent = inputImage.extent
    guard inputExtent.isEmpty == false, inputExtent.isInfinite == false else { return nil }

    let targetSize = Self.samplingExtent(for: inputExtent)
    let scale = min(targetSize.width / inputExtent.width, targetSize.height / inputExtent.height)
    let image = scale < 1 ? Self.downsampled(inputImage, scale: scale) : inputImage
    let analysed = maskingAudibleSash(of: image)
    let extent = analysed.extent

    guard let average = averagedColor(of: analysed, extent: extent) else { return nil }
    return CoverPaletteSamples(
      average: average,
      dominant: dominantColors(of: analysed, extent: extent))
  }

  /// The cover reduced to the analysis size with a filtered resample, so every source pixel
  /// contributes. An affine transform on iOS point-samples: from a large cover each analysis pixel
  /// is one source pixel, so thin detail such as the sash's lettering lands or misses by phase and
  /// the same artwork picks a different colour at each fetched width. Clamped first so the
  /// filter's edge taps read the border rather than transparency.
  private static func downsampled(_ image: CIImage, scale: CGFloat) -> CIImage {
    let filter = CIFilter.lanczosScaleTransform()
    filter.inputImage = image.clampedToExtent()
    filter.scale = Float(scale)
    filter.aspectRatio = 1
    let extent = image.extent
    let target = CGRect(
      x: extent.minX * scale, y: extent.minY * scale,
      width: extent.width * scale, height: extent.height * scale)
    return (filter.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
      .cropped(to: target)
  }

  /// The image with `AudibleSash`'s corner blanked if it carries the sash, and itself otherwise.
  private func maskingAudibleSash(of image: CIImage) -> CIImage {
    let width = Int(image.extent.width.rounded())
    let height = Int(image.extent.height.rounded())
    guard width > 0, height > 0 else { return image }
    let bounds = CGRect(
      x: image.extent.minX, y: image.extent.minY, width: CGFloat(width), height: CGFloat(height))
    let bitmap = render(image, bounds: bounds, height: height)
    guard AudibleSash.isPresent(inRGBAf: bitmap, width: width, height: height) else { return image }
    let masked = AudibleSash.masked(bitmap, width: width, height: height)
    return CIImage(
      bitmapData: masked.withUnsafeBytes { Data($0) },
      bytesPerRow: width * MemoryLayout<Float>.size * 4,
      size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
  }

  nonisolated static func samplingExtent(
    for extent: CGRect, maximumDimension: CGFloat = maximumDimension
  ) -> CGSize {
    let longestEdge = max(extent.width, extent.height)
    guard longestEdge > maximumDimension else { return extent.size }
    let scale = maximumDimension / longestEdge
    return CGSize(width: extent.width * scale, height: extent.height * scale)
  }

  nonisolated static func rgbaColors(fromRGBAf bitmap: [Float]) -> [CoverRGBA] {
    stride(from: 0, to: bitmap.count - (bitmap.count % 4), by: 4).map { offset in
      CoverRGBA(
        red: Double(min(max(bitmap[offset], 0), 1)),
        green: Double(min(max(bitmap[offset + 1], 0), 1)),
        blue: Double(min(max(bitmap[offset + 2], 0), 1)),
        weight: Double(min(max(bitmap[offset + 3], 0), 1)))
    }
  }

  private func averagedColor(of image: CIImage, extent: CGRect) -> CoverRGBA? {
    let filter = CIFilter.areaAverage()
    filter.inputImage = image
    filter.extent = extent
    guard let output = filter.outputImage else { return nil }
    return Self.rgbaColors(fromRGBAf: render(output, bounds: output.extent)).first
  }

  private func dominantColors(of image: CIImage, extent: CGRect) -> [CoverRGBA] {
    let filter = CIFilter.kMeans()
    filter.inputImage = image
    filter.extent = extent
    filter.count = 6
    filter.passes = 6
    // Off: in this context's null working space `perceptual` encodes the pixels a second time and
    // never decodes the centroids, so clusters come out lighter and greyer than the cover, light
    // ones merge and dark ones fall under the chroma floor. Off, it clusters on the sRGB-encoded
    // values it is given (already close to perceptual) and returns true colours.
    filter.perceptual = false
    guard let output = filter.outputImage else { return [] }
    return Self.rgbaColors(fromRGBAf: render(output, bounds: output.extent))
  }

  /// Float, not `RGBA8`, because a k-means centroid's alpha carries its cluster weight rather
  /// than an opacity, and its colour components routinely exceed it. An 8-bit premultiplied render
  /// clamps every component to that weight, so a small vivid cluster would come back as flat grey
  /// and `selectAccent` would have nothing to pick.
  /// `height` rows, written top row first.
  private func render(_ image: CIImage, bounds: CGRect, height: Int = 1) -> [Float] {
    let width = max(1, Int(bounds.width.rounded(.up)))
    var bitmap = [Float](repeating: 0, count: width * height * 4)
    bitmap.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      context.render(
        image, toBitmap: base, rowBytes: width * MemoryLayout<Float>.size * 4, bounds: bounds,
        format: .RGBAf, colorSpace: nil)
    }
    return bitmap
  }
}

/// Dresses a page in its artwork's own colour, as the system media players do. A live-blurred
/// full-screen cover is avoided because its re-render eats the controls' frame budget.
///
/// Colour comes from the cover's weighted dominant cluster, not its area average (an average over a
/// photograph is grey-brown), then is set on the card's terms: fixed lightness in dark, clamped in
/// light, the cover's hue and a set chroma request. No black scrim: it buys contrast by destroying
/// the colour.
enum CoverAmbientPalette {
  /// Used for an entire presentation when no palette is available at entry.
  ///
  /// Built through the same policy as a real page.
  static func fallbackCanvas(
    for scheme: ColorScheme, increasedContrast: Bool = false
  ) -> AmbientCanvas {
    if scheme == .light {
      return increasedContrast ? fallbackLightIncreasedContrast : fallbackLight
    }
    return increasedContrast ? fallbackDarkIncreasedContrast : fallbackDark
  }

  private static let fallbackLight: AmbientCanvas = fallbackCanvas(
    neutral: WhirrRGBColor(0.82, 0.83, 0.85), mode: .light)
  private static let fallbackDark: AmbientCanvas = fallbackCanvas(
    neutral: WhirrRGBColor(0.07, 0.08, 0.10), mode: .dark)
  private static let fallbackLightIncreasedContrast: AmbientCanvas = fallbackCanvas(
    neutral: WhirrRGBColor(0.82, 0.83, 0.85), mode: .light, increasedContrast: true)
  private static let fallbackDarkIncreasedContrast: AmbientCanvas = fallbackCanvas(
    neutral: WhirrRGBColor(0.07, 0.08, 0.10), mode: .dark, increasedContrast: true)

  /// Built as a cover with no cluster: a near-black neutral has a high HSB saturation, and read as
  /// a cluster it would be boosted into a blue page.
  private static func fallbackCanvas(
    neutral: WhirrRGBColor, mode: AmbientAppearanceMode, increasedContrast: Bool = false
  ) -> AmbientCanvas {
    let evidence = CoverPageEvidence(average: neutral, cluster: nil, clusterWeight: 0)
    return canvas(
      page: page(from: evidence, mode: mode, increasedContrast: increasedContrast), mode: mode)
  }

  /// Both app appearances derived from the same artwork evidence.
  static func palette(from samples: CoverPaletteSamples) -> CoverPalette {
    let selected = selectAccent(from: samples.dominant)
    let evidence = CoverPageEvidence(
      average: WhirrRGBColor(samples.average.red, samples.average.green, samples.average.blue),
      cluster: selected.map { WhirrRGBColor($0.red, $0.green, $0.blue) },
      clusterWeight: selected?.weight ?? 0)
    return palette(
      evidence: evidence,
      rawAccentHSB: selected.map {
        let hsb = $0.uiColor.hsba
        return CoverAccentHSB(
          hue: Double(hsb.hue), saturation: Double(hsb.saturation),
          brightness: Double(hsb.brightness))
      })
  }

  /// Rebuilds the palette from persisted evidence, for a surface reading another surface's result.
  /// Matches `palette(from:)` so the detail screen and Home card agree; it needs the area average
  /// as well as the accent because a cover with no cluster paints its page from the average.
  static func palette(fromEvidence evidence: CoverPageEvidence, accent: CoverAccentHSB?)
    -> CoverPalette
  {
    palette(evidence: evidence, rawAccentHSB: accent)
  }

  private static func palette(evidence: CoverPageEvidence, rawAccentHSB: CoverAccentHSB?)
    -> CoverPalette
  {
    CoverPalette(
      rawAccentHSB: rawAccentHSB,
      ambientAppearance: AmbientAppearance(
        evidence: evidence,
        dark: canvas(
          page: page(from: evidence, mode: .dark), mode: .dark,
          actionFill: darkActionFill(from: evidence)),
        light: canvas(page: page(from: evidence, mode: .light), mode: .light),
        darkIncreasedContrast: canvas(
          page: page(from: evidence, mode: .dark, increasedContrast: true), mode: .dark),
        lightIncreasedContrast: canvas(
          page: page(from: evidence, mode: .light, increasedContrast: true), mode: .light)))
  }

  // MARK: - The page colour

  /// The page colour: the selected cluster, or the area average when there is none. No weight
  /// floor, or the page would differ from its own card (usually as the average's grey-brown);
  /// `CoverAccentSelection` already discounts small clusters by the square root of their area.
  static func pageSource(from evidence: CoverPageEvidence) -> WhirrRGBColor {
    evidence.cluster ?? evidence.average
  }

  /// Normalises a cover's evidence into a page on its card's terms: drained in dark; in light a
  /// clamped lightness, a set chroma request and the card's hue.
  ///
  /// The hue angle comes from the saturated form of the source's hue, because a dim or washed-out
  /// colour's OKLab hue is unstable (black resolves to `atan2(0, 0)`) and drifts up to 25 degrees
  /// near that corner. `CoverWash.from` does the same.
  ///
  /// Light chroma is requested at `pageChromaRequest` and reduced only where sRGB cannot hold it at
  /// that lightness, so muted and vivid covers carry the same weight of colour. A source with no
  /// hue by the card's test (no cluster, or under `minimumPageHueSaturation`) keeps its own chroma.
  /// Lightness is clamped rather than veiled: both buy contrast, only a veil destroys the colour.
  ///
  /// Every dark page drains, as its card does (`CoverWash.drainsDark`): at dark lightness sRGB
  /// shows orange-to-olive hues only as rust, brown or olive, at the gamut's chroma ceiling. The
  /// page goes almost black with a trace of hue, and the cover's colour moves to the primary action
  /// and progress fill. Warm yellows turn towards copper (`DarkWarmBand`). The Increase Contrast
  /// dark page drains darkest and keeps an ink primary action.
  static func page(
    from evidence: CoverPageEvidence, mode: AmbientAppearanceMode, increasedContrast: Bool = false
  ) -> CoverWashValue {
    let source = pageSource(from: evidence)
    let hsb = UIColor(red: source.red, green: source.green, blue: source.blue, alpha: 1).hsba
    let hueBasis = CoverWashValue(hue: Double(hsb.hue), saturation: 1, brightness: 1)
      .oklab.hueRadians
    let sourceLab = OKLab(red: source.red, green: source.green, blue: source.blue)
    let hasHue = evidence.cluster != nil && Double(hsb.saturation) >= minimumPageHueSaturation
    // A page with no hue keeps its own, unturned.
    if mode == .dark {
      return CoverWash.drainedPage(
        coverChroma: sourceLab.chroma,
        hueRadians: hasHue ? DarkWarmBand.turned(hueRadians: hueBasis) : hueBasis)
    }
    let band = lightPageLightnessBand
    let lightness =
      increasedContrast
      ? lightPageIncreasedContrastLightness
      : min(max(sourceLab.lightness, band.lowerBound), band.upperBound)
    let chroma = hasHue ? pageChromaRequest : sourceLab.chroma
    return CoverWashValue(
      oklabLightness: lightness,
      chroma: OKLab.displayableChroma(lightness: lightness, hueRadians: hueBasis, upTo: chroma),
      hueRadians: hueBasis)
  }

  /// A single colour treated as a cover whose cluster it is.
  static func page(
    from source: WhirrRGBColor, mode: AmbientAppearanceMode, increasedContrast: Bool = false
  ) -> CoverWashValue {
    page(
      from: CoverPageEvidence(average: source, cluster: source, clusterWeight: 1), mode: mode,
      increasedContrast: increasedContrast)
  }

  /// Assembles a canvas around a resolved page and its pole. Everything below the page colour is a
  /// pure function of it, so the cold and warm paths agree. The exception is `actionFill`, which
  /// `darkActionFill(from:)` derives from the same evidence on both paths.
  static func canvas(
    page: CoverWashValue, mode: AmbientAppearanceMode, actionFill: WhirrRGBColor? = nil
  ) -> AmbientCanvas {
    let backgroundRGB = page.rgbColor
    let ink = mode.ink
    return AmbientCanvas(
      mode: mode,
      background: page.color,
      backgroundRGB: backgroundRGB,
      ink: ink.color,
      inkRGB: ink,
      primaryAction: WhirrAccentPair(fill: actionFill ?? ink, ink: backgroundRGB),
      timelineReadoutStyle: timelineReadoutStyle(for: backgroundRGB, ink: ink),
      metadataLadder: metadataLadder(for: backgroundRGB, ink: ink))
  }

  /// The standard ladder, lifted just far enough that its dimmest rung clears
  /// `minimumAmbientInkContrast` on this page (the same search as `timelineReadoutOpacity`). A page
  /// the standard ladder can carry gets `.standard` back untouched.
  static func metadataLadder(for background: WhirrRGBColor, ink: WhirrRGBColor)
    -> WhirrMetadataLadder
  {
    .liftingFloor(
      to: timelineReadoutOpacity(
        for: background, ink: ink, baseOpacity: WhirrMetadataProminence.floor))
  }

  // MARK: - Pure selection & clamping

  /// Scores a cover cluster using the shared perceptual accent-selection policy.
  static func accentScore(_ color: CoverRGBA) -> Double {
    CoverAccentSelection.score(
      CoverAccentCandidate(
        red: color.red, green: color.green, blue: color.blue, weight: color.weight))
  }

  /// The strongest coloured cluster, or `nil` when none clears the shared chroma floor.
  static func selectAccent(from candidates: [CoverRGBA]) -> CoverRGBA? {
    CoverAccentSelection.select(
      from: candidates.map {
        CoverAccentCandidate(red: $0.red, green: $0.green, blue: $0.blue, weight: $0.weight)
      }
    )
    .map { CoverRGBA(red: $0.red, green: $0.green, blue: $0.blue, weight: $0.weight) }
  }

  /// The band a light page's lightness is clamped into; a dark page drains below it
  /// (`CoverWash.drainedPageLightness`). A cover inside the band keeps its own lightness.
  ///
  /// Each edge is the worst case over the hue circle (swept at 1 degree at the maximum chroma the
  /// band admits), because contrast depends on the composited sRGB channels, not OKLab lightness:
  /// at 0.60 and maximum chroma the floor rung measures 3.30:1 on red and 3.60:1 on green.
  ///
  /// The lower edge sits below the standard ladder's 0.7455 AA limit, because a band starting there
  /// turns every cover darker than pale paper into the same pastel. Below 0.7455 the page lifts its
  /// own ladder floor (`ADR 0007`, `metadataLadder(for:ink:)`). At 0.65 opaque black still clears
  /// 5.51:1 at the worst hue and the worst lift is 0.769 against the standard 0.64; below 0.60 no
  /// alpha clears either ink.
  ///
  /// The upper edge is a glare control: a full-bleed page at 0.92 is a lamp. Emitted light tracks
  /// lightness almost alone (relative luminance spans 0.38-0.46 across hues at 0.75, 0.76-0.82 at
  /// 0.92), and capping chroma moves it by under 0.01, upward.
  static let lightPageLightnessBand: ClosedRange<Double> = 0.65...0.78

  /// Where Increase Contrast sends a light page: as far from the ink as the pole allows, keeping
  /// the artwork's colour, since on a full page lightness is nearly the whole of contrast. Not
  /// `lightPageLightnessBand.upperBound`: that glare ceiling would cost these readers 1.3 ratio
  /// points (4.54:1 at 0.75 against 6.09:1 at 0.92, at the standard floor rung).
  static let lightPageIncreasedContrastLightness = 0.92

  /// The chroma a light page with a hue asks for: between the light page wash (about 0.06) and
  /// what vivid covers brought when the page kept the cover's own chroma.
  static let pageChromaRequest = 0.10

  /// `CoverWash.from`'s floor: below this HSB saturation the card is neutral, so the page is not
  /// boosted either.
  nonisolated static let minimumPageHueSaturation = 0.05

  /// The timeline's readouts clear the same bar as every other label on an ambient page: they are
  /// `caption`/`caption2` at 11-12pt, which is normal text by WCAG's reckoning and never qualified
  /// for the large-text allowance a 3:1 floor would imply.
  static let minimumTimelineReadoutContrast = minimumAmbientInkContrast
  /// WCAG AA for normal text, the floor the ambient ink ladder's dimmest rung must clear. The line
  /// that forced it is the item-detail hero's duration readout, 12pt, below WCAG's 18pt large-text
  /// threshold.
  static let minimumAmbientInkContrast = 4.5
  private static let regularTimelineReadoutOpacity = 0.64
  private static let scrubbingTimelineReadoutOpacity = 0.95
  private static let centeredTimelineReadoutOpacity = 0.5

  /// The already-resolved readout opacities carried with a palette, so the ticking timeline leaf
  /// only chooses between stored values and never resolves a `Color` or runs contrast math.
  struct TimelineReadoutStyle: Equatable, Sendable {
    /// The page's ink. Carried here rather than resolved by the leaf so the ticking readout never
    /// touches the palette, and a light page's readouts are not white.
    let ink: Color
    let regularOpacity: Double
    let scrubbingOpacity: Double
    let centeredOpacity: Double
  }

  /// The least opacity at which `ink` clears the timeline contrast floor over `background`, or
  /// `baseOpacity` unchanged when it already does. Alpha composites in `WhirrRGBColor`'s sRGB
  /// space; a binary search avoids a coarse jump at the boundary. `ink` is a parameter because a
  /// light page needs dark readouts.
  static func timelineReadoutOpacity(
    for background: WhirrRGBColor, ink: WhirrRGBColor, baseOpacity: Double
  ) -> Double {
    let baseOpacity = min(max(baseOpacity, 0), 1)
    guard
      contrastRatio(inkOverlay(baseOpacity, of: ink, over: background), background)
        < minimumTimelineReadoutContrast
    else {
      return baseOpacity
    }

    var lower = baseOpacity
    var upper = 1.0
    guard
      contrastRatio(inkOverlay(upper, of: ink, over: background), background)
        >= minimumTimelineReadoutContrast
    else {
      return upper
    }

    for _ in 0..<32 {
      let midpoint = (lower + upper) / 2
      if contrastRatio(inkOverlay(midpoint, of: ink, over: background), background)
        >= minimumTimelineReadoutContrast
      {
        upper = midpoint
      } else {
        lower = midpoint
      }
    }
    return upper
  }

  /// Resolves the elapsed/remaining opacity while retaining the brighter scrubbing state.
  static func timelineReadoutOpacity(
    for background: WhirrRGBColor, ink: WhirrRGBColor, isScrubbing: Bool
  ) -> Double {
    timelineReadoutOpacity(
      for: background, ink: ink,
      baseOpacity: isScrubbing
        ? scrubbingTimelineReadoutOpacity : regularTimelineReadoutOpacity)
  }

  /// Resolves all three timeline readout roles once when the ambient palette changes. The view on
  /// the per-tick path receives this value rather than doing any color conversion or contrast work.
  static func timelineReadoutStyle(for background: WhirrRGBColor, ink: WhirrRGBColor)
    -> TimelineReadoutStyle
  {
    TimelineReadoutStyle(
      ink: ink.color,
      regularOpacity: timelineReadoutOpacity(for: background, ink: ink, isScrubbing: false),
      scrubbingOpacity: timelineReadoutOpacity(for: background, ink: ink, isScrubbing: true),
      centeredOpacity: timelineReadoutOpacity(
        for: background, ink: ink, baseOpacity: centeredTimelineReadoutOpacity))
  }

  private static func inkOverlay(
    _ opacity: Double, of ink: WhirrRGBColor, over background: WhirrRGBColor
  ) -> WhirrRGBColor {
    WhirrRGBColor(
      opacity * ink.red + (1 - opacity) * background.red,
      opacity * ink.green + (1 - opacity) * background.green,
      opacity * ink.blue + (1 - opacity) * background.blue)
  }
}

extension UIColor {
  /// Decomposed HSB(A), so the pure selection/clamping above reads as plain arithmetic.
  fileprivate var hsba: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    return (hue, saturation, brightness, alpha)
  }
}
