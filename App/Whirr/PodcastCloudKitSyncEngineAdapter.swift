import CloudKit
import Foundation
import SyncEngine

/// The one conformer of `PodcastCloudSyncing` that talks to CloudKit, and the only place in the
/// application where `CKSyncEngine` exists. Core owns the protocol, the record values, the mapping
/// and the merge; this owns engine construction, the delegate callbacks, and translation. It holds
/// no policy: the bootstrap barrier, batch splitting and repair, conflict merge and zone handling
/// live behind `PodcastCloudSyncHandling` in `SyncEngine`, tested against
/// `FakePodcastCloudSyncing` because the owner's security-key setup makes simulator iCloud sign-in
/// unavailable. `PodcastCloudSyncComposition.runtime` builds one per consented session, with that
/// session's `PodcastCloudSyncCoordinator` as handler, held weakly (ADR 0018): the session owns
/// the coordinator, the coordinator owns this, and an adapter outliving its session serves nothing.
@MainActor
final class PodcastCloudKitSyncEngineAdapter: PodcastCloudSyncing, CKSyncEngineDelegate {
  enum Failure: Error, Equatable {
    case notStarted
    /// Configuration is a construction-time value: changing `automaticallySync` means a new
    /// engine, so the bootstrap engine is retired by `stop()` before its replacement starts.
    case alreadyStarted
  }

  private weak let handler: (any PodcastCloudSyncHandling)?
  private var engine: CKSyncEngine?
  private var activation: PodcastCloudActivation?

  init(handler: any PodcastCloudSyncHandling) {
    self.handler = handler
  }

  private var zoneID: CKRecordZone.ID? {
    activation.map { CKRecordZone.ID(zoneName: $0.fence.zone, ownerName: CKCurrentUserDefaultName) }
  }

  func start(_ activation: PodcastCloudActivation) async throws {
    guard engine == nil else { throw Failure.alreadyStarted }
    // A malformed blob is not a reason to refuse to sync: engine state is a discardable cache, and
    // losing it costs a zone refetch. Starting with `nil` is the recovery for state loss,
    // and the bootstrap barrier is repeated either way.
    let serialization = activation.stateSerialization.flatMap {
      try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
    }
    var configuration = CKSyncEngine.Configuration(
      database: CKContainer(identifier: activation.fence.container).privateCloudDatabase,
      stateSerialization: serialization,
      delegate: self)
    configuration.automaticallySync = activation.automaticallySync
    self.activation = activation
    let engine = CKSyncEngine(configuration)
    self.engine = engine
    // Zone creation is explicit work, queued before anything else and only when the coordinator
    // says so: the intent is its decision, and this is the translation of it.
    if activation.zone == .create, let zoneID {
      engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }
    await rehydratePendingChanges(into: engine)
  }

  /// Seeds the new engine's pending set from the durable outbox: `stateSerialization` may be nil,
  /// stale or undecodable by this build, leaving the engine believing it has nothing to send, so
  /// the outbox (the source of truth) is asked once per construction. Translation, not policy: the
  /// handler decides what is outstanding (nothing while the bootstrap barrier is closed) and
  /// `nextRecordZoneChangeBatch` what is sent. A name needing no sending costs one no-op batch.
  private func rehydratePendingChanges(into engine: CKSyncEngine) async {
    add(await handler?.outstandingWork() ?? PodcastCloudPendingWork.none, to: engine)
  }

