import Foundation
import GRDB

/// One raw, mapped server progress observation from an expanded podcast refresh.
public struct PodcastEpisodeProgressObservation: Sendable, Equatable {
  public let serverEpisodeId: String
  public let currentTime: Double
  public let isFinished: Bool
  public let hideFromContinueListening: Bool
  public let serverUpdatedAt: Date?
  /// `nil` when the caller has no row-identity information, which is never reset evidence.
  public let serverRow: ServerRowObservation?

  public init(
    serverEpisodeId: String,
    currentTime: Double,
    isFinished: Bool,
    hideFromContinueListening: Bool = false,
    serverUpdatedAt: Date?,
    serverRow: ServerRowObservation? = nil
  ) {
    self.serverEpisodeId = serverEpisodeId
    self.currentTime = currentTime
    self.isFinished = isFinished
    self.hideFromContinueListening = hideFromContinueListening
    self.serverUpdatedAt = serverUpdatedAt
    self.serverRow = serverRow
  }

  /// The server's post-reset state for an episode a complete snapshot omits.
  static func absent(serverEpisodeId: String) -> PodcastEpisodeProgressObservation {
    PodcastEpisodeProgressObservation(
      serverEpisodeId: serverEpisodeId, currentTime: 0, isFinished: false,
      hideFromContinueListening: false, serverUpdatedAt: nil, serverRow: .absent)
  }
}

/// The complete merge input assembled after episode upsert, inside the refresh transaction.
public struct PodcastProgressMergeContext: Sendable, Equatable {
  public let serverEpisodeId: String
  public let identity: MediaProgressIdentity
  public let currentProgress: MediaProgressRecord?
  public let hasUnacknowledgedLocalOperation: Bool
  public let incomingCurrentTime: Double
  public let incomingIsFinished: Bool
  public let incomingServerUpdatedAt: Date?
  public let durationSeconds: Double?
  public var incomingServerRow: ServerRowObservation? = nil
}

/// SyncEngine's synchronous decision for one context. The store writes it before committing the
/// transaction, closing the race between reading local progress/outbox state and applying a pull.
public enum PodcastProgressMergeDecision: Sendable, Equatable {
  case applyServer
  case recordConflict(detectedAt: Date)
  case keepLocal
}

public typealias PodcastProgressMergeDecider =
  @Sendable (PodcastProgressMergeContext) -> PodcastProgressMergeDecision

/// The fully decoded, mapped result of refreshing one selected podcast show.
///
/// Duplicate episode ids and duplicate progress ids are last-wins, which keeps malformed server
/// arrays deterministic. Progress for an id absent from this item's local episode rows is dropped;
/// it never falls back to item-level progress.
public struct PodcastRefreshApplication: Sendable, Equatable {
  public let accountId: Int64
  public let itemId: Int64
  public let episodes: [PodcastEpisodeRecord]
  /// Authoritative chapter snapshots keyed by server episode id. An episode present here has its
  /// chapters replaced in the same transaction as its row; one absent keeps what it has, which is
  /// what a caller with no chapter information (removal reconciliation) needs.
  public let episodeChapters: [String: [StoredItemChapter]]
  public let progressObservations: [PodcastEpisodeProgressObservation]
  public let autoDownloadEpisodes: Bool?
  public let autoDownloadSchedule: String?
  public let lastEpisodeCheck: Date?
  public let maxEpisodesToKeep: Int?
  public let maxNewEpisodesToDownload: Int?
  /// The show's own synopsis, as the server sent it. Preserved when absent, like the diagnostic
  /// fields below.
  public let showDescription: String?
  /// Whether this show's episode list decoded whole. Says nothing about any other endpoint
  /// decoded in the same refresh. It gates the two writes that a lost field would corrupt:
  /// generation-based soft deletion, and clearing a diagnostic field back to unknown.
  public let responseIsComplete: Bool
  /// When supplied, the content application and catalogue checkpoint commit together.
  public let refreshedAt: Date?
  /// Durable server-item identity for this response. The store validates it against the local
  /// item before applying the response so a response cannot cross item scope.
  public let serverItemId: String?
  /// Request-start ordering token captured immediately before the expanded request. A nil token
  /// denotes an authoritative local snapshot (for example, post-removal reconciliation) and
  /// bypasses stale-response fencing.
  public let requestStartedAt: Date?
  /// Whether `progressObservations` came from a complete `/api/me` snapshot holding every row for
  /// this show. Only then does an observed episode missing from it count as reset.
  public let progressSnapshotIsComplete: Bool

