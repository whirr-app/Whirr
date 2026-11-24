import PodcastFeeds
import SyncEngine

/// App-side adapter for the Settings-only artwork clear. RSS artwork is device-owned, so the
/// account-lifecycle clear remains limited to account-owned cover state.
struct RSSArtworkCacheClearing: ArtworkCacheClearing, Sendable {
  private let client: RSSArtworkClient

  init(client: RSSArtworkClient) {
    self.client = client
  }

  func clearCachedArtwork() async {
    await client.clearCachedArtwork()
  }
}
