import Foundation
import GRDB

extension DefaultHomeReading {
  public func observeContinueListening(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<[HomeItem]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> [HomeItem] in
        guard let accountId = try AccountRecord.fetchOne(db)?.id else { return [] }
        let sql = """
          WITH \(Self.downloadRollupCTE),
          podcastCandidates AS (
            SELECT
              progress.itemId AS itemId,
              progress.podcastEpisodeId AS podcastEpisodeRowId,
              episode.serverEpisodeId AS episodeID,
              episode.title AS episodeTitle,
              episode.durationSeconds AS episodeDurationSeconds,
              progress.currentTime AS progressCurrentTime,
              progress.ebookProgress AS ebookProgress,
              progress.isFinished AS progressIsFinished,
              progress.serverUpdatedAt AS serverUpdatedAt,
              progress.lastActivityAt AS lastActivityAt,
              progress.localSequence AS localSequence,
              ROW_NUMBER() OVER (
                PARTITION BY progress.itemId
                ORDER BY
                  \(Self.recency("progress")) IS NULL ASC,
                  \(Self.recency("progress")) DESC,
                  progress.localSequence DESC,
                  progress.id DESC
              ) AS episodeRank
            FROM mediaProgress AS progress
            JOIN item
              ON item.id = progress.itemId
              AND item.accountId = progress.accountId
            JOIN podcastEpisode AS episode
              ON episode.id = progress.podcastEpisodeId
              AND episode.itemId = progress.itemId
              AND episode.accountId = progress.accountId
            WHERE item.mediaKind = 'podcast'
              -- Not a catalogue projection: live progress rows, not library membership.
              AND item.softDeleted = 0
              AND episode.softDeleted = 0
              AND progress.currentTime > 0
              AND progress.isFinished = 0
              AND progress.hideFromContinueListening = 0
              AND (
                episode.durationSeconds IS NULL
                OR episode.durationSeconds <= 0
                OR episode.durationSeconds - progress.currentTime
                  >= \(Self.minimumRemainingSeconds)
              )
          ),
          selectedProgress AS (
            SELECT
              progress.itemId AS itemId,
              NULL AS podcastEpisodeRowId,
              NULL AS episodeID,
              NULL AS episodeTitle,
              NULL AS episodeDurationSeconds,
              progress.currentTime AS progressCurrentTime,
              progress.ebookProgress AS ebookProgress,
              progress.isFinished AS progressIsFinished,
              progress.serverUpdatedAt AS serverUpdatedAt,
              progress.lastActivityAt AS lastActivityAt,
              progress.localSequence AS localSequence
            FROM mediaProgress AS progress
            JOIN item
              ON item.id = progress.itemId
              AND item.accountId = progress.accountId
            WHERE item.mediaKind <> 'podcast'
              AND progress.podcastEpisodeId IS NULL
              AND progress.currentTime > 0
              AND progress.isFinished = 0
              AND progress.hideFromContinueListening = 0
              AND (
                item.durationSeconds IS NULL
                OR item.durationSeconds <= 0
                OR item.durationSeconds - progress.currentTime
                  >= \(Self.minimumRemainingSeconds)
              )

            UNION ALL

            SELECT
              itemId,
              podcastEpisodeRowId,
              episodeID,
              episodeTitle,
              episodeDurationSeconds,
              progressCurrentTime,
              ebookProgress,
              progressIsFinished,
              serverUpdatedAt,
              lastActivityAt,
              localSequence
            FROM podcastCandidates
            WHERE episodeRank = 1
          )
          SELECT
            item.serverItemId AS serverItemId, item.title AS title, item.author AS author,
            item.mediaKind AS mediaKind, item.numAudioFiles AS numAudioFiles,
            item.ebookFormat AS ebookFormat, item.seriesName AS seriesName,
            item.narratorName AS narratorName,
            item.expandedMetadataFetchedAt AS expandedMetadataFetchedAt,
            item.serverUpdatedAt AS itemServerUpdatedAt,
            CASE
              WHEN selectedProgress.podcastEpisodeRowId IS NULL THEN item.durationSeconds
              ELSE selectedProgress.episodeDurationSeconds
            END AS durationSeconds,
            item.addedAt AS addedAt, item.id AS itemRowId,
            \(Self.downloadCompletionSQL) AS isDownloaded,
            downloadItemRollup.audioDownloaded AS audioDownloaded,
            downloadItemRollup.ebookDownloaded AS ebookDownloaded,
            selectedProgress.episodeID AS episodeID,
            selectedProgress.episodeTitle AS episodeTitle,
            selectedProgress.progressCurrentTime AS progressCurrentTime,
            selectedProgress.ebookProgress AS ebookProgress,
            selectedProgress.progressIsFinished AS progressIsFinished,
            \(Self.recency("selectedProgress")) AS progressRecency
          FROM selectedProgress
          JOIN item ON item.id = selectedProgress.itemId
          JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
          LEFT JOIN downloadItemRollup
            ON downloadItemRollup.itemId = item.id
          WHERE item.accountId = ?
            AND \(ItemVisibilityPredicate.sql)
            AND (\(Self.categoryPredicateSQL(category)))
          ORDER BY
            \(Self.recency("selectedProgress")) IS NULL ASC,
            \(Self.recency("selectedProgress")) DESC,
            item.serverItemId ASC
          LIMIT ?
          """
        return
          try Row
          .fetchAll(db, sql: sql, arguments: [accountId, limit])
          .map { Self.makeHomeItem($0) }
      }.removeDuplicates())
  }

  public func observeContinueReading(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<[HomeItem]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> [HomeItem] in
        guard let accountId = try AccountRecord.fetchOne(db)?.id else { return [] }
        let sql = """
          WITH \(Self.downloadRollupCTE)
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
            progress.currentTime AS progressCurrentTime,
            progress.ebookProgress AS ebookProgress,
            progress.isFinished AS progressIsFinished
          FROM mediaProgress AS progress
          JOIN item
            ON item.id = progress.itemId
            AND item.accountId = progress.accountId
          JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
          LEFT JOIN downloadItemRollup
            ON downloadItemRollup.itemId = item.id
          WHERE item.accountId = ?
            AND \(ItemVisibilityPredicate.sql)
            AND progress.podcastEpisodeId IS NULL
            AND progress.ebookProgress > 0
            AND progress.isFinished = 0
            AND item.mediaKind <> 'podcast'
            AND \(ItemCategoryPredicate.hasReadableEbookSQL)
            AND (\(Self.filterCategoryPredicateSQL(category)))
          ORDER BY
            \(Self.recency("progress")) IS NULL ASC,
            \(Self.recency("progress")) DESC,
            CASE WHEN \(Self.recency("progress")) IS NULL THEN progress.localSequence END DESC,
            item.serverItemId ASC
          LIMIT ?
          """
        return
          try Row
          .fetchAll(db, sql: sql, arguments: [accountId, max(0, limit)])
          .map { Self.makeHomeItem($0) }
      }.removeDuplicates())
  }

  public func observeContinueSeries(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<[HomeItem]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> [HomeItem] in
        guard let accountId = try AccountRecord.fetchOne(db)?.id else { return [] }
        // AuthorSeriesEntityStore writes SearchResultKind.series.rawValue, whose persisted
        // spelling is "series". Resolve hidden ids opportunistically through that already-cached
        // index; do not eagerly fetch filter data just to make this per-refresh lookup complete.
        let hiddenSeriesNames = Set(
          try String.fetchAll(
            db,
            sql: """
              SELECT DISTINCT entity.normalizedName
              FROM hiddenContinueSeries AS hidden
              JOIN library ON library.accountId = hidden.accountId
              JOIN libraryEntityIndex AS entity
                ON entity.libraryId = library.id
                AND entity.kind = ?
                AND entity.serverEntityId = hidden.serverSeriesId
              WHERE hidden.accountId = ?
              """,
            arguments: [SearchResultKind.series.rawValue, accountId]))
        let rows = try Row.fetchAll(
          db,
          sql: """
            WITH \(Self.downloadRollupCTE)
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
              \(Self.recency("mediaProgress")) AS progressRecency,
              item.sortTitle AS sortTitle,
              library.onlyShowLaterBooksInContinueSeries AS onlyShowLaterBooksInContinueSeries
            FROM item
            JOIN library
              ON library.id = item.libraryId
              AND library.accountId = item.accountId
            LEFT JOIN mediaProgress
              ON mediaProgress.itemId = item.id
              AND mediaProgress.accountId = item.accountId
              AND mediaProgress.podcastEpisodeId IS NULL
            LEFT JOIN downloadItemRollup
              ON downloadItemRollup.itemId = item.id
            WHERE item.accountId = ?
              AND \(ItemVisibilityPredicate.sql)
              AND item.seriesName IS NOT NULL
              AND item.mediaKind <> 'podcast'
              AND (\(Self.categoryPredicateSQL(category)))
            """,
          arguments: [accountId])

        let candidates = rows.flatMap { row -> [SeriesCandidate] in
          let item = Self.makeHomeItem(row)
          let isFinished = (row["progressIsFinished"] as Bool?) ?? false
          let currentTime = (row["progressCurrentTime"] as Double?) ?? 0
          let ebookProgress = (row["ebookProgress"] as Double?) ?? 0
          let progressRecency = row["progressRecency"] as Date?
          let sortTitle: String = row["sortTitle"]
          return SeriesFlattenedName.entries(from: row["seriesName"] as String?).map { entry in
            SeriesCandidate(
              normalizedName: AuthorSeriesEntity.normalizedName(entry.name),
              sequence: entry.sequence,
              sequenceValue: SeriesFlattenedName.sequenceValue(entry.sequence),
              sortTitle: sortTitle,
              item: item,
              isFinished: isFinished,
              currentTime: currentTime,
              ebookProgress: ebookProgress,
              progressRecency: progressRecency,
              onlyShowLaterBooksInContinueSeries:
                row["onlyShowLaterBooksInContinueSeries"] as Bool? ?? false)
          }
        }

        var offeredGroups: [(key: String, item: HomeItem, recency: Date?)] = []
        for (key, group) in Dictionary(grouping: candidates, by: \.normalizedName) {
          guard hiddenSeriesNames.contains(key) == false else { continue }
          // A folded group can span libraries. Any opted-in library restricts the whole group:
          // withholding is conservative and honors the reader's setting.
          let isRestricted = group.contains(where: \.onlyShowLaterBooksInContinueSeries)
          let unfinished = group.filter { $0.isFinished == false }
          let eligibleUnfinished: [SeriesCandidate]
          if isRestricted,
            let highestFinishedSequence = group.filter(\.isFinished).compactMap(\.sequenceValue).max()
          {
            eligibleUnfinished = unfinished.filter {
              guard let sequenceValue = $0.sequenceValue else { return false }
              return sequenceValue > highestFinishedSequence
            }
          } else {
            eligibleUnfinished = unfinished
          }

          guard
            group.contains(where: \.isFinished),
            group.contains(where: {
              $0.isFinished == false && ($0.currentTime > 0 || $0.ebookProgress > 0)
            }) == false,
            let next =
              eligibleUnfinished
              .sorted(by: Self.seriesCandidatePrecedes)
              .first
          else { continue }

          offeredGroups.append(
            (
              key: key,
              item: next.item,
              recency: group.compactMap(\.progressRecency).max()
            ))
        }

        let orderedGroups = offeredGroups.sorted { lhs, rhs in
          switch (lhs.recency, rhs.recency) {
          case (let left?, let right?) where left != right:
            return left > right
          case (.some, .none):
            return true
          case (.none, .some):
            return false
          default:
            return lhs.key < rhs.key
          }
        }

        var selectedIDs = Set<String>()
        return orderedGroups.prefix(max(0, limit)).compactMap { group in
          guard selectedIDs.insert(group.item.serverItemId).inserted else { return nil }
          return group.item
        }
      }.removeDuplicates())
  }

}
