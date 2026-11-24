import Foundation
import GRDB

/// One server-side (show, episode) pair the account holds listening progress for.
public struct PodcastProgressIdentity: Sendable, Equatable, Hashable {
  public let serverItemID: String
  public let serverEpisodeID: String

  public init(serverItemID: String, serverEpisodeID: String) {
    self.serverItemID = serverItemID
    self.serverEpisodeID = serverEpisodeID
  }
}

/// One account-wide server observation that can be applied without expanding a show when both
/// the show and episode are already present locally.
public struct PodcastProgressReconciliationObservation: Sendable, Equatable {
  public let identity: PodcastProgressIdentity
  public let currentTime: Double
  public let isFinished: Bool
  public let hideFromContinueListening: Bool
  public let serverUpdatedAt: Date?
  /// `nil` when the caller has no row-identity information, which is never reset evidence.
  public let serverRow: ServerRowObservation?

  public init(
    identity: PodcastProgressIdentity,
    currentTime: Double,
    isFinished: Bool,
    hideFromContinueListening: Bool,
    serverUpdatedAt: Date?,
    serverRow: ServerRowObservation? = nil
  ) {
    self.identity = identity
    self.currentTime = currentTime
    self.isFinished = isFinished
    self.hideFromContinueListening = hideFromContinueListening
    self.serverUpdatedAt = serverUpdatedAt
    self.serverRow = serverRow
  }
}

/// A locally known podcast show whose server progress cannot currently be displayed.
public struct PodcastProgressHydrationNeed: Sendable, Equatable {
  public let localItemID: Int64
  public let serverItemID: String

  public init(localItemID: Int64, serverItemID: String) {
    self.localItemID = localItemID
    self.serverItemID = serverItemID
  }
}

