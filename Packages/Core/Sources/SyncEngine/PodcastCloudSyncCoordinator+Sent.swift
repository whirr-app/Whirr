import Foundation
import GRDB
import Persistence

/// What the engine reports back about the sends it attempted: acknowledgements, deletions, and
/// the failures that must be held, rebased or handed back for another attempt.
extension PodcastCloudSyncCoordinator {
  func handleSent(_ sent: PodcastCloudSentRecords) async throws {
    guard let namespace else { return }
    let batchSize = sent.recordCount

    for acknowledgement in sent.saved {
      if let send = inFlight.removeValue(forKey: acknowledgement.recordName) {
        try await transport.acknowledge(send, systemFields: acknowledgement.systemFields)
      } else {
        // No ledger entry: the send predates this session. The archive is still the newest
        // server state, and the next conditional save needs it.
        let archive = acknowledgement.systemFields
        let recordName = acknowledgement.recordName
        try await database.writeAsync { db in
          try PodcastCloudTransportStore.recordSystemFields(
            in: db, namespace: namespace, recordName: recordName, archive: archive)
          try PodcastCloudTransportStore.release(in: db, namespace: namespace, recordName: recordName)
        }
      }
    }
    for recordName in sent.deleted {
      if let send = inFlight.removeValue(forKey: recordName) {
        try await transport.acknowledgeDeletion(send)
      }
    }

    let failures = try await applySendFailures(
      sent.failed + sent.failedDeletions, batchSize: batchSize)
    let reschedule = failures.reschedule
    let sawLimitExceeded = failures.sawLimitExceeded

    if sawLimitExceeded {
      recordCeiling = max(1, min(recordCeiling, batchSize) / 2)
    } else if sent.failed.isEmpty, sent.failedDeletions.isEmpty, batchSize > 0 {
      recordCeiling = min(PodcastCloudBatchLimits.standard.maximumRecords, recordCeiling * 2)
      if status.retryAfter != nil { await setStatus(.upToDate) }
      await clearInterruption()
    }
    if quotaPaused { await setStatus(.quotaExceeded) }
    await settleAttention()

    // The engine drops a change that failed with anything it does not retry itself, so whatever
    // must still go is handed back. A duplicate add is harmless: the pending set is a set.
    if reschedule.isEmpty == false, let engine {
      await engine.schedule(
        PodcastCloudPendingWork(
          saves: reschedule.filter { !$0.isPhysicalDeletion }.map(\.recordName),
          deletions: reschedule.filter(\.isPhysicalDeletion).map(\.recordName)))
    }
  }

  /// Applies one send pass's failures: hold what cannot be merged, rebase a lost conditional
  /// save, and report what must be handed back to the engine. A batch that exceeded a limit also
  /// reports that its ceiling should shrink.
  private func applySendFailures(
    _ failures: [PodcastCloudFailedRecord],
    batchSize: Int
  ) async throws -> (reschedule: [PodcastCloudPendingSend], sawLimitExceeded: Bool) {
    var reschedule: [PodcastCloudPendingSend] = []
    var sawLimitExceeded = false
    for failure in failures {
      let send = inFlight.removeValue(forKey: failure.recordName)
      switch failure.failure {
      case .batchRequestFailed:
        // An innocent sibling in an atomic batch. Nothing is acknowledged, and the engine retries
        // the change itself; the culprit is handled in its own iteration.
        break
      case .limitExceeded:
        if batchSize <= 1 {
          try await hold(
            failure.recordName, send: send, category: .recordTooLarge, serviceCode: failure.serviceCode)
        } else {
          sawLimitExceeded = true
          if let send { reschedule.append(send) }
        }
      case .recordTooLarge:
        try await hold(
          failure.recordName, send: send, category: .recordTooLarge, serviceCode: failure.serviceCode)
      case .malformedRecord:
        try await hold(
          failure.recordName, send: send, category: .malformed, serviceCode: failure.serviceCode)
      case .serverRecordChanged:
        if let send, send.isPhysicalDeletion {
          // Nothing to merge into a deletion; it goes again as it was.
          reschedule.append(send)
        } else if let rebased = try await resolveConflict(failure) {
          reschedule.append(rebased)
        }
      case .quotaExceeded:
        quotaPaused = true
        if let send { reschedule.append(send) }
      case .other:
        // The engine retries these on its own schedule. The suggested wait is for display only.
        if let retryAfter = failure.retryAfter, status == .upToDate || status.retryAfter != nil {
          await setStatus(.waiting(until: now().addingTimeInterval(retryAfter)))
        }
      }
    }
    return (reschedule, sawLimitExceeded)
  }