  public init(
    accountId: Int64,
    itemId: Int64,
    episodes: [PodcastEpisodeRecord],
    episodeChapters: [String: [StoredItemChapter]] = [:],
    progressObservations: [PodcastEpisodeProgressObservation] = [],
    autoDownloadEpisodes: Bool? = nil,
    autoDownloadSchedule: String? = nil,
    lastEpisodeCheck: Date? = nil,
    maxEpisodesToKeep: Int? = nil,
    maxNewEpisodesToDownload: Int? = nil,
    showDescription: String? = nil,
    responseIsComplete: Bool,
    refreshedAt: Date? = nil,
    serverItemId: String? = nil,
    requestStartedAt: Date? = nil,
    progressSnapshotIsComplete: Bool = false
  ) {
    self.accountId = accountId
    self.itemId = itemId
    self.episodes = episodes
    self.episodeChapters = episodeChapters
    self.progressObservations = progressObservations
    self.autoDownloadEpisodes = autoDownloadEpisodes
    self.autoDownloadSchedule = autoDownloadSchedule
    self.lastEpisodeCheck = lastEpisodeCheck
    self.maxEpisodesToKeep = maxEpisodesToKeep
    self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
    self.showDescription = showDescription
    self.responseIsComplete = responseIsComplete
    self.refreshedAt = refreshedAt
    self.serverItemId = serverItemId
    self.requestStartedAt = requestStartedAt
    self.progressSnapshotIsComplete = progressSnapshotIsComplete
  }
}

public enum PodcastRefreshStoreError: Error, Equatable, Sendable {
  case itemNotFound
  case itemScopeMismatch
  case itemIsNotPodcast
  case invalidEpisodeScope
  /// The decoded response began before a newer same-item mutation or authoritative refresh
  /// checkpoint committed. The transaction must be retried from the newer durable state.
  case supersededByNewerMutation
}

