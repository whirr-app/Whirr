import AVFoundation
import PlayerCore

/// The compositions `CompositionTrimPreparer` has built, one per source file: the latest map's
/// asset replaces any earlier one. Keyed by standardized file URL, the key a track's resource
/// resolves to.
@MainActor
final class PreparedTrimAssets {
  struct Entry {
    let map: PlayerTrimMap
    let asset: AVAsset
  }

  private var entries: [URL: Entry] = [:]

  func store(fileURL: URL, map: PlayerTrimMap, asset: AVAsset) {
    entries[fileURL.standardized] = Entry(map: map, asset: asset)
  }

  /// The entry for `fileURL` only when it was built for exactly `map`.
  func entry(for fileURL: URL, map: PlayerTrimMap) -> Entry? {
    guard let entry = entries[fileURL.standardized], entry.map == map else { return nil }
    return entry
  }

  func removeAll() {
    entries.removeAll()
  }
}
