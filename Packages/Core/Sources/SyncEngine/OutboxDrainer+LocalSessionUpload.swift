import ABSApi
import Foundation
import Persistence

extension OutboxDrainer {
  func setAcknowledgeLocalUploadOverride(_ override: (@Sendable (Int64, Int64) throws -> Void)?) {
    acknowledgeLocalUploadOverride = override
  }

  func setFetchLocalUploadMaterialOverride(
    _ override: (@Sendable (Int64) throws -> PlaybackSessionStore.LocalSessionUploadMaterial?)?
  ) {
    fetchLocalUploadMaterialOverride = override
  }

  private struct LocalSessionUploadDrainPassResult: Sendable {
    var batches = 0
    var sessions = 0
    var halted = false
  }

  private struct LocalSessionUploadBatchResult: Sendable {
    let shouldContinue: Bool
    let sessions: Int
    let result: LocalAllDeviceTrace.BatchResult
    let accepted: Int
    let rejected: Int
  }

  // MARK: - Local session upload batches

  /// The bounded `local-all` reconciliation drain (API-CONVENTIONS.md rule 10). Triggers: launch,
  /// foreground, an offline-session close while conditions are non-offline, and explicit refresh,
  /// never a timer (rule 20). Coalesces like `PlaybackSessionCoordinator.performDrainRequest`: a
  /// mid-drain call only marks a follow-up, so co-incident triggers collapse into one pass plus at
  /// most one repeat, never concurrent batches.
  public func drainLocalSessionUploads(
    now: Date = Date(),
    randomUnit: @Sendable @escaping () -> Double = { Double.random(in: 0...1) }
  ) async {
    emitLocalAllDeviceTraceRecord(
      .drainStart(.init(coalesced: isDrainingLocalSessionUploads ? 1 : 0)))
    if isDrainingLocalSessionUploads {
      localSessionUploadDrainRequestedAgain = true
      return
    }
    isDrainingLocalSessionUploads = true
    let pass = await runLocalSessionUploadDrainPass(now: now, randomUnit: randomUnit)
    emitLocalAllDeviceTraceRecord(
      .drainEnd(.init(batches: pass.batches, sessions: pass.sessions, halted: pass.halted)))
    isDrainingLocalSessionUploads = false
    if localSessionUploadDrainRequestedAgain {
      localSessionUploadDrainRequestedAgain = false
      await drainLocalSessionUploads(now: now, randomUnit: randomUnit)
    }
  }

  /// Test seam for the device trace (see `emitLocalAllDeviceTraceRecord`).
  func setLocalAllDeviceTraceSink(
    _ sink: @escaping @Sendable (LocalAllDeviceTrace.Record) -> Void
  ) {
    emitLocalAllDeviceTraceRecord = sink
  }

  /// Sequential batches of up to 50 sessions (one linear `while` loop over `await`s, never
  /// concurrent) until nothing queued is due, or a batch signals to halt (a whole-batch
  /// cancellation, or a row whose session material could not be read, which retains the row and
  /// stops the drain).
  private func runLocalSessionUploadDrainPass(
    now: Date, randomUnit: @Sendable @escaping () -> Double
  ) async -> LocalSessionUploadDrainPassResult {
    var pass = LocalSessionUploadDrainPassResult()
    while true {
      guard
        let due = try? outboxStore.fetchQueuedLocalSessionUploads(
          accountId: accountId, limit: Self.localSessionUploadBatchSize, dueBy: now),
        due.isEmpty == false
      else { return pass }

      let batch = await sendLocalSessionUploadBatch(due, now: now, randomUnit: randomUnit())
      if batch.sessions > 0 {
        pass.batches += 1
        pass.sessions += batch.sessions
        emitLocalAllDeviceTraceRecord(
          .batch(
            .init(
              index: pass.batches, sessions: batch.sessions, result: batch.result,
              accepted: batch.accepted, rejected: batch.rejected)))
      }
      if batch.shouldContinue == false {
        pass.halted = true
        return pass
      }
    }
  }

