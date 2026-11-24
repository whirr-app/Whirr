import Foundation
import GRDB

public protocol NativeLatestPodcastEpisodesReading: Sendable {
  func observeLatestPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<[HomePodcastEpisode]>
}

/// The setup/test default must emit one empty value: `HomeMoreModel` has a two-source readiness
/// barrier, and a stream that merely finished would leave every Latest Episodes surface loading.
public struct NoOpNativeLatestPodcastEpisodesReading: NativeLatestPodcastEpisodesReading {
  public init() {}
  public func observeLatestPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<[HomePodcastEpisode]> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }
}

public enum LatestPodcastEpisodePolicy {
  /// Product policy shared with the ABS Home projection: trailing audio below one minute is
  /// effectively complete for inbox presentation, without mutating durable state.
  public static let minimumRemainingSeconds = 60
}

/// Device-owned half of the Latest Episodes inbox. One tracked query covers feed metadata, episode
/// state, availability, and `includeInLatest`, then suppresses identical emissions.
public struct RSSLatestPodcastEpisodesReading: NativeLatestPodcastEpisodesReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func observeLatestPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<[HomePodcastEpisode]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> [HomePodcastEpisode] in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT
              feed.id AS feedID,
              feed.title AS showTitle,
              feed.author AS showAuthor,
              feed.feedURL AS feedURL,
              feed.artworkURL AS artworkURL,
              episode.identityKey AS episodeID,
              episode.title AS episodeTitle,
              episode.publishedAt AS publishedAt,
              episode.durationSeconds AS durationSeconds,
              state.position AS progressCurrentTime,
              state.finished AS progressIsFinished
            FROM rssEpisode AS episode
            JOIN rssFeed AS feed ON feed.id = episode.feedId
            LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
            LEFT JOIN rssFeedSettings AS settings ON settings.feedId = feed.id
            WHERE episode.publishedAt >= ?
              AND episode.lastSeenGeneration = feed.refreshGeneration
              AND COALESCE(settings.includeInLatest, 1) = 1
              AND COALESCE(state.finished, 0) = 0
              AND (
                state.position IS NULL
                OR episode.durationSeconds IS NULL
                OR episode.durationSeconds <= 0
                OR episode.durationSeconds - state.position
                  >= \(LatestPodcastEpisodePolicy.minimumRemainingSeconds)
              )
            ORDER BY episode.publishedAt DESC, feed.id ASC, episode.identityKey ASC
            LIMIT ?
            """,
          arguments: [cutoff(), limit])
        return rows.compactMap { row in
          let feedID: Int64 = row["feedID"]
          guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else { return nil }
          return HomePodcastEpisode(
            itemID: itemID,
            showTitle: (row["showTitle"] as String?) ?? "",
            showAuthor: row["showAuthor"],
            episodeID: row["episodeID"],
            title: (row["episodeTitle"] as String?) ?? "",
            subtitle: nil,
            publishedAt: row["publishedAt"],
            durationSeconds: row["durationSeconds"],
            progressSeconds: PlaybackPositionListProjection.quantizedSeconds(
              (row["progressCurrentTime"] as Double?) ?? 0),
            isFinished: (row["progressIsFinished"] as Bool?) ?? false,
            artworkURL: (row["artworkURL"] as String?).flatMap(URL.init(string:)),
            artworkFeedURL: (row["feedURL"] as String?).flatMap(URL.init(string:)))
        }
      }.removeDuplicates())
  }
}
