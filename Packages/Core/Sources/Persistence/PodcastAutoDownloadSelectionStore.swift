import Foundation
import GRDB

/// One episode eligible for an automatic download right now: what
/// `AutomaticEpisodeDownloadPlanning.requestAutomaticEpisodeDownload(itemID:episodeID:)` needs
/// and nothing more. Carries no GRDB type across the store boundary.
public struct PodcastAutoDownloadCandidate: Sendable, Equatable {
  public var itemID: String
  public var episodeID: String
  public var publishedAt: Date

  public init(itemID: String, episodeID: String, publishedAt: Date) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.publishedAt = publishedAt
  }
}

/// The candidate query, `markDecided`, and the crash-window repair clause. A database query, not
/// an event hook: episodes arrive by several paths (the recent-episodes shelf, a selected-show
/// refresh) and a hook on one misses the others.
///
/// Never creates a download row or contacts the network; only `PodcastAutoDownloadCoordinator`
/// turns a candidate into a request, through `AutomaticEpisodeDownloadPlanning`. Every row goes
/// through `PodcastEffectiveSettingsResolver.resolve`.
public struct PodcastAutoDownloadSelectionStore: Sendable {
  private let database: AppDatabase
  private let accountId: Int64
  private let now: @Sendable () -> Date

  public init(
    database: AppDatabase,
    accountId: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.accountId = accountId
    self.now = now
  }

  /// The full eligibility predicate, ordered `publishedAt DESC` then `serverEpisodeId ASC`,
  /// bounded by both budgets (the caller supplies the policy values).
  /// Mutates nothing; a candidate stays eligible until `markDecided` is called for it.
  public func fetchCandidates(
    maxPerShow: Int, maxPerPass: Int
  ) async throws -> [PodcastAutoDownloadCandidate] {
    try await database.readAsync { db in
      try Self.candidates(
        db, accountId: self.accountId, maxPerShow: maxPerShow, maxPerPass: maxPerPass)
    }
  }