  /// One batch: resolves each row's session material, withholds any that are unsendable (a
  /// quarantined session, a session confirmed gone, a missing payload, or a future-skewed
  /// timestamp awaiting confirmation), sends whatever remains,
  /// and applies the per-row acknowledgement. Returns whether the caller may continue to another
  /// batch this pass.
  private func sendLocalSessionUploadBatch(
    _ operations: [OutboxOperationRecord], now: Date, randomUnit: Double
  ) async -> LocalSessionUploadBatchResult {
    var sendable: [(operation: OutboxOperationRecord, session: LocalPlaybackSession)] = []
    var foundUnresolvableRow = false

    for operation in operations {
      guard let operationId = operation.id else { continue }
      let material: PlaybackSessionStore.LocalSessionUploadMaterial?
      do {
        material = try operation.playbackSessionId.flatMap(fetchLocalUploadMaterial(sessionId:))
      } catch {
        // A failed read says nothing about whether the session exists, so the row is retained.
        // It never changes state, so this pass halts after the batch rather than refetching it.
        foundUnresolvableRow = true
        continue
      }
      guard let material else {
        // The session is confirmed gone: there is nothing to send now or ever. Dead-letter it so
        // the row can no longer occupy the head of the queue (`.pending`/`.retryWaiting` reach
        // `.deadLetter` only through `.sending`, per `OutboxStore.legalTransitions`).
        if deadLetterLocalUpload(operationId: operationId, reason: "missingSession") == false {
          foundUnresolvableRow = true
        }
        continue
      }

      guard material.state == .closedAwaitingUpload else {
        // A duplicate `clientSessionId` quarantines the older row at `startSession` time rather
        // than merging, so by now the session this row points at is no longer awaiting upload.
        // Dead-letter the stale row rather than sending or merging it.
        if deadLetterLocalUpload(operationId: operationId, reason: "quarantined") == false {
          foundUnresolvableRow = true
        }
        continue
      }

      guard let currentTime = operation.payloadCurrentTime, let deltaSeconds = operation.payloadAccumulatedDeltaSeconds
      else {
        // Every enqueue writes both fields, so this row is permanently damaged rather than
        // waiting on anything that could change.
        if deadLetterLocalUpload(operationId: operationId, reason: "malformedPayload") == false {
          foundUnresolvableRow = true
        }
        continue
      }

      // `clampSyncTimestamps` owns the shared clamping policy; this call supplies only the
      // account-specific observed offset.
      let observedServerOffset = (try? observedServerTime.fetchOffset(accountId: accountId)) ?? nil
      let clamped = clampSyncTimestamps(
        startedAt: material.startedAt, updatedAt: material.updatedAt, now: now,
        observedServerOffset: observedServerOffset)
      if clamped.exceedsFutureTolerance {
        // Future skew beyond the shared five-minute tolerance: hold for explicit confirmation
        // rather than uploading. `.pending`/`.retryWaiting -> .needsResolution` are both legal
        // (`OutboxStore.legalTransitions`), so no detour through `.sending` is needed.
        _ = try? outboxStore.transition(operationId: operationId, to: .needsResolution)
        await diagnostics.record(
          DiagnosticsEvent(
            category: .clockSkew, statusClass: .clientError, durationMilliseconds: 0,
            endpointTemplate: EndpointTemplate("/api/session/local-all")),
          accountId: accountId)
        continue
      }

      // The duration frozen at close is the audio length this device measured; sending it stops
      // the server using the feed's, which podcast feeds overstate for ad insertion. Absent, never
      // zero, when unknown. `startTime` also comes from the row: the server computes start only
      // on the online `/play` path, so omitting it shows "Started at 00:00" in History.
      let localSession = LocalPlaybackSession(
        id: material.clientSessionId, libraryItemID: material.itemServerId, episodeID: material.episodeServerId,
        duration: operation.payloadDurationSeconds, startTime: material.startPosition, currentTime: currentTime,
        timeListening: deltaSeconds, startedAt: clamped.startedAt, updatedAt: clamped.updatedAt)
      sendable.append((operation, localSession))
    }

    guard sendable.isEmpty == false else {
      // Nothing left to send (every candidate was withheld, dead-lettered or unreadable). The
      // caller's loop never re-fetches a withheld or dead-lettered row (its state has moved on),
      // but an unreadable row never changes state, so halting here stops it spinning forever.
      return LocalSessionUploadBatchResult(
        shouldContinue: foundUnresolvableRow == false, sessions: 0, result: .ok, accepted: 0,
        rejected: 0)
    }

    for (operation, _) in sendable {
      guard let operationId = operation.id else { continue }
      _ = try? outboxStore.transition(operationId: operationId, to: .sending)
    }

    do {
      // A lost response is safe to replay serially (API-CONVENTIONS.md rule 10): the same stable
      // client session UUIDs and wall-clock timestamps are resent, and the server's `updatedAt`
      // guard skips re-applying stale progress to a session it already recorded. Safety rests on
      // that idempotency and on avoiding SQLite write contention.
      let result = try await absClient.syncLocalSessions(account: account, sessions: sendable.map(\.session))
      var acknowledgeWriteFailed = false
      for (operation, session) in sendable {
        guard let operationId = operation.id, let sessionId = operation.playbackSessionId else { continue }
        let rows = [
          OutboxAcknowledgementPolicy.BatchResultRow(id: session.id, success: result.acknowledged.contains(session.id))
        ]
        let decision = policy.decide(
          outcome: .batchResult(rows: rows, expectedID: session.id), attempts: operation.attempts, now: now,
          randomUnit: randomUnit)
        if applyLocalUploadDecision(decision, operationId: operationId, sessionId: sessionId, now: now) == false {
          acknowledgeWriteFailed = true
        }
      }
      return LocalSessionUploadBatchResult(
        shouldContinue: foundUnresolvableRow == false && acknowledgeWriteFailed == false,
        sessions: sendable.count, result: .ok,
        accepted: result.acknowledged.count, rejected: result.unacknowledged.count)
    } catch is CancellationError {
      return LocalSessionUploadBatchResult(
        shouldContinue: applyWholeLocalUploadBatchOutcome(
          .cancelled, to: sendable, now: now, randomUnit: randomUnit)
          && foundUnresolvableRow == false,
        sessions: sendable.count, result: .cancelled, accepted: 0, rejected: 0)
    } catch let apiError as APIError where apiError == .ambiguousLocalSessionResponse {
      return LocalSessionUploadBatchResult(
        shouldContinue: applyWholeLocalUploadBatchOutcome(
          .decodeAmbiguous, to: sendable, now: now, randomUnit: randomUnit)
          && foundUnresolvableRow == false,
        sessions: sendable.count, result: .httpError, accepted: 0, rejected: 0)
    } catch let apiError as APIError {
      let result: LocalAllDeviceTrace.BatchResult = apiError == .transport ? .transport : .httpError
      return LocalSessionUploadBatchResult(
        shouldContinue: applyWholeLocalUploadBatchOutcome(
          .apiFailure(apiError), to: sendable, now: now, randomUnit: randomUnit)
          && foundUnresolvableRow == false,
        sessions: sendable.count, result: result, accepted: 0, rejected: 0)
    } catch {
      return LocalSessionUploadBatchResult(
        shouldContinue: applyWholeLocalUploadBatchOutcome(
          .apiFailure(.transport), to: sendable, now: now, randomUnit: randomUnit)
          && foundUnresolvableRow == false,
        sessions: sendable.count, result: .transport, accepted: 0, rejected: 0)
    }
  }

