import Foundation
import GRDB

public enum RSSEpisodeStoreError: Error, Equatable, Sendable {
  case feedNotFound
  case credentialedEnclosureURL
}

public struct RSSEpisodeUpsert: Sendable, Equatable {
  public let identityKey: String
  public let alternateIdentityKey: String?
  public let guid: String?
  public let title: String?
  /// Full show notes as feed HTML; see `RSSEpisodeRecord.synopsis`.
  public let synopsis: String?
  public let synopsisLine: String?
  public let enclosureURL: URL
  public let enclosureType: String?
  public let declaredBytes: Int64?
  public let publishedAt: Date?
  public let durationSeconds: Double?
  public let seasonNumber: Int?
  public let episodeNumber: Int?
  /// The item's own artwork; see `RSSEpisodeRecord.artworkURL`.
  public let artworkURL: URL?

  public init(
    identityKey: String, alternateIdentityKey: String? = nil, guid: String? = nil,
    title: String? = nil, synopsis: String? = nil, synopsisLine: String? = nil, enclosureURL: URL,
    enclosureType: String? = nil, declaredBytes: Int64? = nil, publishedAt: Date? = nil,
    durationSeconds: Double? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil,
    artworkURL: URL? = nil
  ) {
    self.identityKey = identityKey
    self.alternateIdentityKey = alternateIdentityKey
    self.guid = guid
    self.title = title
    self.synopsis = synopsis
    self.synopsisLine = synopsisLine
    self.enclosureURL = enclosureURL
    self.enclosureType = enclosureType
    self.declaredBytes = declaredBytes
    self.publishedAt = publishedAt
    self.durationSeconds = durationSeconds
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.artworkURL = artworkURL
  }
}

public struct RSSEpisodeStore: Sendable {
  private let database: AppDatabase
  private let activeRSSExclusionProvider: @Sendable () -> Set<Int64>

  /// The default provider excludes nothing, which is correct for every store that never sweeps
  /// (playback, download planning, notification eligibility). Only the store handed to
  /// `RSSPodcastRefreshing` reaches `sweepDroppedEpisodes`, and the composition root passes it the
  /// active-playback tracker, as it does `StorageEvictionStore`.
  public init(database: AppDatabase) {
    self.init(database: database, activeRSSExclusionProvider: { [] })
  }

  public init(
    database: AppDatabase,
    activeRSSExclusionProvider: @escaping @Sendable () -> Set<Int64>
  ) {
    self.database = database
    self.activeRSSExclusionProvider = activeRSSExclusionProvider
  }

  public func fetchEpisode(episodeId: Int64) async throws -> RSSEpisodeRecord? {
    try await database.readAsync { db in
      try RSSEpisodeRecord.fetchOne(db, key: episodeId)
    }
  }

  public func fetchEpisode(feedId: Int64, identityKey: String) async throws -> RSSEpisodeRecord? {
    try await database.readAsync { db in
      try RSSEpisodeRecord
        .filter(Column("feedId") == feedId)
        .filter(Column("identityKey") == identityKey)
        .fetchOne(db)
    }
  }

