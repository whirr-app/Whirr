import Foundation
import GRDB

public enum PodcastStalenessReason: String, Sendable, Equatable {
  case neverHydrated
  case episodeCountMismatch
  case serverUpdated
  /// `lastCompleteEpisodeListAt` is unset: no expanded response has ever proved the full list.
  /// Selected only when the caller asks for it (smart-list expansion).
  case neverCompletelyExpanded
  case backstopExpired
}

public struct PodcastRefreshCandidate: Sendable, Equatable {
  public let localItemID: Int64
  public let serverItemID: String
  public let hasLocalEpisodes: Bool
  public let lastSuccessfulRefreshAt: Date?
  public let changeReason: PodcastStalenessReason
  public let lastCompleteEpisodeListAt: Date?

  public init(
    localItemID: Int64,
    serverItemID: String,
    hasLocalEpisodes: Bool,
    lastSuccessfulRefreshAt: Date?,
    changeReason: PodcastStalenessReason,
    lastCompleteEpisodeListAt: Date? = nil
  ) {
    self.localItemID = localItemID
    self.serverItemID = serverItemID
    self.hasLocalEpisodes = hasLocalEpisodes
    self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
    self.changeReason = changeReason
    self.lastCompleteEpisodeListAt = lastCompleteEpisodeListAt
  }
}

public struct PodcastRefreshStateRecord:
  Codable, Equatable, Sendable, FetchableRecord, PersistableRecord
{
  public static let databaseTableName = "podcastRefreshState"

  public var itemId: Int64
  public var lastAttemptAt: Date?
  public var lastSuccessfulRefreshAt: Date?
  public var consecutiveFailures: Int
  public var nextEligibleAttemptAt: Date?
  /// Set only by a successful response whose episode list proved absence (`recordSuccess`).
  public var lastCompleteEpisodeListAt: Date?

  public init(
    itemId: Int64,
    lastAttemptAt: Date? = nil,
    lastSuccessfulRefreshAt: Date? = nil,
    consecutiveFailures: Int = 0,
    nextEligibleAttemptAt: Date? = nil,
    lastCompleteEpisodeListAt: Date? = nil
  ) {
    self.itemId = itemId
    self.lastAttemptAt = lastAttemptAt
    self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
    self.consecutiveFailures = consecutiveFailures
    self.nextEligibleAttemptAt = nextEligibleAttemptAt
    self.lastCompleteEpisodeListAt = lastCompleteEpisodeListAt
  }
}

