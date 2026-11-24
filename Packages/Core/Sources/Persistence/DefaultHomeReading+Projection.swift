import Foundation
import GRDB

extension DefaultHomeReading {
  static func categoryPredicateSQL(_ category: ItemMediaCategory?) -> String {
    ItemCategoryPredicate.sql(category)
  }

  static func filterCategoryPredicateSQL(_ category: ItemMediaCategory?) -> String {
    ItemFilterCategoryPredicate.sql(category)
  }

  static func recentlyAddedCandidateCTE(
    name: String,
    policyRank: Int,
    category: ItemMediaCategory?,
    extraPredicateSQL: String
  ) -> String {
    """
    \(name) AS (
      SELECT
        item.serverItemId AS serverItemId, item.title AS title, item.author AS author,
        item.mediaKind AS mediaKind, item.numAudioFiles AS numAudioFiles,
        item.ebookFormat AS ebookFormat, item.durationSeconds AS durationSeconds,
        item.seriesName AS seriesName, item.narratorName AS narratorName,
        item.expandedMetadataFetchedAt AS expandedMetadataFetchedAt,
        item.serverUpdatedAt AS itemServerUpdatedAt,
        item.addedAt AS addedAt, item.id AS itemRowId,
        \(Self.downloadCompletionSQL) AS isDownloaded,
        downloadItemRollup.audioDownloaded AS audioDownloaded,
        downloadItemRollup.ebookDownloaded AS ebookDownloaded,
        NULL AS episodeID, NULL AS episodeTitle,
        mediaProgress.currentTime AS progressCurrentTime,
        mediaProgress.ebookProgress AS ebookProgress,
        mediaProgress.isFinished AS progressIsFinished,
        \(policyRank) AS policyRank
      FROM item
      JOIN library
        ON library.id = item.libraryId
        AND library.accountId = item.accountId
      LEFT JOIN mediaProgress
        ON mediaProgress.itemId = item.id AND mediaProgress.podcastEpisodeId IS NULL
      LEFT JOIN downloadItemRollup
        ON downloadItemRollup.itemId = item.id
      WHERE item.accountId = ?
        AND \(ItemVisibilityPredicate.sql)
        AND \(PodcastCatalogueVisibilityPredicate.sql)
        AND (? IS NULL OR item.addedAt >= ?)
        AND (\(Self.filterCategoryPredicateSQL(category)))
    \(extraPredicateSQL)
      ORDER BY item.addedAt DESC, item.id ASC
      LIMIT ?
    )
    """
  }

  static func newPodcastCandidateCTE(
    name: String,
    policyRank: Int,
    extraPredicateSQL: String
  ) -> String {
    """
    \(name) AS (
      SELECT
        item.serverItemId AS itemID,
        item.title AS showTitle,
        item.author AS showAuthor,
        item.serverUpdatedAt AS showServerUpdatedAt,
        episode.serverEpisodeId AS episodeID,
        episode.title AS episodeTitle,
        episode.subtitle AS episodeSubtitle,
        episode.publishedAt AS publishedAt,
        episode.durationSeconds AS durationSeconds,
        progress.currentTime AS progressCurrentTime,
        progress.isFinished AS progressIsFinished,
        \(policyRank) AS policyRank,
        item.id AS itemRowId,
        episode.id AS episodeRowId
      FROM podcastEpisode AS episode
      JOIN item
        ON item.id = episode.itemId
        AND item.accountId = episode.accountId
      JOIN library
        ON library.id = item.libraryId
        AND library.accountId = item.accountId
      LEFT JOIN mediaProgress AS progress
        ON progress.accountId = episode.accountId
        AND progress.itemId = episode.itemId
        AND progress.podcastEpisodeId = episode.id
      JOIN account AS currentAccount
        ON currentAccount.id = item.accountId
      WHERE currentAccount.id = ?
        AND episode.softDeleted = 0
        AND \(ItemVisibilityPredicate.sql)
        AND item.mediaKind = 'podcast'
        AND episode.publishedAt >= ?
        AND COALESCE(progress.isFinished, 0) = 0
        AND (
          progress.currentTime IS NULL
          OR episode.durationSeconds IS NULL
          OR episode.durationSeconds <= 0
          OR episode.durationSeconds - progress.currentTime
            >= \(Self.minimumRemainingSeconds)
        )
    \(extraPredicateSQL)
      ORDER BY episode.publishedAt DESC, episode.serverEpisodeId ASC,
        item.serverItemId ASC, episode.id ASC
      LIMIT ?
    )
    """
  }

  static func validFingerprintSQL(_ column: String) -> String {
    "length(\(column)) = \(PodcastFeedIdentity.fingerprintCharacterCount) AND "
      + "\(column) NOT GLOB '*[^0-9a-f]*'"
  }

  /// "When did this device last touch the item", the only key that answers what the Home
  /// carousels ask. `serverUpdatedAt` moves only when a server observation wins a merge, so it
  /// stays frozen for a whole listen; `localSequence` counts edits to one row and cannot be
  /// compared across rows. `lastActivityAt` is stamped by every local write; the `COALESCE`
  /// covers any row whose stamp predates the v26 backfill.
  static func recency(_ alias: String) -> String {
    "COALESCE(\(alias).lastActivityAt, \(alias).serverUpdatedAt)"
  }

