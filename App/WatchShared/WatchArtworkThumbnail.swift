import Foundation
import ImageIO
import UniformTypeIdentifiers
import WatchProtocol

/// Decode directly to a bounded thumbnail off the UI actor. Never rasterize the original cover.
nonisolated enum WatchArtworkThumbnail {
  static func prepare(_ data: Data, size: WatchArtworkSize) -> Data? {
    prepare(data, maxPixelSize: size.pixelWidth, maxBytes: WatchArtworkReply.maxImageBytes)
  }

  /// The same downsample at any size and byte budget; the widget covers use it too.
  static func prepare(_ data: Data, maxPixelSize: Int, maxBytes: Int) -> Data? {
    guard data.count <= 20 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { return nil }
    for quality in [0.8, 0.6, 0.4] {
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      if CGImageDestinationFinalize(destination), output.length <= maxBytes {
        return output as Data
      }
    }
    return nil
  }
}
