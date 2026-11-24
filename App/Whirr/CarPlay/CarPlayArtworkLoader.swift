import ABSApi
import AppModel
import Persistence
import UIKit

/// The car's way into the artwork pipeline the phone's views use: the same clients, caches,
/// credentials and concurrency limits, without a view to hang the request on.
enum CarPlayArtworkLoader {
  /// The pipeline key for a car thumbnail, or nil when the row has no artwork to ask for.
  nonisolated static func artworkKey(
    for key: CarPlayArtworkKey, defaultSource: ArtworkSource?
  ) -> ArtworkKey? {
    let itemID: String
    let revision: ArtworkRevision
    var source: ArtworkSource?
    switch key.reference {
    case .none:
      return nil
    case .item(let id, let updatedAt):
      itemID = id
      revision = ArtworkRevision(serverUpdatedAt: updatedAt)
    case .feed(let id, let url, let feedURL):
      itemID = id
      revision = .unversioned
      if let feedID = PodcastSourceIdentity(itemId: id)?.rssFeedId, let feedURL {
        source = RSSArtworkSource(feedID: feedID, artworkURL: url, feedURL: feedURL).map(ArtworkSource.rss)
      }
    }
    if source == nil {
      // A followed show with no usable artwork address gets the generated cover the phone
      // draws for it; everything else is the signed-in server's.
      source =
        PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil
        ? .generated(ArtworkAccountScope("artwork:generated:rss")) : defaultSource
    }
    guard let source else { return nil }
    return ArtworkKey(
      source: source, itemID: itemID, variant: .libraryThumbnail(pixelWidth: max(1, key.pixelSize)),
      revision: revision)
  }

  nonisolated static func load(
    client: any ArtworkServing, pipeline: ArtworkImagePipeline = .shared
  ) -> CarPlayArtworkRequests<UIImage>.Load {
    { key in
      guard let artworkKey = artworkKey(for: key, defaultSource: client.defaultSource) else { return nil }
      return await pipeline.image(for: artworkKey, priority: .visible, client: client)
    }
  }
}
