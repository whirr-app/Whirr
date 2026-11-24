import Foundation
import GRDB

/// The mixed-media projection used by Saved for Later. Whole-item saves populate `itemSummary`;
/// episode saves populate `episode`. `subjectTitle` and `contextTitle` stay explicit because an
/// episode's title is its subject even when it has no progress state.
public struct SavedShelfItem: Sendable, Equatable, Identifiable {
  public var id: SavedShelfIdentity { identity }
  public let identity: SavedShelfIdentity
  public let savedAt: Date
  public let subjectTitle: String
  public let contextTitle: String?
  public let category: ItemMediaCategory
  public let itemSummary: ItemSummary?
  public let episode: HomePodcastEpisode?
  public let isUnavailable: Bool

  public init(
    identity: SavedShelfIdentity,
    savedAt: Date,
    subjectTitle: String,
    contextTitle: String?,
    category: ItemMediaCategory,
    itemSummary: ItemSummary?,
    episode: HomePodcastEpisode?,
    isUnavailable: Bool
  ) {
    self.identity = identity
    self.savedAt = savedAt
    self.subjectTitle = subjectTitle
    self.contextTitle = contextTitle
    self.category = category
    self.itemSummary = itemSummary
    self.episode = episode
    self.isUnavailable = isUnavailable
  }
}

public protocol SavedShelfReading: Sendable {
  func observeSaved(filter: ItemMediaCategory?, limit: Int?) -> AsyncStream<[SavedShelfItem]>
  func observeSavedIdentities() -> AsyncStream<Set<SavedShelfIdentity>>
}

public struct NoOpSavedShelfReading: SavedShelfReading, Sendable {
  public init() {}

  public func observeSaved(
    filter: ItemMediaCategory?, limit: Int?
  ) -> AsyncStream<[SavedShelfItem]> {
    AsyncStream { $0.finish() }
  }

  public func observeSavedIdentities() -> AsyncStream<Set<SavedShelfIdentity>> {
    AsyncStream { $0.finish() }
  }
}

