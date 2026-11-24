import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import WatchProtocol

/// The covers the phone fetches for the Watch: one path for on-demand requests and pushed covers.
extension WatchCompanionRuntime {
  /// One fetch path for both the Watch's on-demand requests and pushed covers.
  static func thumbnailLoader(
    artwork: any ArtworkServing, library: any LibraryReading, sources: FollowedShowArtworkSources
  ) -> @MainActor (WatchArtworkRequest) async -> Data? {
    { request in
      let source: ArtworkSource
      let itemID: String
      var revision = ArtworkRevision(request.reference.revision)
      switch request.reference.source {
      case .audiobookshelf(let id):
        guard let defaultSource = artwork.defaultSource else { return nil }
        source = defaultSource
        itemID = id
        revision = Self.phoneArtworkRevision(
          for: request.reference, phoneItem: library.currentItemDetail(itemId: id))
      case .nativeFeed(let id):
        guard let feedID = Int64(id), let identity = PodcastSourceIdentity.rss(feedId: feedID),
          let nativeSource = sources.source(for: identity.itemId)
        else { return nil }
        source = nativeSource
        itemID = identity.itemId
      }
      let key = ArtworkKey(
        source: source, itemID: itemID,
        variant: .libraryThumbnail(pixelWidth: request.size.pixelWidth),
        revision: revision)
      guard let result = try? await artwork.fetch(key) else { return nil }
      return await Task.detached(priority: .utility) {
        WatchArtworkThumbnail.prepare(result.data, size: request.size)
      }.value
    }
  }

  /// The phone owns the library, so its own revision for an ABS cover wins over the Watch's: a
  /// Watch reference can be unversioned or stale, and fetching it through the phone's long-lived
  /// cover cache would serve the Watch a replaced cover indefinitely.
  nonisolated static func phoneArtworkRevision(
    for reference: WatchArtworkReference, phoneItem: ItemSummary?
  ) -> ArtworkRevision {
    guard case .audiobookshelf(let id) = reference.source, let phoneItem,
      phoneItem.serverItemId == id, phoneItem.serverUpdatedAt != nil
    else { return ArtworkRevision(reference.revision) }
    return phoneItem.artworkRevision
  }
}
