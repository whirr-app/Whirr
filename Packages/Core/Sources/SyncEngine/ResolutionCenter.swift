import ABSApi
import Foundation
import Persistence

/// Errors `ResolutionCenter` raises. A missing account is a caller error (nothing to resolve
/// without one). Every other "not found" case (an already-resolved conflict or operation) is an
/// idempotent no-op, not an error.
public enum ResolutionCenterError: Error, Sendable, Equatable {
  case notAuthenticated
  case itemNotFound
}

/// One open resolution item: the Foundation-only, privacy-safe descriptor `ResolutionCenter`
/// enumerates for AppModel to render. Carries no payload, URL, or server id. `kind` holds only
/// local row references, and `itemTitle` is the sole server-derived content, resolved through a
/// local join.
public struct ResolutionOpenItem: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// The zero-position guard.
    case progressConflict(conflictId: Int64)
    /// Future-skew-beyond-tolerance confirmation.
    case skewConfirmation(operationId: Int64, sessionId: Int64)
    /// `reason` is the privacy-safe category already retained on the row.
    case deadLetter(operationId: Int64, reason: String?)
    /// Durable auth pause. One entry per distinct item with at least one `pausedAuth` download
    /// row, so a book's several audio-file rows give one entry.
    case pausedAuthDownload(itemId: Int64)
  }

  public let kind: Kind
  public let itemTitle: String
  /// `nil` where the underlying row has no durable creation timestamp
  /// (`OutboxOperationRecord`/`DownloadRecord`; only `ProgressConflictRecord` has one).
  public let detectedAt: Date?

  public init(kind: Kind, itemTitle: String, detectedAt: Date?) {
    self.kind = kind
    self.itemTitle = itemTitle
    self.detectedAt = detectedAt
  }

  public var id: String {
    switch kind {
    case .progressConflict(let conflictId): return "progressConflict:\(conflictId)"
    case .skewConfirmation(let operationId, _): return "skewConfirmation:\(operationId)"
    case .deadLetter(let operationId, _): return "deadLetter:\(operationId)"
    case .pausedAuthDownload(let itemId): return "pausedAuthDownload:\(itemId)"
    }
  }
}

