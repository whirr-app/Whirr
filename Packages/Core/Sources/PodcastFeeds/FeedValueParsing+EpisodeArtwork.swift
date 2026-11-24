import ABSApi
import Foundation

extension FeedValueParsing {
  /// An item's own `<itunes:image>`, or nil when it has none or it is the show's own image after
  /// artwork normalization: an episode repeating its channel art declares no episode art.
  public static func episodeArtworkURL(_ item: URL?, channel: URL?, feedID: Int64) -> URL? {
    guard let item, let source = RSSArtworkSource(feedID: feedID, artworkURL: item) else {
      return nil
    }
    if let channel, let channelSource = RSSArtworkSource(feedID: feedID, artworkURL: channel),
      channelSource.normalizedArtworkURL == source.normalizedArtworkURL
    {
      return nil
    }
    return item
  }
}
