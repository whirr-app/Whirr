import Foundation
import GRDB

/// The device-owned half of each Home shelf that also has an account-owned half in
/// `HomeReading`. Both projections here are merged with their ABS counterpart by the Home models
/// under the native-subscriptions gate, so a feed row never reaches a shelf while the feature is
/// off.
public protocol NativeContinueListeningReading: Sendable {
  func observeContinueListening(limit: Int) -> AsyncStream<[HomeItem]>

  /// Feeds whose every live download row is completed (the rule `HomeReading.observeDownloaded`
  /// applies to an item), ordered by title. One row per feed, no episode selected: the Downloads
  /// shelf opens the show narrowed to its downloaded episodes.
  func observeDownloaded(limit: Int) -> AsyncStream<[HomeItem]>
}

extension NativeContinueListeningReading {
  /// Default for lightweight readers with no Downloads projection. Emits once and finishes so a
  /// merged shelf's readiness barrier still clears.
  public func observeDownloaded(limit: Int) -> AsyncStream<[HomeItem]> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }
}

/// The setup/test default must emit one empty value: the Continue Listening surfaces wait on a
/// readiness barrier across every source, and a stream that merely finished would leave the shelf
/// loading forever.
public struct NoOpNativeContinueListeningReading: NativeContinueListeningReading {
  public init() {}

  public func observeContinueListening(limit: Int) -> AsyncStream<[HomeItem]> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }

  public func observeDownloaded(limit: Int) -> AsyncStream<[HomeItem]> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }
}

/// Device-owned half of Continue Listening. One tracked query covers feed metadata, episode
/// state, availability, and download status, then suppresses identical emissions.
public struct RSSContinueListeningReading: NativeContinueListeningReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func observeContinueListening(limit: Int) -> AsyncStream<[HomeItem]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> [HomeItem] in
        // The downloaded file's length where there is one: positions are on its timeline.
        let duration = RSSDownloadDurationStore.preferredDurationSQL(
          episode: "episode", download: "download")
        let rows = try Row.fetchAll(
          db,
          sql: """
            WITH candidates AS (
              SELECT
                feed.id AS feedID,
                feed.title AS showTitle,
                feed.author AS showAuthor,
                feed.feedURL AS artworkFeedURL,
                feed.artworkURL AS artworkURL,
                feed.subscribedAt AS addedAt,
                episode.identityKey AS episodeID,
                episode.title AS episodeTitle,
                \(duration) AS durationSeconds,
                state.position AS progressCurrentTime,
                state.finished AS progressIsFinished,
                state.updatedAt AS progressRecency,
                download.state AS downloadState,
                ROW_NUMBER() OVER (
                  PARTITION BY feed.id
                  ORDER BY state.updatedAt DESC, state.localSequence DESC, episode.id DESC
                ) AS episodeRank
              FROM rssEpisodeState AS state
              JOIN rssEpisode AS episode ON episode.id = state.episodeId
              JOIN rssFeed AS feed ON feed.id = episode.feedId
              LEFT JOIN rssDownload AS download ON download.episodeId = episode.id
              WHERE state.position > 0
                AND state.finished = 0
                AND state.hideFromContinueListening = 0
                AND (
                  \(duration) IS NULL
                  OR \(duration) <= 0
                  OR \(duration)
                    - state.position >= \(LatestPodcastEpisodePolicy.minimumRemainingSeconds)
                )
                AND (
                  episode.lastSeenGeneration = feed.refreshGeneration
                  OR (episode.retained = 1 AND download.state = 'completed')
                )
            )
            SELECT * FROM candidates
            WHERE episodeRank = 1
            ORDER BY progressRecency IS NULL ASC, progressRecency DESC, feedID ASC, episodeID ASC
            LIMIT ?
            """,
          arguments: [limit])
        return rows.compactMap { row in
          let feedID: Int64 = row["feedID"]
          guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else { return nil }
          let isDownloaded = (row["downloadState"] as String?) == "completed"
          return HomeItem(
            serverItemId: itemID,
            title: (row["showTitle"] as String?) ?? "",
            author: row["showAuthor"],
            category: .podcast,
            hasReadableEbook: false,
            durationSeconds: row["durationSeconds"],
            progressSeconds: PlaybackPositionListProjection.quantizedSeconds(
              (row["progressCurrentTime"] as Double?) ?? 0),
            ebookProgress: 0,
            isFinished: (row["progressIsFinished"] as Bool?) ?? false,
            addedAt: row["addedAt"],
            isDownloaded: isDownloaded,
            seriesName: nil,
            narratorName: nil,
            expandedMetadataFetchedAt: nil,
            episodeID: row["episodeID"],
            episodeTitle: row["episodeTitle"],
            audioDownloaded: isDownloaded,
            ebookDownloaded: false,
            artworkURL: (row["artworkURL"] as String?).flatMap(URL.init(string:)),
            artworkFeedURL: (row["artworkFeedURL"] as String?).flatMap(URL.init(string:)),
            progressRecency: row["progressRecency"])
        }
      }.removeDuplicates())
  }

  /// A feed belongs on the Downloads shelf under the rule `DefaultHomeReading.observeDownloaded`
  /// applies to an item: at least one non-deleting download row, and none of them still in
  /// flight. Selecting only the rolled-up state keeps received-byte writes out of the tracked
  /// region, as the item projection does.
  public func observeDownloaded(limit: Int) -> AsyncStream<[HomeItem]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> [HomeItem] in
        let rows = try Row.fetchAll(
          db,
          sql: """
            WITH rollup AS (
              SELECT
                episode.feedId AS feedId,
                MAX(CASE WHEN download.state <> 'deleting' THEN 1 ELSE 0 END) AS hasLive,
                MAX(
                  CASE WHEN download.state NOT IN ('completed', 'deleting') THEN 1 ELSE 0 END
                ) AS hasIncomplete
              FROM rssDownload AS download
              JOIN rssEpisode AS episode ON episode.id = download.episodeId
              GROUP BY episode.feedId
            )
            SELECT
              feed.id AS feedID,
              feed.title AS showTitle,
              feed.author AS showAuthor,
              feed.feedURL AS artworkFeedURL,
              feed.artworkURL AS artworkURL,
              feed.subscribedAt AS addedAt
            FROM rssFeed AS feed
            JOIN rollup ON rollup.feedId = feed.id
              AND rollup.hasLive = 1
              AND rollup.hasIncomplete = 0
            ORDER BY feed.title COLLATE NOCASE ASC, feed.id ASC
            LIMIT ?
            """,
          arguments: [max(0, limit)])
        return rows.compactMap { row in
          let feedID: Int64 = row["feedID"]
          guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else { return nil }
          return HomeItem(
            serverItemId: itemID,
            title: (row["showTitle"] as String?) ?? "",
            author: row["showAuthor"],
            category: .podcast,
            hasReadableEbook: false,
            durationSeconds: nil,
            progressSeconds: 0,
            ebookProgress: 0,
            isFinished: false,
            addedAt: row["addedAt"],
            isDownloaded: true,
            audioDownloaded: true,
            ebookDownloaded: false,
            artworkURL: (row["artworkURL"] as String?).flatMap(URL.init(string:)),
            artworkFeedURL: (row["artworkFeedURL"] as String?).flatMap(URL.init(string:)))
        }
      }.removeDuplicates())
  }
}
