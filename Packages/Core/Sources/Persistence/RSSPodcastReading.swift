import Foundation
import GRDB

/// The RSS transposition of `DefaultPodcastReading`, over device-owned RSS tables. Each
/// observation executes one tracked SQL statement and maps its rows in memory. It exposes
/// episode, show-list, and show-diagnostics projections for the RSS-backed Podcasts tab.
public struct RSSPodcastReading: PodcastReading, NativePodcastShowsReading, Sendable {
  let database: AppDatabase
  static let showColumns = """
    feed.id, feed.title, feed.author, feed.synopsis, feed.subscribedAt,
    feed.feedURL, feed.artworkURL, feed.podcastFeedFingerprint
    """

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Every followed feed as the shared show-list currency, in the device's durable native order.
  public func observeShows() -> AsyncStream<NativePodcastShowsSnapshot> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      let mode = try RSSFeedStore.sortMode(db)
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT \(Self.showColumns)
          FROM rssFeed AS feed
          \(Self.latestEpisodeJoin(mode: mode))
          \(Self.showKeyset(mode: mode).ordering)
          """)
      let shows = rows.compactMap(Self.makeShowSummary)
      return NativePodcastShowsSnapshot(mode: mode, shows: shows)
    }
  }

  public func observeShow(itemId: String) -> AsyncStream<ItemSummary?> {
    guard let feedId = Self.rssFeedId(from: itemId) else {
      return ObservationBridge.stream(in: database.dbWriter) { _ in nil }
    }
    return ObservationBridge.stream(in: database.dbWriter) { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT \(Self.showColumns)
            FROM rssFeed AS feed
            WHERE feed.id = ?
            """,
          arguments: [feedId])
      else { return nil }
      return Self.makeShowSummary(row)
    }
  }

  /// `removeDuplicates` is needed because this is a joined query: GRDB re-runs it for every write
  /// to `rssEpisode`, `rssFeed`, `rssEpisodeState`, or `rssDownload` (for any feed), and the show
  /// screen renders every row from the one array it yields. The list selects no byte column, so a
  /// transfer's progress writes never intersect its tracked region. A downloading row reads as
  /// fraction `0` here and takes its live fraction from `observeEpisodeDownloadProgress`.
  public func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]> {
    guard let feedId = Self.rssFeedId(from: itemId) else {
      return ObservationBridge.stream(in: database.dbWriter) { _ in [] }
    }
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          try Self.fetchRows(db, feedId: feedId).map { Self.makeSummary($0, quantizesPosition: true) }
        }
        .removeDuplicates())
  }

  public func episodePrefix(itemId: String, limit: Int) -> PodcastEpisodePrefix? {
    guard let feedId = Self.rssFeedId(from: itemId) else {
      return PodcastEpisodePrefix(episodes: [], isComplete: true)
    }
    return try? database.dbWriter.read { db in
      // One extra row tells a list of exactly `limit` episodes from a longer one.
      let rows = try Self.fetchRows(db, feedId: feedId, limit: limit + 1)
      return PodcastEpisodePrefix(
        episodes: rows.prefix(limit).map { Self.makeSummary($0, quantizesPosition: true) },
        isComplete: rows.count <= limit)
    }
  }

  public func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]> {
    guard let feedId = Self.rssFeedId(from: itemId) else {
      return ObservationBridge.stream(in: database.dbWriter) { _ in [:] }
    }
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db -> [String: Double] in
          let rows = try Row.fetchAll(
            db,
            sql: """
              SELECT
                episode.identityKey AS identityKey,
                download.expectedBytes AS expectedBytes,
                download.actualBytes AS actualBytes
              FROM rssDownload AS download
              JOIN rssEpisode AS episode ON episode.id = download.episodeId
              WHERE episode.feedId = ? AND download.state = ?
              """,
            arguments: [feedId, DownloadState.downloading.rawValue])
          var progress: [String: Double] = [:]
          for row in rows {
            guard
              let fraction = EpisodeDownloadProgressProjection.quantizedFraction(
                receivedBytes: (row["actualBytes"] as Int64?) ?? 0,
                expectedBytes: (row["expectedBytes"] as Int64?) ?? 0)
            else { continue }
            progress[row["identityKey"]] = fraction
          }
          return progress
        }
        .removeDuplicates())
  }

  public func recentEpisodeDescriptions(itemId: String, limit: Int) async throws -> [String] {
    guard let feedId = Self.rssFeedId(from: itemId), limit > 0 else { return [] }
    return try await database.readAsync { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT synopsis
          FROM rssEpisode AS episode
          WHERE episode.feedId = ? AND episode.synopsis IS NOT NULL AND episode.synopsis <> ''
          ORDER BY episode.publishedAt IS NULL ASC, episode.publishedAt DESC, episode.id ASC
          LIMIT ?
          """,
        arguments: [feedId, limit])
    }
  }

  public func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext? {
    guard let feedId = Self.rssFeedId(from: itemID) else { return nil }
    // The downloaded file's length where there is one, as the player and Continue Listening read
    // it: the card's remainder is measured against the position, which is on the file's timeline.
    let duration = RSSDownloadDurationStore.preferredDurationSQL(episode: "episode", download: "download")
    return try await database.readAsync { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT
              episode.identityKey AS identityKey,
              episode.title AS title,
              episode.synopsis AS synopsis,
              episode.synopsisLine AS synopsisLine,
              episode.seasonNumber AS seasonNumber,
              episode.episodeNumber AS episodeNumber,
              \(duration) AS durationSeconds,
              episode.declaredBytes AS declaredBytes,
              episode.publishedAt AS publishedAt,
              episode.lastSeenGeneration AS lastSeenGeneration,
              state.position AS position,
              state.finished AS finished,
              download.id AS downloadId,
              download.expectedBytes AS expectedBytes,
              download.actualBytes AS actualBytes,
              download.state AS downloadState,
              download.holdReason AS holdReason,
              download.errorCode AS errorCode,
              feed.refreshGeneration AS refreshGeneration,
              feed.title AS showTitle,
              feed.author AS showAuthor,
              feed.artworkURL AS artworkURL,
              feed.feedURL AS artworkFeedURL,
              episode.artworkURL AS episodeArtworkURL
            FROM rssEpisode AS episode
            JOIN rssFeed AS feed ON feed.id = episode.feedId
            LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
            LEFT JOIN rssDownload AS download ON download.episodeId = episode.id
            WHERE episode.feedId = ? AND episode.identityKey = ?
            """,
          arguments: [feedId, episodeID])
      else { return nil }
      return PodcastEpisodeContext(
        // The explicit lookup selects `actualBytes`, so progress and playback position stay exact.
        // It feeds one card, not a list.
        episode: Self.makeSummary(row, quantizesPosition: false),
        showTitle: (row["showTitle"] as String?) ?? "",
        showAuthor: row["showAuthor"],
        artworkURL: (row["artworkURL"] as String?).flatMap(URL.init(string:)),
        artworkFeedURL: (row["artworkFeedURL"] as String?).flatMap(URL.init(string:)),
        episodeArtworkURL: (row["episodeArtworkURL"] as String?).flatMap(URL.init(string:)))
    }
  }

  public func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?> {
    guard let feedId = Self.rssFeedId(from: itemId) else {
      return ObservationBridge.stream(in: database.dbWriter) { _ in nil }
    }
    return ObservationBridge.stream(in: database.dbWriter) { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT feed.lastRefreshedAt AS lastRefreshedAt,
                   settings.autoDownload AS autoDownload,
                   settings.keepLatest AS keepLatest
            FROM rssFeed AS feed
            LEFT JOIN rssFeedSettings AS settings ON settings.feedId = feed.id
            WHERE feed.id = ?
            """,
          arguments: [feedId])
      else { return nil }

      let autoDownload: Bool? =
        switch row["autoDownload"] as String? {
        case "enabled": true
        case "disabled": false
        default:
          // Inherit, unknown and absent settings need global context; nil means not explicit.
          nil
        }
      return PodcastShowDiagnostics(
        autoDownloadEpisodes: autoDownload,
        // RSS has no counterpart for an auto-download schedule.
        autoDownloadSchedule: nil,
        lastEpisodeCheck: row["lastRefreshedAt"],
        // Zero is meaningful here: it means keep all episodes, not “unset”.
        maxEpisodesToKeep: row["keepLatest"],
        maxNewEpisodesToDownload: nil)
    }
  }

  /// The list never selects `synopsis`: rows draw `synopsisLine`, and the HTML description would
  /// otherwise be decoded and compared for every row on every emission. The card reads it through
  /// `episode(itemID:episodeID:)`.
  private static func fetchRows(_ db: Database, feedId: Int64, limit: Int? = nil) throws -> [Row] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT
          episode.identityKey AS identityKey,
          episode.title AS title,
          episode.synopsisLine AS synopsisLine,
          episode.seasonNumber AS seasonNumber,
          episode.episodeNumber AS episodeNumber,
          episode.durationSeconds AS durationSeconds,
          episode.declaredBytes AS declaredBytes,
          episode.publishedAt AS publishedAt,
          episode.lastSeenGeneration AS lastSeenGeneration,
          state.position AS position,
          state.finished AS finished,
          download.id AS downloadId,
          download.expectedBytes AS expectedBytes,
          download.state AS downloadState,
          download.holdReason AS holdReason,
          download.errorCode AS errorCode,
          feed.refreshGeneration AS refreshGeneration
        FROM rssEpisode AS episode
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
        LEFT JOIN rssDownload AS download ON download.episodeId = episode.id
        WHERE episode.feedId = ?
        ORDER BY episode.publishedAt IS NULL ASC, episode.publishedAt DESC, episode.id ASC
        LIMIT ?
        """,
      // SQLite reads a negative limit as no limit.
      arguments: [feedId, limit ?? -1])
  }

  static func makeShowSummary(_ row: Row) -> ItemSummary? {
    let feedId: Int64 = row["id"]
    guard let itemId = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else { return nil }
    return ItemSummary(
      serverItemId: itemId,
      mediaKind: "podcast",
      // Pre-first-refresh feeds may be untitled; the shared summary requires a string.
      title: (row["title"] as String?) ?? "",
      author: row["author"],
      durationSeconds: nil,
      progressSeconds: 0,
      category: .podcast,
      hasReadableEbook: false,
      addedAt: row["subscribedAt"],
      seriesName: nil,
      narratorName: nil,
      // This means “ABS expanded metadata fetched”; feed refresh must not fake that signal.
      expandedMetadataFetchedAt: nil,
      itemDescription: row["synopsis"],
      podcastFeedFingerprint:
        PodcastFeedIdentity.validatedFingerprint(row["podcastFeedFingerprint"] as String?),
      artworkURL: (row["artworkURL"] as String?).flatMap(URL.init(string:)),
      artworkFeedURL: (row["feedURL"] as String?).flatMap(URL.init(string:)))
  }

  /// A row without an `actualBytes` column (the list) reduces to fraction `0`; the explicit
  /// episode lookup selects it and gets the exact fraction. The list also floors its playback
  /// position through `PlaybackPositionListProjection`.
  private static func makeSummary(_ row: Row, quantizesPosition: Bool) -> PodcastEpisodeSummary {
    let position = (row["position"] as Double?) ?? 0
    let progressSeconds =
      quantizesPosition ? PlaybackPositionListProjection.quantizedSeconds(position) : position
    let isFinished = (row["finished"] as Bool?) ?? false
    let projectedDownloadStatus = DownloadStatusReducer.reduce(Self.downloadProjections(from: row))
    return PodcastEpisodeSummary(
      id: row["identityKey"],
      // RSS titles are optional, but the shared summary's title is non-optional.
      title: (row["title"] as String?) ?? "",
      subtitle: nil,
      episodeDescription: row["synopsis"],
      seasonNumber: (row["seasonNumber"] as Int?).map(String.init),
      episodeNumber: (row["episodeNumber"] as Int?).map(String.init),
      episodeType: nil,
      durationSeconds: row["durationSeconds"],
      sizeBytes: (row["declaredBytes"] as Int64?).map(Int.init),
      publishedAt: row["publishedAt"],
      progressSeconds: progressSeconds,
      isPlayed: progressSeconds > 0 || isFinished,
      isFinished: isFinished,
      downloadStatus: projectedDownloadStatus,
      // RSS availability means the origin still lists this episode. Retained episodes can remain
      // playable after disappearing from a feed, but their enclosure is no longer available.
      isAvailableOnServer: (row["lastSeenGeneration"] as Int64?)
        == (row["refreshGeneration"] as Int64?),
      isDownloadSizeKnown: ((row["expectedBytes"] as Int64?) ?? 0) > 0,
      synopsisLine: row["synopsisLine"])
  }

  static func rssFeedId(from itemId: String) -> Int64? {
    guard let feedId = PodcastSourceIdentity(itemId: itemId)?.rssFeedId else { return nil }
    return feedId
  }

  private static func downloadProjections(from row: Row) -> [DownloadStatusProjection] {
    guard
      row["downloadId"] as Int64? != nil,
      let rawState = row["downloadState"] as String?,
      let state = DownloadState(rawValue: rawState)
    else { return [] }
    return [
      DownloadStatusProjection(
        expectedBytes: (row["expectedBytes"] as Int64?) ?? 0,
        receivedBytes: (row["actualBytes"] as Int64?) ?? 0,
        state: state,
        holdReason: (row["holdReason"] as String?).flatMap { raw in
          raw == RSSDownloadHoldReason.waitingForWiFi.rawValue ? .waitingForWiFi : nil
        },
        errorCategory: (row["errorCode"] as String?).flatMap(DownloadErrorCategory.init(rawValue:)))
    ]
  }
}