/// SyncEngine's Foundation-only query/act API for resolution items: enumerates every open
/// `needsResolution` progress conflict, skew confirmation, `deadLetter` outbox row and
/// `pausedAuth` download; exposes the per-kind actions; and requeues on successful
/// re-authentication. Every mutating action answers an explicit user choice AppModel forwards;
/// nothing resolves automatically.
///
/// Each local resolution commit is one transaction in the `Persistence` methods this type calls.
/// A server-refresh-dependent action (skew take-server, dead-letter refresh-metadata) leaves the
/// resolution open on failure and commits the fetched value with the resolution state only on
/// success. Every action re-checks the row's current state first, so a repeated call (including
/// one racing a relaunch) is a no-op.
public actor ResolutionCenter {
  private let accountDAO: AccountDAO
  private let itemDAO: ItemDAO
  private let mediaProgressDAO: MediaProgressDAO
  private let outboxStore: OutboxStore
  private let sessionStore: PlaybackSessionStore
  private let observedServerTime: ObservedServerTimeStore
  private let downloadStore: DownloadStore
  private let downloadCoordinator: DownloadCoordinator
  private let client: ABSClient
  private let diagnostics: any DiagnosticsRecording
  /// Routes a re-authenticate action to the app's own auth flow (never performed here), like
  /// `OutboxDrainer.notifySessionGoneRecovery`. Success is reported back through
  /// `handleSuccessfulReauthentication()`, not inferred from this closure returning.
  private let requestReauthentication: @Sendable () async -> Void

  public init(
    database: AppDatabase,
    outboxStore: OutboxStore,
    downloadStore: DownloadStore,
    downloadCoordinator: DownloadCoordinator,
    client: ABSClient,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    requestReauthentication: @escaping @Sendable () async -> Void = {}
  ) {
    accountDAO = AccountDAO(database: database)
    itemDAO = ItemDAO(database: database)
    mediaProgressDAO = MediaProgressDAO(database: database)
    self.outboxStore = outboxStore
    sessionStore = PlaybackSessionStore(database: database, outbox: outboxStore)
    observedServerTime = ObservedServerTimeStore(database: database)
    self.downloadStore = downloadStore
    self.downloadCoordinator = downloadCoordinator
    self.client = client
    self.diagnostics = diagnostics
    self.requestReauthentication = requestReauthentication
  }

  // MARK: - Enumeration

  /// Every open resolution item across all four kinds, for the account's single v1 store.
  public func fetchOpenItems() async throws -> [ResolutionOpenItem] {
    guard let accountRecord = try await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      return []
    }
    var items: [ResolutionOpenItem] = []

    for conflict in try await mediaProgressDAO.fetchOpenConflictsAsync(accountId: accountId) {
      guard let conflictId = conflict.id else { continue }
      items.append(
        ResolutionOpenItem(
          kind: .progressConflict(conflictId: conflictId),
          itemTitle: await title(forItemRowId: conflict.itemId),
          detectedAt: conflict.detectedAt))
    }

    for operation in try await outboxStore.fetchHeldLocalSessionUploadsAsync(accountId: accountId) {
      guard let operationId = operation.id, let sessionId = operation.playbackSessionId else { continue }
      items.append(
        ResolutionOpenItem(
          kind: .skewConfirmation(operationId: operationId, sessionId: sessionId),
          itemTitle: await title(forSessionId: sessionId),
          detectedAt: nil))
    }

    for operation in try await outboxStore.fetchDeadLettersAsync(accountId: accountId) {
      guard let operationId = operation.id else { continue }
      items.append(
        ResolutionOpenItem(
          kind: .deadLetter(operationId: operationId, reason: operation.deadLetterReason),
          itemTitle: await itemRecord(forDeadLetter: operation, accountId: accountId)?.title ?? "Unknown item",
          detectedAt: nil))
    }

    let pausedAuthItemIds = try await Set(
      downloadStore.fetchAllAsync().filter { $0.state == .pausedAuth }.map(\.itemId))
    for itemId in pausedAuthItemIds {
      items.append(
        ResolutionOpenItem(
          kind: .pausedAuthDownload(itemId: itemId),
          itemTitle: await title(forItemRowId: itemId),
          detectedAt: nil))
    }

    return items
  }

  /// The open-item count for a Settings badge. Derived, not stored, so it cannot drift from the
  /// enumeration above.
  public func openCount() async throws -> Int {
    try await fetchOpenItems().count
  }

  // MARK: - Progress conflicts

  /// Keep-local: re-enqueues the local value as a fresh ordinary progress operation and clears
  /// the conflict (one transaction, `MediaProgressDAO.resolveConflictKeepingLocal`). A no-op if
  /// the conflict was already resolved (idempotent/relaunch-safe).
  public func keepLocalProgress(conflictId: Int64) async throws {
    guard let conflict = try await mediaProgressDAO.fetchConflictAsync(id: conflictId) else { return }
    guard let itemRecord = try await itemDAO.fetchOneAsync(id: conflict.itemId) else {
      throw ResolutionCenterError.itemNotFound
    }
    try await mediaProgressDAO.resolveConflictKeepingLocalAsync(
      conflictId: conflictId, entityKey: itemRecord.serverItemId)
  }

  /// Take-server: applies the already-recorded server value through the ordinary
  /// `applyServerResolution` write and clears the conflict (one transaction,
  /// `MediaProgressDAO.resolveConflictTakingServer`). A no-op if already resolved.
  public func takeServerProgress(conflictId: Int64) async throws {
    guard try await mediaProgressDAO.fetchConflictAsync(id: conflictId) != nil else { return }
    try await mediaProgressDAO.resolveConflictTakingServerAsync(conflictId: conflictId)
  }

  /// Use server progress for all: applies the single-conflict take-server path to every open
  /// progress conflict, one at a time, continuing past an individual failure. Progress conflicts
  /// only; skew confirmations, dead letters and paused-auth downloads are untouched. A missing
  /// account means "nothing to resolve" (as in `fetchOpenItems`), not an error.
  public func takeServerForAllProgressConflicts() async throws -> BulkProgressConflictResolutionResult {
    guard let accountRecord = try await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      return BulkProgressConflictResolutionResult(resolvedCount: 0, failedCount: 0)
    }
    let conflicts = try await mediaProgressDAO.fetchOpenConflictsAsync(accountId: accountId)
    var resolvedCount = 0
    var failedCount = 0
    for conflict in conflicts {
      guard let conflictId = conflict.id else { continue }
      do {
        try await takeServerProgress(conflictId: conflictId)
        resolvedCount += 1
      } catch {
        failedCount += 1
      }
    }
    return BulkProgressConflictResolutionResult(resolvedCount: resolvedCount, failedCount: failedCount)
  }

  // MARK: - Skew confirmations

  /// Keep-local confirmation: releases the held clamped upload, re-clamped against `now` (the
  /// moment of confirmation, not when it was first held), authorising that value to win under the
  /// server's last-write-wins behaviour. A no-op if the row is no longer held (already resolved
  /// or relaunch-safe).
  public func keepLocalSkew(operationId: Int64, sessionId: Int64, now: Date = Date()) async throws {
    guard let operation = try await outboxStore.fetchOperationAsync(id: operationId),
      operation.state == .needsResolution
    else { return }
    guard
      let material = try await sessionStore.fetchLocalSessionUploadMaterialAsync(
        sessionId: sessionId
      )
    else { return }
    guard let accountRecord = try await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      throw ResolutionCenterError.notAuthenticated
    }

    // `clampSyncTimestamps` owns the shared clamp policy; this call supplies only the
    // account-specific observed offset.
    let observedServerOffset = (try? observedServerTime.fetchOffset(accountId: accountId)) ?? nil
    let clamped = clampSyncTimestamps(
      startedAt: material.startedAt, updatedAt: material.updatedAt, now: now,
      observedServerOffset: observedServerOffset)
    try await sessionStore.releaseHeldLocalUploadAsync(
      operationId: operationId, sessionId: sessionId, clampedStartedAt: clamped.startedAt,
      clampedUpdatedAt: clamped.updatedAt)
  }

  /// Take-server / discard-upload: runs the item-progress refresh (`GET /api/me`, the source
  /// `SyncEngine`'s library-pull merge reads). On failure or no matching row the resolution is
  /// untouched. On success, in one transaction, removes the held operation, keeps the session as
  /// local history and applies the server value without marking the session uploaded
  /// (`PlaybackSessionStore`'s combined overload). A no-op if the row is no longer held.
  public func takeServerSkew(operationId: Int64, sessionId: Int64) async throws {
    guard let operation = try await outboxStore.fetchOperationAsync(id: operationId),
      operation.state == .needsResolution
    else { return }
    guard
      let material = try await sessionStore.fetchLocalSessionUploadMaterialAsync(
        sessionId: sessionId
      )
    else { return }
    guard let accountRecord = try await accountDAO.fetchAsync() else { throw ResolutionCenterError.notAuthenticated }
    let account = try tokenAccount(for: accountRecord)

    guard let rows = try? await client.fetchUserMediaProgress(account: account),
      let serverRow = rows.first(where: {
        $0.libraryItemID == material.itemServerId && $0.episodeID == material.episodeServerId
      }),
      let serverCurrentTime = serverRow.currentTime
    else {
      // Refresh failed, or the server no longer reports this item at all: leave the resolution
      // open rather than discarding without a value to apply.
      return
    }

    try await sessionStore.discardHeldLocalUploadAsync(
      operationId: operationId, sessionId: sessionId, applyingServerCurrentTime: serverCurrentTime,
      serverIsFinished: serverRow.isFinished, serverUpdatedAt: serverRow.lastUpdate)
  }

  // MARK: - Dead letters

  /// Discard: deletes the dead-lettered row with one diagnostic. A no-op if the row already
  /// left `deadLetter` (idempotent and relaunch-safe).
  public func discardDeadLetter(operationId: Int64) async throws {
    guard let operation = try await outboxStore.fetchOperationAsync(id: operationId), operation.state == .deadLetter
    else { return }
    try await outboxStore.acknowledgeAsync(operationId: operationId) { _ in }
    await diagnostics.record(
      DiagnosticsEvent(category: .outboxTransition, statusClass: .clientError, durationMilliseconds: 0),
      accountId: operation.accountId)
  }

  /// Refresh metadata: triggers the documented item refresh (`GET /api/items/{id}?expanded=1`)
  /// and requeues the row to `pending` only once that refresh succeeds, since a requeue is allowed
  /// only when whatever made the row fail permanently is confirmed resolved. A no-op if the row
  /// already left `deadLetter`.
  public func refreshMetadataDeadLetter(operationId: Int64) async throws {
    guard let operation = try await outboxStore.fetchOperationAsync(id: operationId), operation.state == .deadLetter
    else { return }
    guard let accountRecord = try await accountDAO.fetchAsync() else { throw ResolutionCenterError.notAuthenticated }
    let account = try tokenAccount(for: accountRecord)
    guard let serverItemId = await itemRecord(forDeadLetter: operation, accountId: accountRecord.id ?? -1)?.serverItemId
    else { return }

    guard (try? await client.fetchItemDetail(account: account, itemID: serverItemId)) != nil else {
      // The refresh itself failed: leave the row dead-lettered.
      return
    }
    _ = try? await outboxStore.transitionAsync(operationId: operationId, to: .pending)
  }

  /// Re-authenticate: routes to the app's own auth flow and transitions nothing itself.
  /// Callers invoke `handleSuccessfulReauthentication()` once that flow succeeds.
  public func requestReAuthentication() async {
    await requestReauthentication()
  }

  // MARK: - Auth recovery

  /// Called once the app's re-authentication flow reports success: transitions every `pausedAuth`
  /// download back to `pending` (`DownloadCoordinator.handleSuccessfulReauthentication`) and
  /// requeues every auth-dead-lettered outbox row (`deadLetterReason == "unauthorized"`) back to
  /// `pending`. Idempotent: a repeated call finds nothing left to requeue. The drain no longer
  /// dead-letters a 401 (it retains the row as `pending`), so the requeue serves only rows an
  /// earlier build dead-lettered.
  public func handleSuccessfulReauthentication() async throws {
    await downloadCoordinator.handleSuccessfulReauthentication()
    guard let accountRecord = try await accountDAO.fetchAsync(), let accountId = accountRecord.id else { return }
    for operation in try await outboxStore.fetchDeadLettersAsync(accountId: accountId)
    where operation.deadLetterReason == "unauthorized" {
      guard let operationId = operation.id else { continue }
      _ = try? await outboxStore.transitionAsync(operationId: operationId, to: .pending)
    }
  }

  // MARK: - Helpers

  private func title(forItemRowId itemId: Int64) async -> String {
    (try? await itemDAO.fetchOneAsync(id: itemId))?.title ?? "Unknown item"
  }

  private func title(forSessionId sessionId: Int64) async -> String {
    guard let session = try? await sessionStore.fetchSessionAsync(id: sessionId) else { return "Unknown item" }
    return await title(forItemRowId: session.itemId)
  }

  private static let entityKeyIsServerItemID: Set<String> = [
    OutboxOperationKind.progress.rawValue,
    OutboxOperationKind.progressReset.rawValue,
    OutboxOperationKind.bookmarkCreate.rawValue,
    OutboxOperationKind.bookmarkRename.rawValue,
    OutboxOperationKind.bookmarkDelete.rawValue,
    OutboxOperationKind.ebookPosition.rawValue,
    OutboxOperationKind.ebookReset.rawValue,
    OutboxOperationKind.sharedFinish.rawValue,
    OutboxOperationKind.continueListeningVisibility.rawValue,
  ]

  /// Resolves which item a dead-lettered row concerns: progress, reset, ebook, Continue Listening
  /// visibility and bookmark kinds carry the server item id directly as `entityKey`
  /// (API-CONVENTIONS rule 11; ADR 0011 for the reset leg). Every other kind
  /// (`sessionSync`/`sessionClose`/`localSessionUpload`) resolves it through its playback session.
  private func itemRecord(forDeadLetter operation: OutboxOperationRecord, accountId: Int64) async -> ItemRecord? {
    if Self.entityKeyIsServerItemID.contains(operation.operationKind) {
      return try? await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: operation.entityKey)
    }
    guard let sessionId = operation.playbackSessionId,
      let session = try? await sessionStore.fetchSessionAsync(id: sessionId)
    else { return nil }
    return try? await itemDAO.fetchOneAsync(id: session.itemId)
  }
}