  /// One scan computes every item's per-medium download completeness. The second rollup folds
  /// those medium rows into the item-level badge and the Downloads-shelf membership (item media
  /// only, so a supplement PDF never makes a book "downloaded"). Avoids N+1 queries and
  /// correlated full-table scans, since the schema has no general item-only download index.
  static let downloadRollupCTE = """
    downloadRollup AS (
      SELECT
        itemId,
        mediaKind,
        MAX(CASE WHEN state <> 'deleting' THEN 1 ELSE 0 END) AS hasLive,
        MAX(
          CASE WHEN state NOT IN ('completed', 'deleting') THEN 1 ELSE 0 END
        ) AS hasIncomplete
      FROM download
      GROUP BY itemId, mediaKind
    ),
    downloadItemRollup AS (
      SELECT
        itemId,
        MAX(CASE WHEN mediaKind IN ('audio', 'ebook') THEN hasLive ELSE 0 END) AS hasLive,
        MAX(CASE WHEN mediaKind IN ('audio', 'ebook') THEN hasIncomplete ELSE 0 END)
          AS hasIncomplete,
        MAX(
          CASE
            WHEN mediaKind IN ('audio', 'ebook') AND hasLive = 1 AND hasIncomplete = 0 THEN 1
            ELSE 0
          END
        ) AS hasCompletedKind,
        MAX(
          CASE
            WHEN mediaKind = 'audio' AND hasLive = 1 AND hasIncomplete = 0 THEN 1
            ELSE 0
          END
        ) AS audioDownloaded,
        MAX(
          CASE
            WHEN mediaKind = 'ebook' AND hasLive = 1 AND hasIncomplete = 0 THEN 1
            ELSE 0
          END
        ) AS ebookDownloaded,
        MAX(
          CASE
            WHEN mediaKind = 'supplement' AND hasLive = 1 AND hasIncomplete = 0 THEN 1
            ELSE 0
          END
        ) AS supplementDownloaded
      FROM downloadRollup
      GROUP BY itemId
    )
    """

  /// The item-level "complete" rule `DownloadStore.status(rows:)` and
  /// `ItemFilterPredicate.itemDownloadedOnly` express: at least one non-`deleting` row exists and
  /// every such row, across every requested medium, is `completed`. Selecting only rollup state
  /// here keeps received-byte-only writes out of these observations' tracked region.
  static let downloadCompletionSQL = """
    COALESCE(downloadItemRollup.hasLive = 1 AND downloadItemRollup.hasIncomplete = 0, 0)
    """

  struct SeriesCandidate {
    let normalizedName: String
    let sequence: String?
    let sequenceValue: Double?
    let sortTitle: String
    let item: HomeItem
    let isFinished: Bool
    let currentTime: Double
    let ebookProgress: Double
    let progressRecency: Date?
    let onlyShowLaterBooksInContinueSeries: Bool
  }

  static func seriesCandidatePrecedes(
    _ lhs: SeriesCandidate, _ rhs: SeriesCandidate
  ) -> Bool {
    switch (lhs.sequenceValue, rhs.sequenceValue) {
    case (let left?, let right?) where left != right:
      return left < right
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      break
    }

    if lhs.sequence != rhs.sequence {
      return (lhs.sequence ?? "") < (rhs.sequence ?? "")
    }
    if lhs.sortTitle != rhs.sortTitle {
      return lhs.sortTitle < rhs.sortTitle
    }
    return lhs.item.serverItemId < rhs.item.serverItemId
  }

  static func makeHomeItem(_ row: Row) -> HomeItem {
    let mediaKind: String = row["mediaKind"]
    let ebookFormat: String? = row["ebookFormat"]
    let category = ItemMediaCategory.derive(
      mediaKind: mediaKind,
      numAudioFiles: row["numAudioFiles"],
      ebookFormat: ebookFormat
    )
    return HomeItem(
      serverItemId: row["serverItemId"],
      title: row["title"],
      author: row["author"],
      category: category,
      hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: ebookFormat),
      durationSeconds: row["durationSeconds"],
      progressSeconds: PlaybackPositionListProjection.quantizedSeconds((row["progressCurrentTime"] as Double?) ?? 0),
      ebookProgress: (row["ebookProgress"] as Double?) ?? 0,
      isFinished: (row["progressIsFinished"] as Bool?) ?? false,
      addedAt: row["addedAt"],
      isDownloaded: row["isDownloaded"],
      seriesName: row["seriesName"],
      narratorName: row["narratorName"],
      expandedMetadataFetchedAt: row["expandedMetadataFetchedAt"],
      episodeID: row["episodeID"],
      episodeTitle: row["episodeTitle"],
      audioDownloaded: (row["audioDownloaded"] as Bool?) ?? false,
      ebookDownloaded: (row["ebookDownloaded"] as Bool?) ?? false,
      supplementDownloaded: row.hasColumn("supplementDownloaded")
        ? (row["supplementDownloaded"] as Bool?) ?? false : false,
      progressRecency: row.hasColumn("progressRecency") ? row["progressRecency"] as Date? : nil,
      serverUpdatedAt: row.hasColumn("itemServerUpdatedAt")
        ? row["itemServerUpdatedAt"] as Date? : nil
    )
  }

}