  /// Row ids keyed by identity key for the keys that exist in `feedId`; absent keys are omitted.
  public func fetchEpisodeIDs(feedId: Int64, identityKeys: [String]) async throws -> [String: Int64] {
    guard identityKeys.isEmpty == false else { return [:] }
    return try await database.readAsync { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, identityKey FROM rssEpisode
          WHERE feedId = ? AND identityKey IN (\(databaseQuestionMarks(count: identityKeys.count)))
          """,
        arguments: StatementArguments([feedId]) + StatementArguments(identityKeys))
      var ids: [String: Int64] = [:]
      for row in rows {
        ids[row["identityKey"]] = row["id"]
      }
      return ids
    }
  }

  public func applyRefresh(
    feedId: Int64, episodes: [RSSEpisodeUpsert],
    notificationContext: RSSNotificationDiscoveryContext = .foreground(discoveredAt: Date())
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      guard var feed = try RSSFeedRecord.fetchOne(db, key: feedId) else {
        throw RSSEpisodeStoreError.feedNotFound
      }
      guard episodes.allSatisfy({ Self.hasEmbeddedCredentials($0.enclosureURL) == false }) else {
        throw RSSEpisodeStoreError.credentialedEnclosureURL
      }
      let generation = Int64(feed.refreshGeneration) + 1
      let existingBaseline = try Date.fetchOne(
        db,
        sql: "SELECT establishedAt FROM rssNotificationFeedBaseline WHERE feedId = ?",
        arguments: [feedId])
      let establishesSilentBaseline = existingBaseline == nil
      if establishesSilentBaseline {
        try db.execute(
          sql: "INSERT INTO rssNotificationFeedBaseline (feedId, establishedAt) VALUES (?, ?)",
          arguments: [feedId, notificationContext.discoveredAt])
      }
      let notificationOverride = RSSNotificationOverride.parse(
        try String.fetchOne(
          db, sql: "SELECT notificationOverride FROM rssFeedSettings WHERE feedId = ?",
          arguments: [feedId]))
      var rows = try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY id", arguments: [feedId])
      var claimed = Set<Int64>()
      var seenKeys = Set<String>()

      for episode in episodes where seenKeys.insert(episode.identityKey).inserted {
        let candidates: [(clause: Int, id: Int64, offset: Int)] = rows.enumerated().compactMap {
          offset, row -> (clause: Int, id: Int64, offset: Int)? in
          guard let id = row.id, claimed.contains(id) == false else { return nil }
          if row.identityKey == episode.identityKey { return (1, id, offset) }
          if row.alternateIdentityKey == episode.identityKey { return (2, id, offset) }
          if let alternate = episode.alternateIdentityKey, row.identityKey == alternate {
            return (3, id, offset)
          }
          if let alternate = episode.alternateIdentityKey, row.alternateIdentityKey == alternate {
            return (4, id, offset)
          }
          return nil
        }
        let match: (clause: Int, id: Int64, offset: Int)? = candidates.min { left, right in
          if left.clause == right.clause { return left.id < right.id }
          return left.clause < right.clause
        }
        let record = RSSEpisodeRecord(
          id: match.map { rows[$0.offset].id } ?? nil, feedId: feedId,
          identityKey: episode.identityKey, alternateIdentityKey: episode.alternateIdentityKey,
          guid: episode.guid, title: episode.title, synopsis: episode.synopsis,
          synopsisLine: episode.synopsisLine,
          enclosureURL: episode.enclosureURL.absoluteString, enclosureType: episode.enclosureType,
          declaredBytes: episode.declaredBytes, publishedAt: episode.publishedAt,
          durationSeconds: episode.durationSeconds,
          // Refresh data replaces feed fields; the measured value belongs to the media and must
          // survive a refresh whose document still omits its duration.
          measuredDurationSeconds: match.flatMap { rows[$0.offset].measuredDurationSeconds },
          seasonNumber: episode.seasonNumber,
          episodeNumber: episode.episodeNumber, lastSeenGeneration: Int(generation),
          retained: match.map { rows[$0.offset].retained } ?? false,
          autoDownloadDecidedAt: match.flatMap { rows[$0.offset].autoDownloadDecidedAt },
          // Feed-owned like the other refresh fields: a refresh always overwrites it, including
          // back to nil, so it is never carried over from the matched row.
          artworkURL: episode.artworkURL?.absoluteString)
        if let match {
          try Self.reconcileNotificationIdentity(
            db, feedID: feedId, incoming: episode, existing: rows[match.offset],
            discoveredAt: notificationContext.discoveredAt,
            fallbackDisposition: .silentBaseline)
          claimed.insert(rows[match.offset].id!)
          try record.update(db)
          rows[match.offset] = record
        } else {
          let existingDisposition = try Self.notificationLedgerRow(
            db, feedID: feedId,
            keys: [episode.identityKey, episode.alternateIdentityKey].compactMap { $0 })?.disposition
          var inserted = record
          try inserted.insert(db)
          rows.append(inserted)
          claimed.insert(inserted.id!)
          if existingDisposition == nil {
            let disposition: RSSNotificationDisposition
            if establishesSilentBaseline {
              disposition = .silentBaseline
            } else if notificationContext.source == .foreground {
              disposition = .suppressedForeground
            } else if notificationOverride.resolves(
              globalEnabled: notificationContext.globalEnabled)
            {
              disposition = .pending
            } else {
              disposition = .suppressedDisabled
            }
            try Self.insertNotificationLedger(
              db, feedID: feedId, identityKey: episode.identityKey,
              disposition: disposition, firstSeenAt: notificationContext.discoveredAt)
          }
        }
      }

      feed.refreshGeneration = Int(generation)
      try feed.update(db)
      return generation
    }
  }

  private static func reconcileNotificationIdentity(
    _ db: Database, feedID: Int64, incoming: RSSEpisodeUpsert, existing: RSSEpisodeRecord,
    discoveredAt: Date, fallbackDisposition: RSSNotificationDisposition
  ) throws {
    let keys = [
      incoming.identityKey, incoming.alternateIdentityKey, existing.identityKey,
      existing.alternateIdentityKey,
    ].compactMap { $0 }
    guard let found = try notificationLedgerRow(db, feedID: feedID, keys: keys) else {
      try insertNotificationLedger(
        db, feedID: feedID, identityKey: incoming.identityKey,
        disposition: fallbackDisposition, firstSeenAt: discoveredAt)
      return
    }
    guard found.identityKey != incoming.identityKey else { return }
    try db.execute(
      sql: "UPDATE rssEpisodeNotificationLedger SET disposition = ? WHERE feedId = ? AND identityKey = ?",
      arguments: [RSSNotificationDisposition.alias.rawValue, feedID, found.identityKey])
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO rssEpisodeNotificationLedger
          (feedId, identityKey, disposition, firstSeenAt, scheduledRequestID)
        VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [
        feedID, incoming.identityKey, found.disposition.rawValue, found.firstSeenAt,
        found.scheduledRequestID,
      ])
  }

  private static func hasEmbeddedCredentials(_ url: URL) -> Bool {
    url.user?.isEmpty == false || url.password?.isEmpty == false
  }

  private struct NotificationLedgerRow {
    let identityKey: String
    let disposition: RSSNotificationDisposition
    let firstSeenAt: Date
    let scheduledRequestID: String?
  }

  private static func notificationLedgerRow(
    _ db: Database, feedID: Int64, keys: [String]
  ) throws -> NotificationLedgerRow? {
    for key in keys {
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT identityKey, disposition, firstSeenAt, scheduledRequestID
            FROM rssEpisodeNotificationLedger
            WHERE feedId = ? AND identityKey = ?
            """,
          arguments: [feedID, key]),
        let disposition = RSSNotificationDisposition(rawValue: row["disposition"])
      else { continue }
      return NotificationLedgerRow(
        identityKey: row["identityKey"], disposition: disposition,
        firstSeenAt: row["firstSeenAt"], scheduledRequestID: row["scheduledRequestID"])
    }
    return nil
  }

  private static func insertNotificationLedger(
    _ db: Database, feedID: Int64, identityKey: String,
    disposition: RSSNotificationDisposition, firstSeenAt: Date
  ) throws {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO rssEpisodeNotificationLedger
          (feedId, identityKey, disposition, firstSeenAt)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [feedID, identityKey, disposition.rawValue, firstSeenAt])
  }

  public func recordMeasuredDuration(episodeId: Int64, seconds: Double) async throws {
    guard seconds.isFinite, seconds > 0 else { return }
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisode SET measuredDurationSeconds = ? WHERE id = ?",
        arguments: [seconds, episodeId])
    }
  }

  public func sweepDroppedEpisodes(feedId: Int64) async throws -> (deleted: Int, newlyRetained: Int) {
    try await database.writeAsync { db in
      guard let feed = try RSSFeedRecord.fetchOne(db, key: feedId) else {
        throw RSSEpisodeStoreError.feedNotFound
      }
      guard feed.refreshGeneration > 0 else { return (deleted: 0, newlyRetained: 0) }

      let candidates = try RSSEpisodeRecord.fetchAll(
        db,
        sql: """
          SELECT * FROM rssEpisode
          WHERE feedId = ? AND lastSeenGeneration < ? AND retained = 0
          ORDER BY id
          """,
        arguments: [feedId, feed.refreshGeneration])
      let activeEpisodeIDs = activeRSSExclusionProvider()
      var deleted = 0
      var newlyRetained = 0

      for episode in candidates {
        let episodeId = episode.id!
        guard activeEpisodeIDs.contains(episodeId) == false else { continue }
        let hasHistory = try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM rssEpisodeState
              WHERE episodeId = ?
            ) OR EXISTS(
              SELECT 1 FROM rssDownload WHERE episodeId = ?
            ) OR EXISTS(
              SELECT 1 FROM rssListeningQueueEntry WHERE rssEpisodeId = ?
            ) OR EXISTS(
              SELECT 1 FROM rssSavedShelfEntry WHERE rssEpisodeId = ?
            ) OR EXISTS(
              SELECT 1 FROM rssPlaybackBookmark WHERE episodeId = ?
            ) OR EXISTS(
              SELECT 1 FROM rssWatchCopy WHERE episodeId = ? AND state <> 'removed'
            )
            """,
          arguments: [episodeId, episodeId, episodeId, episodeId, episodeId, episodeId])!
        if hasHistory {
          try db.execute(
            sql: "UPDATE rssEpisode SET retained = 1 WHERE id = ?", arguments: [episodeId])
          newlyRetained += 1
        } else {
          try db.execute(sql: "DELETE FROM rssEpisode WHERE id = ?", arguments: [episodeId])
          deleted += 1
        }
      }

      return (deleted: deleted, newlyRetained: newlyRetained)
    }
  }
}
