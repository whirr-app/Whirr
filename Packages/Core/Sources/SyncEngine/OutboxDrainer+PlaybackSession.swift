import ABSApi
import Foundation
import Persistence

extension OutboxDrainer {
  /// `/sync`/`/close` send `{currentTime, timeListened, duration?}` from the frozen row
  /// (API-CONVENTIONS rule 8), never the session's live `globalPosition`/running delta, which may
  /// have moved on to a later, still-queued row by the time this one is sent.
  func sendSessionOperation(
    _ operation: OutboxOperationRecord
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    guard let sessionId = operation.playbackSessionId else {
      // A session-kind row pointing at no session. Both enqueue paths take a non-optional session
      // id, so this is a corrupted row, not a reachable state. No later pass can fix it, so
      // retaining would halt this session's queue on it forever.
      return .localReferenceGone(reason: "sessionReferenceMissing")
    }
    let session: PlaybackSessionRecord?
    do {
      session = try await sessionStore.fetchSessionAsync(id: sessionId)
    } catch {
      // The store could not answer (`SQLITE_BUSY`, a read error). No evidence either way, and a
      // later attempt may answer. Decode/protocol ambiguity retains the row and stops the drain.
      return .decodeAmbiguous
    }
    guard let session else {
      // Read succeeded and the session row is gone. `markSessionGone` deletes a session's outbox
      // rows in the same transaction and `playbackSessionId` is `ON DELETE CASCADE` besides, so the
      // store is already inconsistent. Unlike the read failure above, a later pass cannot change
      // this, so retaining is wrong.
      return .localReferenceGone(reason: "sessionRowMissing")
    }
    guard let serverSessionId = session.serverSessionId else {
      // The session exists but `/play` was never confirmed for it. Transient, unlike the two cases
      // above: `setServerSessionId` can still land and give this row an endpoint. If it never does,
      // `PlaybackSessionCoordinator.performRecovery` marks the session gone at next launch and
      // deletes its rows, so retaining is bounded either way.
      return .decodeAmbiguous
    }
    let update = SessionSyncUpdate(
      currentTime: operation.payloadCurrentTime ?? session.globalPosition,
      deltaSeconds: operation.payloadAccumulatedDeltaSeconds ?? 0,
      duration: operation.payloadDurationSeconds
    )
    do {
      if operation.operationKind == OutboxOperationKind.sessionClose.rawValue {
        try await absClient.closePlaybackSession(account: account, sessionID: serverSessionId, finalPosition: update)
      } else {
        try await absClient.syncPlaybackSession(account: account, sessionID: serverSessionId, update: update)
      }
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch {
      return .apiFailure(.transport)
    }
  }

  // MARK: - Session-gone 404 classification

  /// `sessionSync`'s `404` is unambiguous, so it goes straight to session-gone. `sessionClose`'s
  /// `404` is ambiguous (a lost response can look identical to a reaped session) and is reconciled
  /// first: neither replayed as idempotent nor treated as acknowledged.
  func handleSessionEndpointNotFound(
    _ operation: OutboxOperationRecord, now: Date, randomUnit: Double
  ) async -> Bool {
    guard operation.operationKind == OutboxOperationKind.sessionClose.rawValue else {
      return await markGoneAndRecover(operation, now: now)
    }

    switch await reconcileAmbiguousClose(operation) {
    case .landedOnServer:
      _ = await acknowledgeSuccess(operation, acknowledgedAt: now)
      return true
    case .sessionGone:
      return await markGoneAndRecover(operation, now: now)
    case .inconclusive:
      // No positive evidence the close landed, nor that the session is gone. Retry later like any
      // other transient outcome.
      guard let operationId = operation.id else { return false }
      let decision = policy.decide(
        outcome: .apiFailure(.transport), attempts: operation.attempts, now: now, randomUnit: randomUnit)
      if case .retryWaiting(let delay) = decision {
        _ = try? outboxStore.transition(
          operationId: operationId, to: .retryWaiting, nextAttemptAt: now.addingTimeInterval(delay))
      }
      return false
    }
  }

  /// The two outcomes that leave a `/sync` unknown: the transport never produced an answer, or the
  /// attempt was cancelled mid-flight (backgrounding, app kill). Any `apiFailure` the server
  /// actually returned proves the request was rejected, so nothing was added and the ordinary
  /// policy handles it.
  func isAmbiguousSyncOutcome(
    _ operation: OutboxOperationRecord, _ outcome: OutboxAcknowledgementPolicy.AttemptOutcome
  ) -> Bool {
    guard operation.operationKind == OutboxOperationKind.sessionSync.rawValue else { return false }
    switch outcome {
    case .cancelled: return true
    case .apiFailure(let error): return error == .transport
    default: return false
    }
  }

  enum SyncReconciliation {
    case landedOnServer
    case didNotLand
    case inconclusive
  }

  /// Reconciles an ambiguous `/sync` against `GET /api/session/{id}`'s own `timeListening`, the
  /// mirror of `reconcileAmbiguousClose`. The request carries no idempotency key, so the server's
  /// ledger is the only evidence.
  ///
  /// The session id came from this client's own `/play` and is never shared, so its total is what
  /// this client has added. Not `currentTime`: a backward seek makes it non-monotonic, and reading
  /// that as "did not land" would drop real listening time.
  func reconcileAmbiguousSync(_ operation: OutboxOperationRecord) async -> SyncReconciliation {
    guard let sessionId = operation.playbackSessionId,
      let session = try? sessionStore.fetchSession(id: sessionId),
      let serverSessionId = session.serverSessionId
    else { return .inconclusive }

    let delta = operation.payloadAccumulatedDeltaSeconds ?? 0
    guard delta > 0 else { return .didNotLand }

    let serverTotal: Double
    do {
      guard let remote = try await absClient.fetchPlaybackSession(account: account, sessionID: serverSessionId),
        let reported = remote.timeListening
      else {
        // The session is gone, or this server does not report the field. Either way there is no
        // ledger to compare against.
        return .inconclusive
      }
      serverTotal = reported
    } catch {
      return .inconclusive
    }

    // The server's total already includes this delta, so the request landed and only its response
    // was lost. Below that, it did not. The tolerance absorbs fractional-second drift between a
    // locally accumulated delta and the server's rounding.
    let expectedAfterLanding = session.acknowledgedListenedSeconds + delta
    return serverTotal >= expectedAfterLanding - Self.reconciliationTolerance
      ? .landedOnServer : .didNotLand
  }

  private enum CloseReconciliation {
    case landedOnServer
    case sessionGone
    case inconclusive
  }

  /// Reconciles a `sessionClose` `404` against `GET /api/session/{id}` plus authoritative
  /// server-side progress (API-CONVENTIONS rule 6a). `GET /api/session/{id}` alone cannot tell "our
  /// close already landed" from "the session was reaped without seeing it" (both read as absent),
  /// so it only gates the check (a still-open session proves the close has not landed yet). The
  /// authoritative-progress comparison decides.
  private func reconcileAmbiguousClose(_ operation: OutboxOperationRecord) async -> CloseReconciliation {
    guard let sessionId = operation.playbackSessionId,
      let session = try? sessionStore.fetchSession(id: sessionId),
      let serverSessionId = session.serverSessionId,
      let itemServerId = try? sessionStore.serverItemID(forSessionId: sessionId)
    else { return .inconclusive }

    do {
      if try await absClient.fetchPlaybackSession(account: account, sessionID: serverSessionId) != nil {
        return .inconclusive
      }
    } catch {
      return .inconclusive
    }

    do {
      let rows = try await absClient.fetchUserMediaProgress(account: account)
      guard let authoritative = rows.first(where: { $0.libraryItemID == itemServerId }),
        let authoritativeCurrentTime = authoritative.currentTime
      else { return .sessionGone }
      let sentPosition = operation.payloadCurrentTime ?? 0
      return authoritativeCurrentTime >= sentPosition - Self.reconciliationTolerance
        ? .landedOnServer : .sessionGone
    } catch {
      return .inconclusive
    }
  }

  /// Marks the session dead (`PlaybackSessionStore.markSessionGone`: one transaction covering the
  /// session row, all its outbox rows, and the preserved-position `progress` row), records one
  /// privacy-safe diagnostic, and routes the recoverable-active-playback decision back to the
  /// coordinator. Always returns `true`: every row for this session was just removed, so its queue
  /// has nothing further to send.
  private func markGoneAndRecover(_ operation: OutboxOperationRecord, now: Date) async -> Bool {
    guard let sessionId = operation.playbackSessionId,
      let outcome = try? sessionStore.markSessionGone(sessionId: sessionId, now: now)
    else { return true }

    await diagnostics.record(
      DiagnosticsEvent(
        category: .sessionLostDelta,
        statusClass: .clientError,
        durationMilliseconds: 0,
        endpointTemplate: EndpointTemplate(
          operation.operationKind == OutboxOperationKind.sessionClose.rawValue
            ? "/api/session/:id/close" : "/api/session/:id/sync")
      ),
      accountId: outcome.accountId
    )

    await notifySessionGoneRecovery(outcome.itemServerId, outcome.episodeServerId)
    return true
  }
}
