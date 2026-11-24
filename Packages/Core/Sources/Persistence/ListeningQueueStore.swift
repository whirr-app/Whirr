import Foundation
import GRDB

/// The one durable Up Next store: an account-scoped dense ordering with a
/// temporary-negative-position renumber, resolving either an audiobook or a podcast-episode
/// `ListeningIdentity` against `listeningQueueEntry`. There is no second queue for either medium.
public struct ListeningQueueStore: ListeningQueueReading, ListeningQueuePrefixReading,
  ListeningQueueDownloadCandidateReading, ListeningQueueStoring, Sendable
{
  let database: AppDatabase
  let accountId: Int64?
  let mutationCheckpoint: @Sendable (ListeningQueueMutationCheckpoint) throws -> Void

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
    self.mutationCheckpoint = { _ in }
  }

  public init(database: AppDatabase) {
    self.database = database
    self.accountId = nil
    self.mutationCheckpoint = { _ in }
  }

  init(
    database: AppDatabase,
    accountId: Int64?,
    mutationCheckpoint: @escaping @Sendable (ListeningQueueMutationCheckpoint) throws -> Void
  ) {
    self.database = database
    self.accountId = accountId
    self.mutationCheckpoint = mutationCheckpoint
  }

  /// Every row of the title, whole-book and chapter alike.
  public func remove(identity: ListeningIdentity) async throws {
    try await removeRows(of: identity) { _ in true }
  }

  public func remove(rowID: Int64) async throws {
    try await database.writeAsync { db in
      var rows = try NativeListeningQueueWriter.records(in: db)
      guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
      try Self.deleteRows(at: [index], from: &rows, in: db)
      try NativeListeningQueueWriter.persist(rows, in: db, checkpoint: mutationCheckpoint)
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
    }
  }

  public func move(rowID: Int64, to position: Int) async throws {
    try await database.writeAsync { db in
      var rows = try NativeListeningQueueWriter.records(in: db)
      guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
      let row = rows.remove(at: index)
      rows.insert(row, at: min(max(position, 0), rows.count))
      try NativeListeningQueueWriter.persist(rows, in: db, checkpoint: mutationCheckpoint)
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
    }
  }

  public func clear() async throws -> ListeningQueueRestoreToken {
    try await database.writeAsync { db in
      let entries = try Self.fetchItems(db, accountId: accountId).map {
        ListeningQueueRestoreToken.Entry(
          identity: $0.identity, chapter: $0.chapter,
          downloadDeclinedAt: try Self.downloadDeclinedAt(db, accountId: accountId, identity: $0.identity))
      }
      _ =
        try ListeningQueueEntryRecord
        .filter(Column("accountId") == accountId)
        .deleteAll(db)
      try db.execute(sql: "DELETE FROM rssListeningQueueEntry")
      try NativeListeningQueueWriter.compact(in: db)
      let revision = try NativeListeningQueueWriter.bumpRevision(in: db)
      return ListeningQueueRestoreToken(
        accountId: accountId, revision: revision, entries: entries)
    }
  }

  /// One transaction, all or nothing: every identity in the token must still resolve (a
  /// tombstone is tolerated) before any row is inserted. Restoring bumps the revision, so
  /// replaying the same token fails `restoreTokenStale` with no separate "consumed" flag.
  public func restore(token: ListeningQueueRestoreToken) async throws {
    guard token.accountId == accountId else {
      throw ListeningQueueStoreError.restoreTokenWrongAccount
    }
    try await database.writeAsync { db in
      guard try NativeListeningQueueWriter.revision(in: db) == token.revision else {
        throw ListeningQueueStoreError.restoreTokenStale
      }
      var restored: [ListeningQueueEntryRecord] = []
      for (index, entry) in token.entries.enumerated() {
        let resolved = try Self.resolveTolerantOfTombstone(
          db, accountId: accountId, identity: entry.identity)
        restored.append(
          Self.makeEntry(
            accountId: accountId, resolved: resolved, position: index, chapter: entry.chapter))
      }
      try NativeListeningQueueWriter.persist(
        restored + NativeListeningQueueWriter.records(in: db), in: db, checkpoint: mutationCheckpoint)
      // Restored rows have new ids, so each decline goes back by identity.
      for entry in token.entries {
        guard let declinedAt = entry.downloadDeclinedAt else { continue }
        try Self.setDownloadDeclined(
          db, accountId: accountId, target: DeclineTarget(entry.identity), at: declinedAt)
      }
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
    }
  }

  public func peekNextLive() async -> ListeningQueueItem? {
    (try? await database.readAsync { db in
      try Self.fetchItems(db, accountId: accountId).first { !$0.isTombstone }
    }) ?? nil
  }

  /// The title's whole-book (or episode) row, and the started chapter row when `rowID` names
  /// one, in one transaction. Another chapter row of the book stays.
  public func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {
    try await removeRows(of: identity) { $0.chapterStart == nil || $0.id == rowID }
  }

  private func removeRows(
    of identity: ListeningIdentity, where include: @escaping @Sendable (ListeningQueueEntryRecord) -> Bool
  ) async throws {
    try await database.writeAsync { db in
      let doomed = try Self.entries(db, accountId: accountId, identity: identity).filter(include)
      guard doomed.isEmpty == false else { return }
      for row in doomed { try NativeListeningQueueWriter.delete(row, in: db) }
      try NativeListeningQueueWriter.persist(
        try NativeListeningQueueWriter.records(in: db), in: db, checkpoint: mutationCheckpoint)
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
    }
  }

  public func fetchQueue() async -> [ListeningQueueItem] {
    (try? await database.readAsync { db in
      try Self.fetchItems(db, accountId: accountId)
    }) ?? []
  }

  public func fetchQueueIdentitiesWithoutDownloads() async throws -> [ListeningIdentity] {
    let rows = try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT
            queue.position AS queuePosition,
            queue.id AS queueID,
            0 AS sourceTag,
            item.serverItemId,
            episode.serverEpisodeId,
            NULL AS rssFeedId,
            NULL AS rssEpisodeIdentity
          FROM listeningQueueEntry AS queue
          JOIN item
            ON item.id = queue.itemId AND item.accountId = queue.accountId
          LEFT JOIN podcastEpisode AS episode
            ON episode.id = queue.podcastEpisodeId AND episode.accountId = queue.accountId
          WHERE queue.accountId = ? AND queue.itemId IS NOT NULL
            AND queue.downloadDeclinedAt IS NULL
            AND NOT EXISTS (
              SELECT 1
              FROM download
              WHERE download.accountId = queue.accountId
                AND download.itemId = queue.itemId
                AND download.mediaKind = ?
                AND (
                  (queue.podcastEpisodeId IS NULL AND download.podcastEpisodeId IS NULL)
                  OR (
                    queue.podcastEpisodeId IS NOT NULL
                    AND download.podcastEpisodeId = queue.podcastEpisodeId
                  )
                )
            )

          UNION ALL

          SELECT
            queue.position AS queuePosition,
            queue.id AS queueID,
            1 AS sourceTag,
            NULL AS serverItemId,
            NULL AS serverEpisodeId,
            rssEpisode.feedId AS rssFeedId,
            rssEpisode.identityKey AS rssEpisodeIdentity
          FROM rssListeningQueueEntry AS queue
          JOIN rssEpisode ON rssEpisode.id = queue.rssEpisodeId
          WHERE queue.rssEpisodeId IS NOT NULL
            AND queue.downloadDeclinedAt IS NULL
            AND NOT EXISTS (
              SELECT 1 FROM rssDownload
              WHERE rssDownload.episodeId = queue.rssEpisodeId
            )

          ORDER BY queuePosition, sourceTag, queueID
          """,
        arguments: [accountId, DownloadMediaKind.audio.rawValue]
      ).compactMap { row -> ListeningIdentity? in
        if let feedID = row["rssFeedId"] as Int64?,
          let episodeID = row["rssEpisodeIdentity"] as String?
        {
          return .rssEpisode(feedID: feedID, episodeID: episodeID)
        }
        let itemID: String = row["serverItemId"]
        if let episodeID = row["serverEpisodeId"] as String? {
          return .podcastEpisode(itemID: itemID, episodeID: episodeID)
        }
        return .audiobook(itemID: itemID)
      }
    }
    // Several chapter rows of one book name it once, at its first position.
    var seen: Set<ListeningIdentity> = []
    return rows.filter { seen.insert($0).inserted }
  }

  public func observeQueue() -> AsyncStream<[ListeningQueueItem]> {
    // Each emission replaces the whole queue. Both layers keep only the newest, so a suspended
    // sheet resumes at the current order without applying obsolete intermediate ones.
    ObservationBridge.stream(
      in: database.dbWriter, deduplication: .everyChange
    ) { db in
      try Self.fetchItems(db, accountId: accountId)
    }
  }

  public func observeLiveQueue(limit: Int) -> AsyncStream<[ListeningQueueItem]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { [accountId] db in
        try Self.fetchItems(db, accountId: accountId, liveLimit: limit)
      }.removeDuplicates())
  }

  // MARK: - Resolution

  /// Applies every insertion-time rejection rule: unknown or wrong-account item, a soft-deleted
  /// item, an ebook, and a category/identity-shape mismatch in either direction. Used by
  /// `append`/`insertNext` only, never by `remove`/`move`/`acknowledgeStarted`, which must still
  /// find an already-tombstoned row.
  static func resolveForInsertion(
    _ db: Database, accountId: Int64?, identity: ListeningIdentity
  ) throws -> (itemId: Int64?, episodeId: Int64?, rssEpisodeId: Int64?) {
    if case .rssEpisode(let feedID, let episodeID) = identity.source {
      guard
        let rssEpisodeId = try Self.rssEpisodeID(db, feedID: feedID, episodeID: episodeID)
      else { throw ListeningQueueStoreError.episodeNotFound }
      return (nil, nil, rssEpisodeId)
    }

    let itemRow = try Self.fetchItemRow(db, accountId: accountId, itemID: identity.itemID)
    let itemId: Int64 = itemRow["id"]
    let category = ItemMediaCategory.derive(
      mediaKind: itemRow["mediaKind"], numAudioFiles: itemRow["numAudioFiles"],
      ebookFormat: itemRow["ebookFormat"])

    switch identity.source {
    case .audiobook:
      switch category {
      case .ebook: throw ListeningQueueStoreError.ebookNotQueueable
      case .podcast: throw ListeningQueueStoreError.episodeIdentityRequired
      case .audiobook: return (itemId, nil, nil)
      }
    case .podcastEpisode(_, let episodeID):
      switch category {
      case .ebook: throw ListeningQueueStoreError.ebookNotQueueable
      case .audiobook: throw ListeningQueueStoreError.episodeIdentityNotAllowed
      case .podcast: break
      }
      guard
        let episodeId = try Int64.fetchOne(
          db,
          sql: """
            SELECT id FROM podcastEpisode
            WHERE accountId = ? AND itemId = ? AND serverEpisodeId = ?
            """,
          arguments: [accountId, itemId, episodeID])
      else { throw ListeningQueueStoreError.episodeNotFound }
      return (itemId, episodeId, nil)
    case .rssEpisode:
      preconditionFailure("RSS identities resolve before ABS item lookup")
    }
  }

  /// The item row, rejecting only "wrong account or unknown" and "soft-deleted", the two checks
  /// that apply regardless of media category.
  private static func fetchItemRow(_ db: Database, accountId: Int64?, itemID: String) throws -> Row {
    guard
      let itemRow = try Row.fetchOne(
        db,
        sql: """
          SELECT id, mediaKind, numAudioFiles, ebookFormat, softDeleted
          FROM item WHERE accountId = ? AND serverItemId = ?
          """,
        arguments: [accountId, itemID])
    else { throw ListeningQueueStoreError.itemNotFound }
    if itemRow["softDeleted"] as Bool {
      throw ListeningQueueStoreError.itemSoftDeleted
    }
    return itemRow
  }

  /// Resolves an identity to its row ids as `resolveForInsertion` does, but tolerates a
  /// tombstoned item/episode, so `restore(token:)` can restore an identity as its existing
  /// tombstone. Only outright absence (a hard-deleted row) fails.
  private static func resolveTolerantOfTombstone(
    _ db: Database, accountId: Int64?, identity: ListeningIdentity
  ) throws -> (itemId: Int64?, episodeId: Int64?, rssEpisodeId: Int64?) {
    switch identity.source {
    case .audiobook(let itemID):
      guard
        let itemId = try Int64.fetchOne(
          db, sql: "SELECT id FROM item WHERE accountId = ? AND serverItemId = ?",
          arguments: [accountId, itemID])
      else { throw ListeningQueueStoreError.restoreIdentityUnavailable }
      return (itemId, nil, nil)
    case .podcastEpisode(let itemID, let episodeID):
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT item.id AS itemId, episode.id AS episodeId
            FROM item
            JOIN podcastEpisode AS episode
              ON episode.itemId = item.id AND episode.accountId = item.accountId
            WHERE item.accountId = ?
              AND item.serverItemId = ?
              AND episode.serverEpisodeId = ?
            LIMIT 1
            """,
          arguments: [accountId, itemID, episodeID]),
        let itemId = row["itemId"] as Int64?,
        let episodeId = row["episodeId"] as Int64?
      else { throw ListeningQueueStoreError.restoreIdentityUnavailable }
      return (itemId, episodeId, nil)
    case .rssEpisode(let feedID, let episodeID):
      guard
        let rssEpisodeId = try Self.rssEpisodeID(db, feedID: feedID, episodeID: episodeID)
      else { throw ListeningQueueStoreError.restoreIdentityUnavailable }
      return (nil, nil, rssEpisodeId)
    }
  }

  /// The existing rows for an identity (a book may have several chapter rows), at any position,
  /// tolerant of a tombstoned item/episode. Used by `remove` and `acknowledgeStarted`, never
  /// insertion validation.
  static func entries(
    _ db: Database, accountId: Int64?, identity: ListeningIdentity
  ) throws -> [ListeningQueueEntryRecord] {
    switch identity.source {
    case .audiobook(let itemID):
      return try ListeningQueueEntryRecord.fetchAll(
        db,
        sql: """
          SELECT queue.*
          FROM listeningQueueEntry AS queue
          JOIN item ON item.id = queue.itemId AND item.accountId = queue.accountId
          WHERE queue.accountId = ?
            AND queue.podcastEpisodeId IS NULL
            AND item.serverItemId = ?
          """,
        arguments: [accountId, itemID])
    case .podcastEpisode(let itemID, let episodeID):
      return try ListeningQueueEntryRecord.fetchAll(
        db,
        sql: """
            SELECT queue.*
            FROM listeningQueueEntry AS queue
            JOIN podcastEpisode AS episode
              ON episode.id = queue.podcastEpisodeId AND episode.accountId = queue.accountId
            JOIN item ON item.id = episode.itemId AND item.accountId = episode.accountId
            WHERE queue.accountId = ?
              AND item.serverItemId = ?
              AND episode.serverEpisodeId = ?
          """,
        arguments: [accountId, itemID, episodeID])
    case .rssEpisode(let feedID, let episodeID):
      return try ListeningQueueEntryRecord.fetchAll(
        db,
        sql: """
          SELECT -queue.id AS id, 0 AS accountId, NULL AS itemId, NULL AS podcastEpisodeId,
                 queue.rssEpisodeId, queue.position
          FROM rssListeningQueueEntry AS queue JOIN rssEpisode ON rssEpisode.id = queue.rssEpisodeId
          WHERE rssEpisode.feedId = ? AND rssEpisode.identityKey = ?
          """, arguments: [feedID, episodeID])
    }
  }

  /// Any row of the same title, whatever its extent.
  static func matches(
    _ row: ListeningQueueEntryRecord,
    resolved: (itemId: Int64?, episodeId: Int64?, rssEpisodeId: Int64?)
  ) -> Bool {
    row.itemId == resolved.itemId && row.podcastEpisodeId == resolved.episodeId
      && row.rssEpisodeId == resolved.rssEpisodeId
  }

  static func makeEntry(
    accountId: Int64?,
    resolved: (itemId: Int64?, episodeId: Int64?, rssEpisodeId: Int64?),
    position: Int,
    chapter: ListeningQueueChapter? = nil
  ) -> ListeningQueueEntryRecord {
    ListeningQueueEntryRecord(
      accountId: accountId ?? 0,
      itemId: resolved.itemId,
      podcastEpisodeId: resolved.episodeId,
      rssEpisodeId: resolved.rssEpisodeId,
      position: position,
      chapterStart: chapter?.start,
      chapterEnd: chapter?.end,
      chapterTitle: chapter?.title)
  }

  private static func rssEpisodeID(
    _ db: Database, feedID: Int64, episodeID: String
  ) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
      arguments: [feedID, episodeID])
  }

  // MARK: - Projection

  /// One row per queue entry, projecting ABS and RSS episode sources into the same queue value.
  /// ABS category is derived here in Swift; RSS is always a podcast.
  /// True for a queue row that is not a tombstone: the same three rules the row mapping in
  /// `fetchItems` applies.
  private static let liveRowSQL = """
    AND CASE
      WHEN queue.rssEpisodeId IS NOT NULL
        THEN rssEpisode.lastSeenGeneration >= rssFeed.refreshGeneration
      -- Not a catalogue projection: the queue names the title it holds.
      ELSE item.softDeleted = 0 AND COALESCE(episode.softDeleted, 0) = 0
    END
    """

  private static func chapter(_ row: Row) -> ListeningQueueChapter? {
    guard let start = row["chapterStart"] as Double?, let end = row["chapterEnd"] as Double?
    else { return nil }
    return ListeningQueueChapter(start: start, end: end, title: row["chapterTitle"])
  }

  /// `liveLimit` reads only the first that many rows that are not tombstones.
  private static func fetchItems(
    _ db: Database, accountId: Int64?, liveLimit: Int? = nil
  ) throws -> [ListeningQueueItem] {
    let liveOnly = liveLimit == nil ? "" : liveRowSQL
    return try Row.fetchAll(
      db,
      sql: """
        SELECT
          queue.id,
          queue.position,
          queue.chapterStart,
          queue.chapterEnd,
          queue.chapterTitle,
          item.serverItemId,
          item.title AS itemTitle,
          item.author AS itemAuthor,
          item.mediaKind,
          item.numAudioFiles,
          item.ebookFormat,
          item.softDeleted AS itemSoftDeleted,
          item.serverUpdatedAt AS itemServerUpdatedAt,
          episode.serverEpisodeId,
          episode.title AS episodeTitle,
          episode.softDeleted AS episodeSoftDeleted,
          rssEpisode.feedId AS rssFeedId,
          rssEpisode.identityKey AS rssEpisodeIdentity,
          rssEpisode.title AS rssEpisodeTitle,
          rssEpisode.lastSeenGeneration AS rssLastSeenGeneration,
          rssFeed.title AS rssFeedTitle,
          rssFeed.feedURL AS rssFeedURL,
          rssFeed.artworkURL AS rssArtworkURL,
          rssEpisode.artworkURL AS rssEpisodeArtworkURL,
          rssFeed.refreshGeneration AS rssRefreshGeneration
        FROM (\(NativeListeningQueueWriter.unionSQL)) AS queue
        LEFT JOIN item ON item.id = queue.itemId AND item.accountId = queue.accountId
        LEFT JOIN podcastEpisode AS episode
          ON episode.id = queue.podcastEpisodeId AND episode.accountId = queue.accountId
        LEFT JOIN rssEpisode ON rssEpisode.id = queue.rssEpisodeId
        LEFT JOIN rssFeed ON rssFeed.id = rssEpisode.feedId
        WHERE (queue.accountId = ? OR queue.rssEpisodeId IS NOT NULL)
          \(liveOnly)
        ORDER BY queue.position, queue.sourceTag, queue.rowID
        LIMIT ?
        """,
      // SQLite reads a negative limit as no limit.
      arguments: [accountId, liveLimit.map { max(0, $0) } ?? -1]
    ).compactMap { row -> ListeningQueueItem? in
      if let feedID = row["rssFeedId"] as Int64?,
        let episodeID = row["rssEpisodeIdentity"] as String?
      {
        guard let identity = ListeningIdentity.rssEpisode(feedID: feedID, episodeID: episodeID)
        else { return nil }
        let lastSeen = row["rssLastSeenGeneration"] as Int
        let refreshGeneration = row["rssRefreshGeneration"] as Int
        return ListeningQueueItem(
          id: row["id"],
          position: row["position"],
          identity: identity,
          primaryTitle: (row["rssEpisodeTitle"] as String?) ?? "Unavailable Episode",
          secondaryTitle: (row["rssFeedTitle"] as String?) ?? "Podcast",
          category: .podcast,
          isTombstone: lastSeen < refreshGeneration,
          artworkURL: (row["rssArtworkURL"] as String?).flatMap { URL(string: $0) },
          artworkFeedURL: (row["rssFeedURL"] as String?).flatMap { URL(string: $0) },
          episodeArtworkURL: (row["rssEpisodeArtworkURL"] as String?).flatMap { URL(string: $0) })
      }

      let itemID: String = row["serverItemId"]
      let category = ItemMediaCategory.derive(
        mediaKind: row["mediaKind"], numAudioFiles: row["numAudioFiles"],
        ebookFormat: row["ebookFormat"])
      let itemTitle: String = row["itemTitle"]
      let itemAuthor = (row["itemAuthor"] as String?) ?? ""
      let itemSoftDeleted = row["itemSoftDeleted"] as Bool

      if let episodeID = row["serverEpisodeId"] as String? {
        guard
          let identity = ListeningIdentity.podcastEpisode(
            itemID: itemID, episodeID: episodeID)
        else { return nil }
        return ListeningQueueItem(
          id: row["id"],
          position: row["position"],
          identity: identity,
          primaryTitle: row["episodeTitle"],
          secondaryTitle: itemTitle,
          category: category,
          isTombstone: itemSoftDeleted || (row["episodeSoftDeleted"] as Bool),
          serverUpdatedAt: row["itemServerUpdatedAt"])
      } else {
        guard let identity = ListeningIdentity.audiobook(itemID: itemID) else { return nil }
        return ListeningQueueItem(
          id: row["id"],
          position: row["position"],
          identity: identity,
          primaryTitle: itemTitle,
          secondaryTitle: itemAuthor,
          category: category,
          isTombstone: itemSoftDeleted,
          serverUpdatedAt: row["itemServerUpdatedAt"],
          chapter: Self.chapter(row))
      }
    }
  }
}
