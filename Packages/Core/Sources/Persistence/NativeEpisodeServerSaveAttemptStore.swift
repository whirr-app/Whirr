import Foundation
import GRDB

/// Persistence failures and illegal state-machine operations are caller errors, not server retry
/// outcomes. The store never classifies network errors and never talks to Audiobookshelf.
public enum NativeEpisodeServerSaveAttemptStoreError: Error, Equatable, Sendable {
  case accountNotFound(Int64)
  case invalidAccountFence
  case accountFenceMismatch
  case invalidIdentity
  case invalidEpisodeIdentity
  case invalidServerIdentity
  case attemptNotFound(Int64)
  case illegalTransition(
    from: NativeEpisodeServerSaveAttemptState,
    to: NativeEpisodeServerSaveAttemptState)
  case serverItemIdentityRequired
  case concurrentServerItemMutation
  case serverEpisodeIdentityRequired
  case serverIdentityAlreadyRecorded
  case preflightRequired
  case preflightAlreadyRecorded
  case preflightMustPrecedeRequest
  case preExistingEpisodeCannotBeRemoved
  case supersededByNewerAttempt
}

/// Account-owned persistence for the save/remove operation. Each mutating method commits one
/// transaction; the `updatingLocalState` overloads let a coordinator persist an adjacent local
/// state change in that same transaction before the next network step is sent.
public struct NativeEpisodeServerSaveAttemptStore: Sendable {
  private let database: AppDatabase

  /// The complete legal transition table (ADR 0006). A retry/reconciliation caller must cross
  /// these edges explicitly, so nothing silently turns an accepted request into a new send or a
  /// pre-existing episode into a removable one.
  public static let legalTransitions: [NativeEpisodeServerSaveAttemptState: Set<NativeEpisodeServerSaveAttemptState>] =
    [
      .preparing: [.creatingShow, .requestingDownload, .failed],
      .creatingShow: [.requestingDownload, .createUncertain, .failed],
      .createUncertain: [.preparing, .requestingDownload, .failed],
      .requestingDownload: [.accepted, .uncertain, .failed],
      .accepted: [.confirmed, .uncertain],
      .confirmed: [.deleting],
      .deleting: [.removed, .deleteUncertain, .deleteFailed],
      .removed: [],
      .deleteUncertain: [.deleting, .removed, .deleteFailed],
      .deleteFailed: [.deleting],
      .uncertain: [.preparing, .accepted, .confirmed, .failed],
      .failed: [.preparing],
    ]

  static let activeStates: [NativeEpisodeServerSaveAttemptState] = [
    .preparing, .creatingShow, .requestingDownload, .accepted, .confirmed, .deleting,
    .deleteUncertain, .deleteFailed, .uncertain, .createUncertain,
  ]

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Creation and lookup

  /// Creates a fresh explicit attempt. Use `beginAttempt` when a UI tap should coalesce with an
  /// existing in-flight/accepted operation for this account and RSS identity.
  @discardableResult
  func createAttempt(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil,
    now: Date = Date()
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try database.write {
      try Self.create(
        accountId: accountId, feedId: feedId, episodeId: episodeId,
        episodeIdentityKey: episodeIdentityKey, preflightPresence: preflightPresence, now: now, in: $0)
    }
  }

  @discardableResult
  func createAttemptAsync(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil,
    now: Date = Date()
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync {
      try Self.create(
        accountId: accountId, feedId: feedId, episodeId: episodeId,
        episodeIdentityKey: episodeIdentityKey, preflightPresence: preflightPresence, now: now, in: $0)
    }
  }

  /// Idempotent start for an explicit tap. A non-removed active row for the same account and RSS
  /// identity is returned unchanged, preventing concurrent taps from manufacturing two flights.
  @discardableResult
  func beginAttempt(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    alternateEpisodeIdentityKeys: [String] = [],
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil,
    now: Date = Date()
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try database.write {
      try Self.begin(
        accountId: accountId, feedId: feedId, episodeId: episodeId,
        episodeIdentityKey: episodeIdentityKey, alternateEpisodeIdentityKeys: alternateEpisodeIdentityKeys,
        preflightPresence: preflightPresence, now: now, in: $0)
    }
  }

