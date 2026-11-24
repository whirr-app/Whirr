import ABSApi
import Foundation

/// One recent episode as a preview shows it. `synopsis` is the raw feed text; turning feed HTML
/// into display text belongs to the presentation layer.
public struct FeedPreviewEpisode: Sendable, Equatable {
  public let title: String?
  public let publishedAt: Date?
  public let duration: TimeInterval?
  public let synopsis: String?

  public init(title: String?, publishedAt: Date?, duration: TimeInterval?, synopsis: String?) {
    self.title = title
    self.publishedAt = publishedAt
    self.duration = duration
    self.synopsis = synopsis
  }
}

/// The channel-level summary shown before a follow: what the add surface previews.
public struct FeedPreview: Sendable, Equatable {
  /// Enough episodes to judge a show before following it. Each synopsis is already capped by
  /// `FeedParseLimits`, so a retained preview stays small.
  public static let recentEpisodeLimit = 10

  public let feedURL: URL
  public let title: String
  public let author: String?
  public let artworkURL: URL?
  public let synopsis: String?
  public let episodeCount: Int
  /// Newest first, at most `recentEpisodeLimit`.
  public let recentEpisodes: [FeedPreviewEpisode]

  public init(
    feedURL: URL, title: String, author: String?, artworkURL: URL?, synopsis: String?,
    episodeCount: Int, recentEpisodes: [FeedPreviewEpisode] = []
  ) {
    self.feedURL = feedURL
    self.title = title
    self.author = author
    self.artworkURL = artworkURL
    self.synopsis = synopsis
    self.episodeCount = episodeCount
    self.recentEpisodes = recentEpisodes
  }

  /// Feeds are usually newest-first, but nothing guarantees it, so order by the parsed date.
  /// Items whose date is missing or unparsable follow every dated item, and ties keep feed order.
  static func recentEpisodes(
    from items: [ParsedFeedItem], limit: Int = recentEpisodeLimit
  ) -> [FeedPreviewEpisode] {
    // Only the date is needed to order every item; the rest is built for the kept few.
    let dated = items.enumerated().map { offset, item in
      (offset: offset, item: item, date: item.pubDate.flatMap(FeedValueParsing.pubDate))
    }
    let ordered = dated.sorted { lhs, rhs in
      switch (lhs.date, rhs.date) {
      case (let left?, let right?) where left != right: return left > right
      case (.some, nil): return true
      case (nil, .some): return false
      default: return lhs.offset < rhs.offset
      }
    }
    return ordered.prefix(limit).map { entry in
      FeedPreviewEpisode(
        title: entry.item.title,
        publishedAt: entry.date,
        duration: entry.item.durationText.flatMap(FeedValueParsing.duration),
        // Match what the card will render once the show is followed.
        synopsis: entry.item.content ?? entry.item.synopsis)
    }
  }
}

/// Why a feed preview could not be produced. Coarse, since the add surface needs only three
/// distinctions: the address is not a usable feed URL, the host could not be reached, or the host
/// answered but did not serve a feed.
public enum FeedPreviewError: Error, Sendable, Equatable {
  case invalidURL
  case unreachable
  case notAFeed
}

/// Fetches and parses a feed far enough to preview it. Composes the feed transport
/// (`FeedFetchClient`) and `FeedParser`; holds no state of its own.
public struct FeedPreviewClient: Sendable {
  private let fetchClient: FeedFetchClient

  public init(fetchClient: FeedFetchClient = FeedFetchClient()) {
    self.fetchClient = fetchClient
  }

  public func preview(for url: URL) async throws -> FeedPreview {
    try await preview(for: url, credential: nil)
  }

  public func preview(for url: URL, credential: FeedCredential?) async throws -> FeedPreview {
    guard let endpoint = FeedEndpoint(url: url) else { throw FeedPreviewError.invalidURL }

    let outcome: FeedFetchOutcome
    do {
      outcome = try await fetchClient.fetch(endpoint, credential: credential)
    } catch let error as APIError {
      if error == .cancelled { throw CancellationError() }
      throw Self.previewError(for: error)
    } catch is CancellationError {
      throw CancellationError()
    } catch is FeedFetchError {
      // FeedFetchError is a transient backoff window: report it as unreachable.
      throw FeedPreviewError.unreachable
    } catch {
      // URLError and other transport-level failures.
      throw FeedPreviewError.unreachable
    }

    guard case .fetched(let response) = outcome else {
      // A preview sends no validators, so a 304 should not occur. Treat it as not-a-feed rather
      // than a phantom success.
      throw FeedPreviewError.notAFeed
    }

    do {
      // Validators are not accepted: a preview keeps no copy of the feed to be "not modified"
      // against, so replaying them would turn the next preview into a 304 it cannot use. This also
      // keeps ADR 0004's "a preview persists nothing" true.
      let parsed = try FeedParser.parse(response.body)
      return FeedPreview(
        feedURL: url, title: parsed.title, author: parsed.author, artworkURL: parsed.artworkURL,
        synopsis: parsed.synopsis, episodeCount: parsed.items.count,
        recentEpisodes: FeedPreview.recentEpisodes(from: parsed.items))
    } catch {
      throw FeedPreviewError.notAFeed
    }
  }

  private static func previewError(for error: APIError) -> FeedPreviewError {
    switch error {
    case .transport, .rateLimited, .serverFailure:
      // Connection-level or transient server-side: the host was not reachably serving content.
      return .unreachable
    default:
      // A live host answered with a client-error status (401/403/404/413/unexpected) or an
      // unreadable body: there is a server, but no feed here.
      return .notAFeed
    }
  }
}
