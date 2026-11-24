import Foundation
import GRDB

/// An episode as a paged list shows it: enough to title a row, to say whether it can play
/// without a connection, and to play exactly that episode.
public struct PodcastEpisodePageRow: Sendable, Equatable {
  public let identity: ListeningIdentity
  public let title: String
  public let publishedAt: Date?
  public let durationSeconds: Double?
  public let isFinished: Bool
  /// How far in the listener is; zero for an episode not started.
  public let progressSeconds: Double
  /// The episode's own audio is fully on the device. A show's aggregate download state never
  /// sets this.
  public let audioDownloaded: Bool
  /// The origin still offers the episode for streaming.
  public let isAvailableOnServer: Bool

  public init(
    identity: ListeningIdentity, title: String, publishedAt: Date?, durationSeconds: Double?,
    isFinished: Bool, audioDownloaded: Bool, isAvailableOnServer: Bool, progressSeconds: Double = 0
  ) {
    self.identity = identity
    self.title = title
    self.publishedAt = publishedAt
    self.durationSeconds = durationSeconds
    self.isFinished = isFinished
    self.progressSeconds = progressSeconds
    self.audioDownloaded = audioDownloaded
    self.isAvailableOnServer = isAvailableOnServer
  }
}

/// Bounded show and episode reads for one podcast source, in the order that source's phone
/// screens use. A page costs a page whatever the source holds, and a cursor read under an
/// order the list has since left throws `AudioBrowsePagingError.staleCursor`.
public protocol PodcastBrowsePaging: Sendable {
  func showPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<ItemSummary, AudioBrowseCursor>

  /// The episodes of the show `itemID` names; empty when this source does not hold that show.
  func episodePage(
    itemID: String, after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<PodcastEpisodePageRow, AudioBrowseCursor>
}

/// Server podcasts: shows in `DefaultPodcastShowOrdering`'s order, episodes in
/// `DefaultPodcastReading`'s.
public struct DefaultPodcastBrowsePaging: PodcastBrowsePaging {
  private let database: AppDatabase
  private let accountId: Int64

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
  }

  public func showPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<ItemSummary, AudioBrowseCursor> {
    let limit = DefaultAudioBrowsePaging.clamped(limit)
    return try await database.readAsync { db in
      // The mode is read in the same transaction as the page, so a cursor is checked against the
      // order the rows are actually in.
      let keyset = DefaultPodcastShowOrdering.keyset(
        mode: try DefaultPodcastShowOrdering.mode(db, accountId: self.accountId))
      let after = try keyset.predicate(after: cursor)
      let fetched = try Row.fetchAll(
        db,
        sql: """
          SELECT item.*, \(keyset.selection)
          \(DefaultPodcastShowOrdering.liveShowsSQL)
          \(after.sql)
          \(keyset.ordering)
          LIMIT ?
          """,
        arguments: [self.accountId] + after.arguments + [limit + 1])
      let page = keyset.page(fetched, limit: limit)
      return AudioBrowsePage(
        rows: try page.rows.map { DefaultLibraryReading.makeSummary(try ItemRecord(row: $0)) },
        next: page.next)
    }
  }