  @discardableResult
  public func beginAttemptAsync(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    alternateEpisodeIdentityKeys: [String] = [],
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil,
    now: Date = Date()
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync {
      try Self.begin(
        accountId: accountId, feedId: feedId, episodeId: episodeId,
        episodeIdentityKey: episodeIdentityKey,
        alternateEpisodeIdentityKeys: alternateEpisodeIdentityKeys, preflightPresence: preflightPresence,
        now: now, in: $0)
    }
  }

  func fetchAttempt(id: Int64) throws -> NativeEpisodeServerSaveAttemptRecord? {
    try database.read { db in try Self.fetchAttempt(id: id, in: db) }
  }

  public func fetchAttemptAsync(id: Int64) async throws -> NativeEpisodeServerSaveAttemptRecord? {
    try await database.readAsync { db in try Self.fetchAttempt(id: id, in: db) }
  }

  func fetchAttempts(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String? = nil
  ) throws -> [NativeEpisodeServerSaveAttemptRecord] {
    try database.read { db in
      try Self.fetchAttempts(
        accountId: accountId, feedId: feedId, episodeId: episodeId,
        episodeIdentityKey: episodeIdentityKey, in: db)
    }
  }

  public func fetchAttemptsAsync(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String? = nil
  ) async throws -> [NativeEpisodeServerSaveAttemptRecord] {
    try await database.readAsync { db in
      try Self.fetchAttempts(
        accountId: accountId, feedId: feedId, episodeId: episodeId,
        episodeIdentityKey: episodeIdentityKey, in: db)
    }
  }