  private func fetchLocalUploadMaterial(
    sessionId: Int64
  ) throws -> PlaybackSessionStore.LocalSessionUploadMaterial? {
    if let fetchLocalUploadMaterialOverride { return try fetchLocalUploadMaterialOverride(sessionId) }
    return try sessionStore.fetchLocalSessionUploadMaterial(sessionId: sessionId)
  }

  /// Returns whether the row left the queue. A failed write leaves it due again, so the caller
  /// must halt the pass rather than refetch it forever.
  private func deadLetterLocalUpload(operationId: Int64, reason: String) -> Bool {
    _ = try? outboxStore.transition(operationId: operationId, to: .sending)
    return (try? outboxStore.transition(operationId: operationId, to: .deadLetter, deadLetterReason: reason)) != nil
  }

  /// Applies the same classified outcome (transport/429/5xx/401-exhausted/cancellation) to every
  /// row in a batch whose request itself failed, as opposed to a decoded per-row result, which
  /// `sendLocalSessionUploadBatch`'s success path handles via
  /// `OutboxAcknowledgementPolicy.batchResult`. Returns whether the caller may continue to another
  /// batch this pass (`false` once any row requeues via cancellation, as in the per-entity loop).
  private func applyWholeLocalUploadBatchOutcome(
    _ outcome: OutboxAcknowledgementPolicy.AttemptOutcome,
    to sendable: [(operation: OutboxOperationRecord, session: LocalPlaybackSession)],
    now: Date, randomUnit: Double
  ) -> Bool {
    var shouldContinue = true
    for (operation, _) in sendable {
      guard let operationId = operation.id, let sessionId = operation.playbackSessionId else { continue }
      let decision = policy.decide(outcome: outcome, attempts: operation.attempts, now: now, randomUnit: randomUnit)
      if applyLocalUploadDecision(decision, operationId: operationId, sessionId: sessionId, now: now) == false {
        shouldContinue = false
      }
      // Each of these leaves the batch immediately due again, so the pass must stop rather than
      // refetch it; a latched client refuses locally, which would otherwise loop without bound.
      if case .cancelledRequeue = decision { shouldContinue = false }
      if case .retainAndHaltQueue = decision { shouldContinue = false }
      if case .awaitReauthentication = decision { shouldContinue = false }
    }
    return shouldContinue
  }

  /// Returns whether the drain pass may continue: `false` only when an acknowledge's local write
  /// failed. The row goes back to `pending` (as in `attempt`'s `acknowledgeSuccess` fallback;
  /// `sending` would hide it until the launch-time recovery sweep), and since that is immediately
  /// due the pass halts rather than replay against the failing write. The next drain retries; the
  /// replay is idempotent.
  private func applyLocalUploadDecision(
    _ decision: OutboxAcknowledgementPolicy.Decision, operationId: Int64, sessionId: Int64, now: Date
  ) -> Bool {
    switch decision {
    case .acknowledge:
      do {
        if let acknowledgeLocalUploadOverride {
          try acknowledgeLocalUploadOverride(operationId, sessionId)
        } else {
          try sessionStore.acknowledgeLocalUpload(operationId: operationId, sessionId: sessionId)
        }
      } catch {
        _ = try? outboxStore.transition(operationId: operationId, to: .pending)
        return false
      }
    case .retryWaiting(let delay):
      _ = try? outboxStore.transition(
        operationId: operationId, to: .retryWaiting, nextAttemptAt: now.addingTimeInterval(delay))
    case .deadLetter(let reason):
      _ = try? outboxStore.transition(operationId: operationId, to: .deadLetter, deadLetterReason: reason)
    case .retainAndHaltQueue, .cancelledRequeue, .awaitReauthentication:
      _ = try? outboxStore.transition(operationId: operationId, to: .pending)
    }
    return true
  }
}