/// Selects the podcast shows whose episode-level progress the library pull could not land.
///
/// Book progress is item-keyed, so a pull writes it against the row it just saved. Episode
/// progress needs a `podcastEpisode` row (Home's Continue Listening inner-joins one) and the
/// minified library page carries no episodes, so a never-expanded show holds server progress
/// nothing local can join. This finds those shows: episodes missing, or present without a
/// progress row.
public struct PodcastProgressHydrationStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Applies account progress to locally known episode rows, ahead of the expansion selection
  /// below: a completed or hidden episode does not justify a request, but its newer server state
  /// must still replace a stale resumable row.
  ///
  /// With `progressSnapshotIsComplete`, an episode this device observed on the server that the
  /// snapshot omits is reconciled as the server's post-reset state, so reset evidence reaches it.
  public func reconcileKnownProgress(
    accountId: Int64,
    observations: [PodcastProgressReconciliationObservation],
    progressSnapshotIsComplete: Bool = false,
    decideProgress: @escaping PodcastProgressMergeDecider
  ) async throws {
    guard observations.isEmpty == false || progressSnapshotIsComplete else { return }
    try await database.writeAsync { db in
      var observations = observations
      if progressSnapshotIsComplete {
        observations += try Self.absentObservedEpisodes(
          db, accountId: accountId, present: Set(observations.map(\.identity)))
      }
      for observation in observations {
        guard
          let itemId = try Int64.fetchOne(
            db,
            sql: """
              SELECT item.id
              FROM item
              JOIN library
                ON library.id = item.libraryId AND library.accountId = item.accountId
              WHERE item.accountId = ?
                AND item.serverItemId = ?
                AND item.mediaKind = 'podcast'
                AND \(ItemVisibilityPredicate.sql)
              """,
            arguments: [accountId, observation.identity.serverItemID]),
          let episode =
            try PodcastEpisodeRecord
            .filter(Column("accountId") == accountId)
            .filter(Column("itemId") == itemId)
            .filter(Column("serverEpisodeId") == observation.identity.serverEpisodeID)
            .filter(Column("softDeleted") == false)
            .fetchOne(db),
          let episodeId = episode.id
        else {
          continue
        }

        let identity = MediaProgressIdentity.episode(
          itemId: itemId, podcastEpisodeId: episodeId)
        let hasUnacknowledgedLocalOperation =
          try MediaProgressDAO.hasUnacknowledgedLocalOperation(
            db, accountId: accountId, identity: identity)
          || PodcastRefreshStore.hasActiveSessionLocalIntent(
            db, accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId)
        let hasUnacknowledgedVisibilityOperation =
          try MediaProgressDAO.hasUnacknowledgedLocalOperation(
            db, accountId: accountId, identity: identity,
            field: .continueListeningVisibility)
        let context = PodcastProgressMergeContext(
          serverEpisodeId: observation.identity.serverEpisodeID,
          identity: identity,
          currentProgress: try MediaProgressDAO.fetchProgress(
            db, accountId: accountId, identity: identity),
          hasUnacknowledgedLocalOperation: hasUnacknowledgedLocalOperation,
          incomingCurrentTime: observation.currentTime,
          incomingIsFinished: observation.isFinished,
          incomingServerUpdatedAt: observation.serverUpdatedAt,
          durationSeconds: episode.durationSeconds,
          incomingServerRow: observation.serverRow)
        switch decideProgress(context) {
        case .applyServer:
          try MediaProgressDAO.upsertServerProgress(
            db, accountId: accountId, identity: identity,
            currentTime: observation.currentTime, isFinished: observation.isFinished,
            serverUpdatedAt: observation.serverUpdatedAt)
          try MediaProgressDAO.deleteConflict(db, accountId: accountId, identity: identity)
        case .recordConflict(let detectedAt):
          try MediaProgressDAO.upsertConflict(
            db, accountId: accountId, identity: identity,
            serverCurrentTime: observation.currentTime,
            serverIsFinished: observation.isFinished,
            serverUpdatedAt: observation.serverUpdatedAt, detectedAt: detectedAt)
        case .keepLocal:
          break
        }
        if hasUnacknowledgedVisibilityOperation == false {
          try MediaProgressDAO.applyServerVisibility(
            db, accountId: accountId, identity: identity,
            hideFromContinueListening: observation.hideFromContinueListening)
        }
        if let serverRow = observation.serverRow {
          try MediaProgressDAO.recordObservedServerProgressId(
            db, accountId: accountId, identity: identity, serverProgressId: serverRow.progressId,
            serverUpdatedAt: observation.serverUpdatedAt)
        }
      }
    }
  }

  private static func absentObservedEpisodes(
    _ db: Database, accountId: Int64, present: Set<PodcastProgressIdentity>
  ) throws -> [PodcastProgressReconciliationObservation] {
    let podcastItemIds = try Int64.fetchAll(
      db,
      sql: """
        SELECT item.id
        FROM item
        JOIN library
          ON library.id = item.libraryId AND library.accountId = item.accountId
        WHERE item.accountId = ?
          AND item.mediaKind = 'podcast'
          AND \(ItemVisibilityPredicate.sql)
        """,
      arguments: [accountId])
    return try MediaProgressDAO.observedEpisodeServerIDs(
      db, accountId: accountId, itemIds: podcastItemIds
    ).compactMap { observed in
      let identity = PodcastProgressIdentity(
        serverItemID: observed.serverItemId, serverEpisodeID: observed.serverEpisodeId)
      guard present.contains(identity) == false else { return nil }
      return PodcastProgressReconciliationObservation(
        identity: identity, currentTime: 0, isFinished: false, hideFromContinueListening: false,
        serverUpdatedAt: nil, serverRow: .absent)
    }
  }

  /// The shows behind `identities` needing their episode list expanded before their progress can
  /// show, in caller order (server-recency, so `limit` keeps the most recently listened shows).
  ///
  /// `podcastRefreshState` is shared with every other expansion path: a repeatedly failing show
  /// stays inside its backoff window here too, so a broken show cannot cost a request on every
  /// foreground.
  public func showsNeedingHydration(
    accountId: Int64,
    identities: [PodcastProgressIdentity],
    now: Date,
    limit: Int
  ) async throws -> [PodcastProgressHydrationNeed] {
    guard limit > 0, identities.isEmpty == false else { return [] }
    var distinctShowIDs: [String] = []
    var seenShowIDs: Set<String> = []
    for identity in identities where seenShowIDs.insert(identity.serverItemID).inserted {
      distinctShowIDs.append(identity.serverItemID)
    }
    // SQLite's bound-variable ceiling is per statement, and this list is caller-supplied.
    let chunks = distinctShowIDs.chunked(maximumCount: 400)

    return try await database.readAsync { db in
      var localIDsByServerID: [String: Int64] = [:]
      var covered: Set<PodcastProgressIdentity> = []
      for chunk in chunks {
        let placeholders = databaseQuestionMarks(count: chunk.count)
        for row in try Row.fetchAll(
          db,
          sql: """
            SELECT i.id AS itemId, i.serverItemId AS serverItemId
            FROM item i
            JOIN library l ON l.id = i.libraryId AND l.accountId = i.accountId
            LEFT JOIN podcastRefreshState s ON s.itemId = i.id
            WHERE i.accountId = ? AND i.mediaKind = 'podcast' AND i.softDeleted = 0
              AND l.softDeleted = 0 AND l.isIncluded = 1
              AND i.serverItemId IN (\(placeholders))
              AND (s.nextEligibleAttemptAt IS NULL OR s.nextEligibleAttemptAt <= ?)
            """,
          arguments: StatementArguments([accountId] as [any DatabaseValueConvertible])
            + StatementArguments(chunk) + StatementArguments([now]))
        {
          localIDsByServerID[row["serverItemId"]] = row["itemId"]
        }

        for row in try Row.fetchAll(
          db,
          sql: """
            SELECT i.serverItemId AS serverItemId, e.serverEpisodeId AS serverEpisodeId
            FROM mediaProgress p
            JOIN podcastEpisode e ON e.id = p.podcastEpisodeId AND e.accountId = p.accountId
            JOIN item i ON i.id = e.itemId AND i.accountId = e.accountId
            JOIN library l ON l.id = i.libraryId AND l.accountId = i.accountId
            WHERE p.accountId = ? AND e.softDeleted = 0 AND i.softDeleted = 0
              AND l.softDeleted = 0 AND l.isIncluded = 1
              AND i.serverItemId IN (\(placeholders))
            """,
          arguments: StatementArguments([accountId] as [any DatabaseValueConvertible])
            + StatementArguments(chunk))
        {
          covered.insert(
            PodcastProgressIdentity(
              serverItemID: row["serverItemId"], serverEpisodeID: row["serverEpisodeId"]))
        }
      }

      var needs: [PodcastProgressHydrationNeed] = []
      var selected: Set<String> = []
      for identity in identities {
        guard needs.count < limit else { break }
        guard covered.contains(identity) == false else { continue }
        guard let localItemID = localIDsByServerID[identity.serverItemID] else { continue }
        guard selected.insert(identity.serverItemID).inserted else { continue }
        needs.append(
          PodcastProgressHydrationNeed(
            localItemID: localItemID, serverItemID: identity.serverItemID))
      }
      return needs
    }
  }
}