  public func episodePage(
    itemID: String, after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<PodcastEpisodePageRow, AudioBrowseCursor> {
    let limit = DefaultAudioBrowsePaging.clamped(limit)
    let keyset = Keyset(
      scope: "server-episodes:\(itemID)",
      terms: [
        KeysetTerm(expression: "episode.publishedAt IS NULL"),
        KeysetTerm(expression: "COALESCE(episode.publishedAt, '')", descending: true),
        KeysetTerm(expression: "episode.serverEpisodeId"),
        KeysetTerm(expression: "episode.id"),
      ])
    let after = try keyset.predicate(after: cursor)
    return try await database.readAsync { db in
      // Download state is two correlated lookups rather than a join: a join yields one row per
      // file, and the limit must count episodes.
      let fetched = try Row.fetchAll(
        db,
        sql: """
          WITH selectedItem AS (
            SELECT item.id, item.accountId
            FROM item
            JOIN library
              ON library.id = item.libraryId
              AND library.accountId = item.accountId
            WHERE item.accountId = ? AND item.serverItemId = ? AND \(ItemVisibilityPredicate.sql)
            ORDER BY item.id
            LIMIT 1
          )
          SELECT
            episode.serverEpisodeId AS serverEpisodeId,
            episode.title AS title,
            episode.publishedAt AS publishedAt,
            episode.durationSeconds AS durationSeconds,
            episode.storedAudioIno AS storedAudioIno,
            episode.storedAudioExpectedSize AS storedAudioExpectedSize,
            episode.storedAudioMimeType AS storedAudioMimeType,
            episode.storedAudioDurationSeconds AS storedAudioDurationSeconds,
            COALESCE(progress.isFinished, 0) AS isFinished,
            COALESCE(progress.currentTime, 0) AS progressSeconds,
            (
              EXISTS (
                SELECT 1 FROM download
                WHERE download.accountId = episode.accountId
                  AND download.itemId = episode.itemId
                  AND download.podcastEpisodeId = episode.id
                  AND download.state <> 'deleting'
              )
              AND NOT EXISTS (
                SELECT 1 FROM download
                WHERE download.accountId = episode.accountId
                  AND download.itemId = episode.itemId
                  AND download.podcastEpisodeId = episode.id
                  AND download.state NOT IN ('completed', 'deleting')
              )
            ) AS audioDownloaded,
            \(keyset.selection)
          FROM podcastEpisode AS episode
          JOIN selectedItem
            ON selectedItem.id = episode.itemId
            AND selectedItem.accountId = episode.accountId
          LEFT JOIN mediaProgress AS progress
            ON progress.accountId = episode.accountId
            AND progress.itemId = episode.itemId
            AND progress.podcastEpisodeId = episode.id
          WHERE episode.softDeleted = 0
            \(after.sql)
          \(keyset.ordering)
          LIMIT ?
          """,
        arguments: [self.accountId, itemID] + after.arguments + [limit + 1])
      let page = keyset.page(fetched, limit: limit)
      let rows = page.rows.compactMap { row -> PodcastEpisodePageRow? in
        guard
          let identity = ListeningIdentity.podcastEpisode(itemID: itemID, episodeID: row["serverEpisodeId"])
        else { return nil }
        let stored = DefaultPodcastReading.storedAudio(row)
        return PodcastEpisodePageRow(
          identity: identity, title: row["title"], publishedAt: row["publishedAt"],
          durationSeconds: stored.durationSeconds, isFinished: row["isFinished"],
          audioDownloaded: row["audioDownloaded"], isAvailableOnServer: stored.isAvailableOnServer,
          progressSeconds: row["progressSeconds"])
      }
      return AudioBrowsePage(rows: rows, next: page.next)
    }
  }
}

/// Followed feeds: shows in the device's durable native order, episodes in `observeEpisodes`
/// order.
extension RSSPodcastReading: PodcastBrowsePaging {
  /// The one definition of each native order, shared by `observeShows` and the paged read.
  static func showKeyset(mode: NativePodcastShowSortMode) -> Keyset {
    let alphabetical = [
      KeysetTerm(expression: "COALESCE(feed.title, '') COLLATE NOCASE"), KeysetTerm(expression: "feed.id"),
    ]
    switch mode {
    case .alphabetical:
      return Keyset(scope: "rss-shows:alphabetical", terms: alphabetical)
    case .mostRecent:
      return Keyset(
        scope: "rss-shows:mostRecent",
        terms: [
          KeysetTerm(expression: "latest.latestPublishedAt IS NULL"),
          KeysetTerm(expression: "COALESCE(latest.latestPublishedAt, '')", descending: true),
        ] + alphabetical)
    case .custom:
      return Keyset(
        scope: "rss-shows:custom",
        terms: [
          KeysetTerm(expression: "feed.customSortIndex IS NULL"),
          KeysetTerm(expression: "COALESCE(feed.customSortIndex, 0)"),
        ] + alphabetical)
    }
  }

