import Foundation
import GRDB

public enum RSSFeedStoreError: Error, Equatable, Sendable {
  case duplicateFeed(existingFeedId: Int64)
  case feedNotFound
  case invalidFeedURL
  case duplicateSortFeed(feedId: Int64)
  case unknownSortFeed(feedId: Int64)
  case incompleteSortFeedIds(missingFeedIds: [Int64])
}

/// Device-owned RSS subscriptions. RSS feeds are independent of account identity.
public struct RSSFeedStore: Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func subscribe(
    feedURL: URL,
    title: String?,
    author: String?,
    synopsis: String?,
    artworkURL: URL?,
    subscribedAt: Date,
    recoveryReason: NativeFeedRecoveryReason? = nil
  ) async throws -> Int64 {
    guard let feedURL = Self.credentialFreeFeedURL(feedURL) else {
      throw RSSFeedStoreError.invalidFeedURL
    }

    return try await database.writeAsync { db in
      let feedURLString = feedURL.absoluteString
      if let existingFeedId = try Int64.fetchOne(
        db, sql: "SELECT id FROM rssFeed WHERE feedURL = ?", arguments: [feedURLString])
      {
        throw RSSFeedStoreError.duplicateFeed(existingFeedId: existingFeedId)
      }

      var record = RSSFeedRecord(
        feedURL: feedURLString,
        title: title,
        author: author,
        synopsis: synopsis,
        artworkURL: Self.credentialFreeArtworkURL(artworkURL)?.absoluteString,
        subscribedAt: subscribedAt)
      try record.insert(db)
      let feedID = db.lastInsertedRowID
      if let recoveryReason {
        try RSSFeedRecoveryRecord(
          feedId: feedID, reason: recoveryReason, createdAt: subscribedAt
        ).insert(db)
      }
      return feedID
    }
  }

  public func clearRecovery(feedId: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM rssFeedRecovery WHERE feedId = ?", arguments: [feedId])
    }
  }

  public func unsubscribe(feedId: Int64) async throws {
    try await database.writeAsync { db in
      try Self.unsubscribe(in: db, feedId: feedId)
    }
  }

  /// The unsubscribe itself, for a caller that already holds the transaction. A remote unfollow is
  /// projected inside the cloud admission transaction and must leave the catalogue as a local
  /// unsubscribe would.
  public static func unsubscribe(in db: Database, feedId: Int64) throws {
    try requireFeed(db, feedId: feedId)

    // Copies cascade with their episodes, but the Watch may still hold the files; bump the set's
    // generation first so the next offer tells it to drop them.
    try RSSWatchCopyStore.noteFeedRemoval(in: db, feedId: feedId)

    let sortIndex = try Int.fetchOne(
      db, sql: "SELECT customSortIndex FROM rssFeed WHERE id = ?", arguments: [feedId])
    try db.execute(sql: "DELETE FROM rssFeed WHERE id = ?", arguments: [feedId])
    try compactListeningQueuePositions(db)
    if let sortIndex {
      try db.execute(
        sql: """
          UPDATE rssFeed
          SET customSortIndex = customSortIndex - 1
          WHERE customSortIndex IS NOT NULL AND customSortIndex > ?
          """,
        arguments: [sortIndex])
    }
  }

  /// Unsubscribe cascades the feed's native queue rows. The shared writer restores dense mixed
  /// ordering and invalidates clear/restore tokens after that source mutation.
  private static func compactListeningQueuePositions(_ db: Database) throws {
    try NativeListeningQueueWriter.compact(in: db)
    try NativeListeningQueueWriter.bumpRevision(in: db)
  }

  public func fetchFeed(feedId: Int64) async throws -> RSSFeedRecord? {
    try await database.readAsync { db in
      try RSSFeedRecord.fetchOne(db, key: feedId)
    }
  }

  public func fetchFeed(feedURL: URL) async throws -> RSSFeedRecord? {
    guard let feedURL = Self.credentialFreeFeedURL(feedURL) else { return nil }

    return try await database.readAsync { db in
      try RSSFeedRecord.fetchOne(
        db, sql: "SELECT * FROM rssFeed WHERE feedURL = ?", arguments: [feedURL.absoluteString])
    }
  }

  public func fetchFeeds() async throws -> [RSSFeedRecord] {
    try await database.readAsync { db in
      try Self.fetchFeeds(db)
    }
  }

  /// Feeds awaiting credential recovery remain visible but never enter automatic refresh work.
  /// Least recently attempted first (never-attempted rows sort first), then least recently
  /// refreshed. Bounded passes take a prefix and stamp each feed as they reach it, so every
  /// candidate is visited within ⌈candidates / budget⌉ passes, whether its refreshes succeed,
  /// fail, or are cut off by the pass deadline.
  public func fetchRefreshableFeedIDs() async throws -> [Int64] {
    try await database.readAsync { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT rssFeed.id
          FROM rssFeed
          LEFT JOIN rssFeedRecovery ON rssFeedRecovery.feedId = rssFeed.id
          WHERE rssFeedRecovery.feedId IS NULL
          ORDER BY rssFeed.lastRefreshAttemptAt, rssFeed.lastRefreshedAt, rssFeed.id
          """)
    }
  }

  /// Orders refresh candidates only. `lastRefreshedAt` stays the last success: it is shown as the
  /// last episode check and gates `refreshIfStale`, so a failed attempt must not move it.
  public func recordRefreshAttempt(feedID: Int64, at date: Date) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET lastRefreshAttemptAt = ? WHERE id = ?", arguments: [date, feedID])
    }
  }

  public func observeFeeds() -> AsyncStream<[RSSFeedRecord]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.fetchFeeds(db)
    }
  }

  public func sortMode() async throws -> NativePodcastShowSortMode {
    try await database.readAsync { db in
      try Self.sortMode(db)
    }
  }

  public func setSortMode(_ mode: NativePodcastShowSortMode) async throws {
    try await database.writeAsync { db in
      try Self.writeSortMode(db, mode)
    }
  }

  public func replaceCustomOrder(feedIds: [Int64]) async throws {
    try await database.writeAsync { db in
      let liveFeedIds = try Set(Int64.fetchAll(db, sql: "SELECT id FROM rssFeed"))
      var namedFeedIds = Set<Int64>()
      for feedId in feedIds {
        guard namedFeedIds.insert(feedId).inserted else {
          throw RSSFeedStoreError.duplicateSortFeed(feedId: feedId)
        }
        guard liveFeedIds.contains(feedId) else {
          throw RSSFeedStoreError.unknownSortFeed(feedId: feedId)
        }
      }

      let missingFeedIds = liveFeedIds.subtracting(namedFeedIds).sorted()
      guard missingFeedIds.isEmpty else {
        throw RSSFeedStoreError.incompleteSortFeedIds(missingFeedIds: missingFeedIds)
      }

      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = NULL")
      for (index, feedId) in feedIds.enumerated() {
        try db.execute(
          sql: "UPDATE rssFeed SET customSortIndex = ? WHERE id = ?",
          arguments: [index, feedId])
      }
      try Self.writeSortMode(db, .custom)
    }
  }

  public func resetToAlphabetical() async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = NULL")
      try db.execute(sql: "DELETE FROM rssShowOrder WHERE id = 0")
    }
  }

  public func validators(feedURL: URL) async throws -> (etag: String?, lastModified: String?)? {
    guard let feedURL = Self.credentialFreeFeedURL(feedURL) else { return nil }

    return try await database.readAsync { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT etag, lastModified FROM rssFeed WHERE feedURL = ?",
          arguments: [feedURL.absoluteString])
      else {
        return nil
      }
      return (etag: row["etag"], lastModified: row["lastModified"])
    }
  }

  public func storeValidators(
    etag: String?, lastModified: String?, feedURL: URL
  ) async throws {
    guard let feedURL = Self.credentialFreeFeedURL(feedURL) else {
      throw RSSFeedStoreError.invalidFeedURL
    }

    try await database.writeAsync { db in
      guard
        try Int64.fetchOne(
          db, sql: "SELECT id FROM rssFeed WHERE feedURL = ?",
          arguments: [feedURL.absoluteString]) != nil
      else {
        throw RSSFeedStoreError.feedNotFound
      }

      try db.execute(
        sql: "UPDATE rssFeed SET etag = ?, lastModified = ? WHERE feedURL = ?",
        arguments: [etag, lastModified, feedURL.absoluteString])
    }
  }

  public func applyChannelMetadata(
    feedId: Int64,
    title: String?,
    author: String?,
    synopsis: String?,
    language: String?,
    artworkURL: URL?,
    refreshedAt: Date
  ) async throws {
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)

      try db.execute(
        sql: """
          UPDATE rssFeed
          SET title = ?, author = ?, synopsis = ?, language = ?, artworkURL = ?, lastRefreshedAt = ?
          WHERE id = ?
          """,
        arguments: [
          title, author, synopsis, language,
          Self.credentialFreeArtworkURL(artworkURL)?.absoluteString,
          refreshedAt, feedId,
        ])
    }
  }

  private static func credentialFreeArtworkURL(_ url: URL?) -> URL? {
    guard let url, url.user?.isEmpty != false, url.password?.isEmpty != false else { return nil }
    return url
  }

  private static func credentialFreeFeedURL(_ url: URL) -> URL? {
    guard url.user != nil || url.password != nil else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }

    components.user = nil
    components.password = nil
    return components.url
  }

  private static func requireFeed(_ db: Database, feedId: Int64) throws {
    guard try Int64.fetchOne(db, sql: "SELECT id FROM rssFeed WHERE id = ?", arguments: [feedId]) != nil
    else { throw RSSFeedStoreError.feedNotFound }
  }

  private static func fetchFeeds(_ db: Database) throws -> [RSSFeedRecord] {
    try RSSFeedRecord.fetchAll(
      db,
      sql: """
        SELECT * FROM rssFeed
        ORDER BY customSortIndex IS NULL, customSortIndex, title COLLATE NOCASE, id
        """)
  }

  static func sortMode(_ db: Database) throws -> NativePodcastShowSortMode {
    guard
      let rawMode = try String.fetchOne(
        db, sql: "SELECT mode FROM rssShowOrder WHERE id = 0"),
      let mode = NativePodcastShowSortMode(rawValue: rawMode)
    else { return .alphabetical }
    return mode
  }

  private static func writeSortMode(_ db: Database, _ mode: NativePodcastShowSortMode) throws {
    try db.execute(
      sql: """
        INSERT INTO rssShowOrder (id, mode) VALUES (0, ?)
        ON CONFLICT(id) DO UPDATE SET mode = excluded.mode
        """,
      arguments: [mode.rawValue])
  }
}
