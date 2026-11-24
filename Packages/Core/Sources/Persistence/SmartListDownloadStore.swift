import Foundation
import GRDB

/// What `SmartListDownloadReconciler` reads and writes besides the download boundary: the wanted
/// set, the claims, the request-time probe, the shared "kept besides" check, hand-removal
/// declines, hidden-episode and decline pruning, and deleting a list.
///
/// An episode is a `(itemID, episodeID)` pair as the reading names it: a server item and episode
/// id, or `rss:<feedId>` and the native episode's identity key.
public struct SmartListDownloadStore: Sendable {
  private let database: AppDatabase
  private let nativeEnabled: @Sendable () async -> Bool
  private let activeNativeEpisodeIDs: @Sendable () -> Set<Int64>
  private let now: @Sendable () -> Date

  /// `nativeEnabled` is the device's native-subscriptions preference, read per call. A switch-off
  /// empties the native half of every wanted set, so its claims are released. The active native
  /// episode ids come from the playback tracker, as the storage ceiling's exclusion does.
  public init(
    database: AppDatabase,
    nativeEnabled: @escaping @Sendable () async -> Bool = { true },
    activeNativeEpisodeIDs: @escaping @Sendable () -> Set<Int64> = { [] },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.database = database
    self.nativeEnabled = nativeEnabled
    self.activeNativeEpisodeIDs = activeNativeEpisodeIDs
    self.now = now
  }

  // MARK: - Wanted set

  public func wantedEpisodes() async throws -> [SmartListWantedEpisode] {
    try await reading().wantedEpisodes()
  }

  /// Membership changes of the wanted set. Reads the native preference once, when called.
  public func observeWantedEpisodes() async -> AsyncStream<[SmartListWantedEpisode.Key]> {
    await reading().observeWantedEpisodes()
  }

  private func reading() async -> SmartListEpisodesReading {
    SmartListEpisodesReading(database: database, nativeEnabled: await nativeEnabled(), now: now)
  }

  // MARK: - Claims

  public func claims() async throws -> [SmartListDownloadClaimRecord] {
    try await SmartListDownloadClaimStore(database: database).allClaims()
  }

  public func recordClaim(
    listID: Int64, itemID: String, episodeID: String, accountID: Int64?, at date: Date
  ) async throws {
    try await SmartListDownloadClaimStore(database: database).add(
      listID: listID, itemID: itemID, episodeID: episodeID, accountID: accountID, now: date)
  }

  public func dropClaim(listID: Int64, itemID: String, episodeID: String) async throws {
    try await SmartListDownloadClaimStore(database: database).remove(
      listID: listID, itemID: itemID, episodeID: episodeID)
  }

