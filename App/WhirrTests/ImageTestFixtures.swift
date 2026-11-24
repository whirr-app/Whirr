import Foundation
import UIKit

private final class ImageTestFixtureBundleToken {}

enum ImageTestFixtures {
  /// A static, full-detail 512×512 JPEG derived from the app artwork. Fixed bytes from the test
  /// bundle avoid UIKit's runtime encoder and its special handling of 2×2 images.
  static let knownGoodCoverData: Data = {
    let bundle = Bundle(for: ImageTestFixtureBundleToken.self)
    let url = bundle.url(forResource: "KnownGoodCover", withExtension: "jpg")
    precondition(url != nil, "KnownGoodCover.jpg must be included in the WhirrTests bundle")
    return try! Data(contentsOf: url!)
  }()

  /// A 200×300 portrait JPEG (2:3, the shape of a typical ebook cover). The other cover fixture
  /// is square, so fit-with-fill, which needs a non-square source, would be untestable without it.
  static let portraitCoverData: Data = {
    let bundle = Bundle(for: ImageTestFixtureBundleToken.self)
    let url = bundle.url(forResource: "PortraitCover", withExtension: "jpg")
    precondition(url != nil, "PortraitCover.jpg must be included in the WhirrTests bundle")
    return try! Data(contentsOf: url!)
  }()

  /// A solid PNG of exactly `width` × `height` pixels. Rendered at scale 1 because the default
  /// renderer format takes the main screen's scale, which would triple every dimension on a 3×
  /// simulator and fail a test asserting the sizes it asked for.
  static func solidPNGData(width: Int, height: Int) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: width, height: height)
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    return image.pngData()!
  }
}
