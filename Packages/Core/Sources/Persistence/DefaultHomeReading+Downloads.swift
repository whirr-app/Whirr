import Foundation
import GRDB

extension DefaultHomeReading {
  public func observeDownloaded(
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
            downloadItemRollup.supplementDownloaded AS supplementDownloaded,
            NULL AS episodeID, NULL AS episodeTitle,
            mediaProgress.currentTime AS progressCurrentTime,
            mediaProgress.ebookProgress AS ebookProgress,
            mediaProgress.isFinished AS progressIsFinished
          FROM item
          LEFT JOIN mediaProgress
            ON mediaProgress.itemId = item.id AND mediaProgress.podcastEpisodeId IS NULL
          JOIN downloadItemRollup
            ON downloadItemRollup.itemId = item.id
            AND downloadItemRollup.hasCompletedKind = 1
          WHERE item.accountId = ?
            -- Not a catalogue projection: a completed download is device-owned.
            AND item.softDeleted = 0
            AND (\(Self.filterCategoryPredicateSQL(category)))
          ORDER BY item.sortTitle ASC
          LIMIT ?
          """
        return
          try Row
          .fetchAll(db, sql: sql, arguments: [accountId, max(0, limit)])
          .map { Self.makeHomeItem($0) }
      }.removeDuplicates())
  }

}