/// Durable, query-driven catalogue selection. An absent state row means never expanded; routing
/// always comes from live episode rows, so upgrades need no bookkeeping backfill.
public struct PodcastCatalogRefreshStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Scoped to the libraries this pass would actually select from. An audiobook library that is
  /// mid-traversal, or that has never finished one, says nothing about whether the podcast
  /// catalogue is safe to expand, and gating on every library would let one unreachable or
  /// persistently failing library disable podcast refresh entirely.
  public func traversalIsReady() async throws -> Bool {
    try await database.readAsync { db in
      let libraryIDs = try Int64.fetchAll(
        db,
        sql: """
          SELECT DISTINCT libraryId FROM item
          JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
          WHERE item.mediaKind = 'podcast' AND \(ItemVisibilityPredicate.sql)
          """)
      guard libraryIDs.isEmpty == false else { return false }
      let placeholders = databaseQuestionMarks(count: libraryIDs.count)
      let arguments = StatementArguments(libraryIDs)
      let running =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM syncRun
            WHERE state = 'running' AND libraryId IN (\(placeholders))
            """,
          arguments: arguments) ?? 0
      guard running == 0 else { return false }
      let completedLibraryCount =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(DISTINCT libraryId) FROM syncRun
            WHERE state = 'completed' AND libraryId IN (\(placeholders))
            """,
          arguments: arguments) ?? 0
      return completedLibraryCount == libraryIDs.count
    }
  }

  /// `itemIDs` restricts the selection to those local item ids (nil is every podcast show), and
  /// `includeNeverCompletelyExpanded` adds the `neverCompletelyExpanded` reason. The defaults keep
  /// every existing caller's behaviour.
  public func candidates(
    now: Date,
    backstop: TimeInterval,
    includeBackstop: Bool = true,
    itemIDs: Set<Int64>? = nil,
    includeNeverCompletelyExpanded: Bool = false,
    limit: Int
  ) async throws -> [PodcastRefreshCandidate] {
    guard limit > 0 else { return [] }
    if let itemIDs, itemIDs.isEmpty { return [] }
    let restriction =
      itemIDs.map { "AND i.id IN (\(databaseQuestionMarks(count: $0.count)))" } ?? ""
    let restrictionArguments = (itemIDs ?? []).sorted()
    return try await database.readAsync { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT i.id AS itemId, i.serverItemId,
                 i.serverUpdatedAt, i.podcastServerEpisodeCount,
                 s.lastSuccessfulRefreshAt, s.lastCompleteEpisodeListAt,
                 COUNT(e.id) AS liveEpisodeCount
          FROM item i
          JOIN library l ON l.id = i.libraryId AND l.accountId = i.accountId
          LEFT JOIN podcastRefreshState s ON s.itemId = i.id
          LEFT JOIN podcastEpisode e ON e.itemId = i.id AND e.softDeleted = 0
          WHERE i.softDeleted = 0 AND i.mediaKind = 'podcast'
            AND l.softDeleted = 0 AND l.isIncluded = 1
            AND (s.nextEligibleAttemptAt IS NULL OR s.nextEligibleAttemptAt <= ?)
            \(restriction)
          GROUP BY i.id
          ORDER BY i.id
          """,
        arguments: StatementArguments([now]) + StatementArguments(restrictionArguments))

      var candidates: [PodcastRefreshCandidate] = []
      for row in rows {
        let itemID: Int64 = row["itemId"]
        let serverItemID: String = row["serverItemId"]
        let liveCount: Int = row["liveEpisodeCount"]
        let lastSuccess: Date? = row["lastSuccessfulRefreshAt"]
        let lastComplete: Date? = row["lastCompleteEpisodeListAt"]
        let serverUpdatedAt: Date? = row["serverUpdatedAt"]
        let serverCount: Int? = row["podcastServerEpisodeCount"]

        let reason: PodcastStalenessReason?
        if liveCount == 0 {
          reason = .neverHydrated
        } else if let serverCount, serverCount != liveCount {
          reason = .episodeCountMismatch
        } else if let serverUpdatedAt, let lastSuccess, serverUpdatedAt > lastSuccess {
          reason = .serverUpdated
        } else if includeNeverCompletelyExpanded, lastComplete == nil {
          reason = .neverCompletelyExpanded
        } else if includeBackstop,
          lastSuccess.map({ now.timeIntervalSince($0) >= backstop }) ?? true
        {
          reason = .backstopExpired
        } else {
          reason = nil
        }
        guard let reason else { continue }
        candidates.append(
          PodcastRefreshCandidate(
            localItemID: itemID,
            serverItemID: serverItemID,
            hasLocalEpisodes: liveCount > 0,
            lastSuccessfulRefreshAt: lastSuccess,
            changeReason: reason,
            lastCompleteEpisodeListAt: lastComplete))
      }

      return candidates.sorted {
        let lhsRank = Self.rank($0.changeReason)
        let rhsRank = Self.rank($1.changeReason)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if $0.changeReason == .backstopExpired,
          $0.lastSuccessfulRefreshAt != $1.lastSuccessfulRefreshAt
        {
          return ($0.lastSuccessfulRefreshAt ?? .distantPast)
            < ($1.lastSuccessfulRefreshAt ?? .distantPast)
        }
        return $0.localItemID < $1.localItemID
      }.prefix(limit).map { $0 }
    }
  }

  public func recordSuccess(
    itemID: Int64, at date: Date, episodeListIsComplete: Bool = false
  ) async throws {
    try await database.writeAsync { db in
      try Self.recordSuccess(
        itemID: itemID, at: date, episodeListIsComplete: episodeListIsComplete, in: db)
    }
  }

  public func recordShowFailure(
    itemID: Int64,
    at date: Date,
    randomUnit: Double
  ) async throws {
    try await database.writeAsync { db in
      var state =
        try PodcastRefreshStateRecord.fetchOne(db, key: itemID)
        ?? PodcastRefreshStateRecord(itemId: itemID)
      state.lastAttemptAt = date
      state.consecutiveFailures += 1
      let exponent = min(state.consecutiveFailures - 1, 9)
      let rawDelay = min(300, pow(2, Double(exponent)))
      let jitter = 0.5 + min(1, max(0, randomUnit))
      state.nextEligibleAttemptAt = date.addingTimeInterval(rawDelay * jitter)
      try state.save(db)
    }
  }

  /// The one success path. `lastCompleteEpisodeListAt` moves only when the applied response's
  /// episode list was complete; a prefetched or otherwise partial response leaves it alone.
  static func recordSuccess(
    itemID: Int64, at date: Date, episodeListIsComplete: Bool, in db: Database
  ) throws {
    var state =
      try PodcastRefreshStateRecord.fetchOne(db, key: itemID)
      ?? PodcastRefreshStateRecord(itemId: itemID)
    state.lastAttemptAt = date
    state.lastSuccessfulRefreshAt = date
    if episodeListIsComplete { state.lastCompleteEpisodeListAt = date }
    state.consecutiveFailures = 0
    state.nextEligibleAttemptAt = nil
    try state.save(db)
  }

  private static func rank(_ reason: PodcastStalenessReason) -> Int {
    switch reason {
    case .neverHydrated: return 0
    case .episodeCountMismatch: return 1
    case .serverUpdated: return 2
    case .neverCompletelyExpanded: return 3
    case .backstopExpired: return 4
    }
  }
}