/// The account-scoped Saved for Later read store. Its projections retain item and
/// episode tombstones: a saved identity remains visible and removable after reversible deletion.
public struct DefaultSavedShelfReading: SavedShelfReading, Sendable {
  private let database: AppDatabase
  private let accountId: Int64?

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
  }

  /// Native mode excludes account-owned rows.
  public init(database: AppDatabase) {
    self.database = database
    self.accountId = nil
  }

  public func observeSaved(
    filter: ItemMediaCategory?, limit: Int?
  ) -> AsyncStream<[SavedShelfItem]> {
    let categoryPredicate = ItemFilterCategoryPredicate.sql(filter)
    // A device-owned episode has no `item` row to derive a category from: it is a podcast
    // episode by construction, so it belongs to the unfiltered and podcast shelves only.
    let nativePredicate = (filter == nil || filter == .podcast) ? "1 = 1" : "0 = 1"
    let limitSQL = limit == nil ? "" : "\nLIMIT ?"

    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db -> [SavedShelfItem] in
          var arguments = StatementArguments()
          if let limit {
            arguments += StatementArguments([max(0, limit)])
          }

          let rows = try Row.fetchAll(
            db,
            sql: """
              SELECT
                saved.id AS savedID,
                saved.savedAt AS savedAt,
                saved.podcastEpisodeId AS episodeRowID,
                saved.subjectTitle AS savedSubjectTitle,
                saved.contextTitle AS savedContextTitle,
                item.serverItemId AS itemID,
                item.mediaKind AS itemMediaKind,
                item.title AS itemTitle,
                item.author AS itemAuthor,
                item.durationSeconds AS itemDurationSeconds,
                item.ebookFormat AS itemEbookFormat,
                item.addedAt AS itemAddedAt,
                item.seriesName AS itemSeriesName,
                item.narratorName AS itemNarratorName,
                item.expandedMetadataFetchedAt AS itemExpandedMetadataFetchedAt,
                item.serverUpdatedAt AS itemServerUpdatedAt,
                item.itemDescription AS itemDescription,
                item.numAudioFiles AS itemNumAudioFiles,
                item.softDeleted AS itemSoftDeleted,
                itemProgress.currentTime AS itemProgressSeconds,
                episode.serverEpisodeId AS episodeID,
                episode.title AS episodeTitle,
                episode.subtitle AS episodeSubtitle,
                episode.publishedAt AS episodePublishedAt,
                episode.durationSeconds AS episodeDurationSeconds,
                episode.softDeleted AS episodeSoftDeleted,
                episodeProgress.currentTime AS episodeProgressSeconds,
                episodeProgress.isFinished AS episodeProgressIsFinished,
                rssEpisode.feedId AS rssFeedID,
                rssEpisode.identityKey AS rssEpisodeID,
                rssEpisode.title AS rssEpisodeTitle,
                rssEpisode.publishedAt AS rssPublishedAt,
                rssEpisode.durationSeconds AS rssDurationSeconds,
                rssEpisode.lastSeenGeneration AS rssLastSeenGeneration,
                rssFeed.title AS rssFeedTitle,
                rssFeed.author AS rssFeedAuthor,
                rssFeed.feedURL AS rssFeedURL,
                rssFeed.artworkURL AS rssArtworkURL,
                rssFeed.refreshGeneration AS rssRefreshGeneration,
                rssState.position AS rssProgressSeconds,
                rssState.finished AS rssProgressIsFinished
              FROM (
                SELECT id, accountId, itemId, podcastEpisodeId, NULL AS nativeRSS,
                       NULL AS rssEpisodeId, savedAt, subjectTitle, contextTitle
                FROM savedShelfEntry WHERE accountId = ?
                UNION ALL
                SELECT -id AS id, NULL AS accountId, NULL AS itemId, NULL AS podcastEpisodeId,
                       1 AS nativeRSS, rssEpisodeId, savedAt, subjectTitle, contextTitle
                FROM rssSavedShelfEntry
              ) AS saved
              LEFT JOIN item
                ON item.id = saved.itemId
                AND item.accountId = saved.accountId
              LEFT JOIN podcastEpisode AS episode
                ON episode.id = saved.podcastEpisodeId
                AND episode.itemId = saved.itemId
                AND episode.accountId = saved.accountId
              LEFT JOIN mediaProgress AS itemProgress
                ON itemProgress.itemId = saved.itemId
                AND itemProgress.accountId = saved.accountId
                AND itemProgress.podcastEpisodeId IS NULL
              LEFT JOIN mediaProgress AS episodeProgress
                ON episodeProgress.itemId = saved.itemId
                AND episodeProgress.accountId = saved.accountId
                AND episodeProgress.podcastEpisodeId = saved.podcastEpisodeId
              LEFT JOIN rssEpisode ON rssEpisode.id = saved.rssEpisodeId
              LEFT JOIN rssFeed ON rssFeed.id = rssEpisode.feedId
              LEFT JOIN rssEpisodeState AS rssState ON rssState.episodeId = saved.rssEpisodeId
              WHERE (
                  (rssEpisode.id IS NOT NULL AND (\(nativePredicate)))
                  OR (item.id IS NOT NULL AND (\(categoryPredicate)))
                )
              ORDER BY saved.savedAt DESC, saved.id DESC\(limitSQL)
              """,
            arguments: StatementArguments([accountId]) + arguments)
          return rows.compactMap(Self.makeItem)
        }
        .removeDuplicates())
  }

  public func observeSavedIdentities() -> AsyncStream<Set<SavedShelfIdentity>> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db -> Set<SavedShelfIdentity> in
          let rows = try Row.fetchAll(
            db,
            sql: """
              SELECT
                item.serverItemId AS itemID,
                episode.serverEpisodeId AS episodeID,
                rssEpisode.feedId AS rssFeedID,
                rssEpisode.identityKey AS rssEpisodeID
              FROM (
                SELECT id, accountId, itemId, podcastEpisodeId, NULL AS rssEpisodeId
                FROM savedShelfEntry WHERE accountId = ?
                UNION ALL
                SELECT -id AS id, NULL AS accountId, NULL AS itemId, NULL AS podcastEpisodeId, rssEpisodeId
                FROM rssSavedShelfEntry
              ) AS saved
              LEFT JOIN item
                ON item.id = saved.itemId
                AND item.accountId = saved.accountId
              LEFT JOIN podcastEpisode AS episode
                ON episode.id = saved.podcastEpisodeId
                AND episode.itemId = saved.itemId
                AND episode.accountId = saved.accountId
              LEFT JOIN rssEpisode ON rssEpisode.id = saved.rssEpisodeId
              """,
            arguments: [accountId])

          return Set(
            rows.compactMap { row -> SavedShelfIdentity? in
              if let feedID = row["rssFeedID"] as Int64?,
                let episodeID = row["rssEpisodeID"] as String?
              {
                guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else {
                  return nil
                }
                return .rssEpisode(itemID: itemID, episodeID: episodeID)
              }
              guard let itemID = row["itemID"] as String? else { return nil }
              if let episodeID = row["episodeID"] as String? {
                return .podcastEpisode(itemID: itemID, episodeID: episodeID)
              }
              return .item(itemID: itemID)
            })
        }
        .removeDuplicates())
  }

  private static func makeItem(_ row: Row) -> SavedShelfItem? {
    if let feedID = row["rssFeedID"] as Int64? {
      return makeNativeEpisodeItem(row, feedID: feedID)
    }
    guard let itemID = row["itemID"] as String? else { return nil }
    let itemMediaKind: String = row["itemMediaKind"]
    let itemEbookFormat: String? = row["itemEbookFormat"]
    let derivedCategory = ItemMediaCategory.derive(
      mediaKind: itemMediaKind,
      numAudioFiles: row["itemNumAudioFiles"],
      ebookFormat: itemEbookFormat)
    let savedAt: Date = row["savedAt"]
    let itemSoftDeleted: Bool = row["itemSoftDeleted"]
    let itemTitle = preferredTitle(
      live: row["itemTitle"] as String?, fallback: row["savedContextTitle"] as String?)

    guard let episodeID = row["episodeID"] as String? else {
      let subjectTitle = preferredTitle(
        live: row["itemTitle"] as String?, fallback: row["savedSubjectTitle"] as String?)
      let itemSummary = ItemSummary(
        serverItemId: itemID,
        mediaKind: itemMediaKind,
        title: subjectTitle,
        author: row["itemAuthor"],
        durationSeconds: row["itemDurationSeconds"],
        progressSeconds: PlaybackPositionListProjection.quantizedSeconds((row["itemProgressSeconds"] as Double?) ?? 0),
        category: derivedCategory,
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: itemEbookFormat),
        addedAt: row["itemAddedAt"],
        seriesName: row["itemSeriesName"],
        narratorName: row["itemNarratorName"],
        expandedMetadataFetchedAt: row["itemExpandedMetadataFetchedAt"],
        itemDescription: row["itemDescription"],
        serverUpdatedAt: row["itemServerUpdatedAt"])
      return SavedShelfItem(
        identity: .item(itemID: itemID),
        savedAt: savedAt,
        subjectTitle: subjectTitle,
        contextTitle: nil,
        category: derivedCategory,
        itemSummary: itemSummary,
        episode: nil,
        isUnavailable: itemSoftDeleted)
    }

    let episodeTitle = preferredTitle(
      live: row["episodeTitle"] as String?, fallback: row["savedSubjectTitle"] as String?)
    let episode = HomePodcastEpisode(
      itemID: itemID,
      showTitle: itemTitle,
      showAuthor: row["itemAuthor"],
      episodeID: episodeID,
      title: episodeTitle,
      subtitle: row["episodeSubtitle"],
      publishedAt: (row["episodePublishedAt"] as Date?) ?? .distantPast,
      durationSeconds: row["episodeDurationSeconds"],
      progressSeconds: PlaybackPositionListProjection.quantizedSeconds((row["episodeProgressSeconds"] as Double?) ?? 0),
      isFinished: (row["episodeProgressIsFinished"] as Bool?) ?? false,
      showServerUpdatedAt: row["itemServerUpdatedAt"])
    return SavedShelfItem(
      identity: .podcastEpisode(itemID: itemID, episodeID: episodeID),
      savedAt: savedAt,
      subjectTitle: episodeTitle,
      contextTitle: itemTitle,
      category: .podcast,
      itemSummary: nil,
      episode: episode,
      isUnavailable: itemSoftDeleted || ((row["episodeSoftDeleted"] as Bool?) ?? false))
  }

  /// A device-owned episode: the feed stands in for the show and `rssEpisodeState` for progress.
  /// Availability mirrors the listening queue's tombstone rule: an episode the feed no longer
  /// lists is unavailable, but the saved row still shows and remains removable.
  private static func makeNativeEpisodeItem(_ row: Row, feedID: Int64) -> SavedShelfItem? {
    guard
      let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId,
      let episodeID = row["rssEpisodeID"] as String?
    else { return nil }
    let showTitle = preferredTitle(
      live: row["rssFeedTitle"] as String?, fallback: row["savedContextTitle"] as String?)
    let episodeTitle = preferredTitle(
      live: row["rssEpisodeTitle"] as String?, fallback: row["savedSubjectTitle"] as String?)
    let lastSeenGeneration = row["rssLastSeenGeneration"] as Int
    let refreshGeneration = row["rssRefreshGeneration"] as Int
    let episode = HomePodcastEpisode(
      itemID: itemID,
      showTitle: showTitle,
      showAuthor: row["rssFeedAuthor"],
      episodeID: episodeID,
      title: episodeTitle,
      subtitle: nil,
      publishedAt: (row["rssPublishedAt"] as Date?) ?? .distantPast,
      durationSeconds: row["rssDurationSeconds"],
      progressSeconds: PlaybackPositionListProjection.quantizedSeconds((row["rssProgressSeconds"] as Double?) ?? 0),
      isFinished: (row["rssProgressIsFinished"] as Bool?) ?? false,
      artworkURL: (row["rssArtworkURL"] as String?).flatMap(URL.init(string:)),
      artworkFeedURL: (row["rssFeedURL"] as String?).flatMap(URL.init(string:)))
    return SavedShelfItem(
      identity: .rssEpisode(itemID: itemID, episodeID: episodeID),
      savedAt: row["savedAt"],
      subjectTitle: episodeTitle,
      contextTitle: showTitle,
      category: .podcast,
      itemSummary: nil,
      episode: episode,
      isUnavailable: lastSeenGeneration < refreshGeneration)
  }

  private static func preferredTitle(live: String?, fallback: String?) -> String {
    guard let live, live.isEmpty == false else { return fallback ?? "" }
    return live
  }
}
