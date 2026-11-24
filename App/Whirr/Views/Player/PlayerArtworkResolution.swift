import ABSApi
import Foundation
import Persistence

/// Which cover the mini player and the expanded page both draw, and what tints from it: the
/// playing episode's own image first, then the followed show's, then the loaded item's. One value
/// computed the same way by both, so the open flight's cover match (`PlayerMorphGeometry.Snapshot`)
/// holds on source, item and revision.
nonisolated struct PlayerArtworkResolution: Equatable, Sendable {
  /// The episode's own image, when it has one.
  let episodeSource: ArtworkSource?
  /// What the player draws.
  let source: ArtworkSource?
  /// The show's cover: what the palette identity compares against, and what draws when the
  /// episode's image cannot be had.
  let showSource: ArtworkSource?

  init(
    episodeSource: ArtworkSource?, followedShowSource: ArtworkSource?,
    loadedSource: ArtworkSource?
  ) {
    let show = followedShowSource ?? loadedSource
    self.episodeSource = episodeSource
    self.showSource = show
    self.source = episodeSource ?? show
  }

  /// Nil when the show's cover is already what draws.
  var fallbackSource: ArtworkSource? {
    showSource == source ? nil : showSource
  }

  /// The palette identity for `key`, the cover this resolution draws: the episode image's own row
  /// when it is not the show's, else the item's.
  func paletteIdentity(for key: ArtworkKey, isProvisional: Bool) -> CoverPaletteIdentity {
    CoverPaletteIdentity(drawing: key, showSource: showSource, isProvisional: isProvisional)
  }

  /// The episode source the stored image answers with, else the one a queue row or the bar seeded
  /// for this same item and episode. Nil for an item that is not an RSS episode.
  @MainActor
  static func resolve(
    itemID: String, episodeID: String?, followedShowSource: ArtworkSource?,
    loadedSource: ArtworkSource?, seed: PlayerMetadataSeed?, episodeArtwork: PlayerEpisodeArtwork?
  ) -> PlayerArtworkResolution {
    let feedURL = Self.feedURL(of: followedShowSource ?? loadedSource)
    let observed = episodeArtwork?.source(itemID: itemID, episodeID: episodeID, feedURL: feedURL)
    return PlayerArtworkResolution(
      episodeSource: observed ?? seededEpisodeSource(seed, itemID: itemID, episodeID: episodeID),
      followedShowSource: followedShowSource, loadedSource: loadedSource)
  }

  /// The seed's episode image, only for the identity it was made for.
  static func seededEpisodeSource(
    _ seed: PlayerMetadataSeed?, itemID: String, episodeID: String?
  ) -> ArtworkSource? {
    guard let seed, seed.identity.itemID == itemID, seed.identity.episodeID == episodeID else {
      return nil
    }
    return seed.episodeArtworkSource
  }

  private static func feedURL(of source: ArtworkSource?) -> URL? {
    guard case .rss(let rss)? = source else { return nil }
    return rss.feedURL
  }
}