  /// Whether any list holds a claim on the episode, other than `excluding`'s.
  public func hasClaim(itemID: String, episodeID: String, excluding listID: Int64? = nil)
    async throws -> Bool
  {
    try await database.readAsync { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(SELECT 1 FROM smartListDownloadClaim
            WHERE itemID = ? AND episodeID = ? AND listId IS NOT ?)
          """,
        arguments: [itemID, episodeID, listID]) ?? false
    }
  }

  // MARK: - Downloads

  /// Whether the episode has a download row of any origin and state. Server episodes resolve
  /// under `accountID`; with none, a server episode has no row to find.
  public func hasDownloadRow(itemID: String, episodeID: String, accountID: Int64?) async throws
    -> Bool
  {
    try await database.readAsync { db in
      try Self.hasDownloadRow(db, itemID: itemID, episodeID: episodeID, accountID: accountID)
    }
  }

  /// What the reconciler may do with a wanted episode at request time, in one read: a hand
  /// removal declined it, something already downloads it, or it may be requested. A decline wins
  /// over a row, so a declined episode is neither requested nor claimed by sharing.
  public func requestState(itemID: String, episodeID: String, accountID: Int64?) async throws
    -> SmartListRequestState
  {
    try await database.readAsync { db in
      if try Self.isDeclined(db, itemID: itemID, episodeID: episodeID) { return .declined }
      return try Self.hasDownloadRow(db, itemID: itemID, episodeID: episodeID, accountID: accountID)
        ? .hasDownloadRow : .requestable
    }
  }

  private static func hasDownloadRow(
    _ db: Database, itemID: String, episodeID: String, accountID: Int64?
  ) throws -> Bool {
    if let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      return try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(SELECT 1 FROM rssDownload AS download
            JOIN rssEpisode AS episode ON episode.id = download.episodeId
            WHERE episode.feedId = ? AND episode.identityKey = ?)
          """,
        arguments: [feedID, episodeID]) ?? false
    }
    guard let accountID else { return false }
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM download
          JOIN item ON item.id = download.itemId AND item.accountId = download.accountId
          JOIN podcastEpisode AS episode ON episode.id = download.podcastEpisodeId
          WHERE download.accountId = ? AND item.serverItemId = ?
            AND episode.serverEpisodeId = ?)
        """,
      arguments: [accountID, itemID, episodeID]) ?? false
  }

  /// Whether anything other than a smart list's claim keeps this episode's download: a stored
  /// pinned list (server episodes only), Up Next, Saved for Later, active playback, or a transfer
  /// in flight. The same listening checks the pinned-list release makes.
  public func isKeptBesidesClaims(itemID: String, episodeID: String, accountID: Int64?)
    async throws -> Bool
  {
    let active = activeNativeEpisodeIDs()
    return try await database.readAsync { db in
      if let accountID, PodcastSourceIdentity(itemId: itemID)?.rssFeedId == nil,
        try PinnedListStore.isPinned(
          db: db, accountID: accountID,
          member: PinnedListMember(serverItemID: itemID, serverEpisodeID: episodeID))
      {
        return true
      }
      return try DownloadKeepChecks.isKeptByListening(
        db, accountID: accountID, itemID: itemID, episodeID: episodeID,
        activeNativeEpisodeIDs: active)
    }
  }

  // MARK: - Lists

  /// Deletes a list. Its claims cascade with it, so a caller that releases them reads them first.
  public func deleteList(id: Int64) async throws {
    try await SmartListStore(database: database).delete(id: id)
  }

  // MARK: - Hidden episodes

  /// Drops hidden-episode rows whose episode is finished or gone. A server episode is
  /// judged only where the device holds it, so a signed-out device keeps its server rows.
  /// Returns the number removed.
  @discardableResult
  public func pruneHiddenEpisodes() async throws -> Int {
    let stale = try await database.readAsync { db in
      try Self.staleEpisodes(db, table: "smartListHiddenEpisode")
    }
    guard stale.isEmpty == false else { return 0 }
    return try await SmartListHiddenEpisodeStore(database: database).prune(episodes: stale)
  }

  // MARK: - Declines

  /// Declines each episode an auto-downloading list wants right now that matches: the one
  /// episode, every episode of `itemID` when `episodeID` is nil, or every wanted episode when
  /// `itemID` is nil (Remove All). One row per episode across lists. The set is
  /// recomputed in the same transaction as the insert, so a list edit cannot slip between them;
  /// the native preference and the clock are sampled just before. Returns what it declined.
  /// Claims are left alone: the caller drops them once the purge has succeeded.
  @discardableResult
  public func declineWanted(
    itemID: String?, episodeID: String?, accountID: Int64?, at date: Date
  ) async throws -> [SmartListEpisodeIdentity] {
    let nativeEnabled = await nativeEnabled()
    let now = now()
    return try await database.writeAsync { db in
      var declined: [SmartListEpisodeIdentity] = []
      for episode in try SmartListEpisodesReading.wanted(db, nativeEnabled: nativeEnabled, now: now) {
        if let itemID, episode.itemID != itemID { continue }
        if let episodeID, episode.episodeID != episodeID { continue }
        let identity = SmartListEpisodeIdentity(itemID: episode.itemID, episodeID: episode.episodeID)
        guard declined.contains(identity) == false else { continue }
        let account = episode.source == .native ? nil : accountID
        if episode.source == .server, account == nil { continue }
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO smartListDownloadDecline (itemID, episodeID, accountId, declinedAt)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [episode.itemID, episode.episodeID, account, date])
        declined.append(identity)
      }
      return declined
    }
  }

  /// Drops every list's claim on these episodes, once their files are gone.
  public func dropClaims(episodes: [SmartListEpisodeIdentity]) async throws {
    guard episodes.isEmpty == false else { return }
    try await database.writeAsync { db in
      for episode in episodes {
        try db.execute(
          sql: "DELETE FROM smartListDownloadClaim WHERE itemID = ? AND episodeID = ?",
          arguments: [episode.itemID, episode.episodeID])
      }
    }
  }

  /// Clears a decline after a hand download; `episodeID` nil clears the item's.
  public func clearDecline(itemID: String, episodeID: String?) async throws {
    try await database.writeAsync { db in
      if let episodeID {
        try db.execute(
          sql: "DELETE FROM smartListDownloadDecline WHERE itemID = ? AND episodeID = ?",
          arguments: [itemID, episodeID])
      } else {
        try db.execute(
          sql: "DELETE FROM smartListDownloadDecline WHERE itemID = ?", arguments: [itemID])
      }
    }
  }

  public func isDeclined(itemID: String, episodeID: String) async throws -> Bool {
    try await database.readAsync { db in
      try Self.isDeclined(db, itemID: itemID, episodeID: episodeID)
    }
  }

  /// Drops declines whose episode is finished or gone, by the hidden rows' rule.
  /// Returns the number removed.
  @discardableResult
  public func pruneDeclines() async throws -> Int {
    try await database.writeAsync { db in
      var removed = 0
      for episode in try Self.staleEpisodes(db, table: "smartListDownloadDecline") {
        try db.execute(
          sql: "DELETE FROM smartListDownloadDecline WHERE itemID = ? AND episodeID = ?",
          arguments: [episode.itemID, episode.episodeID])
        removed += db.changesCount
      }
      return removed
    }
  }

  private static func isDeclined(_ db: Database, itemID: String, episodeID: String) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM smartListDownloadDecline WHERE itemID = ? AND episodeID = ?)
        """,
      arguments: [itemID, episodeID]) ?? false
  }

  // MARK: - Finished or gone

  /// The distinct episodes in `table` (keyed by `itemID`, `episodeID`) that are finished or no
  /// longer exist. A server episode is judged only where the device holds it.
  private static func staleEpisodes(_ db: Database, table: String)
    throws -> [(itemID: String, episodeID: String)]
  {
    try Row.fetchAll(
      db,
      sql: """
        SELECT DISTINCT marked.itemID, marked.episodeID FROM \(table) AS marked
        WHERE CASE WHEN marked.itemID LIKE 'rss:%' THEN
            NOT EXISTS (
              SELECT 1 FROM rssEpisode AS episode
              WHERE episode.feedId = CAST(substr(marked.itemID, 5) AS INTEGER)
                AND episode.identityKey = marked.episodeID)
            OR EXISTS (
              SELECT 1 FROM rssEpisode AS episode
              JOIN rssEpisodeState AS state ON state.episodeId = episode.id
              WHERE episode.feedId = CAST(substr(marked.itemID, 5) AS INTEGER)
                AND episode.identityKey = marked.episodeID AND state.finished = 1)
          ELSE
            EXISTS (
              SELECT 1 FROM podcastEpisode AS episode
              JOIN item ON item.id = episode.itemId
              WHERE item.serverItemId = marked.itemID
                AND episode.serverEpisodeId = marked.episodeID
                AND (episode.softDeleted = 1 OR EXISTS (
                  SELECT 1 FROM mediaProgress AS progress
                  WHERE progress.accountId = episode.accountId
                    AND progress.itemId = episode.itemId
                    AND progress.podcastEpisodeId = episode.id
                    AND progress.isFinished = 1)))
          END
        """
    ).map { (itemID: $0["itemID"] as String, episodeID: $0["episodeID"] as String) }
  }
}

/// A smart-list episode as claims and declines name it: a server item and episode id, or
/// `rss:<feedId>` and the native `identityKey`.
public struct SmartListEpisodeIdentity: Sendable, Hashable {
  public let itemID: String
  public let episodeID: String

  public init(itemID: String, episodeID: String) {
    self.itemID = itemID
    self.episodeID = episodeID
  }
}

/// What `SmartListDownloadStore.requestState` found for a wanted episode.
public enum SmartListRequestState: Sendable, Equatable {
  case declined
  case hasDownloadRow
  case requestable
}
