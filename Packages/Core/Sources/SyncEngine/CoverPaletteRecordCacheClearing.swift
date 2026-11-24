import Persistence

/// Clears the persisted palette rows that are derived from disposable artwork bytes.
public struct CoverPaletteRecordCacheClearing: ArtworkCacheClearing, Sendable {
  private let recordStore: CoverPaletteRecordStore

  public init(recordStore: CoverPaletteRecordStore) {
    self.recordStore = recordStore
  }

  public func clearCachedArtwork() async {
    try? await recordStore.removeAll()
  }
}
