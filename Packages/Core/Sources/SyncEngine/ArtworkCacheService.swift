/// The AppModel-facing artwork cache: its on-device size and the repair clear.
///
/// The automatic top-up is not routed through this type. `CoverCacheAllCoordinator.topUp()` runs
/// it directly on an unconstrained foreground; this service only needs the pass's cancellation so
/// a clear does not race the pass filling the same store.
public actor ArtworkCacheService: ArtworkCacheAccess {
  private let artwork: any ArtworkCachePassCancelling
  private let maintenance: any ArtworkCacheMaintaining

  public init(
    artwork: any ArtworkCachePassCancelling,
    maintenance: any ArtworkCacheMaintaining = NoOpArtworkCacheMaintenance()
  ) {
    self.artwork = artwork
    self.maintenance = maintenance
  }

  public func artworkCacheBytes() async -> Int64 {
    await maintenance.cachedByteSize()
  }

  public func clearArtworkCache() async {
    // An automatic pass may be filling the cache on this foreground. Cancel it first, then clear,
    // so it cannot refill behind the clear; the next unconstrained foreground tops the cache up
    // again. Cancelling an idle coordinator is a no-op.
    await artwork.cancel()
    await maintenance.clear()
  }
}