  /// Merges a lost conditional save against the server record the failure carried, in one
  /// transaction with whatever the outbox holds for the record now (which may be a newer local
  /// mutation than the one that was sent). Returns the rebased send when something must go again.
  func resolveConflict(_ failure: PodcastCloudFailedRecord) async throws -> PodcastCloudPendingSend? {
    guard let namespace else { return nil }
    let recordName = failure.recordName
    guard let server = failure.serverRecord, server.fields.recordName == recordName else {
      try await hold(recordName, send: nil, category: .unmergeable)
      return nil
    }
    let applier = applier
    let receivedAt = now()
    let key = recordNameKeys.current
    let monotonic = monotonic
    do {
      let (pending, drained) = try await database.writeAsync { db -> (PodcastCloudPendingSend?, Bool) in
        let drained = try Self.drainBeforeAdmission(in: db, key: key, now: receivedAt, monotonic: monotonic)
        return (
          try Self.resolveConflict(
            in: db, namespace: namespace, recordName: recordName, server: server, receivedAt: receivedAt,
            applier: applier, monotonic: monotonic), drained
        )
      }
      if drained { await outboxDidChange() }
      return pending
    } catch {
      try await hold(recordName, send: nil, category: .unmergeable)
      return nil
    }
  }

  static func resolveConflict(
    in db: Database, namespace: Data, recordName: String, server: PodcastCloudFetchedRecord,
    receivedAt: Date, applier: any PodcastCloudRemoteApplying, monotonic: PodcastCloudMonotonicSource
  ) throws -> PodcastCloudPendingSend? {
    try PodcastCloudTransportStore.recordSystemFields(
      in: db, namespace: namespace, recordName: recordName, archive: server.systemFields)
    guard
      let current = try PodcastCloudTransportStore.pendingSend(
        in: db, namespace: namespace, recordName: recordName),
      current.isPhysicalDeletion == false
    else { return nil }
    let local = try PodcastCloudRecordPayload.decode(current.payload)
    let hasUnsentListening = Self.isUnsentListeningPending(local: local, server: server.fields)
    switch try PodcastCloudRecordMerge.merge(
      local: local, server: server.fields, hasUnsentListening: hasUnsentListening)
    {
    case .keepServer:
      try PodcastCloudTransportStore.supersede(
        in: db, namespace: namespace, recordName: recordName, generation: current.generation)
      try Self.accept(server.fields, receivedAt: receivedAt, applier: applier, in: db)
      return nil
    case .publish(let merged):
      if merged != local {
        // Parts of the server's record won: project them here too, then publish the union.
        try Self.accept(merged, receivedAt: receivedAt, applier: applier, in: db)
        try PodcastCloudTransportStore.enqueue(
          in: db, recordName: recordName, payload: try PodcastCloudRecordPayload.encode(merged))
      } else {
        try PodcastCloudLocalPublication.recordAccepted(local, in: db)
      }
      return try PodcastCloudTransportStore.pendingSend(
        in: db, namespace: namespace, recordName: recordName)
    case .adoptLocalAsExplicit(let localFields):
      // This device's own value stays local and is republished as a fresh explicit action;
      // the local row is left untouched (never passed to `accept`), so a playing session's
      // sequence is not advanced by the reset it is refusing to adopt.
      try Self.republishAsExplicit(
        localFields, over: server, receivedAt: receivedAt, monotonic: monotonic, in: db)
      return try PodcastCloudTransportStore.pendingSend(
        in: db, namespace: namespace, recordName: recordName)
    }
  }

  /// Stamps and enqueues local edits the dirty log holds before a remote value is admitted, in the
  /// same transaction. Projection overwrites the local tables, so an edit that had not reached the
  /// outbox yet would otherwise be lost to a remote value it should have been merged with; drained
  /// first, it is a pending send and admission merges it. Returns whether anything was enqueued.
  static func drainBeforeAdmission(
    in db: Database, key: PodcastCloudRecordNameKey?, now: Date, monotonic: PodcastCloudMonotonicSource
  ) throws -> Bool {
    guard let key, try PodcastCloudDirtyLog.isEmpty(in: db) == false else { return false }
    return try PodcastCloudLocalReconciler.drain(in: db, recordNameKey: key, now: now, monotonic: monotonic)
      .published.isEmpty == false
  }

  /// Records a winning remote value (its stamp and the record itself as accepted) and its
  /// projection through the applier. Called inside the admission transaction.
  static func accept(
    _ fields: PodcastCloudRecordFields, receivedAt: Date, applier: any PodcastCloudRemoteApplying,
    in db: Database
  ) throws {
    let stamp = try PodcastCloudRecordMerge.governingStamp(of: fields)
    try PodcastCloudLocalPublication.recordAccepted(fields, in: db)
    try applier.apply(
      PodcastCloudAdmittedRecord(fields: fields, stamp: stamp, receivedAt: receivedAt), in: db)
  }
}