/// Atomically applies the Persistence-owned half of one expanded podcast refresh.
///
/// Callers decode and map the complete response first, so a cancellation, transport failure or
/// top-level decode failure before `apply` writes nothing. Once entered, episode rows, merge
/// decisions, diagnostics and optional deletion inference commit together or roll back together.
public struct PodcastRefreshStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func apply(
    _ application: PodcastRefreshApplication,
    decideProgress: @escaping PodcastProgressMergeDecider
  ) throws {
    try database.write { db in
      try Self.apply(application, decideProgress: decideProgress, in: db)
    }
  }

  public func applyAsync(
    _ application: PodcastRefreshApplication,
    decideProgress: @escaping PodcastProgressMergeDecider
  ) async throws {
    try Task.checkCancellation()
    try await database.writeAsync { db in
      try Task.checkCancellation()
      try Self.apply(application, decideProgress: decideProgress, in: db)
    }
  }

  /// Resolves the account-scoped item row for a durable server item id and applies a complete
  /// episode snapshot through the reconciliation `apply` uses. Runs inside another store's write
  /// transaction (`NativeEpisodeServerSaveAttemptStore.transitionToRemovedApplyingReconciliation`),
  /// so a removal's episode/count reconciliation commits atomically with its `.removed`
  /// transition. `episodes` may carry any placeholder `itemId`; each record is restamped with the
  /// resolved row. A missing, cross-account or ambiguous item throws
  /// `PodcastRefreshStoreError.itemNotFound`/`.itemScopeMismatch`, rolling back the caller.
  static func applyRemovalReconciliation(
    accountId: Int64,
    serverItemId: String,
    episodes: [PodcastEpisodeRecord],
    refreshedAt: Date?,
    in db: Database
  ) throws {
    let matchingItems =
      try ItemRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("serverItemId") == serverItemId)
      .fetchAll(db)
    guard matchingItems.isEmpty == false else {
      throw PodcastRefreshStoreError.itemNotFound
    }
    // `serverItemId` is unique only within a library, so a malformed cache can hold two rows for
    // one account-wide server id. Picking one with `fetchOne` would reconcile an arbitrary
    // library and still let the attempt become terminal. Removal needs one unambiguous
    // account/server-item podcast row.
    guard matchingItems.count == 1, let item = matchingItems.first, let localItemID = item.id else {
      throw PodcastRefreshStoreError.itemScopeMismatch
    }
    let application = PodcastRefreshApplication(
      accountId: accountId,
      itemId: localItemID,
      episodes: episodes.map { episode in
        var episode = episode
        episode.itemId = localItemID
        return episode
      },
      responseIsComplete: true,
      refreshedAt: refreshedAt,
      serverItemId: serverItemId)
    try Self.apply(application, decideProgress: { _ in .keepLocal }, in: db)
  }

  private static func apply(
    _ application: PodcastRefreshApplication,
    decideProgress: PodcastProgressMergeDecider,
    in db: Database
  ) throws {
    guard var item = try ItemRecord.fetchOne(db, key: application.itemId) else {
      throw PodcastRefreshStoreError.itemNotFound
    }
    guard item.accountId == application.accountId else {
      throw PodcastRefreshStoreError.itemScopeMismatch
    }
    guard item.mediaKind == "podcast" else {
      throw PodcastRefreshStoreError.itemIsNotPodcast
    }
    if let serverItemId = application.serverItemId, item.serverItemId != serverItemId {
      throw PodcastRefreshStoreError.itemScopeMismatch
    }
    guard
      application.episodes.allSatisfy({
        $0.accountId == application.accountId && $0.itemId == application.itemId
      })
    else {
      throw PodcastRefreshStoreError.invalidEpisodeScope
    }

    // The fence runs before generation allocation, episode upserts, progress merges, diagnostic
    // updates and the catalogue checkpoint, in the same transaction, so a stale response fails
    // whole and leaves no partial episode/count snapshot. Removal reconciliation passes a nil
    // requestStartedAt because its local snapshot is authoritative, not a network observation.
    try Self.rejectIfSuperseded(application, item: item, in: db)

    let generation =
      (try Int.fetchOne(
        db,
        sql: "SELECT MAX(lastSeenGeneration) FROM podcastEpisode WHERE itemId = ?",
        arguments: [application.itemId]) ?? 0) + 1

    var episodeByServerID: [String: PodcastEpisodeRecord] = [:]
    for episode in application.episodes {
      episodeByServerID[episode.serverEpisodeId] = episode
    }
    for serverEpisodeID in episodeByServerID.keys.sorted() {
      guard var episode = episodeByServerID[serverEpisodeID] else { continue }
      let existing =
        try PodcastEpisodeRecord
        .filter(Column("itemId") == application.itemId)
        .filter(Column("serverEpisodeId") == serverEpisodeID)
        .fetchOne(db)
      episode.id = existing?.id
      episode.lastSeenGeneration = generation
      episode.softDeleted = false
      try episode.save(db)
      if let chapters = application.episodeChapters[serverEpisodeID], let episodeRowId = episode.id {
        try PodcastEpisodeChapterStore.replace(
          db, accountId: application.accountId, podcastEpisodeId: episodeRowId, chapters: chapters)
      }
    }

    if application.responseIsComplete {
      try db.execute(
        sql: """
          UPDATE podcastEpisode
          SET softDeleted = 1
          WHERE accountId = ?
            AND itemId = ?
            AND lastSeenGeneration <> ?
          """,
        arguments: [application.accountId, application.itemId, generation])
    }

    var progressByServerID: [String: PodcastEpisodeProgressObservation] = [:]
    for observation in application.progressObservations {
      progressByServerID[observation.serverEpisodeId] = observation
    }
    if application.progressSnapshotIsComplete {
      for observed in try MediaProgressDAO.observedEpisodeServerIDs(
        db, accountId: application.accountId, itemIds: [application.itemId])
      where progressByServerID[observed.serverEpisodeId] == nil {
        progressByServerID[observed.serverEpisodeId] = .absent(
          serverEpisodeId: observed.serverEpisodeId)
      }
    }
    for serverEpisodeID in progressByServerID.keys.sorted() {
      guard
        let observation = progressByServerID[serverEpisodeID],
        let episode =
          try PodcastEpisodeRecord
          .filter(Column("accountId") == application.accountId)
          .filter(Column("itemId") == application.itemId)
          .filter(Column("serverEpisodeId") == serverEpisodeID)
          .fetchOne(db),
        let episodeID = episode.id
      else {
        continue
      }
      let identity = MediaProgressIdentity.episode(
        itemId: application.itemId, podcastEpisodeId: episodeID)
      let hasUnacknowledgedLocalOperation =
        try MediaProgressDAO.hasUnacknowledgedLocalOperation(
          db, accountId: application.accountId, identity: identity)
        || Self.hasActiveSessionLocalIntent(
          db,
          accountId: application.accountId,
          itemId: application.itemId,
          podcastEpisodeId: episodeID)
      let hasUnacknowledgedVisibilityOperation =
        try MediaProgressDAO.hasUnacknowledgedLocalOperation(
          db, accountId: application.accountId, identity: identity,
          field: .continueListeningVisibility)
      let context = PodcastProgressMergeContext(
        serverEpisodeId: serverEpisodeID,
        identity: identity,
        currentProgress: try MediaProgressDAO.fetchProgress(
          db, accountId: application.accountId, identity: identity),
        hasUnacknowledgedLocalOperation: hasUnacknowledgedLocalOperation,
        incomingCurrentTime: observation.currentTime,
        incomingIsFinished: observation.isFinished,
        incomingServerUpdatedAt: observation.serverUpdatedAt,
        durationSeconds: episode.durationSeconds,
        incomingServerRow: observation.serverRow)
      switch decideProgress(context) {
      case .applyServer:
        try MediaProgressDAO.upsertServerProgress(
          db, accountId: application.accountId, identity: identity,
          currentTime: observation.currentTime, isFinished: observation.isFinished,
          serverUpdatedAt: observation.serverUpdatedAt)
        try MediaProgressDAO.deleteConflict(db, accountId: application.accountId, identity: identity)
      case .recordConflict(let detectedAt):
        try MediaProgressDAO.upsertConflict(
          db, accountId: application.accountId, identity: identity,
          serverCurrentTime: observation.currentTime, serverIsFinished: observation.isFinished,
          serverUpdatedAt: observation.serverUpdatedAt, detectedAt: detectedAt)
      case .keepLocal:
        break
      }
      if hasUnacknowledgedVisibilityOperation == false {
        try MediaProgressDAO.applyServerVisibility(
          db, accountId: application.accountId, identity: identity,
          hideFromContinueListening: observation.hideFromContinueListening)
      }
      if let serverRow = observation.serverRow {
        try MediaProgressDAO.recordObservedServerProgressId(
          db, accountId: application.accountId, identity: identity,
          serverProgressId: serverRow.progressId, serverUpdatedAt: observation.serverUpdatedAt)
      }
    }

    // Diagnostic fields are preserved when absent: a partial response says nothing about a field
    // it lost, so a known value goes stale rather than blank. A complete response is
    // authoritative and may clear a field the server no longer exposes.
    if application.responseIsComplete {
      item.podcastAutoDownloadEpisodes = application.autoDownloadEpisodes
      item.podcastAutoDownloadSchedule = application.autoDownloadSchedule
      item.podcastLastEpisodeCheck = application.lastEpisodeCheck
      item.podcastMaxEpisodesToKeep = application.maxEpisodesToKeep
      item.podcastMaxNewEpisodesToDownload = application.maxNewEpisodesToDownload
      item.itemDescription = application.showDescription
      // A complete expanded response is authoritative for the show's live episode set. Count
      // after last-wins deduplication so the stored signal agrees with the rows just applied;
      // incomplete responses preserve the prior signal because omission is not evidence of an
      // empty show.
      item.podcastServerEpisodeCount = episodeByServerID.count
    } else {
      if let autoDownloadEpisodes = application.autoDownloadEpisodes {
        item.podcastAutoDownloadEpisodes = autoDownloadEpisodes
      }
      if let autoDownloadSchedule = application.autoDownloadSchedule {
        item.podcastAutoDownloadSchedule = autoDownloadSchedule
      }
      if let lastEpisodeCheck = application.lastEpisodeCheck {
        item.podcastLastEpisodeCheck = lastEpisodeCheck
      }
      if let maxEpisodesToKeep = application.maxEpisodesToKeep {
        item.podcastMaxEpisodesToKeep = maxEpisodesToKeep
      }
      if let maxNewEpisodesToDownload = application.maxNewEpisodesToDownload {
        item.podcastMaxNewEpisodesToDownload = maxNewEpisodesToDownload
      }
      if let showDescription = application.showDescription {
        item.itemDescription = showDescription
      }
    }
    try item.update(db)
    if let refreshedAt = application.refreshedAt {
      try PodcastCatalogRefreshStore.recordSuccess(
        itemID: application.itemId, at: refreshedAt,
        episodeListIsComplete: application.responseIsComplete, in: db)
    }
  }

  /// Refuses observations that did not start after the latest durable state for this exact account
  /// and server item. Equal wall-clock stamps fail closed because they cannot prove whether the
  /// response or mutation came first; an old uncertain attempt stops fencing once a demonstrably
  /// later refresh starts.
  private static func rejectIfSuperseded(
    _ application: PodcastRefreshApplication,
    item: ItemRecord,
    in db: Database
  ) throws {
    guard let requestStartedAt = application.requestStartedAt else { return }

    let hasNewerCheckpointOrMutation =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1
            FROM podcastRefreshState
            WHERE itemId = ? AND lastSuccessfulRefreshAt >= ?
          )
          OR EXISTS(
            SELECT 1
            FROM nativeEpisodeServerSaveAttempt
            WHERE accountId = ?
              AND serverItemId = ?
              AND updatedAt >= ?
          )
          """,
        arguments: [
          item.id ?? application.itemId, requestStartedAt,
          application.accountId, item.serverItemId, requestStartedAt,
        ]) ?? false
    guard hasNewerCheckpointOrMutation == false else {
      throw PodcastRefreshStoreError.supersededByNewerMutation
    }
  }

  static func hasActiveSessionLocalIntent(
    _ db: Database,
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64
  ) throws -> Bool {
    let sessions =
      try PlaybackSessionRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == itemId)
      .filter(Column("podcastEpisodeId") == podcastEpisodeId)
      .filter(Column("state") == PlaybackSessionState.active.rawValue)
      .fetchAll(db)

    if sessions.contains(where: \.isOffline) {
      return true
    }

    let unacknowledgedStates = [
      OutboxOperationState.pending.rawValue,
      OutboxOperationState.sending.rawValue,
      OutboxOperationState.retryWaiting.rawValue,
      OutboxOperationState.needsResolution.rawValue,
    ]
    for session in sessions where session.isOffline == false {
      guard let sessionId = session.id else { continue }
      if try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(unacknowledgedStates.contains(Column("state")))
        .fetchCount(db) > 0
      {
        return true
      }
    }
    return false
  }
}
