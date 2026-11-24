import Foundation
import GRDB

/// The Downloads screen's device-owned RSS projection. It carries feed metadata
/// and no account identity: RSS survives logout and is grouped by feed rather than mixed into ABS
/// item rows.
public struct RSSDownloadedEpisode: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let state: DownloadState
  public let actualBytes: Int64
  public let expectedBytes: Int64?
  public let holdReason: RSSDownloadHoldReason?

  public init(
    id: String, title: String, state: DownloadState, actualBytes: Int64,
    expectedBytes: Int64?, holdReason: RSSDownloadHoldReason?
  ) {
    self.id = id
    self.title = title
    self.state = state
    self.actualBytes = actualBytes
    self.expectedBytes = expectedBytes
    self.holdReason = holdReason
  }
}

public struct RSSDownloadedFeed: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let title: String
  public let author: String?
  public let sourceURL: URL
  public let artworkURL: URL?
  public let episodes: [RSSDownloadedEpisode]

  public init(
    id: Int64, title: String, author: String? = nil, sourceURL: URL,
    episodes: [RSSDownloadedEpisode], artworkURL: URL? = nil
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.sourceURL = sourceURL
    self.artworkURL = artworkURL
    self.episodes = episodes
  }

  public var totalBytes: Int64 {
    episodes.reduce(into: Int64(0)) { $0 += $1.actualBytes }
  }
}

public protocol RSSDownloadsReading: Sendable {
  func observeRSSDownloads() -> AsyncStream<[RSSDownloadedFeed]>
}

extension RSSDownloadsReading {
  /// Completed episodes only, in feeds that have one, emitted when that set changes. A transfer's
  /// progress changes `observeRSSDownloads()` at every 2% step but never this, so a consumer that
  /// only lists finished downloads does no work while one runs. The filtering runs off the main
  /// actor, ahead of the consumer.
  public func observeCompletedRSSDownloads() -> AsyncStream<[RSSDownloadedFeed]> {
    let source = observeRSSDownloads()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        var previous: [RSSDownloadedFeed]?
        for await feeds in source {
          let completed = feeds.compactMap { feed -> RSSDownloadedFeed? in
            let episodes = feed.episodes.filter { $0.state == .completed }
            guard episodes.isEmpty == false else { return nil }
            return RSSDownloadedFeed(
              id: feed.id, title: feed.title, author: feed.author, sourceURL: feed.sourceURL,
              episodes: episodes, artworkURL: feed.artworkURL)
          }
          guard completed != previous else { continue }
          previous = completed
          continuation.yield(completed)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

public struct NoOpRSSDownloadsReading: RSSDownloadsReading, Sendable {
  public init() {}
  public func observeRSSDownloads() -> AsyncStream<[RSSDownloadedFeed]> {
    AsyncStream {
      $0.yield([])
      $0.finish()
    }
  }
}

/// The single database-backed projection used by the production Downloads screen.  Joining the
/// three RSS tables here keeps SwiftUI/AppModel independent of GRDB and guarantees a feed cannot
/// appear without at least one persisted download row.
public struct DefaultRSSDownloadsReading: RSSDownloadsReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  /// `removeDuplicates` is load-bearing: in-flight `actualBytes` are floored to the shared progress
  /// quantum before the comparison, so a transfer's quarter-second progress writes reach consumers
  /// once per 2% step instead of on every tick; rows in any other state keep their exact byte
  /// count. A long-lived consumer that only lists finished downloads, such as the Watch catalogue
  /// publisher, should use `observeCompletedRSSDownloads()`, which drops even those steps.
  public func observeRSSDownloads() -> AsyncStream<[RSSDownloadedFeed]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db in try Self.fetchFeeds(db) }.removeDuplicates())
  }

  private static func fetchFeeds(_ db: Database) throws -> [RSSDownloadedFeed] {
    let feeds = try RSSFeedRecord.fetchAll(db, sql: "SELECT * FROM rssFeed ORDER BY title COLLATE NOCASE, id")
    return try feeds.compactMap { feed in
      guard let feedID = feed.id, let sourceURL = URL(string: feed.feedURL) else { return nil }
      let episodes = try RSSDownloadedEpisodeRecord.fetchAll(
        db,
        sql: """
          SELECT e.identityKey, e.title, d.state, d.actualBytes, d.expectedBytes, d.holdReason
          FROM rssDownload d JOIN rssEpisode e ON e.id = d.episodeId
          WHERE e.feedId = ? ORDER BY e.publishedAt DESC, e.id DESC
          """,
        arguments: [feedID]
      ).map {
        RSSDownloadedEpisode(
          id: $0.identityKey, title: $0.title ?? "Untitled episode", state: $0.state,
          actualBytes: $0.state == .downloading
            ? EpisodeDownloadProgressProjection.quantizedBytes(
              receivedBytes: $0.actualBytes, expectedBytes: $0.expectedBytes)
            : $0.actualBytes,
          expectedBytes: $0.expectedBytes,
          holdReason: $0.holdReason)
      }
      guard episodes.isEmpty == false else { return nil }
      return RSSDownloadedFeed(
        id: feedID, title: feed.title ?? sourceURL.absoluteString, author: feed.author,
        sourceURL: sourceURL, episodes: episodes,
        artworkURL: feed.artworkURL.flatMap(URL.init(string:)))
    }
  }
}

