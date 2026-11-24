import Foundation
import WatchProtocol

/// Who asked for each download: the listener on the wrist, or the phone's desired set (ADR 0021).
extension WatchDownloadStore {
  /// Every file this store holds for `selection`, in enqueue order. The shared enqueue step reads it
  /// so a file already held is skipped rather than refused as a duplicate.
  public func manifests(for selection: WatchSelection) -> [WatchDownloadManifest] {
    allManifests().filter { $0.selection == selection }
  }

  /// Makes every file of `selection` the phone's at `revision`: a download the phone now asks for
  /// is kept rather than fetched again, and a later omission from the phone's set may remove it.
  /// Returns the adopted files; none when the store holds nothing for the selection.
  @discardableResult
  public func adopt(selection: WatchSelection, revision: UInt64) throws -> [WatchDownloadManifest] {
    let ids = manifestsByID.values.filter { $0.selection == selection }.map(\.id)
    guard !ids.isEmpty else { return [] }
    for id in ids {
      guard var manifest = manifestsByID[id] else { continue }
      manifest.origin = .phone
      manifest.phoneRevision = revision
      manifestsByID[id] = manifest
    }
    try persist()
    return manifests(for: selection)
  }
}