  /// Stamps `autoDownloadDecidedAt` for one episode. Call only once a download row has actually
  /// been created for it. A no-op if the item/episode no longer resolves (e.g. removed between
  /// the query and the stamp).
  public func markDecided(itemID: String, episodeID: String) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE podcastEpisode
          SET autoDownloadDecidedAt = ?
          WHERE accountId = ?
            AND serverEpisodeId = ?
            AND itemId = (
              SELECT id FROM item WHERE accountId = ? AND serverItemId = ?
            )
          """,
        arguments: [self.now(), self.accountId, episodeID, self.accountId, itemID])
    }
  }

  /// The crash-window heal: stamps `decidedAt` on any episode that has an automatic-origin row
  /// but no stamp. Covers the gap between `DownloadCoordinator` creating a row and `markDecided`
  /// landing. If the process dies in between, the surviving row already blocks candidacy, but
  /// the missing stamp would leave the episode looking undecided forever. Idempotent. Returns
  /// the number of episodes stamped, for aggregate diagnostics only.
  @discardableResult
  public func repairDecidedStamps() async throws -> Int {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE podcastEpisode
          SET autoDownloadDecidedAt = ?
          WHERE accountId = ?
            AND autoDownloadDecidedAt IS NULL
            AND EXISTS (
              SELECT 1 FROM download
              WHERE download.podcastEpisodeId = podcastEpisode.id
                AND download.origin = ?
            )
          """,
        arguments: [self.now(), self.accountId, DownloadOrigin.automatic.rawValue])
      return db.changesCount
    }
  }

  // MARK: - Internals

  /// The eligibility-qualified episode set, before the keep-latest window and the budgets are
  /// applied. Those two are cheaper to apply in Swift than to fold into the SQL.
  private static func candidates(
    _ db: Database, accountId: Int64, maxPerShow: Int, maxPerPass: Int
  ) throws -> [PodcastAutoDownloadCandidate] {
    let global = try globalSettings(db, accountId: accountId)
    let presence = try DownloadStore.episodePresence(db)

    let rows = try Row.fetchAll(
      db,
      sql: """
        WITH liveEpisodeRank AS (
          SELECT id AS episodeRowId,
                 ROW_NUMBER() OVER (
                   PARTITION BY itemId
                   ORDER BY publishedAt IS NULL ASC, publishedAt DESC, serverEpisodeId ASC
                 ) AS rankInShow
          FROM podcastEpisode
          WHERE accountId = ? AND softDeleted = 0
        )
        SELECT
          item.serverItemId AS itemID,
          episode.serverEpisodeId AS episodeID,
          episode.publishedAt AS publishedAt,
          episode.storedAudioDurationSeconds AS storedAudioDurationSeconds,
          show.autoDownloadOverride AS autoDownloadOverrideRaw,
          show.keepLatestOverride AS keepLatestOverride,
          show.deleteAfterPlayedOverride AS deleteAfterPlayedOverride,
          show.enabledAt AS showEnabledAt,
          progress.isFinished AS progressIsFinished,
          liveEpisodeRank.rankInShow AS rankInShow
        FROM podcastEpisode AS episode
        JOIN item ON item.id = episode.itemId
        JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
        JOIN liveEpisodeRank ON liveEpisodeRank.episodeRowId = episode.id
        LEFT JOIN podcastShowSettings AS show
          ON show.itemId = item.id AND show.accountId = item.accountId
        LEFT JOIN mediaProgress AS progress
          ON progress.accountId = episode.accountId
          AND progress.itemId = episode.itemId
          AND progress.podcastEpisodeId = episode.id
        WHERE episode.accountId = ?
          AND item.accountId = ?
          AND \(ItemVisibilityPredicate.sql)
          AND item.mediaKind = 'podcast'
          AND episode.softDeleted = 0
          AND episode.publishedAt IS NOT NULL
          AND episode.autoDownloadDecidedAt IS NULL
          AND episode.storedAudioIno IS NOT NULL AND episode.storedAudioIno != ''
          AND episode.storedAudioExpectedSize IS NOT NULL AND episode.storedAudioExpectedSize > 0
          AND episode.storedAudioMimeType IS NOT NULL AND episode.storedAudioMimeType != ''
          AND episode.storedAudioDurationSeconds IS NOT NULL
          AND episode.storedAudioDurationSeconds > 0
        ORDER BY episode.publishedAt DESC, episode.serverEpisodeId ASC
        """,
      arguments: [accountId, accountId, accountId])

    var perShowCount: [String: Int] = [:]
    var results: [PodcastAutoDownloadCandidate] = []

    for row in rows {
      guard results.count < maxPerPass else { break }

      // Mirrors `DownloadCoordinator.planEpisodeDownload`'s own stored-audio guard: a duration
      // that survived the `> 0` SQL filter but is not finite (e.g. `.infinity`) is not a complete
      // identity either.
      let duration: Double = row["storedAudioDurationSeconds"]
      guard duration.isFinite else { continue }

      let itemID: String = row["itemID"]
      let episodeID: String = row["episodeID"]
      let publishedAt: Date = row["publishedAt"]
      let overrideRaw: String? = row["autoDownloadOverrideRaw"]
      let override = PodcastShowAutoDownloadOverride.parse(
        overrideRaw ?? PodcastShowAutoDownloadOverride.inherit.rawValue)
      let keepLatestOverride: Int? = row["keepLatestOverride"]
      let deleteAfterPlayedOverride: Bool? = row["deleteAfterPlayedOverride"]
      let showEnabledAt: Date? = row["showEnabledAt"]
      let progressIsFinished: Bool? = row["progressIsFinished"]
      let rankInShow: Int = row["rankInShow"]

      let effective = PodcastEffectiveSettingsResolver.resolve(
        global: global,
        showOverride: override,
        showKeepLatestOverride: keepLatestOverride,
        showDeleteAfterPlayedOverride: deleteAfterPlayedOverride,
        showEnabledAt: showEnabledAt)

      guard effective.isEnabled else { continue }
      guard publishedAt > effective.floor else { continue }
      // Absent progress (a `LEFT JOIN` miss) means "not finished", so NULL is never finished.
      guard progressIsFinished != true else { continue }
      guard effective.keepLatestCount == 0 || rankInShow <= effective.keepLatestCount else {
        continue
      }

      let key = EpisodeDownloadKey(itemID: itemID, episodeID: episodeID)
      // A row in `.deleting` state does not block. Every other state (queued, downloading,
      // paused, failed, completed) is a surviving row, manual or automatic alike.
      if let existingPresence = presence[key], existingPresence != .deleting { continue }

      guard (perShowCount[itemID] ?? 0) < maxPerShow else { continue }

      perShowCount[itemID, default: 0] += 1
      results.append(
        PodcastAutoDownloadCandidate(itemID: itemID, episodeID: episodeID, publishedAt: publishedAt)
      )
    }

    return results
  }

  private static func globalSettings(_ db: Database, accountId: Int64) throws
    -> PodcastGlobalSettings
  {
    guard let record = try PodcastSettingsRecord.fetchOne(db, key: accountId) else {
      return .defaults
    }
    return PodcastGlobalSettings(
      autoDownloadEnabled: record.autoDownloadEnabled,
      keepLatestCount: record.keepLatestCount,
      deleteAfterPlayed: record.deleteAfterPlayed,
      allowCellularAutoDownload: record.allowCellularAutoDownload,
      enabledAt: record.enabledAt)
  }
}
