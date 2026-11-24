import CoreGraphics
import Foundation
import SwiftUI

/// A soft halo in the cover's own colour behind a drained card's artwork.
///
/// A drained card is near-black, so without a progress bar only its badge carries the cover's
/// colour; the halo gives some back. It takes the drained mark's colour and follows the marks'
/// rules (dark appearance, a drained wash with a hue, not under Increase Contrast), else draws
/// nothing.
///
/// Not `.shadow` or `.blur`: each is an offscreen Gaussian pass per visible card, every frame a
/// shelf scrolls. The separable Gaussian of `sigma` is built once per artwork shape as the outer
/// product of two 1-D profiles, drawn white and tinted here: one textured quad per card.
///
/// Laid out in the cover's frame at the fitted artwork's shape and `alignment`, so the caller must
/// supply the aspect ratio. Draws outside its bounds; whatever clips it decides where it stops.
public struct CoverGlow: View {
  /// The halo's opacity at full strength, behind the artwork.
  nonisolated static let opacity = 0.45
  /// The Gaussian's standard deviation, in points, for an artwork whose long side is
  /// `referenceLongSide`. It scales with the artwork.
  nonisolated static let sigma: CGFloat = 26
  /// The glowing block's size over the artwork's.
  nonisolated static let spread: CGFloat = 1.04
  /// How far the halo sits below the artwork, in points.
  nonisolated static let drop: CGFloat = 5
  nonisolated static let referenceLongSide: CGFloat = 144

  let aspectRatio: CGFloat?
  let alignment: Alignment

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.drainedCoverWash) private var drainedCoverWash

  /// `aspectRatio` is the artwork's width over its height; `nil` fills the frame, for a cover drawn
  /// to fill it.
  public init(aspectRatio: CGFloat?, alignment: Alignment = .center) {
    self.aspectRatio = aspectRatio
    self.alignment = alignment
  }

  public var body: some View {
    if let tint = Self.tint(
      colorScheme: colorScheme, wash: drainedCoverWash,
      increasedContrast: colorSchemeContrast == .increased)
    {
      halo(tint: tint)
    }
  }

  @ViewBuilder
  private func halo(tint: CoverWashValue) -> some View {
    let shape = ArtworkShape(aspectRatio: aspectRatio ?? 1)
    if let image = Images.shared.image(for: shape) {
      Color.clear
        .aspectRatio(aspectRatio, contentMode: .fit)
        .overlay {
          Image(decorative: image, scale: Images.pixelsPerPoint)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(tint.color.opacity(Self.opacity))
            // The image is the artwork's shape with a margin all round; stretched to the artwork's
            // frame and scaled back out about its centre, the margin lands outside the artwork.
            .scaleEffect(
              x: shape.canvas.width / shape.artwork.width,
              y: shape.canvas.height / shape.artwork.height
            )
            .offset(y: Self.drop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  /// The halo's colour, or `nil` where it draws nothing; see `WashInk.drainedMark`.
  nonisolated static func tint(colorScheme: ColorScheme, wash: CoverWash?, increasedContrast: Bool)
    -> CoverWashValue?
  {
    WashInk.drainedMark(colorScheme: colorScheme, wash: wash, increasedContrast: increasedContrast)
  }

  /// The share of a Gaussian of `sigma` over `span` that reaches `x`.
  nonisolated static func profile(_ x: Double, across span: ClosedRange<Double>) -> Double {
    let scale = Double(sigma) * 2.0.squareRoot()
    return 0.5 * (erf((x - span.lowerBound) / scale) - erf((x - span.upperBound) / scale))
  }

  /// An artwork shape the halo is built for, in points at `referenceLongSide`. Aspect ratios are
  /// bucketed, so covers of near enough the same shape share one image.
  struct ArtworkShape: Hashable {
    static let bucket = 0.02
    static let aspectRange: ClosedRange<Double> = 0.4...2.5

    let bucketIndex: Int

    init(aspectRatio: Double) {
      let finite = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
      let clamped = min(max(finite, Self.aspectRange.lowerBound), Self.aspectRange.upperBound)
      bucketIndex = Int((clamped / Self.bucket).rounded())
    }

    var aspectRatio: Double { Double(bucketIndex) * Self.bucket }

    var artwork: CGSize {
      let long = CoverGlow.referenceLongSide
      return aspectRatio >= 1
        ? CGSize(width: long, height: long / aspectRatio)
        : CGSize(width: long * aspectRatio, height: long)
    }

    /// The artwork with three sigma all round, past which the halo is under 0.2%.
    var canvas: CGSize {
      let margin = 3 * CoverGlow.sigma
      return CGSize(width: artwork.width + 2 * margin, height: artwork.height + 2 * margin)
    }
  }

  /// The built images, one per artwork shape, for the life of the process.
  @MainActor
  final class Images {
    static let shared = Images()
    /// A low-frequency image loses nothing at half a pixel per point, and costs a twelfth of the
    /// memory it would at 3x.
    static let pixelsPerPoint: CGFloat = 0.5

    private var images: [ArtworkShape: CGImage] = [:]
    private(set) var builds = 0

    func image(for shape: ArtworkShape) -> CGImage? {
      if let image = images[shape] { return image }
      guard let image = Self.build(shape) else { return nil }
      builds += 1
      images[shape] = image
      return image
    }

    /// White, premultiplied, its alpha the product of the horizontal and vertical profiles.
    private static func build(_ shape: ArtworkShape) -> CGImage? {
      let width = Int((shape.canvas.width * pixelsPerPoint).rounded(.up))
      let height = Int((shape.canvas.height * pixelsPerPoint).rounded(.up))
      let margin = Double(3 * CoverGlow.sigma)
      func block(_ length: CGFloat) -> ClosedRange<Double> {
        let overhang = Double(length) * Double(CoverGlow.spread - 1) / 2
        return (margin - overhang)...(margin + Double(length) + overhang)
      }
      // Sampled at pixel centres, in points.
      func samples(_ count: Int, across span: ClosedRange<Double>) -> [Double] {
        (0..<count).map {
          CoverGlow.profile((Double($0) + 0.5) / Double(pixelsPerPoint), across: span)
        }
      }
      let columns = samples(width, across: block(shape.artwork.width))
      let rows = samples(height, across: block(shape.artwork.height))

      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      for y in 0..<height {
        for x in 0..<width {
          let alpha = UInt8((columns[x] * rows[y] * 255).rounded())
          let offset = (y * width + x) * 4
          bytes[offset] = alpha
          bytes[offset + 1] = alpha
          bytes[offset + 2] = alpha
          bytes[offset + 3] = alpha
        }
      }
      guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
      return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
  }
}
