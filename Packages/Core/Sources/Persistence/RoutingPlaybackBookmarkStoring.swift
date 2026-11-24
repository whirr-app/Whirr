import Foundation

/// Sends each bookmark write to the surface that owns the item's origin: the account's bookmark
/// table for a server item, the device-owned one for a native episode. Without this, a native
/// episode resolves no `item` row, `setBookmark` throws, and the mini player keeps the previous
/// item.
///
/// Routing matches the playback router, including an id with the reserved prefix that does not
/// decode: it stays on the server path and is reported as an unresolved target.
///
/// Reads project both surfaces through one database snapshot. The `abs` read half is unused in
/// production: writes need an injectable surface, but only the database gives a consistent
/// snapshot of both tables.
public struct RoutingPlaybackBookmarkStoring: PlaybackBookmarkStoring, Sendable {
  private let abs: any PlaybackBookmarkStoring
  private let rss: RSSPlaybackBookmarkStore
  private let reads: MergedPlaybackBookmarkReading

  public init(
    abs: any PlaybackBookmarkStoring,
    rss: RSSPlaybackBookmarkStore,
    reads: MergedPlaybackBookmarkReading
  ) {
    self.abs = abs
    self.rss = rss
    self.reads = reads
  }

  public func observeBookmark() -> AsyncStream<PlaybackBookmark?> {
    reads.observeBookmark()
  }

  public func fetchBookmark() async -> PlaybackBookmark? {
    await reads.fetchBookmark()
  }

  public func setBookmark(itemID: String) async throws {
    try await setBookmark(itemID: itemID, episodeID: nil)
  }

  public func setBookmark(itemID: String, episodeID: String?) async throws {
    if let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      try await rss.setBookmark(feedId: feedId, episodeID: episodeID)
    } else {
      try await abs.setBookmark(itemID: itemID, episodeID: episodeID)
    }
  }
}
