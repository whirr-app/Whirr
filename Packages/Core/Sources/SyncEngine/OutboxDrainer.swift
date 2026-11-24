import ABSApi
import Foundation
import Persistence

/// The sole outbox-drain orchestrator (ARCHITECTURE.md), owned and driven by `SyncEngine`.
/// It sits beside the pull orchestrator so the two keyed-queue disciplines stay independently
/// testable. One instance owns one v1 account's drain state: keyed per-entity queues (never two
/// concurrent passes over one entity key, since actor reentrancy does not serialise across
/// `await`), at most one active request per operation, endpoint-specific acknowledgement
/// (`OutboxAcknowledgementPolicy`), and `BackoffPolicy` retry keyed off the persisted `attempts`
/// count, so a relaunch between attempts still computes the correct delay.
///
/// Audio progress, ebook legs and session operations all reuse this state machine. `entityKey` is
/// passed straight through as the wire `libraryItemID`.
///
/// `sessionSync` and `sessionClose` share the session's entity key
/// (`"session:<clientSessionId>"`, `PlaybackSessionStore`), so requests never overlap and a close
/// waits behind earlier syncs. Outcomes differ: a session-endpoint `404` is classified
/// session-gone (`PlaybackSessionStore.markSessionGone`) ahead of the generic permanent-error
/// branch, and a `sessionClose` `404` is reconciled against `GET /api/session/{id}` plus server
/// progress before counting as an acknowledged close.
public actor OutboxDrainer {
  let outboxStore: OutboxStore
  let sessionStore: PlaybackSessionStore
  /// Per-account observed-server-clock-offset store, read at upload time by the local-session
  /// upload batch drain. Built from the same `database` as the other stores.
  let observedServerTime: ObservedServerTimeStore
  /// Resolves item duration so audio progress PATCHes keep Audiobookshelf's separately-persisted
  /// `progress` fraction consistent with `currentTime`.
  let items: ItemDAO
  /// Resolves a `progress` row's `podcastEpisodeId` (a local row id) to the episode's server id
  /// at send time. Constructed from the same `database` every other store here is.
  let podcastEpisodes: PodcastEpisodeDAO
  /// The ebook acknowledgement path updates the progress row and deletes the dedicated operation
  /// in one `writeAsync` transaction; a plain `OutboxStore.acknowledge` would lose that atomicity.
  private let mediaProgressDAO: MediaProgressDAO
  let absClient: ABSClient
  let account: TokenAccount
  let accountId: Int64
  let policy: OutboxAcknowledgementPolicy
  let diagnostics: any DiagnosticsRecording
  /// Called after a locally-active session is marked gone, so the coordinator (which alone knows
  /// the live cadence phase) can decide whether to request a zero-delta replacement session. A
  /// plain closure keeps this actor decoupled from the concrete coordinator type.
  let notifySessionGoneRecovery: @Sendable (_ itemID: String, _ episodeID: String?) async -> Void

  /// Entity keys with a queue currently being drained. Guards against a second concurrent
  /// `drainOutbox()` call double-processing the same keyed queue.
  private var drainingEntityKeys: Set<String> = []
  /// Callers waiting for an entity's running pass to end.
  private var entityPassWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  /// Operation ids with an in-flight request, alongside `drainingEntityKeys`: at most one active
  /// request per operation.
  private var inFlightOperationIDs: Set<Int64> = []

  /// Float tolerance for comparing a close row's sent position against authoritative server
  /// progress during close-ambiguity reconciliation. Never an exact `==` on a value that crossed
  /// the network and a decode round trip twice.
  static let reconciliationTolerance: Double = 1.0

  // MARK: - Local session upload batches

  /// Bounded batches, never individual calls (API-CONVENTIONS.md rule 10). Mirrors
  /// `ABSApi.LocalSessionSyncBounds.maximum`, which is the real enforcement point and would throw
  /// first if the two drifted.
  static let localSessionUploadBatchSize = 50
  /// Guards against a second concurrent `drainLocalSessionUploads` call double-processing the
  /// whole-account batch queue. The unit of work is the account, not an entity, so one flag
  /// suffices.
  var isDrainingLocalSessionUploads = false
  /// Set by a call that arrived while a drain was running; consumed by one follow-up pass once the
  /// in-flight one finishes.
  var localSessionUploadDrainRequestedAgain = false

  /// Test-substitutable device-trace sink. The production sink is DEBUG-only; the seam pins that
  /// the records are wired to the local-all control flow.
  var emitLocalAllDeviceTraceRecord: @Sendable (LocalAllDeviceTrace.Record) -> Void = {
    LocalAllDeviceTrace.emit($0)
  }

  /// Test-substitutable acknowledge step for the local-all batch path. The only way a suite can
  /// make `PlaybackSessionStore.acknowledgeLocalUpload`'s write fail, since the in-memory database
  /// never does. `nil` (production) runs the real store call.
  var acknowledgeLocalUploadOverride: (@Sendable (Int64, Int64) throws -> Void)?

  /// Test-substitutable session-material read for the local-all batch path. The only way a suite
  /// can make `PlaybackSessionStore.fetchLocalSessionUploadMaterial` throw. `nil` (production) runs
  /// the real store call.
  var fetchLocalUploadMaterialOverride: (@Sendable (Int64) throws -> PlaybackSessionStore.LocalSessionUploadMaterial?)?

  public init(
    outboxStore: OutboxStore,
    database: AppDatabase,
    absClient: ABSClient,
    account: TokenAccount,
    accountId: Int64,
    policy: OutboxAcknowledgementPolicy = OutboxAcknowledgementPolicy(),
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    notifySessionGoneRecovery: @escaping @Sendable (_ itemID: String, _ episodeID: String?) async -> Void = {
      _, _ in
    }
  ) {
    self.outboxStore = outboxStore
    sessionStore = PlaybackSessionStore(database: database, outbox: outboxStore)
    observedServerTime = ObservedServerTimeStore(database: database)
    items = ItemDAO(database: database)
    podcastEpisodes = PodcastEpisodeDAO(database: database)
    mediaProgressDAO = MediaProgressDAO(database: database)
    self.absClient = absClient
    self.account = account
    self.accountId = accountId
    self.policy = policy
    self.diagnostics = diagnostics
    self.notifySessionGoneRecovery = notifySessionGoneRecovery
  }

  /// Drains every entity key with queued (`pending`/`retryWaiting`) operations. Different
  /// entities' queues may interleave; each queue is strictly sequential by `localSequence`.
  /// `now`/`randomUnit` drive backoff deterministically, with no wall-clock sleep
  /// (API-CONVENTIONS.md rule 14): a row not yet due stays queued for a later call.
  ///
  /// The key set is re-fetched after each wave: a mid-drain `markSessionGone` creates a
  /// preserved-position `progress` row whose key may not be in the first snapshot, and waiting
  /// for the next lifecycle trigger could strand it overnight. Only never-seen keys start another
  /// wave, so a row parked as `retryWaiting` cannot spin the loop.
  public func drainOutbox(
    now: Date = Date(),
    randomUnit: @Sendable @escaping () -> Double = { Double.random(in: 0...1) }
  ) async {
    var drainedKeys: Set<String> = []
    while true {
      guard let entityKeys = try? outboxStore.distinctQueuedEntityKeys(accountId: accountId) else { return }
      let freshKeys = entityKeys.filter { drainedKeys.contains($0) == false }
      guard freshKeys.isEmpty == false else { return }
      drainedKeys.formUnion(freshKeys)
      await withTaskGroup(of: Void.self) { group in
        for entityKey in freshKeys {
          group.addTask { await self.drainEntityQueue(entityKey, now: now, randomUnit: randomUnit) }
        }
      }
    }
  }

  private func drainEntityQueue(
    _ entityKey: String,
    now: Date,
    randomUnit: @Sendable @escaping () -> Double
  ) async {
    // A caller that finds the entity draining waits for that pass and then runs its own, rather
    // than returning: a background task awaiting this drain would otherwise end while the send it
    // depends on is still in flight. Its own pass also sends a row committed during that send.
    while drainingEntityKeys.contains(entityKey) {
      await withCheckedContinuation { entityPassWaiters[entityKey, default: []].append($0) }
    }
    drainingEntityKeys.insert(entityKey)
    defer {
      drainingEntityKeys.remove(entityKey)
      for waiter in entityPassWaiters.removeValue(forKey: entityKey) ?? [] { waiter.resume() }
    }

    while true {
      guard let head = try? outboxStore.fetchQueued(accountId: accountId, entityKey: entityKey).first,
        let operationId = head.id
      else { break }
      // Strictly sequential order: if the head-of-queue row isn't due yet, nothing behind it may
      // be attempted out of turn either.
      guard isDue(head, now: now) else { break }
      guard inFlightOperationIDs.contains(operationId) == false else { break }

      inFlightOperationIDs.insert(operationId)
      let shouldContinue = await attempt(head, now: now, randomUnit: randomUnit())
      inFlightOperationIDs.remove(operationId)

      if shouldContinue == false { break }
    }
  }

  func isDue(_ operation: OutboxOperationRecord, now: Date) -> Bool {
    guard let nextAttemptAt = operation.nextAttemptAt else { return true }
    return nextAttemptAt <= now
  }

  /// Sends one operation and applies whatever `OutboxStore`/`PlaybackSessionStore` transition its
  /// outcome implies. Returns whether this entity's queue may continue to its next operation this
  /// pass.
  private func attempt(_ operation: OutboxOperationRecord, now: Date, randomUnit: Double) async -> Bool {
    guard let operationId = operation.id,
      let sending = try? outboxStore.transition(operationId: operationId, to: .sending)
    else { return false }

    let outcome = await send(sending)
    await recordEbookDiagnosticIfNeeded(operation: sending, outcome: outcome)

    // Session-gone 404s are classified ahead of the generic permanent-error branch. Only session
    // endpoints qualify; an unrelated 404 (the `progress` kind) falls through to the ordinary
    // policy.
    if isSessionKind(sending), case .apiFailure(let error) = outcome, error == .notFound {
      return await handleSessionEndpointNotFound(sending, now: now, randomUnit: randomUnit)
    }

    // `/sync` is additive server-side and answers with no body, so an outcome that never saw a
    // response cannot tell a failed request from a landed one, and replaying a landed one adds its
    // listening time to the session twice. Reconcile against the session's own server-side total
    // before the ordinary policy may schedule a resend.
    if isAmbiguousSyncOutcome(sending, outcome) {
      switch await reconcileAmbiguousSync(sending) {
      case .landedOnServer:
        guard await acknowledgeSuccess(sending, acknowledgedAt: now) else {
          _ = try? outboxStore.transition(operationId: operationId, to: .pending)
          return false
        }
        return true
      case .didNotLand:
        break  // Fall through: the ordinary policy replays it, which is now known to be safe.
      case .inconclusive:
        // No evidence either way. Retaining costs a delayed upload; resending blind risks the
        // user's listening history, so wait for a pass that can tell.
        _ = try? outboxStore.transition(operationId: operationId, to: .pending)
        return false
      }
    }

    let decision = policy.decide(outcome: outcome, attempts: sending.attempts, now: now, randomUnit: randomUnit)

    switch decision {
    case .acknowledge:
      guard await acknowledgeSuccess(sending, acknowledgedAt: now) else {
        _ = try? outboxStore.transition(operationId: operationId, to: .pending)
        return false
      }
      return true
    case .retryWaiting(let delay):
      _ = try? outboxStore.transition(
        operationId: operationId, to: .retryWaiting, nextAttemptAt: now.addingTimeInterval(delay))
      return false
    case .deadLetter(let reason):
      _ = try? outboxStore.transition(operationId: operationId, to: .deadLetter, deadLetterReason: reason)
      return true
    case .retainAndHaltQueue, .cancelledRequeue, .awaitReauthentication:
      _ = try? outboxStore.transition(operationId: operationId, to: .pending)
      return false
    }
  }

  private func isSessionKind(_ operation: OutboxOperationRecord) -> Bool {
    operation.operationKind == OutboxOperationKind.sessionSync.rawValue
      || operation.operationKind == OutboxOperationKind.sessionClose.rawValue
  }

  /// Diagnostics are one closed category plus a fixed endpoint template. No operation id, item id,
  /// CFI, fraction, token, or server-provided error text crosses this boundary (SECURITY.md).
  ///
  /// A `progressReset` row's category follows its medium: ebook shares `.ebookProgress` with the
  /// other ebook legs; audio (or episode) uses `.outboxTransition`. The endpoint template reflects
  /// the pre-attempt phase (`operation` is read before `send` ran): resolve/restore are
  /// PATCH-shaped item routes, delete the row-id route. Templates are fixed and carry no id
  /// (API-CONVENTIONS.md rule 11).
  private func recordEbookDiagnosticIfNeeded(
    operation: OutboxOperationRecord,
    outcome: OutboxAcknowledgementPolicy.AttemptOutcome
  ) async {
    let category: DiagnosticsCategory
    let endpointTemplate: EndpointTemplate?
    switch operation.operationKind {
    case OutboxOperationKind.ebookPosition.rawValue, OutboxOperationKind.ebookReset.rawValue:
      category = .ebookProgress
      endpointTemplate = EndpointTemplate("/api/me/progress/:id")
    case OutboxOperationKind.sharedFinish.rawValue:
      category = .ebookFinish
      endpointTemplate = EndpointTemplate("/api/me/progress/:id")
    case OutboxOperationKind.progressReset.rawValue:
      category = operation.progressResetMedium == .ebook ? .ebookProgress : .outboxTransition
      switch operation.progressResetPhase {
      case .resolve, .restore:
        endpointTemplate = EndpointTemplate(
          operation.podcastEpisodeId == nil ? "/api/me/progress/:id" : "/api/me/progress/:id/:episodeId")
      case .delete:
        endpointTemplate = EndpointTemplate("/api/me/progress/:progressId")
      }
    default:
      return
    }
    await diagnostics.record(
      DiagnosticsEvent(
        category: category,
        statusClass: Self.diagnosticsStatusClass(for: outcome),
        durationMilliseconds: 0,
        endpointTemplate: endpointTemplate
      ),
      accountId: accountId
    )
  }

  private static func diagnosticsStatusClass(
    for outcome: OutboxAcknowledgementPolicy.AttemptOutcome
  ) -> DiagnosticsStatusClass {
    switch outcome {
    case .ordinarySuccess, .batchResult:
      return .success
    case .cancelled:
      return .cancelled
    case .decodeAmbiguous, .localReferenceGone:
      return .clientError
    case .apiFailure(let error):
      switch error {
      case .cancelled: return .cancelled
      case .transport: return .transportError
      case .rateLimited, .serverFailure: return .serverError
      default: return .clientError
      }
    }
  }

  /// Applies whichever endpoint-specific acknowledgement `OutboxAcknowledgementPolicy.decide` says
  /// is due. `sessionSync`/`sessionClose` subtract/free through `PlaybackSessionStore`, the only
  /// path that also updates the session's own delta/row atomically with the outbox delete. Every
  /// other kind uses the plain generic acknowledgement.
  func acknowledgeSuccess(
    _ operation: OutboxOperationRecord,
    acknowledgedAt: Date
  ) async -> Bool {
    guard let operationId = operation.id else { return false }
    switch operation.operationKind {
    case OutboxOperationKind.sessionSync.rawValue:
      guard let sessionId = operation.playbackSessionId else { return true }
      do {
        try await sessionStore.acknowledgeSyncAsync(operationId: operationId, sessionId: sessionId)
        return true
      } catch {
        return false
      }
    case OutboxOperationKind.sessionClose.rawValue:
      guard let sessionId = operation.playbackSessionId else { return true }
      do {
        try await sessionStore.acknowledgeCloseAsync(operationId: operationId, sessionId: sessionId)
        return true
      } catch {
        return false
      }
    case OutboxOperationKind.ebookPosition.rawValue,
      OutboxOperationKind.ebookReset.rawValue,
      OutboxOperationKind.sharedFinish.rawValue:
      do {
        try await mediaProgressDAO.acknowledgeEbookOutboxOperationAsync(
          operationId: operationId, acknowledgedAt: acknowledgedAt)
        return true
      } catch {
        return false
      }
    case OutboxOperationKind.progressReset.rawValue:
      do {
        try await mediaProgressDAO.acknowledgeProgressResetAsync(operationId: operationId)
        return true
      } catch {
        return false
      }
    default:
      do {
        try await outboxStore.acknowledgeAsync(operationId: operationId) { _ in }
        return true
      } catch {
        return false
      }
    }
  }

  // MARK: - Send (routes by operation kind)

  /// Routes each persisted operation kind to its field-specific wire leg while keeping the common
  /// `OutboxAcknowledgementPolicy.AttemptOutcome` contract unchanged.
  private func send(_ operation: OutboxOperationRecord) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    switch operation.operationKind {
    case OutboxOperationKind.sessionSync.rawValue, OutboxOperationKind.sessionClose.rawValue:
      return await sendSessionOperation(operation)
    case OutboxOperationKind.ebookPosition.rawValue:
      return await sendEbookPosition(operation)
    case OutboxOperationKind.ebookReset.rawValue:
      return await sendEbookReset(operation)
    case OutboxOperationKind.progressReset.rawValue:
      return await sendProgressReset(operation)
    case OutboxOperationKind.sharedFinish.rawValue:
      return await sendSharedFinish(operation)
    case OutboxOperationKind.continueListeningVisibility.rawValue:
      return await sendContinueListeningVisibility(operation)
    case OutboxOperationKind.bookmarkCreate.rawValue,
      OutboxOperationKind.bookmarkRename.rawValue,
      OutboxOperationKind.bookmarkDelete.rawValue:
      return await sendAudioBookmark(operation)
    default:
      return await sendProgress(operation)
    }
  }

}

/// Default `DiagnosticsRecording` for callers (chiefly tests exercising only the `progress`-kind
/// path) that don't care about diagnostics. Never wired in production, where `SyncEngine`'s real
/// `DiagnosticsStore` is always supplied. `public` only because it backs a public initialiser's
/// default argument.
public struct NoOpDiagnosticsRecording: DiagnosticsRecording {
  public init() {}
  public func record(_ event: DiagnosticsEvent, accountId: Int64) async {}
}