/// The outcome of `takeServerForAllProgressConflicts()`: how many open progress conflicts were
/// resolved versus how many failed and were left open for individual retry. Counts, never a list
/// of which items failed, so the surface AppModel sees stays Foundation-only and privacy-safe.
public struct BulkProgressConflictResolutionResult: Sendable, Equatable {
  public let resolvedCount: Int
  public let failedCount: Int

  public init(resolvedCount: Int, failedCount: Int) {
    self.resolvedCount = resolvedCount
    self.failedCount = failedCount
  }
}

// MARK: - AppModel boundary

/// The resolution-center surface AppModel sees, as with `DownloadIntents`: AppModel may not
/// import `ResolutionCenter`'s concrete actor (ARCHITECTURE.md). `now` is an explicit parameter
/// because protocol requirements carry no default argument, so `ResolutionCenterModel` passes the
/// moment of confirmation itself.
public protocol ResolutionCenterAccess: Sendable {
  func fetchOpenItems() async throws -> [ResolutionOpenItem]
  func openCount() async throws -> Int
  func keepLocalProgress(conflictId: Int64) async throws
  func takeServerProgress(conflictId: Int64) async throws
  func takeServerForAllProgressConflicts() async throws -> BulkProgressConflictResolutionResult
  func keepLocalSkew(operationId: Int64, sessionId: Int64, now: Date) async throws
  func takeServerSkew(operationId: Int64, sessionId: Int64) async throws
  func discardDeadLetter(operationId: Int64) async throws
  func refreshMetadataDeadLetter(operationId: Int64) async throws
  func requestReAuthentication() async
}

extension ResolutionCenter: ResolutionCenterAccess {}

/// The default no-op `ResolutionCenterAccess` conformance: no open items are ever reported and
/// every action is a silent no-op. Serves as `AppDependencies.resolutionCenterAccess`'s default,
/// like `NoOpDownloadIntents`.
public struct NoOpResolutionCenterAccess: ResolutionCenterAccess, Sendable {
  public init() {}
  public func fetchOpenItems() async throws -> [ResolutionOpenItem] { [] }
  public func openCount() async throws -> Int { 0 }
  public func keepLocalProgress(conflictId: Int64) async throws {}
  public func takeServerProgress(conflictId: Int64) async throws {}
  public func takeServerForAllProgressConflicts() async throws -> BulkProgressConflictResolutionResult {
    BulkProgressConflictResolutionResult(resolvedCount: 0, failedCount: 0)
  }
  public func keepLocalSkew(operationId: Int64, sessionId: Int64, now: Date) async throws {}
  public func takeServerSkew(operationId: Int64, sessionId: Int64) async throws {}
  public func discardDeadLetter(operationId: Int64) async throws {}
  public func refreshMetadataDeadLetter(operationId: Int64) async throws {}
  public func requestReAuthentication() async {}
}
