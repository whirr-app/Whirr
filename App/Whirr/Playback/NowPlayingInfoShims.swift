import ABSApi
import MediaPlayer

/// The slice of `MPNowPlayingInfoCenter` behaviour `NowPlayingMetadataAdapter` needs, wrapped so
/// `NowPlayingMetadataTests` can inject a fake instead of touching the process-wide
/// `MPNowPlayingInfoCenter.default()`.
protocol NowPlayingInfoSink: AnyObject {
  var nowPlayingInfo: [String: Any]? { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoSink {}

/// Static per-item display metadata `PlayerCore` has no notion of (title, author). `PlayerItem`
/// only carries the credential-free timeline/chapter data (ARCHITECTURE.md); this fills the gap
/// from whatever layer holds the library record, keyed by item id so `NowPlayingMetadataAdapter`
/// needs no second source of playback truth.
protocol NowPlayingItemInfoProviding: AnyObject {
  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo?

  /// Resolves on the full `(item, episode)` identity `PlayerItem` carries: item id alone shows one
  /// show title for every episode. No defaulted extension forwards to the item-only overload, since
  /// a decorator inheriting it would silently drop every episode id; item-scope conformers say so.
  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo?
}

nonisolated struct NowPlayingItemInfo: Equatable {
  let title: String
  let author: String?
  let artworkSource: ArtworkSource?
  /// Drawn when `artworkSource` (an episode's own image) is unavailable or fails: the show's.
  let fallbackArtworkSource: ArtworkSource?
  /// The ABS item's cover revision, so the lock screen re-fetches a replaced cover. RSS artwork is
  /// addressed by URL and stays unversioned.
  let artworkRevision: ArtworkRevision

  init(
    title: String, author: String? = nil, artworkSource: ArtworkSource? = nil,
    fallbackArtworkSource: ArtworkSource? = nil,
    artworkRevision: ArtworkRevision = .unversioned
  ) {
    self.title = title
    self.author = author
    self.artworkSource = artworkSource
    self.fallbackArtworkSource = fallbackArtworkSource
    self.artworkRevision = artworkRevision
  }
}