  /// Every attempt of one account for any of `episodeIds` in one feed, newest change first, in
  /// one read. The show screen projects a status for every listed episode, so this avoids one
  /// read per row on every list emission.
  public func fetchAttemptsAsync(
    accountId: Int64,
    feedId: Int64,
    episodeIds: [Int64]
  ) async throws -> [NativeEpisodeServerSaveAttemptRecord] {
    guard episodeIds.isEmpty == false else { return [] }
    return try await database.readAsync { db in
      let records =
        try NativeEpisodeServerSaveAttemptRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("feedId") == feedId)
        .filter(episodeIds.contains(Column("episodeId")))
        .order(Column("updatedAt").desc, Column("id").desc)
        .fetchAll(db)
      let account = try Self.accountRecord(accountId: accountId, in: db)
      for record in records {
        try Self.validateAccountFence(record, account: account)
      }
      return records
    }
  }

  /// Live per-episode status for the show screen's visible rows: an account-scoped
  /// `ValueObservation` reduced to the latest attempt per episode with the record's own
  /// tie-break, the same one `NativeEpisodeServerSaveStatusProjection` uses in its pull path, so
  /// the two agree on which attempt is current. An empty `episodeIds` yields one `[:]` emission
  /// and finishes, matching the pull fallback.
  public func observeLatestAttempts(
    accountId: Int64,
    feedId: Int64,
    episodeIds: [Int64]
  ) -> AsyncStream<[Int64: NativeEpisodeServerSaveAttemptRecord]> {
    guard episodeIds.isEmpty == false else {
      return AsyncStream { continuation in
        continuation.yield([:])
        continuation.finish()
      }
    }
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db -> [Int64: NativeEpisodeServerSaveAttemptRecord] in
          // Same account fence as the pull path. Account replacement can reuse the local row
          // id, so without validating the account here an existing observation would keep
          // projecting the previous account's attempts until the caller resubscribed.
          guard let account = try AccountRecord.fetchOne(db, key: accountId) else { return [:] }
          let records =
            try NativeEpisodeServerSaveAttemptRecord
            .filter(Column("accountId") == accountId)
            .filter(Column("feedId") == feedId)
            .filter(episodeIds.contains(Column("episodeId")))
            .fetchAll(db)
          return Self.latestBy(from: records, account: account) { $0.episodeId }
        }
        .removeDuplicates())
  }

  /// Live status for a server show's own episode list, keyed by the server episode id the
  /// attempt confirmed. The server show screen has no RSS row to key by; what it can name is the
  /// episode the server created, and only an attempt that recorded that id can be removed from
  /// there. Rows without a server episode id are not reported. Same account fence and same
  /// latest-per-key reduction as `observeLatestAttempts(accountId:feedId:episodeIds:)`.
  public func observeLatestAttempts(
    accountId: Int64,
    serverItemId: String
  ) -> AsyncStream<[String: NativeEpisodeServerSaveAttemptRecord]> {
    guard serverItemId.isEmpty == false else {
      return AsyncStream { continuation in
        continuation.yield([:])
        continuation.finish()
      }
    }
    return ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db -> [String: NativeEpisodeServerSaveAttemptRecord] in
          guard let account = try AccountRecord.fetchOne(db, key: accountId) else { return [:] }
          let records =
            try NativeEpisodeServerSaveAttemptRecord
            .filter(Column("accountId") == accountId)
            .filter(Column("serverItemId") == serverItemId)
            .filter(Column("serverEpisodeId") != nil)
            .fetchAll(db)
          return Self.latestBy(from: records, account: account) { $0.serverEpisodeId }
        }
        .removeDuplicates())
  }

  /// The latest attempt per key among rows that pass the account fence. Both observations above
  /// reduce the same way, and `NativeEpisodeServerSaveAttemptRecord.isOlder(than:)` is the one
  /// order, so a newer attempt is never masked by an older sibling with a coincident `updatedAt`.
  private static func latestBy<Key: Hashable>(
    from records: [NativeEpisodeServerSaveAttemptRecord],
    account: AccountRecord,
    key keyOf: (NativeEpisodeServerSaveAttemptRecord) -> Key?
  ) -> [Key: NativeEpisodeServerSaveAttemptRecord] {
    var latest: [Key: NativeEpisodeServerSaveAttemptRecord] = [:]
    for record in records {
      guard let key = keyOf(record),
        (try? Self.validateAccountFence(record, account: account)) != nil
      else { continue }
      if let current = latest[key], record.isOlder(than: current) { continue }
      latest[key] = record
    }
    return latest
  }

  /// Attempts of one account in any of `states`, oldest change first, for a recovery pass.
  public func fetchAttemptsAsync(
    accountId: Int64,
    states: Set<NativeEpisodeServerSaveAttemptState>
  ) async throws -> [NativeEpisodeServerSaveAttemptRecord] {
    let rawStates = states.map(\.rawValue)
    return try await database.readAsync { db in
      try NativeEpisodeServerSaveAttemptRecord
        .filter(Column("accountId") == accountId)
        .filter(rawStates.contains(Column("state")))
        .order(Column("updatedAt").asc, Column("id").asc)
        .fetchAll(db)
    }
  }

  /// Confirms an attempt whose complete preflight found the episode already on the server. This
  /// is the one edge outside `legalTransitions`, and it is guarded by provenance: nothing was
  /// sent, the attempt is complete, and the `.preExisting` provenance it keeps is what forbids a
  /// later removal. Leaving such a row in `.preparing` would let later taps coalesce into an
  /// attempt that never finishes and would present Preparing after a relaunch.
  public func confirmPreExistingAsync(
    attemptId: Int64,
    serverItemId: String,
    serverEpisodeId: String,
    now: Date
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync { db in
      guard var record = try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: attemptId) else {
        throw NativeEpisodeServerSaveAttemptStoreError.attemptNotFound(attemptId)
      }
      try Self.validateAccountFence(record, in: db)
      guard record.state == .preparing, record.preflightPresence == .preExisting else {
        throw NativeEpisodeServerSaveAttemptStoreError.illegalTransition(
          from: record.state, to: .confirmed)
      }
      try Self.validateServerIdentity(serverItemId)
      try Self.validateServerIdentity(serverEpisodeId)
      if let existing = record.serverItemId, existing != serverItemId {
        throw NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
      }
      if let existing = record.serverEpisodeId, existing != serverEpisodeId {
        throw NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
      }
      record.serverItemId = serverItemId
      record.serverEpisodeId = serverEpisodeId
      record.errorCategory = nil
      record.state = .confirmed
      record.updatedAt = now
      try record.update(db)
      return record
    }
  }

  // MARK: - State transitions

  @discardableResult
  func transition(
    attemptId: Int64,
    to newState: NativeEpisodeServerSaveAttemptState,
    serverItemId: String? = nil,
    serverEpisodeId: String? = nil,
    alternateEpisodeIdentityKeys: [String] = [],
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil,
    errorCategory: NativeEpisodeServerSaveErrorCategory? = nil,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try database.write {
      try Self.transition(
        attemptId: attemptId, to: newState, serverItemId: serverItemId,
        serverEpisodeId: serverEpisodeId, alternateEpisodeIdentityKeys: alternateEpisodeIdentityKeys,
        preflightPresence: preflightPresence, errorCategory: errorCategory, now: now,
        updatingLocalState: updatingLocalState, in: $0)
    }
  }

  @discardableResult
  public func transitionAsync(
    attemptId: Int64,
    to newState: NativeEpisodeServerSaveAttemptState,
    serverItemId: String? = nil,
    serverEpisodeId: String? = nil,
    alternateEpisodeIdentityKeys: [String] = [],
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil,
    errorCategory: NativeEpisodeServerSaveErrorCategory? = nil,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync {
      try Self.transition(
        attemptId: attemptId, to: newState,
        serverItemId: serverItemId, serverEpisodeId: serverEpisodeId,
        alternateEpisodeIdentityKeys: alternateEpisodeIdentityKeys, preflightPresence: preflightPresence,
        errorCategory: errorCategory, now: now, updatingLocalState: updatingLocalState, in: $0)
    }
  }

  /// The `.removed` transition, with the post-delete episode/count snapshot committed in the same
  /// transaction, so no GRDB type crosses the SyncEngine boundary. `episodes` may carry any
  /// placeholder `itemId`: `PodcastRefreshStore.applyRemovalReconciliation` resolves the real row
  /// from `serverItemId` and restamps it. A missing or cross-account item rolls the transaction
  /// back, leaving the attempt in its prior (nonterminal) state.
  @discardableResult
  public func transitionToRemovedApplyingReconciliation(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    episodes: [PodcastEpisodeRecord]?,
    refreshedAt: Date,
    now: Date = Date()
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await transitionAsync(
      attemptId: attemptId, to: .removed, serverItemId: serverItemId, errorCategory: nil, now: now,
      updatingLocalState: { db in
        guard let attempt = try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: attemptId),
          attempt.accountId == accountId
        else { throw NativeEpisodeServerSaveAttemptStoreError.accountFenceMismatch }
        guard attempt.serverItemId == serverItemId else {
          throw attempt.serverItemId == nil
            ? NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
            : NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
        }

        // The helper resolves the item by account/server identity; require exactly one podcast row
        // first, or GRDB's `fetchOne` could reconcile an arbitrary duplicate. No row at all is
        // different from an ambiguous one: there is no catalogue state for `.removed` to run ahead
        // of, so the transition commits without a snapshot rather than pinning the attempt in
        // convergence-pending.
        let items =
          try ItemRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("serverItemId") == serverItemId)
          .fetchAll(db)
        let hasLocalItem = items.isEmpty == false
        if hasLocalItem {
          guard items.count == 1 else {
            throw PodcastRefreshStoreError.itemScopeMismatch
          }
          guard items[0].mediaKind == ItemMediaCategory.podcast.rawValue else {
            throw PodcastRefreshStoreError.itemIsNotPodcast
          }
        }

        // A concurrent save for the same server item may have a newer episode response in
        // flight. Do not let this removal's complete snapshot erase that operation's local
        // episode rows; the caller will retry reconciliation after the other operation settles.
        let mutationStates = Self.activeStates
          .filter { $0 != .confirmed }
          .map(\.rawValue)
        let removalUpdatedAt = attempt.updatedAt
        let hasConcurrentMutation =
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS(
                SELECT 1 FROM nativeEpisodeServerSaveAttempt
                WHERE accountId = ? AND serverItemId = ? AND id <> ?
                  AND (
                    state IN (\(mutationStates.map { "'\($0)'" }.joined(separator: ", ")))
                    OR (
                      state IN ('\(NativeEpisodeServerSaveAttemptState.confirmed.rawValue)',
                                '\(NativeEpisodeServerSaveAttemptState.removed.rawValue)')
                      AND (
                        updatedAt > ?
                        OR (updatedAt = ? AND id > ?)
                      )
                    )
                  )
              )
              """,
            arguments: [accountId, serverItemId, attemptId, removalUpdatedAt, removalUpdatedAt, attemptId]) ?? false
        guard hasConcurrentMutation == false else {
          throw NativeEpisodeServerSaveAttemptStoreError.concurrentServerItemMutation
        }

        guard hasLocalItem, let episodes else { return }
        try PodcastRefreshStore.applyRemovalReconciliation(
          accountId: accountId, serverItemId: serverItemId, episodes: episodes,
          refreshedAt: refreshedAt, in: db)
      })
  }

  /// Keeps a server-confirmed absence recoverable when its local catalogue transaction could not
  /// commit. From `.deleting` this crosses the ordinary state edge; from an already pending row it
  /// only refreshes the durable category/timestamp, preserving the state-machine rule that a
  /// second DELETE is never implied by a local retry.
  @discardableResult
  public func markRemovalConvergencePendingAsync(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    errorCategory: NativeEpisodeServerSaveErrorCategory = .localPersistence,
    now: Date = Date()
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync { db in
      guard let existing = try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: attemptId)
      else { throw NativeEpisodeServerSaveAttemptStoreError.attemptNotFound(attemptId) }
      try Self.validateAccountFence(existing, in: db)
      guard existing.accountId == accountId else {
        throw NativeEpisodeServerSaveAttemptStoreError.accountFenceMismatch
      }
      try Self.validateServerIdentity(serverItemId)
      guard existing.serverItemId == serverItemId else {
        throw existing.serverItemId == nil
          ? NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
          : NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
      }
      guard existing.state == .deleting || existing.state == .deleteUncertain else {
        throw NativeEpisodeServerSaveAttemptStoreError.illegalTransition(
          from: existing.state, to: .deleteUncertain)
      }

      if existing.state == .deleting {
        return try Self.transition(
          attemptId: attemptId, to: .deleteUncertain, serverItemId: serverItemId,
          serverEpisodeId: nil, alternateEpisodeIdentityKeys: [], preflightPresence: nil,
          errorCategory: errorCategory, now: now, updatingLocalState: { _ in }, in: db)
      }

      var record = existing
      record.errorCategory = errorCategory
      record.updatedAt = now
      try record.update(db)
      return record
    }
  }

  /// Records the created show id without crossing a state edge. Persist-before-send checkpoint
  /// between a successful create response and the enqueue request.
  @discardableResult
  func recordServerItemID(
    _ serverItemId: String,
    attemptId: Int64,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try database.write {
      try Self.updateIdentity(
        attemptId: attemptId, serverItemId: serverItemId,
        serverEpisodeId: nil, now: now, updatingLocalState: updatingLocalState, in: $0)
    }
  }

  public func recordServerItemIDAsync(
    _ serverItemId: String,
    attemptId: Int64,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync {
      try Self.updateIdentity(
        attemptId: attemptId, serverItemId: serverItemId,
        serverEpisodeId: nil, now: now, updatingLocalState: updatingLocalState, in: $0)
    }
  }

  /// Persists the confirmed episode id as its own checkpoint. A remove request may only use this
  /// value after the attempt reaches `.confirmed`.
  @discardableResult
  func recordServerEpisodeID(
    _ serverEpisodeId: String,
    attemptId: Int64,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try database.write {
      try Self.updateIdentity(
        attemptId: attemptId, serverItemId: nil,
        serverEpisodeId: serverEpisodeId, now: now, updatingLocalState: updatingLocalState, in: $0)
    }
  }

  @discardableResult
  public func recordServerEpisodeIDAsync(
    _ serverEpisodeId: String,
    attemptId: Int64,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync {
      try Self.updateIdentity(
        attemptId: attemptId, serverItemId: nil,
        serverEpisodeId: serverEpisodeId, now: now, updatingLocalState: updatingLocalState, in: $0)
    }
  }

  @discardableResult
  func recordPreflightPresence(
    _ presence: NativeEpisodeServerSavePreflightPresence,
    attemptId: Int64,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try database.write {
      try Self.updatePreflight(
        attemptId: attemptId, presence: presence, now: now,
        updatingLocalState: updatingLocalState, in: $0)
    }
  }

  @discardableResult
  public func recordPreflightPresenceAsync(
    _ presence: NativeEpisodeServerSavePreflightPresence,
    attemptId: Int64,
    now: Date = Date(),
    updatingLocalState: @escaping @Sendable (Database) throws -> Void = { _ in }
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await database.writeAsync {
      try Self.updatePreflight(
        attemptId: attemptId, presence: presence,
        now: now, updatingLocalState: updatingLocalState, in: $0)
    }
  }
}
