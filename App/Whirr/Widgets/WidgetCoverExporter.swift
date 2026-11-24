import ABSApi
import Foundation
import WidgetProtocol

/// Writes the covers a snapshot would draw into the App Group as small JPEGs. The extension never
/// fetches artwork itself, so ADR 0004's RSS artwork rules stay with the app.
///
/// The cover cache is tried first at the Home card width; only a miss goes to the network.
nonisolated struct WidgetCoverExporter: Sendable {
  /// The medium widget's cover is the largest drawn, about 100pt; at 3x that is 300 pixels.
  static let maxPixelSize = 320
  /// Twelve covers at this size stay far inside the extension's memory budget.
  static let maxBytes = 64 * 1024

  let artwork: any ArtworkServing
  let store: WidgetFileStore

  /// Exports `missing`, prunes everything not in `wanted`, and returns the names now on disk
  /// that a snapshot may reference. `@concurrent` so decoding and file writes leave the main
  /// actor, which a nonisolated async method would otherwise inherit from its caller here.
  @concurrent
  func export(missing: [WidgetCoverRequest], wanted: Set<String>) async -> Set<String> {
    for request in missing.prefix(WidgetStorageLayout.maxCoverFiles) {
      if Task.isCancelled { break }
      guard let data = await sourceData(for: request.key),
        let jpeg = WatchArtworkThumbnail.prepare(
          data, maxPixelSize: Self.maxPixelSize, maxBytes: Self.maxBytes)
      else { continue }
      try? store.writeCover(jpeg, named: request.fileName)
    }
    store.pruneCovers(keeping: wanted)
    return store.existingCoverNames().intersection(wanted)
  }

  private func sourceData(for key: ArtworkKey) async -> Data? {
    if let cached = await artwork.data(for: key) { return cached }
    return try? await artwork.fetch(key).data
  }
}
