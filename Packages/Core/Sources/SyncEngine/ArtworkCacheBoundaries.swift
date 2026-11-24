import Foundation

/// AppModel's boundary onto the on-device artwork cache. The concrete SyncEngine actor stays below
/// this protocol so AppModel never imports or constructs it directly.
public protocol ArtworkCacheAccess: Sendable {
  /// What the disposable cover cache currently occupies on this device. Metadata has no
  /// counterpart figure: it lives inside the app database rather than in a store of its own.
  func artworkCacheBytes() async -> Int64
  /// Empties the cover cache. A repair, not space management: cached covers are served
  /// indefinitely because the server sends no validators (API-CONVENTIONS), so this is the only
  /// way artwork replaced on the server is picked up.
  func clearArtworkCache() async
}

/// The default artwork-cache boundary: an empty cache and silent actions, so callers compose
/// before the concrete service is wired.
public struct NoOpArtworkCacheAccess: ArtworkCacheAccess, Sendable {
  public init() {}

  public func artworkCacheBytes() async -> Int64 { 0 }

  public func clearArtworkCache() async {}
}

/// The artwork pass's cancellation seam. A clear runs while the automatic top-up may be filling
/// the same store, so the service cancels that pass before emptying it.
public protocol ArtworkCachePassCancelling: Actor {
  func cancel()
}
