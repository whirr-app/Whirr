import Foundation
import GRDB

extension DefaultHomeReading {
  public func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<HomeRecentlyAddedSnapshot> {
    observeRecentlyAdded(category: category, limit: limit, since: nil)
  }

  public func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int, since: Date?
  ) -> AsyncStream<HomeRecentlyAddedSnapshot> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> HomeRecentlyAddedSnapshot in
        let effectiveLimit = max(0, limit)
        guard effectiveLimit > 0, let accountId = try AccountRecord.fetchOne(db)?.id else {
          return HomeRecentlyAddedSnapshot(all: [], nativePreferred: [])
        }
        let nativePredicateSQL = """
          AND (
            item.mediaKind <> 'podcast'
            OR NOT EXISTS (
              SELECT 1
              FROM rssFeed AS feed
              WHERE feed.podcastFeedFingerprint = item.podcastFeedFingerprint
                AND \(Self.validFingerprintSQL("item.podcastFeedFingerprint"))
                AND \(Self.validFingerprintSQL("feed.podcastFeedFingerprint"))
            )
          )
          """
        let allCandidatesSQL = Self.recentlyAddedCandidateCTE(
          name: "allCandidates", policyRank: 0, category: category, extraPredicateSQL: "")
        let nativeCandidatesSQL = Self.recentlyAddedCandidateCTE(
          name: "nativeCandidates",
          policyRank: 1,
          category: category,
          extraPredicateSQL: nativePredicateSQL)
        let sql = """
          WITH \(Self.downloadRollupCTE),
          \(allCandidatesSQL),
          \(nativeCandidatesSQL)
          SELECT * FROM allCandidates
          UNION ALL
          SELECT * FROM nativeCandidates
          ORDER BY policyRank ASC, addedAt DESC, itemRowId ASC
          """
        // SQLite orders NULL as the smallest value, so `ORDER BY addedAt DESC` places rows with
        // no `addedAt` last. The outer ordering keeps the two independently limited branches
        // deterministic while Swift splits the bounded (at most 2 * effectiveLimit) union.
        let rows = try Row.fetchAll(
          db,
          sql: sql,
          arguments: [
            accountId, since, since, effectiveLimit,
            accountId, since, since, effectiveLimit,
          ])
        var all: [HomeItem] = []
        var nativePreferred: [HomeItem] = []
        for row in rows {
          let item = Self.makeHomeItem(row)
          if (row["policyRank"] as Int) == 0 {
            all.append(item)
          } else {
            nativePreferred.append(item)
          }
        }
        return HomeRecentlyAddedSnapshot(all: all, nativePreferred: nativePreferred)
      }.removeDuplicates())
  }

  /// A queue of what is left to hear: finished episodes leave it, as do those played to inside
  /// their final minute (`minimumRemainingSeconds`, the rule Continue Listening applies, so the
  /// shelves agree). Part-played episodes with real audio left stay.
  ///
  /// The join puts `mediaProgress` (written every playback tick) in the tracked region, so
  /// `removeDuplicates` stops each tick invalidating every visible row, as in
  /// `DefaultLibraryReading.observeItemPlaybackStatuses`.
  public func observeNewPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<HomeLatestPodcastEpisodesSnapshot> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> HomeLatestPodcastEpisodesSnapshot in
        let effectiveLimit = max(0, limit)
        guard effectiveLimit > 0, let account = try AccountRecord.fetchOne(db),
          let accountId = account.id
        else {
          return HomeLatestPodcastEpisodesSnapshot(all: [], nativePreferred: [])
        }
        // Read here, inside the observation's fetch, so each re-run uses the window as it stands at
        // that moment rather than the one that applied when the caller subscribed.
        let since = cutoff()
        let accountServerIdentityFingerprint =
          account.serverIdentityFingerprint
        let nativePredicateSQL = """
          AND NOT EXISTS (
            SELECT 1
            FROM nativeEpisodeServerSaveAttempt AS attempt
            JOIN rssFeed AS nativeFeed
              ON nativeFeed.id = attempt.feedId
            JOIN rssEpisode AS nativeEpisode
              ON nativeEpisode.id = attempt.episodeId
              AND nativeEpisode.feedId = nativeFeed.id
            LEFT JOIN rssEpisodeState AS nativeState
              ON nativeState.episodeId = nativeEpisode.id
            LEFT JOIN rssFeedSettings AS nativeSettings
              ON nativeSettings.feedId = nativeFeed.id
            WHERE attempt.accountId = currentAccount.id
              AND attempt.accountClientUUID = currentAccount.clientUUID
              AND attempt.accountServerIdentityFingerprint = ?
              AND attempt.serverItemId = item.serverItemId
              AND attempt.serverEpisodeId = episode.serverEpisodeId
              AND (
                attempt.episodeIdentityKey = nativeEpisode.identityKey
                OR attempt.episodeIdentityKey = nativeEpisode.alternateIdentityKey
              )
              AND nativeFeed.podcastFeedFingerprint = item.podcastFeedFingerprint
              AND \(Self.validFingerprintSQL("item.podcastFeedFingerprint"))
              AND \(Self.validFingerprintSQL("nativeFeed.podcastFeedFingerprint"))
              AND nativeEpisode.lastSeenGeneration = nativeFeed.refreshGeneration
              AND COALESCE(nativeSettings.includeInLatest, 1) = 1
              AND nativeEpisode.publishedAt >= ?
              AND COALESCE(nativeState.finished, 0) = 0
              AND (
                nativeState.position IS NULL
                OR nativeEpisode.durationSeconds IS NULL
                OR nativeEpisode.durationSeconds <= 0
                OR nativeEpisode.durationSeconds - nativeState.position
                  >= \(Self.minimumRemainingSeconds)
              )
          )
          """
        let allCandidatesSQL = Self.newPodcastCandidateCTE(
          name: "allCandidates", policyRank: 0, extraPredicateSQL: "")
        let nativeCandidatesSQL = Self.newPodcastCandidateCTE(
          name: "nativeCandidates", policyRank: 1, extraPredicateSQL: nativePredicateSQL)
        let sql = """
          WITH \(allCandidatesSQL),
          \(nativeCandidatesSQL)
          SELECT * FROM allCandidates
          UNION ALL
          SELECT * FROM nativeCandidates
          ORDER BY policyRank ASC, publishedAt DESC, episodeID ASC, itemID ASC, episodeRowId ASC
          """
        let rows = try Row.fetchAll(
          db,
          sql: sql,
          arguments: [
            accountId, since, effectiveLimit,
            accountId, since, accountServerIdentityFingerprint, since, effectiveLimit,
          ])
        var all: [HomePodcastEpisode] = []
        var nativePreferred: [HomePodcastEpisode] = []
        for row in rows {
          let episode = HomePodcastEpisode(
            itemID: row["itemID"],
            showTitle: (row["showTitle"] as String?) ?? "",
            showAuthor: row["showAuthor"],
            episodeID: row["episodeID"],
            title: (row["episodeTitle"] as String?) ?? "",
            subtitle: row["episodeSubtitle"],
            publishedAt: row["publishedAt"],
            durationSeconds: row["durationSeconds"],
            progressSeconds: PlaybackPositionListProjection.quantizedSeconds(
              (row["progressCurrentTime"] as Double?) ?? 0),
            isFinished: (row["progressIsFinished"] as Bool?) ?? false,
            showServerUpdatedAt: row["showServerUpdatedAt"])
          if (row["policyRank"] as Int) == 0 {
            all.append(episode)
          } else {
            nativePreferred.append(episode)
          }
        }
        return HomeLatestPodcastEpisodesSnapshot(all: all, nativePreferred: nativePreferred)
      }.removeDuplicates())
  }

}
