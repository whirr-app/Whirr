import Foundation
import GRDB

/// Reads a smart list's episodes from both sources in one SQL statement per call: a native half
/// over `rssEpisode`, an Audiobookshelf half over `podcastEpisode`, unioned, filtered by the
/// list's rules and ordered by its total sort key (see `SmartListSortKey`). The account is
/// resolved inside each read, as Home does, so a stream started before login emits once it
/// appears. Native subscriptions are a device preference the caller owns: with `nativeEnabled`
/// false the native half is empty, and so is the twin rule that would otherwise prefer it. The
/// statement's shape does not change with either source.
///
/// Each progress write re-runs the observed statement, as Latest's does; `removeDuplicates` over
/// quantized rows stops it reaching the UI.
public struct SmartListEpisodesReading: Sendable {
  public static let defaultLimit = 200
  public static let maximumLimit = 1_000

  private let database: AppDatabase
  private let nativeEnabled: Bool
  private let now: @Sendable () -> Date

  public init(
    database: AppDatabase, nativeEnabled: Bool, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.database = database
    self.nativeEnabled = nativeEnabled
    self.now = now
  }

  // MARK: - Observation

  /// The list's first `limit` rows (at most 1,000), re-emitted whenever they change.
  public func observeEpisodes(
    listID: Int64, limit: Int = SmartListEpisodesReading.defaultLimit
  ) -> AsyncStream<SmartListSnapshot> {
    let limit = min(max(limit, 1), Self.maximumLimit)
    let nativeEnabled = nativeEnabled
    let now = now
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> SmartListSnapshot in
        try Self.snapshot(db, listID: listID, limit: limit, nativeEnabled: nativeEnabled, now: now())
      }.removeDuplicates())
  }

  /// The same read `observeEpisodes` performs, once. Observation retries a failing query forever
  /// without emitting, so this is where a SQL error surfaces as a thrown error.
  public func fetchSnapshot(
    listID: Int64, limit: Int = SmartListEpisodesReading.defaultLimit
  ) async throws -> SmartListSnapshot {
    let limit = min(max(limit, 1), Self.maximumLimit)
    let nativeEnabled = nativeEnabled
    let now = now()
    return try await database.dbWriter.read { db in
      try Self.snapshot(db, listID: listID, limit: limit, nativeEnabled: nativeEnabled, now: now)
    }
  }

  private static func snapshot(
    _ db: Database, listID: Int64, limit: Int, nativeEnabled: Bool, now: Date
  ) throws -> SmartListSnapshot {
    guard
      let query = try Self.query(
        db, listID: listID, nativeEnabled: nativeEnabled, now: now, unfinishedOnly: false)
    else { return .empty }
    let statement = query.listStatement(limit: limit + 1, withCount: true)
    let rows = try Row.fetchAll(db, sql: statement.sql, arguments: statement.arguments)
    let order = query.rules.sortOrder
    let episodes = rows.prefix(limit).compactMap {
      SmartListQuery.episode(from: $0, order: order)
    }
    return SmartListSnapshot(
      episodes: episodes, hasMore: rows.count > limit,
      matchCount: rows.first.map { $0["matchCount"] as Int } ?? 0)
  }

  // MARK: - One-shot reads

  /// What a run plays next: unfinished episodes only, whatever the Played toggle says. Priority
  /// episodes first (never the anchor itself), then those strictly after `anchor` in list order,
  /// then the rest from the top, so the run drains the list. A nil anchor, or one written under
  /// another sort order, starts from the top. `excluding` drops those identities from all three
  /// groups. A still-unfinished anchor can come back last, from the wrap.
  public func nextEpisodes(
    listID: Int64, after anchor: SmartListSortKey?,
    excluding: [(itemID: String, episodeID: String)] = [], count: Int
  ) async throws -> [SmartListCandidate] {
    guard count > 0 else { return [] }
    let nativeEnabled = nativeEnabled
    let now = now()
    return try await database.readAsync { db in
      guard
        let query = try Self.query(
          db, listID: listID, nativeEnabled: nativeEnabled, now: now, unfinishedOnly: true)
      else { return [] }
      let usableAnchor = anchor.flatMap { $0.order == query.rules.sortOrder ? $0 : nil }
      let statement = query.nextStatement(after: usableAnchor, excluding: excluding, count: count)
      return try Row.fetchAll(db, sql: statement.sql, arguments: statement.arguments)
        .compactMap { SmartListQuery.episode(from: $0, order: query.rules.sortOrder) }
        .map(SmartListCandidate.init(episode:))
    }
  }

  /// The list's first `count` unfinished episodes in plain list order, for auto-download.
  public func topEpisodes(listID: Int64, count: Int) async throws -> [SmartListCandidate] {
    try await nextEpisodes(listID: listID, after: nil, count: count)
  }

  /// Every auto-downloading list's top episodes, lists in display order, each in list order: the
  /// wanted set before it is unioned. Independent of any run.
  public func wantedEpisodes() async throws -> [SmartListWantedEpisode] {
    let nativeEnabled = nativeEnabled
    let now = now()
    return try await database.readAsync { db in
      try Self.wanted(db, nativeEnabled: nativeEnabled, now: now)
    }
  }

  /// The wanted set's identities, re-emitted when they change: an episode joins or leaves a top
  /// N, a list's limit or rules change, auto-download turns on or off, or a list is deleted. Not
  /// a download or progress write that changes nothing about membership.
  public func observeWantedEpisodes() -> AsyncStream<[SmartListWantedEpisode.Key]> {
    let nativeEnabled = nativeEnabled
    let now = now
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> [SmartListWantedEpisode.Key] in
        try Self.wanted(db, nativeEnabled: nativeEnabled, now: now()).map(\.key)
      }.removeDuplicates())
  }

  /// Internal so `SmartListDownloadStore.declineWanted` can recompute the set inside its write.
  /// A list auto-downloads only while it includes both download states: a Not
  /// downloaded list would drop each episode as it finished downloading, release it, and request
  /// it again; a Downloaded list would request nothing.
  static func wanted(
    _ db: Database, nativeEnabled: Bool, now: Date
  ) throws -> [SmartListWantedEpisode] {
    let lists = try SmartListRecord.fetchAll(
      db,
      sql: """
        SELECT * FROM smartList
        WHERE autoDownload = 1 AND includeDownloaded = 1 AND includeNotDownloaded = 1
        ORDER BY position, id
        """)
    var wanted: [SmartListWantedEpisode] = []
    for list in lists {
      guard let listID = list.id,
        let query = try Self.query(
          db, listID: listID, nativeEnabled: nativeEnabled, now: now, unfinishedOnly: true)
      else { continue }
      let statement = query.nextStatement(
        after: nil, excluding: [], count: list.autoDownloadLimit.rawValue)
      wanted += try Row.fetchAll(db, sql: statement.sql, arguments: statement.arguments)
        .compactMap { SmartListQuery.episode(from: $0, order: query.rules.sortOrder) }
        .map {
          SmartListWantedEpisode(
            listID: listID, source: $0.source, itemID: $0.itemID, episodeID: $0.episodeID)
        }
    }
    return wanted
  }

  /// How many episodes an unsaved draft would match. `listID` makes an existing list's hidden
  /// episodes count as hidden.
  public func matchCount(
    rules: SmartListRules, shows: [SmartListShowSelection], listID: Int64? = nil
  ) async throws -> Int {
    let nativeEnabled = nativeEnabled
    let now = now()
    return try await database.readAsync { db in
      let query = SmartListQuery(
        rules: rules, shows: .draft(shows), hiddenListID: listID,
        account: try Self.account(db), nativeEnabled: nativeEnabled, now: now,
        unfinishedOnly: false)
      let statement = query.countStatement()
      return try Int.fetchOne(db, sql: statement.sql, arguments: statement.arguments) ?? 0
    }
  }

  /// Show keys (`serverUserId|serverItemId`) of this account's podcasts that have a followed
  /// native feed with the same feed fingerprint: Recently Added's show-level rule, which hides
  /// the Audiobookshelf copy. The editor's picker lists such a show once, as the native one.
  public func serverShowKeysWithFollowedNativeTwin() async throws -> Set<String> {
    try await database.readAsync { db in
      guard let account = try Self.account(db) else { return [] }
      let sql = """
        SELECT DISTINCT account.serverUserId || '|' || item.serverItemId
        FROM item
        JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
        JOIN account ON account.id = item.accountId
        WHERE item.accountId = ?
          AND item.mediaKind = 'podcast' AND \(ItemVisibilityPredicate.sql)
          AND \(DefaultHomeReading.validFingerprintSQL("item.podcastFeedFingerprint"))
          AND EXISTS (
            SELECT 1 FROM rssFeed AS feed
            WHERE feed.podcastFeedFingerprint = item.podcastFeedFingerprint
              AND \(DefaultHomeReading.validFingerprintSQL("feed.podcastFeedFingerprint")))
        """
      return Set(try String.fetchAll(db, sql: sql, arguments: [account.id]))
    }
  }

  // MARK: - Helpers

  private static func account(_ db: Database) throws -> SmartListQuery.AccountBinding? {
    guard let record = try AccountRecord.fetchOne(db), let id = record.id else { return nil }
    return SmartListQuery.AccountBinding(
      id: id, clientUUID: record.clientUUID,
      serverIdentityFingerprint: record.serverIdentityFingerprint)
  }

  private static func query(
    _ db: Database, listID: Int64, nativeEnabled: Bool, now: Date, unfinishedOnly: Bool
  ) throws -> SmartListQuery? {
    guard let record = try SmartListRecord.fetchOne(db, key: listID) else { return nil }
    return SmartListQuery(
      rules: record.rules, shows: .stored(listID: listID), hiddenListID: listID,
      account: try account(db), nativeEnabled: nativeEnabled, now: now,
      unfinishedOnly: unfinishedOnly)
  }
}