  /// Only the most-recent order needs each feed's newest episode.
  static func latestEpisodeJoin(mode: NativePodcastShowSortMode) -> String {
    guard mode == .mostRecent else { return "" }
    return """
      LEFT JOIN (
        SELECT feedId, MAX(publishedAt) AS latestPublishedAt
        FROM rssEpisode
        GROUP BY feedId
      ) AS latest ON latest.feedId = feed.id
      """
  }

  public func showPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<ItemSummary, AudioBrowseCursor> {
    let limit = DefaultAudioBrowsePaging.clamped(limit)
    return try await database.readAsync { db in
      let mode = try RSSFeedStore.sortMode(db)
      let keyset = Self.showKeyset(mode: mode)
      let after = try keyset.predicate(after: cursor)
      let fetched = try Row.fetchAll(
        db,
        sql: """
          SELECT \(Self.showColumns), \(keyset.selection)
          FROM rssFeed AS feed
          \(Self.latestEpisodeJoin(mode: mode))
          WHERE 1 = 1
            \(after.sql)
          \(keyset.ordering)
          LIMIT ?
          """,
        arguments: after.arguments + [limit + 1])
      let page = keyset.page(fetched, limit: limit)
      return AudioBrowsePage(rows: page.rows.compactMap(Self.makeShowSummary), next: page.next)
    }
  }

  public func episodePage(
    itemID: String, after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<PodcastEpisodePageRow, AudioBrowseCursor> {
    guard let feedID = Self.rssFeedId(from: itemID) else { return AudioBrowsePage(rows: [], next: nil) }
    let limit = DefaultAudioBrowsePaging.clamped(limit)
    let keyset = Keyset(
      scope: "rss-episodes:\(feedID)",
      terms: [
        KeysetTerm(expression: "episode.publishedAt IS NULL"),
        KeysetTerm(expression: "COALESCE(episode.publishedAt, '')", descending: true),
        KeysetTerm(expression: "episode.id"),
      ])
    let after = try keyset.predicate(after: cursor)
    return try await database.readAsync { db in
      let fetched = try Row.fetchAll(
        db,
        sql: """
          SELECT
            episode.identityKey AS identityKey,
            episode.title AS title,
            episode.publishedAt AS publishedAt,
            episode.durationSeconds AS durationSeconds,
            COALESCE(state.finished, 0) AS finished,
            COALESCE(state.position, 0) AS progressSeconds,
            EXISTS (
              SELECT 1 FROM rssDownload AS download
              WHERE download.episodeId = episode.id AND download.state = 'completed'
            ) AS audioDownloaded,
            COALESCE(episode.lastSeenGeneration = feed.refreshGeneration, 0) AS isAvailableOnServer,
            \(keyset.selection)
          FROM rssEpisode AS episode
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
          WHERE episode.feedId = ?
            \(after.sql)
          \(keyset.ordering)
          LIMIT ?
          """,
        arguments: [feedID] + after.arguments + [limit + 1])
      let page = keyset.page(fetched, limit: limit)
      let rows = page.rows.compactMap { row -> PodcastEpisodePageRow? in
        guard let identity = ListeningIdentity.rssEpisode(feedID: feedID, episodeID: row["identityKey"])
        else { return nil }
        return PodcastEpisodePageRow(
          identity: identity, title: (row["title"] as String?) ?? "", publishedAt: row["publishedAt"],
          durationSeconds: row["durationSeconds"], isFinished: row["finished"],
          audioDownloaded: row["audioDownloaded"], isAvailableOnServer: row["isAvailableOnServer"],
          progressSeconds: row["progressSeconds"])
      }
      return AudioBrowsePage(rows: rows, next: page.next)
    }
  }
}
