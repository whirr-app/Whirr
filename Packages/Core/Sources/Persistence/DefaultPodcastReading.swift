import Foundation
import GRDB

/// Database-backed podcast projection. Each observation executes one tracked SQL statement and
/// maps its rows in memory; it never opens one query per episode.
public struct DefaultPodcastReading: PodcastReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// `removeDuplicates` is load-bearing: the show page renders every row
  /// from this single value, so byte-progress writes must not invalidate the whole page. The list
  /// selects no received-byte column at all, so those writes never intersect its tracked region;
  /// a downloading row reads as fraction `0` here and takes its live fraction from
  /// `observeEpisodeDownloadProgress`.
  public func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in try Self.fetchEpisodes(db, itemId: itemId) }
        .removeDuplicates())
  }

  public func episodePrefix(itemId: String, limit: Int) -> PodcastEpisodePrefix? {
    try? database.dbWriter.read { db in
      // An episode spans one row per download, so a row limit can cut the last episode's rows
      // short. Only the last episode can be cut, and only when the limit was reached.
      let rows = try Self.fetchEpisodeRows(db, itemId: itemId, rowLimit: limit)
      let episodes = Self.makeEpisodeSummaries(rows, quantizesPosition: true)
      guard rows.count >= limit else { return PodcastEpisodePrefix(episodes: episodes, isComplete: true) }
      return PodcastEpisodePrefix(episodes: Array(episodes.dropLast()), isComplete: false)
    }
  }

  private static func fetchEpisodes(_ db: Database, itemId: String) throws -> [PodcastEpisodeSummary] {
    makeEpisodeSummaries(
      try fetchEpisodeRows(db, itemId: itemId, rowLimit: nil), quantizesPosition: true)
  }

  private static func fetchEpisodeRows(_ db: Database, itemId: String, rowLimit: Int?) throws -> [Row] {
    try Row.fetchAll(
      db,
      sql: """
        WITH selectedItem AS (
          SELECT item.id, item.accountId
          FROM item
          JOIN library
            ON library.id = item.libraryId
            AND library.accountId = item.accountId
          WHERE serverItemId = ? AND \(ItemVisibilityPredicate.sql)
          ORDER BY item.accountId, item.id
          LIMIT 1
        )
        SELECT
          episode.id AS episodeRowId,
          episode.serverEpisodeId AS serverEpisodeId,
          episode.title AS title,
          episode.subtitle AS subtitle,
          episode.episodeDescription AS episodeDescription,
          episode.seasonNumber AS seasonNumber,
          episode.episodeNumber AS episodeNumber,
          episode.episodeType AS episodeType,
          episode.durationSeconds AS durationSeconds,
          episode.sizeBytes AS sizeBytes,
          episode.publishedAt AS publishedAt,
          episode.storedAudioIno AS storedAudioIno,
          episode.storedAudioExpectedSize AS storedAudioExpectedSize,
          episode.storedAudioMimeType AS storedAudioMimeType,
          episode.storedAudioDurationSeconds AS storedAudioDurationSeconds,
          progress.currentTime AS progressCurrentTime,
          progress.isFinished AS progressIsFinished,
          download.id AS downloadId,
          download.expectedBytes AS downloadExpectedBytes,
          download.state AS downloadState,
          download.holdReason AS downloadHoldReason,
          download.errorCategory AS downloadErrorCategory
        FROM podcastEpisode AS episode
        JOIN selectedItem
          ON selectedItem.id = episode.itemId
          AND selectedItem.accountId = episode.accountId
        LEFT JOIN mediaProgress AS progress
          ON progress.accountId = episode.accountId
          AND progress.itemId = episode.itemId
          AND progress.podcastEpisodeId = episode.id
        LEFT JOIN download
          ON download.accountId = episode.accountId
          AND download.itemId = episode.itemId
          AND download.podcastEpisodeId = episode.id
        WHERE episode.softDeleted = 0
        ORDER BY
          episode.publishedAt IS NULL ASC,
          episode.publishedAt DESC,
          episode.serverEpisodeId ASC,
          episode.id ASC,
          download.id ASC
        LIMIT ?
        """,
      // SQLite reads a negative limit as no limit.
      arguments: [itemId, rowLimit ?? -1])
  }

  public func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db -> [String: Double] in
          let rows = try Row.fetchAll(
            db,
            sql: """
              WITH selectedItem AS (
                SELECT item.id, item.accountId
                FROM item
                JOIN library
                  ON library.id = item.libraryId
                  AND library.accountId = item.accountId
                WHERE serverItemId = ? AND \(ItemVisibilityPredicate.sql)
                ORDER BY item.accountId, item.id
                LIMIT 1
              )
              SELECT
                episode.serverEpisodeId AS serverEpisodeId,
                download.expectedBytes AS expectedBytes,
                download.receivedBytes AS receivedBytes
              FROM download
              JOIN selectedItem
                ON selectedItem.id = download.itemId
                AND selectedItem.accountId = download.accountId
              JOIN podcastEpisode AS episode
                ON episode.id = download.podcastEpisodeId
                AND episode.softDeleted = 0
              WHERE download.state = ?
              """,
            arguments: [itemId, DownloadState.downloading.rawValue])
          // An episode may own more than one file row; the reducer sums them, so this does too.
          var totals: [String: (expected: Int64, received: Int64)] = [:]
          for row in rows {
            let episodeID: String = row["serverEpisodeId"]
            var total = totals[episodeID] ?? (0, 0)
            total.expected += (row["expectedBytes"] as Int64?) ?? 0
            total.received += (row["receivedBytes"] as Int64?) ?? 0
            totals[episodeID] = total
          }
          var progress: [String: Double] = [:]
          for (episodeID, total) in totals {
            guard
              let fraction = EpisodeDownloadProgressProjection.quantizedFraction(
                receivedBytes: total.received, expectedBytes: total.expected)
            else { continue }
            progress[episodeID] = fraction
          }
          return progress
        }
        .removeDuplicates())
  }

  /// Scoped like `episode(itemID:episodeID:)`, which it serves: no library-inclusion predicate.
  public func recentEpisodeDescriptions(itemId: String, limit: Int) async throws -> [String] {
    guard limit > 0 else { return [] }
    return try await database.readAsync { db in
      try String.fetchAll(
        db,
        sql: """
          WITH selectedItem AS (
            SELECT id, accountId
            FROM item
            WHERE serverItemId = ? AND softDeleted = 0
            ORDER BY accountId, id
            LIMIT 1
          )
          SELECT episode.episodeDescription
          FROM podcastEpisode AS episode
          JOIN selectedItem
            ON selectedItem.id = episode.itemId
            AND selectedItem.accountId = episode.accountId
          WHERE episode.softDeleted = 0
            AND episode.episodeDescription IS NOT NULL
            AND episode.episodeDescription <> ''
          ORDER BY
            episode.publishedAt IS NULL ASC,
            episode.publishedAt DESC,
            episode.serverEpisodeId ASC,
            episode.id ASC
          LIMIT ?
          """,
        arguments: [itemId, limit])
    }
  }

  /// This is the explicit detail/player lookup, not a discovery projection. It does not apply
  /// the library-inclusion predicate so a retained download or playback session remains
  /// resolvable after its library is excluded.
  public func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext? {
    try await database.readAsync { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          WITH selectedItem AS (
            SELECT id, accountId, title, author, serverUpdatedAt
            FROM item
            WHERE serverItemId = ? AND softDeleted = 0
            ORDER BY accountId, id
            LIMIT 1
          )
          SELECT
            episode.id AS episodeRowId,
            episode.serverEpisodeId AS serverEpisodeId,
            episode.title AS title,
            episode.subtitle AS subtitle,
            episode.episodeDescription AS episodeDescription,
            episode.seasonNumber AS seasonNumber,
            episode.episodeNumber AS episodeNumber,
            episode.episodeType AS episodeType,
            episode.durationSeconds AS durationSeconds,
            episode.sizeBytes AS sizeBytes,
            episode.publishedAt AS publishedAt,
            episode.storedAudioIno AS storedAudioIno,
            episode.storedAudioExpectedSize AS storedAudioExpectedSize,
            episode.storedAudioMimeType AS storedAudioMimeType,
            episode.storedAudioDurationSeconds AS storedAudioDurationSeconds,
            progress.currentTime AS progressCurrentTime,
            progress.isFinished AS progressIsFinished,
            download.id AS downloadId,
            download.expectedBytes AS downloadExpectedBytes,
            download.receivedBytes AS downloadReceivedBytes,
            download.state AS downloadState,
            download.holdReason AS downloadHoldReason,
            download.errorCategory AS downloadErrorCategory,
            selectedItem.title AS showTitle,
            selectedItem.author AS showAuthor,
            selectedItem.serverUpdatedAt AS showServerUpdatedAt
          FROM podcastEpisode AS episode
          JOIN selectedItem
            ON selectedItem.id = episode.itemId
            AND selectedItem.accountId = episode.accountId
          LEFT JOIN mediaProgress AS progress
            ON progress.accountId = episode.accountId
            AND progress.itemId = episode.itemId
            AND progress.podcastEpisodeId = episode.id
          LEFT JOIN download
            ON download.accountId = episode.accountId
            AND download.itemId = episode.itemId
            AND download.podcastEpisodeId = episode.id
          WHERE episode.softDeleted = 0
            AND episode.serverEpisodeId = ?
          ORDER BY download.id ASC
          """,
        arguments: [itemID, episodeID])
      // The join to `selectedItem` already constrains the episode to this item's (accountId, id),
      // so an episode of a different item never appears in `rows` and this single guard covers
      // both "unknown episode" and "episode of another item".
      // This lookup selects `receivedBytes`, so the summary carries exact progress: it feeds one
      // card, not a list. Its playback position stays exact for the same reason.
      guard let summary = Self.makeEpisodeSummaries(rows, quantizesPosition: false).first else {
        return nil
      }
      let first = rows[0]
      return PodcastEpisodeContext(
        episode: summary,
        showTitle: first["showTitle"],
        showAuthor: first["showAuthor"],
        artworkURL: nil,
        artworkFeedURL: nil,
        showServerUpdatedAt: first["showServerUpdatedAt"])
    }
  }

  public func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            WITH selectedItem AS (
              SELECT item.id
              FROM item
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              WHERE serverItemId = ? AND \(ItemVisibilityPredicate.sql)
              ORDER BY item.accountId, item.id
              LIMIT 1
            )
            SELECT
              podcastAutoDownloadEpisodes AS autoDownloadEpisodes,
              podcastAutoDownloadSchedule AS autoDownloadSchedule,
              podcastLastEpisodeCheck AS lastEpisodeCheck,
              podcastMaxEpisodesToKeep AS maxEpisodesToKeep,
              podcastMaxNewEpisodesToDownload AS maxNewEpisodesToDownload
            FROM item
            WHERE id = (SELECT id FROM selectedItem)
            """,
          arguments: [itemId])
      else { return nil }
      return PodcastShowDiagnostics(
        autoDownloadEpisodes: row["autoDownloadEpisodes"],
        autoDownloadSchedule: row["autoDownloadSchedule"],
        lastEpisodeCheck: row["lastEpisodeCheck"],
        maxEpisodesToKeep: row["maxEpisodesToKeep"],
        maxNewEpisodesToDownload: row["maxNewEpisodesToDownload"])
    }
  }

  /// The server shows that are the same feed as a followed one: every visible item of the current
  /// account whose stored fingerprint equals `podcastFeedFingerprint`, in the same
  /// non-soft-deleted, included libraries every other item read uses. It runs on the existing
  /// `(accountId, podcastFeedFingerprint)` index and sees a known-empty show too, because it reads
  /// the item row rather than its episodes. A malformed fingerprint matches nothing.
  public func observeServerCopyItemIDs(podcastFeedFingerprint: String) -> AsyncStream<[String]> {
    guard let fingerprint = PodcastFeedIdentity.validatedFingerprint(podcastFeedFingerprint) else {
      return ObservationBridge.stream(in: database.dbWriter) { _ in [String]() }
    }
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db -> [String] in
          guard let accountId = try AccountRecord.fetchOne(db)?.id else { return [] }
          return try String.fetchAll(
            db,
            sql: """
              SELECT item.serverItemId
              FROM item
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              WHERE item.accountId = ?
                AND item.podcastFeedFingerprint = ?
                AND item.mediaKind = 'podcast'
                AND \(ItemVisibilityPredicate.sql)
              ORDER BY item.serverItemId
              """,
            arguments: [accountId, fingerprint])
        }
        .removeDuplicates())
  }

  /// Rows without a `downloadReceivedBytes` column (the list) reduce a downloading episode to
  /// fraction `0`; the explicit episode lookup selects it and reduces to the exact fraction. The
  /// list floors its playback position through `PlaybackPositionListProjection` likewise.
  private static func makeEpisodeSummaries(
    _ rows: [Row], quantizesPosition: Bool
  ) -> [PodcastEpisodeSummary] {
    var result: [PodcastEpisodeSummary] = []
    var index = rows.startIndex
    while index < rows.endIndex {
      let first = rows[index]
      let episodeRowId: Int64 = first["episodeRowId"]
      var downloads: [DownloadStatusProjection] = []
      var next = index
      while next < rows.endIndex {
        let row = rows[next]
        guard (row["episodeRowId"] as Int64) == episodeRowId else { break }
        if row["downloadId"] as Int64? != nil,
          let stateRaw = row["downloadState"] as String?,
          let state = DownloadState(rawValue: stateRaw)
        {
          downloads.append(
            DownloadStatusProjection(
              expectedBytes: (row["downloadExpectedBytes"] as Int64?) ?? 0,
              receivedBytes: (row["downloadReceivedBytes"] as Int64?) ?? 0,
              state: state,
              holdReason: (row["downloadHoldReason"] as String?).flatMap(DownloadHoldReason.init(rawValue:)),
              errorCategory: (row["downloadErrorCategory"] as String?).flatMap(
                DownloadErrorCategory.init(rawValue:))))
        }
        next += 1
      }

      let position = (first["progressCurrentTime"] as Double?) ?? 0
      let progressSeconds =
        quantizesPosition ? PlaybackPositionListProjection.quantizedSeconds(position) : position
      let isFinished = (first["progressIsFinished"] as Bool?) ?? false
      let (isAvailableOnServer, durationSeconds) = storedAudio(first)

      let projectedDownloadStatus = DownloadStatusReducer.reduce(downloads)

      result.append(
        PodcastEpisodeSummary(
          id: first["serverEpisodeId"],
          title: first["title"],
          subtitle: first["subtitle"],
          episodeDescription: first["episodeDescription"],
          seasonNumber: first["seasonNumber"],
          episodeNumber: first["episodeNumber"],
          episodeType: first["episodeType"],
          durationSeconds: durationSeconds,
          sizeBytes: first["sizeBytes"],
          publishedAt: first["publishedAt"],
          progressSeconds: progressSeconds,
          isPlayed: progressSeconds > 0 || isFinished,
          isFinished: isFinished,
          downloadStatus: projectedDownloadStatus,
          isAvailableOnServer: isAvailableOnServer,
          isDownloadSizeKnown: true))
      index = next
    }
    return result
  }

  /// Whether the server holds a streamable file for the episode, and the duration to show: the
  /// stored file's when it has one, else the feed's claim.
  static func storedAudio(_ row: Row) -> (isAvailableOnServer: Bool, durationSeconds: Double?) {
    let ino = row["storedAudioIno"] as String?
    let expectedSize = row["storedAudioExpectedSize"] as Int?
    let mimeType = row["storedAudioMimeType"] as String?
    let duration = row["storedAudioDurationSeconds"] as Double?
    let hasDuration = (duration ?? 0).isFinite && (duration ?? 0) > 0
    let isAvailable =
      ino?.isEmpty == false && (expectedSize ?? 0) > 0 && mimeType?.isEmpty == false && hasDuration
    return (isAvailable, hasDuration ? duration : (row["durationSeconds"] as Double?))
  }

}