  private func add(_ work: PodcastCloudPendingWork, to engine: CKSyncEngine) {
    guard let zoneID, work.isEmpty == false else { return }
    engine.state.add(
      pendingRecordZoneChanges:
        work.saves.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) }
        + work.deletions.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
  }

  func schedule(_ work: PodcastCloudPendingWork) async {
    guard let engine else { return }
    add(work, to: engine)
  }

  func deleteZone() async throws {
    guard let engine, let zoneID else { throw Failure.notStarted }
    engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
    try await engine.sendChanges()
  }

  func fetchChanges() async throws {
    guard let engine else { throw Failure.notStarted }
    try await engine.fetchChanges()
  }

  func sendChanges() async throws {
    guard let engine else { throw Failure.notStarted }
    try await engine.sendChanges()
  }

  func stop() async {
    let retired = engine
    engine = nil
    activation = nil
    await retired?.cancelOperations()
  }

  // MARK: - CKSyncEngineDelegate

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    // The fence in one line: an event from an engine this adapter has already retired is a stale
    // callback, and is discarded rather than allowed to write.
    guard engine === syncEngine, let zoneID else { return }
    switch event {
    case .stateUpdate(let update):
      guard let blob = try? JSONEncoder().encode(update.stateSerialization) else { return }
      await handler?.handle(.stateSerialization(blob))
    case .sentDatabaseChanges(let changes):
      let saved = changes.savedZones.contains { $0.zoneID == zoneID }
      let failedSave = changes.failedZoneSaves.first { $0.zone.zoneID == zoneID }
      if saved || failedSave != nil {
        if failedSave?.error.code == .quotaExceeded { await handler?.handle(.quotaExceeded) }
        await handler?.handle(.zoneSave(succeeded: saved && failedSave == nil))
      }
      let deleted = changes.deletedZoneIDs.contains(zoneID)
      let failedDelete = changes.failedZoneDeletes[zoneID] != nil
      if deleted || failedDelete {
        await handler?.handle(.zoneDeletion(succeeded: deleted && !failedDelete))
      }
    case .sentRecordZoneChanges(let changes):
      // A save can be the first to learn the zone is gone. Zone loss is reported as such, before
      // the per-record results, so the coordinator treats it as zone loss, not a send failure.
      let lost = changes.failedRecordSaves.compactMap { zoneLoss(in: $0.error) }.first
      if let lost { await handler?.handle(.zoneLost(lost)) }
      await handler?.handle(.sentRecords(sentRecords(from: changes)))
    case .didSendChanges:
      await handler?.handle(.sendPassEnded)
    case .fetchedRecordZoneChanges(let changes):
      await handler?.handle(.fetchedChanges(fetchedChanges(from: changes)))
    case .didFetchRecordZoneChanges(let result):
      guard result.zoneID == zoneID else { return }
      if let loss = zoneLoss(in: result.error) {
        await handler?.handle(.zoneLost(loss))
      }
      if result.error?.code == .quotaExceeded {
        await handler?.handle(.quotaExceeded)
      }
      await handler?.handle(.fetchCompleted(succeeded: result.error == nil))
    case .accountChange(let change):
      await handler?.handle(.accountChanged(PodcastCloudKitTranslation.accountChange(for: change.changeType)))
    default:
      break
    }
  }

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard engine === syncEngine, let zoneID else { return nil }
    guard let batch = await handler?.nextBatch(within: .standard) else { return nil }
    return PodcastCloudKitTranslation.batch(from: batch, in: zoneID)
  }

  // MARK: - Event translation

  private func sentRecords(
    from changes: CKSyncEngine.Event.SentRecordZoneChanges
  ) -> PodcastCloudSentRecords {
    let saved = changes.savedRecords.map {
      PodcastCloudAcknowledgedRecord(recordName: $0.recordID.recordName, systemFields: Self.systemFields(of: $0))
    }
    let failed = changes.failedRecordSaves.map { failure -> PodcastCloudFailedRecord in
      // `serverRecordChanged` carries the server's record, so the merge has its new base without a
      // second fetch. Any other failure has no base to offer.
      let serverRecord = failure.error.serverRecord.flatMap { record in
        (try? PodcastCloudKitTranslation.fields(from: record)).map {
          PodcastCloudFetchedRecord(
            fields: $0, systemFields: Self.systemFields(of: record),
            serverModificationDate: record.modificationDate,
            plaintextFieldNames: PodcastCloudKitTranslation.plaintextFieldNames(of: record))
        }
      }
      return PodcastCloudKitTranslation.failedRecord(
        recordName: failure.record.recordID.recordName, error: failure.error, serverRecord: serverRecord)
    }
    let failedDeletions = changes.failedRecordDeletes.map { recordID, error in
      PodcastCloudKitTranslation.failedRecord(recordName: recordID.recordName, error: error)
    }
    return PodcastCloudSentRecords(
      saved: saved, failed: failed, deleted: changes.deletedRecordIDs.map(\.recordName),
      failedDeletions: failedDeletions)
  }

  private func fetchedChanges(
    from changes: CKSyncEngine.Event.FetchedRecordZoneChanges
  ) -> PodcastCloudFetchedChanges {
    // A record of an undeclared type is not decoded, but it is named rather than failing the
    // whole batch: one record a newer schema version introduced must not stop this version from
    // applying the rest, and holding it by name is what surfaces it as `Sync needs attention`.
    var modifications: [PodcastCloudFetchedRecord] = []
    var undeclared: [String] = []
    for modification in changes.modifications {
      let record = modification.record
      guard let fields = try? PodcastCloudKitTranslation.fields(from: record) else {
        undeclared.append(record.recordID.recordName)
        continue
      }
      modifications.append(
        PodcastCloudFetchedRecord(
          fields: fields, systemFields: Self.systemFields(of: record),
          serverModificationDate: record.modificationDate,
          plaintextFieldNames: PodcastCloudKitTranslation.plaintextFieldNames(of: record)))
    }
    return PodcastCloudFetchedChanges(
      modifications: modifications,
      deletions: changes.deletions.map(\.recordID.recordName),
      undeclaredRecordNames: undeclared)
  }

  private func zoneLoss(in error: (any Error)?) -> PodcastCloudZoneLoss? {
    guard let error = error as? CKError else { return nil }
    return PodcastCloudKitTranslation.zoneLoss(for: error.code)
  }

  /// `CKRecord.encodeSystemFields` output, carried across the boundary as opaque `Data`. A
  /// hand-written change tag is not enough to reconstruct a conditional save.
  private static func systemFields(of record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }
}
