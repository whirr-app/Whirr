import Foundation
import PodcastFeeds
import SyncEngine

/// Device-owned authorization for a private RSS enclosure. It is separate from the
/// ABS playback authorization: the only secret held here is the feed credential, and headers are
/// returned only for the feed's own origin.
public struct RSSPlaybackStreamAuthorization: Sendable, PlaybackStreamAuthorizationProviding,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let feedURL: URL
  private let headerFields: [String: String]

  public init?(credential: PodcastFeedCredential, feedURL: URL) {
    guard feedURL.user == nil, feedURL.password == nil,
      case .allow(stripAuthorization: false) = FeedRedirectPolicy.evaluate(
        original: feedURL, target: feedURL, hopNumber: 1)
    else { return nil }

    self.feedURL = feedURL
    headerFields = credential.headerFields
  }

  public func httpHeaderFields(for url: URL) -> [String: String] {
    guard url.isFileURL == false, url.user == nil, url.password == nil,
      case .allow(stripAuthorization: false) = FeedRedirectPolicy.evaluate(
        original: feedURL, target: url, hopNumber: 1)
    else { return [:] }
    return headerFields
  }

  public var description: String {
    "RSSPlaybackStreamAuthorization(fields: Authorization)"
  }

  public var debugDescription: String { description }
}