extension DefaultRSSDownloadsReading: DownloadedAudioPaging {
  /// Completed episodes of followed feeds, by show title; a show's episodes run newest first.
  public func downloadedAudioPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<DownloadedAudioPageRow, AudioBrowseCursor> {
    let limit = DefaultAudioBrowsePaging.clamped(limit)
    let keyset = Keyset(
      scope: "rss-downloads",
      terms: [
        KeysetTerm(expression: "COALESCE(feed.title, '') COLLATE NOCASE"),
        KeysetTerm(expression: "feed.id"),
        KeysetTerm(expression: "episode.publishedAt IS NULL"),
        KeysetTerm(expression: "COALESCE(episode.publishedAt, '')", descending: true),
        KeysetTerm(expression: "episode.id", descending: true),
      ])
    let after = try keyset.predicate(after: cursor)
    return try await database.readAsync { db in
      let fetched = try Row.fetchAll(
        db,
        sql: """
          SELECT
            feed.id AS feedID, feed.title AS feedTitle, feed.feedURL AS feedURL,
            feed.artworkURL AS artworkURL,
            episode.identityKey AS identityKey, episode.title AS title,
            \(keyset.selection)
          FROM rssEpisode AS episode
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          WHERE EXISTS (
              SELECT 1 FROM rssDownload AS download
              WHERE download.episodeId = episode.id AND download.state = 'completed'
            )
            \(after.sql)
          \(keyset.ordering)
          LIMIT ?
          """,
        arguments: after.arguments + [limit + 1])
      let page = keyset.page(fetched, limit: limit)
      let rows = page.rows.compactMap { row -> DownloadedAudioPageRow? in
        guard
          let identity = ListeningIdentity.rssEpisode(feedID: row["feedID"], episodeID: row["identityKey"])
        else { return nil }
        return DownloadedAudioPageRow(
          identity: identity, title: (row["title"] as String?) ?? "Untitled episode",
          subtitle: row["feedTitle"],
          artworkURL: (row["artworkURL"] as String?).flatMap(URL.init(string:)),
          artworkFeedURL: (row["feedURL"] as String?).flatMap(URL.init(string:)))
      }
      return AudioBrowsePage(rows: rows, next: page.next)
    }
  }
}

private struct RSSDownloadedEpisodeRecord: FetchableRecord, Decodable {
  let identityKey: String
  let title: String?
  let state: DownloadState
  let actualBytes: Int64
  let expectedBytes: Int64?
  let holdReason: RSSDownloadHoldReason?
}
