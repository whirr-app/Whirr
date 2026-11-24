import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

extension ExpandedPlayerView {
  /// The item-detail fetch's own result once loaded. Always the freshest answer, but not the
  /// only one this view can render (`ExpandedPlayerPresentation.metadata`'s `liveTitle`/
  /// `liveAuthor`).
  private var liveTitle: String? {
    if case .loaded(let item) = itemModel?.state { return item.title }
    return nil
  }

  private var liveAuthor: String? {
    if case .loaded(let item) = itemModel?.state { return item.author }
    return nil
  }

  /// The loaded item's cover identity, or until it loads an identity-matched seed's: the mini
  /// player's, on an open from the bar, so the page keys its cover as the bar does.
  private var artworkIdentity: ExpandedPlayerPresentation.ArtworkIdentity {
    var live: ExpandedPlayerPresentation.ArtworkIdentity?
    if case .loaded(let item) = itemModel?.state, item.serverItemId == itemID {
      live = .init(source: item.providerArtworkSource, revision: item.artworkRevision)
    }
    return ExpandedPlayerPresentation.artworkIdentity(
      itemID: itemID, episodeID: displayedEpisodeID, live: live, metadataSeed: metadataSeed)
  }

  private var liveArtworkSource: ArtworkSource? { artworkIdentity.source }

  /// The same resolution the bar computes, so the open flight's covers match.
  var artworkResolution: PlayerArtworkResolution {
    .resolve(
      itemID: itemID, episodeID: displayedEpisodeID,
      followedShowSource: followedShowArtworkSources?.source(for: itemID),
      loadedSource: liveArtworkSource, seed: metadataSeed, episodeArtwork: episodeArtwork)
  }

  var resolvedArtworkSource: ArtworkSource? { artworkResolution.source }

  /// The key the page's cover is drawn under, shared by the artwork task and the canvas so both
  /// name one cover.
  var artworkPaletteKey: ArtworkKey {
    Self.paletteArtworkKey(
      itemID: itemID, coverClient: coverClient, source: resolvedArtworkSource,
      displayScale: displayScale, revision: liveArtworkRevision)
  }

  /// The palette identity of the cover this page draws: the episode image's own row when it has
  /// one, else the item's, and provisional until the item loads. The artwork task and the canvas
  /// read this one answer, so both key and read the same cover as the queue advances.
  var paletteIdentity: CoverPaletteIdentity {
    artworkResolution.paletteIdentity(
      for: artworkPaletteKey, isProvisional: isItemLoaded == false)
  }

  /// Under the same identity check as `artworkIdentity`.
  var isItemLoaded: Bool {
    if case .loaded(let item) = itemModel?.state, item.serverItemId == itemID { return true }
    return false
  }

  var liveArtworkRevision: ArtworkRevision { artworkIdentity.revision }

  /// Renders from the retained projection (`playback.displayedItem`) the moment it's
  /// available, so this never shows "Loading…" while a matching bookmark already names the item.
  /// Only `liveTitle` resolving supersedes it. Both `itemModel` and `playback.displayedItem`
  /// change rarely (never per playback tick), so reading them here in `body` is safe.
  var title: String {
    ExpandedPlayerPresentation.metadata(
      itemID: itemID, episodeID: displayedEpisodeID, displayedItem: playback.displayedItem,
      liveTitle: liveTitle, liveAuthor: liveAuthor, metadataSeed: metadataSeed
    ).title
  }

  var author: String? {
    ExpandedPlayerPresentation.metadata(
      itemID: itemID, episodeID: displayedEpisodeID, displayedItem: playback.displayedItem,
      liveTitle: liveTitle, liveAuthor: liveAuthor, metadataSeed: metadataSeed
    ).author
  }
}
