import Foundation
import GRDB

/// The production `LibraryReading` conformance: each method bridges a GRDB `ValueObservation` to
/// an `AsyncStream`, so no GRDB type crosses into AppModel (ARCHITECTURE.md §1). Server-facing
/// `libraryId`/`itemId` strings resolve to row ids inside the tracked closure, so the region
/// includes the `library`/`item` lookups and a row created later (a browse screen open before the
/// first sync) is picked up.
public struct DefaultLibraryReading: LibraryReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public var itemCount: Int {
    (try? database.read { db in try Self.unfilteredItemCount(db) }) ?? 0
  }

  public func observeBrowseList(libraryId: String) -> AsyncStream<[ItemSummary]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard let libraryRowId = try Self.libraryRowId(for: libraryId, db) else { return [] }
      return
        try ItemRecord
        .filter(Column("libraryId") == libraryRowId)
        .filter(Column("softDeleted") == false)
        .filter(sql: PodcastCatalogueVisibilityPredicate.sql)
        .order(Column("sortTitle"))
        .fetchAll(db)
        .map(Self.makeSummary)
    }
  }

  /// Cross-library and unbounded (this is the whole browse list), so the category constraint
  /// runs in SQL via the filter-membership predicate. This differs from the identity predicate
  /// used by projections: a mixed audiobook belongs in both the Audiobooks and Ebooks filters.
  /// Filtering in Swift afterwards would decode and project every row in every library only to
  /// discard most of them, on every committed transaction.
  ///
  /// `removeDuplicates` because a sync re-pull saves every row whether or not it changed, and the
  /// Watch artwork sync holds this stream for the app's life.
  public func observeBrowseList(category: ItemMediaCategory?) -> AsyncStream<[ItemSummary]> {
    let observation = ValueObservation.tracking { db in
      try ItemRecord.fetchAll(
        db,
        sql: """
          SELECT item.* FROM item
          JOIN library
            ON library.id = item.libraryId
            AND library.accountId = item.accountId
          WHERE \(ItemVisibilityPredicate.sql)
            AND \(PodcastCatalogueVisibilityPredicate.sql)
            AND (\(ItemFilterCategoryPredicate.sql(category)))
          ORDER BY item.sortTitle
          """,
        arguments: []
      )
      .map(Self.makeSummary)
    }
    return ObservationBridge.stream(in: database.dbWriter, observation: observation.removeDuplicates())
  }

  /// The filtered counterpart of the overload above; every dimension runs in SQL. Composing the
  /// fixed `ItemFilterPredicate`/`ItemFilterCategoryPredicate` strings through `filter(sql:)` lets
  /// GRDB infer `download` and `mediaProgress` into the tracked region from the compiled
  /// statement, so it cannot drift from the predicates.
  ///
  /// `removeDuplicates` is load-bearing, more than in `observeItemPlaybackStatuses`: a Downloaded
  /// predicate tracks byte counts that change throughout a transfer and a playback predicate
  /// tracks every progress tick; those must re-run the query without pushing an unchanged snapshot
  /// into `@Observable` state.
  public func observeBrowseList(filters: BrowseFilters) -> AsyncStream<LibraryBrowseSnapshot> {
    let categoriesSQL = Self.categoriesPredicateSQL(filters.categories)
    // The library-entry download scope, not the item-only one: podcast downloads are
    // episode-keyed, so the item-only scope would exclude every podcast show from
    // `Podcasts + Downloaded`.
    let downloadedSQL = ItemFilterPredicate.libraryEntryDownloadedOnly(filters.downloadedOnly)
    let playbackSQL = ItemFilterPredicate.itemPlayback(filters.playback)
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          let items = try ItemRecord.fetchAll(
            db,
            sql: """
              SELECT item.* FROM item
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              WHERE \(ItemVisibilityPredicate.sql)
                AND \(PodcastCatalogueVisibilityPredicate.sql)
                AND (\(categoriesSQL))
                AND (\(downloadedSQL))
                AND (\(playbackSQL))
              ORDER BY item.sortTitle
              """,
            arguments: []
          )
          .map(Self.makeSummary)
          // In the same tracked read, so the rows and the count can never describe two moments.
          return LibraryBrowseSnapshot(
            items: items,
            unfilteredItemCount: try Self.unfilteredItemCount(db))
        }
        .removeDuplicates())
  }

  /// OR's the single-category predicate across the set, matching `BrowseFilters.categories`'s own
  /// contract that `nil` means no constraint (an empty set is canonicalized to `nil` on
  /// construction, so it cannot reach here).
  private static func categoriesPredicateSQL(_ categories: Set<ItemMediaCategory>?) -> String {
    guard let categories, categories.isEmpty == false else { return "1" }
    return categories.map { "(\(ItemFilterCategoryPredicate.sql($0)))" }.joined(separator: " OR ")
  }

  public func observeSyncStatus(libraryId: String) -> AsyncStream<LibrarySyncStatus> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard let libraryRowId = try Self.libraryRowId(for: libraryId, db) else {
        return LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil)
      }
      return try Self.syncStatus(forLibraryRowId: libraryRowId, db)
    }
  }

  /// Every library's status folded into one, for the cross-library browse list. `lastCompletedAt`
  /// takes the oldest library's completion (nil if any library has never completed), so a merged
  /// list reports itself as stale as its least-recently-synced part rather than hiding one
  /// never-synced library behind another's fresh run.
  public func observeAggregateSyncStatus() -> AsyncStream<LibrarySyncStatus> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      let libraryRowIds =
        try LibraryRecord
        .filter(Column("softDeleted") == false)
        .filter(Column("isIncluded") == true)
        .fetchAll(db)
        .compactMap(\.id)
      guard libraryRowIds.isEmpty == false else {
        return LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil)
      }
      let perLibrary = try libraryRowIds.map { try Self.syncStatus(forLibraryRowId: $0, db) }
      let completions = perLibrary.map(\.lastCompletedAt)
      return LibrarySyncStatus(
        isRunning: perLibrary.contains(where: \.isRunning),
        lastRunIncomplete: perLibrary.contains(where: \.lastRunIncomplete),
        lastCompletedAt: completions.contains(where: { $0 == nil }) ? nil : completions.compactMap { $0 }.min()
      )
    }
  }

  private static func syncStatus(forLibraryRowId libraryRowId: Int64, _ db: Database) throws
    -> LibrarySyncStatus
  {
    let runs =
      try SyncRunRecord
      .filter(Column("libraryId") == libraryRowId)
      .order(Column("startedAt"))
      .fetchAll(db)
    let isRunning = runs.contains { $0.state == .running }
    let mostRecentlyStarted = runs.last
    let lastRunIncomplete =
      mostRecentlyStarted.map { $0.state == .incomplete || $0.state == .unstablePagination } ?? false
    let lastCompletedAt =
      runs
      .filter { $0.state == .completed }
      .compactMap(\.completedAt)
      .max()
    return LibrarySyncStatus(
      isRunning: isRunning, lastRunIncomplete: lastRunIncomplete, lastCompletedAt: lastCompletedAt)
  }

  public func observeItemDetail(itemId: String) -> AsyncStream<ItemSummary?> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.itemDetail(itemId: itemId, db: db)
    }
  }

  /// A single-row read from the durable local cache for direct cache readers. Presentation detail
  /// models provide their own optional display seed and use `observeItemDetail` as their sole
  /// loader, which still owns every update.
  public func currentItemDetail(itemId: String) -> ItemSummary? {
    try? database.read { db in try Self.itemDetail(itemId: itemId, db: db) }
  }

  public func currentAudioProgress(itemId: String, episodeId: String?) -> StoredAudioProgress? {
    try? database.read { db in
      guard
        let item = try ItemRecord.filter(Column("serverItemId") == itemId)
          .filter(Column("softDeleted") == false).fetchOne(db),
        let itemRowId = item.id
      else { return nil }
      var request = MediaProgressRecord.filter(Column("accountId") == item.accountId)
        .filter(Column("itemId") == itemRowId)
      if let episodeId {
        guard
          let episode = try PodcastEpisodeRecord.filter(Column("itemId") == itemRowId)
            .filter(Column("serverEpisodeId") == episodeId).fetchOne(db),
          let episodeRowId = episode.id
        else { return nil }
        request = request.filter(Column("podcastEpisodeId") == episodeRowId)
      } else {
        request = request.filter(Column("podcastEpisodeId") == nil)
      }
      guard let progress = try request.fetchOne(db) else { return nil }
      let changedAt =
        progress.origin == .local
        ? progress.lastActivityAt ?? progress.serverUpdatedAt : progress.serverUpdatedAt ?? progress.lastActivityAt
      return StoredAudioProgress(position: progress.currentTime, isFinished: progress.isFinished, changedAt: changedAt)
    }
  }

  public func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard ids.isEmpty == false else { return [] }
      let records = try ItemRecord.fetchAll(
        db,
        sql: """
          SELECT item.* FROM item
          JOIN library
            ON library.id = item.libraryId
            AND library.accountId = item.accountId
          WHERE item.serverItemId IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
            AND \(ItemVisibilityPredicate.sql)
          """,
        arguments: StatementArguments(ids))
      let byServerId = Dictionary(records.map { ($0.serverItemId, $0) }, uniquingKeysWith: { first, _ in first })
      return ids.compactMap { byServerId[$0] }.map(Self.makeSummary)
    }
  }

  /// `removeDuplicates` is what makes this affordable to keep open on a browse screen: the tracked
  /// region includes `mediaProgress`, which every playback tick writes to, but the values below
  /// contain only stable playback states rather than positions. Only a not-started/in-progress/
  /// finished transition can therefore invalidate visible rows.
  public func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          let rows = try Row.fetchAll(
            db,
            sql: """
              SELECT item.serverItemId AS itemID,
                CASE WHEN mediaProgress.isFinished = 1 THEN 1 ELSE 0 END AS isFinished
              FROM mediaProgress
              JOIN item ON item.id = mediaProgress.itemId
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              WHERE mediaProgress.podcastEpisodeId IS NULL
                AND \(ItemVisibilityPredicate.sql)
                AND (
                  mediaProgress.isFinished = 1
                  OR COALESCE(mediaProgress.currentTime, 0) > 0
                  OR COALESCE(mediaProgress.ebookProgress, 0) > 0
                )
              """)
          return Dictionary(
            rows.map { row in
              let itemID: String = row["itemID"]
              let isFinished: Bool = row["isFinished"]
              return (itemID, isFinished ? .finished : .inProgress)
            },
            uniquingKeysWith: { first, second in
              first == .finished || second == .finished ? .finished : .inProgress
            })
        }
        .removeDuplicates())
  }

  /// Same shape and `removeDuplicates` rationale as `observeItemPlaybackStatuses`, one join
  /// further out: the progress row's `podcastEpisodeId` resolves to the episode's server id, and
  /// the item join supplies the show's. The ebook term is absent, matching
  /// `ItemFilterPredicate.episodePlayback`: a podcast episode has no ebook edition. Rows whose ids
  /// cannot form a listening identity are dropped rather than mis-keyed.
  public func observeEpisodePlaybackStatuses() -> AsyncStream<[ListeningIdentity: ItemPlaybackStatus]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          let rows = try Row.fetchAll(
            db,
            sql: """
              SELECT item.serverItemId AS itemID, episode.serverEpisodeId AS episodeID,
                CASE WHEN mediaProgress.isFinished = 1 THEN 1 ELSE 0 END AS isFinished
              FROM mediaProgress
              JOIN podcastEpisode AS episode ON episode.id = mediaProgress.podcastEpisodeId
              JOIN item ON item.id = episode.itemId
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              WHERE episode.softDeleted = 0
                AND \(ItemVisibilityPredicate.sql)
                AND (
                  mediaProgress.isFinished = 1
                  OR COALESCE(mediaProgress.currentTime, 0) > 0
                )
              """)
          return Dictionary(
            rows.compactMap { row -> (ListeningIdentity, ItemPlaybackStatus)? in
              let itemID: String = row["itemID"]
              let episodeID: String = row["episodeID"]
              let isFinished: Bool = row["isFinished"]
              guard let identity = ListeningIdentity.podcastEpisode(itemID: itemID, episodeID: episodeID)
              else { return nil }
              return (identity, isFinished ? .finished : .inProgress)
            },
            uniquingKeysWith: { first, second in
              first == .finished || second == .finished ? .finished : .inProgress
            })
        }
        .removeDuplicates())
  }

  /// `removeDuplicates` is load-bearing, as in `observeItemPlaybackStatuses`: the region includes
  /// `mediaProgress` and `rssEpisodeState`, written every tick, but the projection changes only
  /// when a row is hidden or shown.
  ///
  /// Device-owned dismissals come from `rssEpisodeState`, not account- or library-scoped, matching
  /// the native Continue Listening shelf they suppress.
  public func observeContinueListeningHidden() -> AsyncStream<Set<ListeningIdentity>> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          let rows = try Row.fetchAll(
            db,
            sql: """
              SELECT item.serverItemId AS itemID, NULL AS episodeID
              FROM mediaProgress AS progress
              JOIN item
                ON item.id = progress.itemId
                AND item.accountId = progress.accountId
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              WHERE progress.podcastEpisodeId IS NULL
                AND progress.hideFromContinueListening = 1
                AND \(ItemVisibilityPredicate.sql)

              UNION ALL

              SELECT item.serverItemId AS itemID, episode.serverEpisodeId AS episodeID
              FROM mediaProgress AS progress
              JOIN item
                ON item.id = progress.itemId
                AND item.accountId = progress.accountId
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              JOIN podcastEpisode AS episode
                ON episode.id = progress.podcastEpisodeId
                AND episode.itemId = progress.itemId
                AND episode.accountId = progress.accountId
              WHERE progress.podcastEpisodeId IS NOT NULL
                AND progress.hideFromContinueListening = 1
                AND \(ItemVisibilityPredicate.sql)
                AND episode.softDeleted = 0
              """)
          let accountOwned = rows.compactMap { row -> ListeningIdentity? in
            let itemID: String = row["itemID"]
            let episodeID: String? = row["episodeID"]
            if let episodeID {
              return .podcastEpisode(itemID: itemID, episodeID: episodeID)
            }
            return .audiobook(itemID: itemID)
          }
          let deviceOwned = try Row.fetchAll(
            db,
            sql: """
              SELECT episode.feedId AS feedID, episode.identityKey AS episodeID
              FROM rssEpisodeState AS state
              JOIN rssEpisode AS episode ON episode.id = state.episodeId
              WHERE state.hideFromContinueListening = 1
              """
          ).compactMap { row -> ListeningIdentity? in
            .rssEpisode(feedID: row["feedID"], episodeID: row["episodeID"])
          }
          return Set(accountOwned + deviceOwned)
        }
        .removeDuplicates())
  }

  public func observeItemPlaybackProgress(itemIDs: Set<String>)
    -> AsyncStream<[String: ItemPlaybackProgress]>
  {
    guard itemIDs.isEmpty == false else {
      return AsyncStream { continuation in
        continuation.yield([:])
        continuation.finish()
      }
    }
    let requestedItemIDs = Array(itemIDs)
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          let items = try ItemRecord.fetchAll(
            db,
            sql: """
              SELECT item.* FROM item
              JOIN library
                ON library.id = item.libraryId
                AND library.accountId = item.accountId
              WHERE item.serverItemId IN (\(requestedItemIDs.map { _ in "?" }.joined(separator: ", ")))
                AND \(ItemVisibilityPredicate.sql)
              """,
            arguments: StatementArguments(requestedItemIDs))
          let serverIDByRowID = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
              item.id.map { ($0, item.serverItemId) }
            })
          guard serverIDByRowID.isEmpty == false else { return [:] }

          let progresses =
            try MediaProgressRecord
            .filter(Array(serverIDByRowID.keys).contains(Column("itemId")))
            .filter(Column("podcastEpisodeId") == nil)
            .fetchAll(db)
          return Dictionary(
            progresses.compactMap { progress -> (String, ItemPlaybackProgress)? in
              guard let serverItemID = serverIDByRowID[progress.itemId] else { return nil }
              let hasPosition = progress.currentTime > 0 || (progress.ebookProgress ?? 0) > 0
              guard progress.isFinished || hasPosition else { return nil }
              return (
                serverItemID,
                ItemPlaybackProgress(
                  currentTime: PlaybackPositionListProjection.quantizedSeconds(progress.currentTime),
                  ebookProgress: progress.ebookProgress,
                  isFinished: progress.isFinished)
              )
            },
            uniquingKeysWith: { first, second in
              first.isFinished ? first : second
            })
        }
        .removeDuplicates())
  }

  private static func libraryRowId(for serverLibraryId: String, _ db: Database) throws -> Int64? {
    try LibraryRecord
      .filter(Column("serverLibraryId") == serverLibraryId)
      .filter(Column("softDeleted") == false)
      .filter(Column("isIncluded") == true)
      .fetchOne(db)?.id
  }

  private static func unfilteredItemCount(_ db: Database) throws -> Int {
    try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM item
        JOIN library
          ON library.id = item.libraryId
          AND library.accountId = item.accountId
        WHERE \(ItemVisibilityPredicate.sql)
          AND \(PodcastCatalogueVisibilityPredicate.sql)
        """) ?? 0
  }

  private static func itemDetail(itemId: String, db: Database) throws -> ItemSummary? {
    guard
      let record =
        try ItemRecord
        .filter(Column("serverItemId") == itemId)
        .filter(Column("softDeleted") == false)
        .fetchOne(db)
    else { return nil }
    let progress: MediaProgressRecord? =
      if let itemRowId = record.id {
        try MediaProgressRecord
          .filter(Column("accountId") == record.accountId)
          .filter(Column("itemId") == itemRowId)
          .filter(Column("podcastEpisodeId") == nil)
          .fetchOne(db)
      } else {
        nil
      }
    return makeSummary(record, progressSeconds: progress?.currentTime ?? 0)
  }

  /// Derives `category` from the stored signals (the one place `ItemMediaCategory.derive` may
  /// live) and forwards the stored `addedAt`.
  /// Internal rather than private so `DefaultPodcastShowOrdering` projects rows through this exact
  /// function: a second copy of it would be free to drift from `ItemMediaCategory.derive`.
  static func makeSummary(_ record: ItemRecord) -> ItemSummary {
    makeSummary(record, progressSeconds: 0)
  }

  static func makeSummary(_ record: ItemRecord, progressSeconds: Double) -> ItemSummary {
    ItemSummary(
      serverItemId: record.serverItemId,
      mediaKind: record.mediaKind,
      title: record.title,
      author: record.author,
      durationSeconds: record.durationSeconds,
      progressSeconds: progressSeconds,
      category: ItemMediaCategory.derive(
        mediaKind: record.mediaKind,
        numAudioFiles: record.numAudioFiles,
        ebookFormat: record.ebookFormat
      ),
      hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: record.ebookFormat),
      addedAt: record.addedAt,
      seriesName: record.seriesName,
      narratorName: record.narratorName,
      expandedMetadataFetchedAt: record.expandedMetadataFetchedAt,
      itemDescription: record.itemDescription,
      audioDownloadExpectedBytes: record.audioDownloadExpectedBytes,
      ebookDownloadExpectedBytes: record.ebookDownloadExpectedBytes,
      podcastFeedFingerprint:
        record.mediaKind == ItemMediaCategory.podcast.rawValue
        ? PodcastFeedIdentity.validatedFingerprint(record.podcastFeedFingerprint) : nil,
      serverUpdatedAt: record.serverUpdatedAt
    )
  }

}
