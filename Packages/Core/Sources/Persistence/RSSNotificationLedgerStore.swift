import Foundation
import GRDB

/// Read/transition side of the durable discovery ledger. Episode insertion itself remains owned
/// by `RSSEpisodeStore.applyRefresh`, which writes the ledger in the same transaction.
public struct RSSNotificationLedgerStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Returns a bounded, newest-first candidate set and permanently suppresses pending rows that
  /// are now known to be disabled or ineligible. A missing episode row stays pending: it may have
  /// been swept and later re-presented, and the ledger outlives it.
  public func eligibleCandidates(
    globalEnabled: Bool, now: Date, limit: Int
  ) async throws -> [RSSNotificationCandidate] {
    let boundedLimit = max(0, min(limit, 32))
    guard boundedLimit > 0 else { return [] }
    return try await database.writeAsync { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ledger.feedId AS feedID,
                 ledger.identityKey AS identityKey,
                 baseline.establishedAt AS baselineAt,
                 feed.title AS showTitle,
                 episode.title AS episodeTitle,
                 episode.enclosureURL AS enclosureURL,
                 episode.enclosureType AS enclosureType,
                 episode.publishedAt AS publishedAt,
                 settings.notificationOverride AS notificationOverride
          FROM rssEpisodeNotificationLedger AS ledger
          JOIN rssNotificationFeedBaseline AS baseline ON baseline.feedId = ledger.feedId
          JOIN rssFeed AS feed ON feed.id = ledger.feedId
          LEFT JOIN rssEpisode AS episode
            ON episode.feedId = ledger.feedId AND episode.identityKey = ledger.identityKey
          LEFT JOIN rssFeedSettings AS settings ON settings.feedId = ledger.feedId
          WHERE ledger.disposition = ?
          ORDER BY episode.publishedAt IS NULL, episode.publishedAt DESC,
                   ledger.firstSeenAt DESC, ledger.feedId, ledger.identityKey
          LIMIT ?
          """,
        arguments: [RSSNotificationDisposition.pending.rawValue, boundedLimit * 4])

      var candidates: [RSSNotificationCandidate] = []
      for row in rows {
        let feedID: Int64 = row["feedID"]
        let identityKey: String = row["identityKey"]
        // An episode swept after discovery stays pending rather than being mistaken for malformed.
        guard let enclosureURLString = row["enclosureURL"] as String? else { continue }
        let override = RSSNotificationOverride.parse(row["notificationOverride"])
        guard override.resolves(globalEnabled: globalEnabled) else {
          try Self.suppress(
            db, feedID: feedID, identityKey: identityKey, as: .suppressedDisabled)
          continue
        }
        guard
          let publishedAt = row["publishedAt"] as Date?,
          let baselineAt = row["baselineAt"] as Date?,
          publishedAt > baselineAt,
          publishedAt >= PodcastEpisodeRecency.cutoff(now: now),
          Self.isPlayableURL(enclosureURLString),
          Self.isPlayableMIME(row["enclosureType"])
        else {
          try Self.suppress(
            db, feedID: feedID, identityKey: identityKey, as: .suppressedIneligible)
          continue
        }
        guard candidates.count < boundedLimit else { continue }
        candidates.append(
          RSSNotificationCandidate(
            feedID: feedID, identityKey: identityKey,
            showTitle: (row["showTitle"] as String?) ?? "Podcast",
            episodeTitle: (row["episodeTitle"] as String?) ?? "New episode",
            publishedAt: publishedAt))
      }
      return candidates
    }
  }

  /// Transitions the batch all-or-nothing and returns the rows moved: every candidate, or zero. A
  /// partial result would mean a disarm landed mid-batch, and the request already handed to the OS
  /// describes all candidates, so it would name a feed the user just silenced. Rolling back leaves
  /// every row pending and retryable; zero tells the caller to cancel the scheduled request.
  ///
  /// A retry after the OS accepted an earlier request is harmless: the coordinator reuses the same
  /// stable request identifier.
  public func markScheduled(
    _ candidates: [RSSNotificationCandidate], requestID: String
  ) async throws -> Int {
    guard candidates.isEmpty == false else { return 0 }
    do {
      return try await database.writeAsync { db in
        var updatedCount = 0
        for candidate in candidates {
          try db.execute(
            sql: """
              UPDATE rssEpisodeNotificationLedger
              SET disposition = ?, scheduledRequestID = ?
              WHERE feedId = ? AND identityKey = ? AND disposition = ?
              """,
            arguments: [
              RSSNotificationDisposition.scheduled.rawValue, requestID, candidate.feedID,
              candidate.identityKey, RSSNotificationDisposition.pending.rawValue,
            ])
          updatedCount += db.changesCount
        }
        guard updatedCount == candidates.count else { throw PartialScheduleTransition() }
        return updatedCount
      }
    } catch is PartialScheduleTransition {
      return 0
    }
  }

  /// Thrown only to roll back a partial `markScheduled` transaction; never escapes that method.
  private struct PartialScheduleTransition: Error {}

  /// Atomically retires notification work for a lifecycle change and returns the OS request IDs it
  /// invalidates. Capturing the IDs and transitioning the rows in one writer transaction closes
  /// both sides of the delivery race: a batch marked first is captured here, a batch marked later
  /// finds its pending rows suppressed and cancels itself.
  ///
  /// A feed-scoped request can contain other feeds' episodes; cancelling it must not consume their
  /// discoveries, so its non-target scheduled rows return to pending before commit. A global
  /// disarm suppresses pending and scheduled rows, so re-enabling never replays earlier
  /// discoveries.
  public func disarm(feedID: Int64? = nil) async throws -> [String] {
    try await database.writeAsync { db in
      let requestIDs: [String]
      if let feedID {
        requestIDs = try String.fetchAll(
          db,
          sql: """
            SELECT DISTINCT scheduledRequestID
            FROM rssEpisodeNotificationLedger
            WHERE feedId = ? AND scheduledRequestID IS NOT NULL
            ORDER BY scheduledRequestID
            """,
          arguments: [feedID])
      } else {
        requestIDs = try String.fetchAll(
          db,
          sql: """
            SELECT DISTINCT scheduledRequestID
            FROM rssEpisodeNotificationLedger
            WHERE scheduledRequestID IS NOT NULL
            ORDER BY scheduledRequestID
            """)
      }

      if let feedID {
        try db.execute(
          sql: """
            UPDATE rssEpisodeNotificationLedger
            SET disposition = ?, scheduledRequestID = NULL
            WHERE feedId = ? AND disposition IN (?, ?)
            """,
          arguments: [
            RSSNotificationDisposition.suppressedLifecycle.rawValue, feedID,
            RSSNotificationDisposition.pending.rawValue,
            RSSNotificationDisposition.scheduled.rawValue,
          ])

        for requestID in requestIDs {
          try db.execute(
            sql: """
              UPDATE rssEpisodeNotificationLedger
              SET disposition = ?, scheduledRequestID = NULL
              WHERE feedId <> ? AND scheduledRequestID = ? AND disposition = ?
              """,
            arguments: [
              RSSNotificationDisposition.pending.rawValue, feedID, requestID,
              RSSNotificationDisposition.scheduled.rawValue,
            ])
          // Alias rows carry the original request ID for identity continuity but are never
          // candidates themselves. Clear those stale references without making them pending.
          try db.execute(
            sql: """
              UPDATE rssEpisodeNotificationLedger
              SET scheduledRequestID = NULL
              WHERE scheduledRequestID = ?
              """,
            arguments: [requestID])
        }
      } else {
        try db.execute(
          sql: """
            UPDATE rssEpisodeNotificationLedger
            SET disposition = ?, scheduledRequestID = NULL
            WHERE disposition IN (?, ?)
            """,
          arguments: [
            RSSNotificationDisposition.suppressedLifecycle.rawValue,
            RSSNotificationDisposition.pending.rawValue,
            RSSNotificationDisposition.scheduled.rawValue,
          ])
        try db.execute(
          sql: """
            UPDATE rssEpisodeNotificationLedger
            SET scheduledRequestID = NULL
            WHERE scheduledRequestID IS NOT NULL
            """)
      }
      return requestIDs
    }
  }

  public func suppressPending(feedID: Int64? = nil) async throws {
    try await database.writeAsync { db in
      if let feedID {
        try db.execute(
          sql: """
            UPDATE rssEpisodeNotificationLedger SET disposition = ?
            WHERE feedId = ? AND disposition = ?
            """,
          arguments: [
            RSSNotificationDisposition.suppressedLifecycle.rawValue, feedID,
            RSSNotificationDisposition.pending.rawValue,
          ])
      } else {
        try db.execute(
          sql: """
            UPDATE rssEpisodeNotificationLedger SET disposition = ?
            WHERE disposition = ?
            """,
          arguments: [
            RSSNotificationDisposition.suppressedLifecycle.rawValue,
            RSSNotificationDisposition.pending.rawValue,
          ])
      }
    }
  }

  private static func suppress(
    _ db: Database, feedID: Int64, identityKey: String, as disposition: RSSNotificationDisposition
  ) throws {
    try db.execute(
      sql: """
        UPDATE rssEpisodeNotificationLedger SET disposition = ?
        WHERE feedId = ? AND identityKey = ? AND disposition = ?
        """,
      arguments: [
        disposition.rawValue, feedID, identityKey, RSSNotificationDisposition.pending.rawValue,
      ])
  }

  private static func isPlayableURL(_ string: String) -> Bool {
    guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), url.host != nil else {
      return false
    }
    return scheme == "https" || scheme == "http"
  }

  private static func isPlayableMIME(_ raw: String?) -> Bool {
    guard let raw, raw.isEmpty == false else { return true }
    let base =
      raw.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
      .lowercased() ?? ""
    return base.hasPrefix("audio/")
  }
}
