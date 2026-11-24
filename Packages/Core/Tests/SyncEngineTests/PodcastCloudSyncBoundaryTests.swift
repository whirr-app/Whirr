import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

/// The sync boundary, from the target that owns it.
///
/// One property these tests cannot assert: `PodcastCloudActivation` can only be built from a
/// `PodcastCloudInstallationResolution`, whose initializer is `fileprivate` to
/// `PodcastCloudInstallationResolver`, so every activation below must resolve an identity first
/// and the compiler enforces it. A test that could fake a resolution would show the enforcement
/// had been lost.
@Suite("Podcast cloud sync boundary")
struct PodcastCloudSyncBoundaryTests {
  private func resolution(
    database: AppDatabase, anchor: FakePodcastCloudInstallationAnchor
  ) async throws -> PodcastCloudInstallationResolution {
    let outcome = try await PodcastCloudInstallationResolver.resolve(database: database, anchor: anchor)
    guard case .resolved(let resolution) = outcome else {
      throw BoundaryTestFailure.unresolved
    }
    return resolution
  }

  private enum BoundaryTestFailure: Error { case unresolved }

  private func fence(epoch: Int64 = 1) -> PodcastCloudAccountFence {
    PodcastCloudAccountFence(
      container: "iCloud.com.remoteconcern.whirr", environment: "development", zone: "PodcastState",
      iCloudUserRecordID: "_user", accountEpoch: epoch)
  }

  // MARK: - Resolution

  @Test("a first run mints an identity, anchors it, and hands back a typed clock")
  func firstRunMints() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()

    let resolved = try await resolution(database: database, anchor: anchor)

    #expect(anchor.value == resolved.clock.installationUUID)
    #expect(resolved.clock.physicalMilliseconds == 0)
    #expect(resolved.clock.repairRequired == false)
  }

  @Test("an ordinary relaunch adopts the same identity rather than minting a second one")
  func relaunchAdopts() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()

    let first = try await resolution(database: database, anchor: anchor)
    let second = try await resolution(database: database, anchor: anchor)

    #expect(first.clock.installationUUID == second.clock.installationUUID)
    #expect(anchor.writes == 1)
  }

  @Test("the restore signature re-mints the identity and carries the numeric state forward")
  func restoreReMintsButKeepsCounters() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()
    let store = PodcastCloudInstallationStore(database: database, anchor: anchor)

    let original = try await resolution(database: database, anchor: anchor)
    // Somewhere non-trivial, so a reset would be visible rather than indistinguishable from a
    // fresh mint. `repairRequired` is included because clearing it on re-mint would launder
    // a quarantine through a restore.
    try await store.advance(
      PodcastCloudClockFields(
        installationUUID: original.clock.installationUUID.uuidString.lowercased(),
        physicalMilliseconds: 5_000, logicalCounter: 7, anchorServerMilliseconds: 4_000,
        lastAdmittedPhysicalMilliseconds: 3_000, lastAdmittedLogicalCounter: 2,
        repairRequired: true))

    anchor.clear()
    let reMinted = try await resolution(database: database, anchor: anchor)

    #expect(reMinted.clock.installationUUID != original.clock.installationUUID)
    #expect(anchor.value == reMinted.clock.installationUUID)
    #expect(reMinted.clock.physicalMilliseconds == 5_000)
    #expect(reMinted.clock.logicalCounter == 7)
    #expect(reMinted.clock.anchorServerMilliseconds == 4_000)
    #expect(reMinted.clock.lastAdmittedPhysicalMilliseconds == 3_000)
    #expect(reMinted.clock.lastAdmittedLogicalCounter == 2)
    #expect(reMinted.clock.repairRequired)
  }

  @Test("an unreadable anchor refuses, persists nothing, and resolves on the next launch")
  func unreadableAnchorRefuses() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor(readsFail: true)

    let refused = try await PodcastCloudInstallationResolver.resolve(database: database, anchor: anchor)
    #expect(refused == .refused)
    #expect(anchor.value == nil)

    // The exit path from a transient Keychain outage: nothing was written, so the next launch is
    // still a first run and mints normally. No repair control is needed.
    anchor.setReadsFail(false)
    let resolved = try await resolution(database: database, anchor: anchor)
    #expect(anchor.value == resolved.clock.installationUUID)
  }

  @Test("a failed anchor write is rethrown rather than absorbed as a refusal")
  func writeFailureIsNotARefusal() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor(writesFail: true)

    // Only `anchorUnreadable` becomes `.refused`. Reporting a write fault as a refusal would make
    // a durable failure look like a transient outage and retry it on every launch forever.
    await #expect(throws: FakePodcastCloudInstallationAnchor.Failure.unwritable) {
      try await PodcastCloudInstallationResolver.resolve(database: database, anchor: anchor)
    }
    #expect(anchor.value == nil)
  }

  // MARK: - The fake's own contract

  @Test("a command before start is refused, because a torn-down engine has none to serve")
  func commandsRequireStart() async throws {
    let handler = FakePodcastCloudSyncHandling()
    let cloud = FakePodcastCloudSyncing(handler: handler)

    await #expect(throws: FakePodcastCloudSyncing.Misuse.notStarted) { try await cloud.fetchChanges() }
    await #expect(throws: FakePodcastCloudSyncing.Misuse.notStarted) { try await cloud.sendChanges() }
    #expect(cloud.calls.isEmpty)
  }

  @Test("starting twice is refused, because configuration is a construction-time value")
  func startingTwiceIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()
    let resolution = try await resolution(database: database, anchor: anchor)
    let cloud = FakePodcastCloudSyncing(handler: FakePodcastCloudSyncHandling())

    let bootstrap = PodcastCloudActivation(
      resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: false)
    try await cloud.start(bootstrap)
    await #expect(throws: FakePodcastCloudSyncing.Misuse.alreadyStarted) {
      try await cloud.start(bootstrap)
    }

    // Retire-and-replace: the barrier engine is stopped, then its single replacement starts
    // with `automaticallySync` true and the validated state. Two engines, never a mutated one.
    await cloud.stop()
    let converging = PodcastCloudActivation(
      resolution: resolution, fence: fence(), stateSerialization: Data("blob".utf8),
      automaticallySync: true)
    try await cloud.start(converging)

    // The refused second start is not recorded: it never became a call the boundary served.
    #expect(cloud.activations.map(\.automaticallySync) == [false, true])
    #expect(cloud.calls == [.start(bootstrap), .stop, .start(converging)])
  }

  @Test("events and batches travel back through the handler")
  func handlerReceivesEventsAndSuppliesBatches() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()
    let resolution = try await resolution(database: database, anchor: anchor)
    let handler = FakePodcastCloudSyncHandling()
    let cloud = FakePodcastCloudSyncing(handler: handler)
    try await cloud.start(
      PodcastCloudActivation(
        resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: false))

    let fields = try PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: "v1.globals"
    ).build()
    handler.stubBatches([PodcastCloudRecordBatch(saves: [fields])])

    try await cloud.deliver(.zoneSave(succeeded: true))
    try await cloud.deliver(.fetchCompleted(succeeded: false))
    let first = try await cloud.requestBatch()
    let second = try await cloud.requestBatch()

    #expect(handler.events == [.zoneSave(succeeded: true), .fetchCompleted(succeeded: false)])
    #expect(first?.saves.map(\.recordName) == ["v1.globals"])
    // An exhausted queue answers nil, the same answer a closed bootstrap barrier gives.
    #expect(second == nil)
    #expect(handler.requestedLimits == [.standard, .standard])
  }

  @Test("delivering an event to a stopped fake is refused")
  func deliveryRequiresAStartedEngine() async throws {
    let cloud = FakePodcastCloudSyncing(handler: FakePodcastCloudSyncHandling())
    await #expect(throws: FakePodcastCloudSyncing.Misuse.notStarted) {
      try await cloud.deliver(.fetchCompleted(succeeded: true))
    }
  }

  // MARK: - Batch ceilings

  @Test("no ceiling may exceed CloudKit's per-request cap")
  func noCeilingExceedsTheRequestCap() {
    #expect(PodcastCloudBatchLimits.requestRecordCap == 250)

    // An application ceiling may be lower than CloudKit's documented per-request cap, never
    // higher: a batch above it is rejected by the service, not split by it.
    let overreaching = PodcastCloudBatchLimits(
      maximumRecords: 1_000, maximumBytes: -1, maximumRecordBytes: -1)
    #expect(overreaching.maximumRecords == 250)
    #expect(overreaching.maximumBytes == 0)
    #expect(overreaching.maximumRecordBytes == 0)
  }

  @Test("a batch is measured against records, per-record bytes, and total bytes")
  func batchFitsRespectsEveryCeiling() throws {
    let fields = try PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: "v1.globals"
    ).build()
    let limits = PodcastCloudBatchLimits(maximumRecords: 2, maximumBytes: 100, maximumRecordBytes: 60)

    #expect(PodcastCloudRecordBatch(saves: [fields]).fits(limits) { _ in 50 })
    // Deletions count toward the record ceiling: CloudKit's cap is saves plus deletes.
    #expect(PodcastCloudRecordBatch(saves: [fields], deletions: ["a", "b"]).fits(limits) { _ in 1 } == false)
    #expect(PodcastCloudRecordBatch(saves: [fields]).fits(limits) { _ in 61 } == false)
    #expect(PodcastCloudRecordBatch(saves: [fields, fields]).fits(limits) { _ in 55 } == false)
    #expect(PodcastCloudRecordBatch(saves: []).isEmpty)
  }

  // MARK: - Outbox rehydration

  @Test func pendingWorkCarriesTheStoredShapeAcross() {
    let work = PodcastCloudPendingWork(
      PodcastCloudOutstandingWork(saves: ["v1.globals"], deletions: ["v1.sub.a"]))

    #expect(work.saves == ["v1.globals"])
    #expect(work.deletions == ["v1.sub.a"])
    #expect(work.isEmpty == false)
  }

  @Test func emptyOutstandingWorkIsTheSameAsNone() {
    #expect(
      PodcastCloudPendingWork(PodcastCloudOutstandingWork(saves: [], deletions: []))
        == PodcastCloudPendingWork.none)
    #expect(PodcastCloudPendingWork.none.isEmpty)
  }

  /// The handler answers `.none` by default, so a test that wants seeding has to say so, as
  /// `stubBatches` requires.
  @Test func theHandlerReportsNothingOutstandingUntilItIsToldOtherwise() async {
    let handler = FakePodcastCloudSyncHandling()

    #expect(await handler.outstandingWork().isEmpty)

    handler.stubPendingWork(PodcastCloudPendingWork(saves: ["v1.globals"], deletions: []))
    #expect(await handler.outstandingWork().saves == ["v1.globals"])
    #expect(handler.outstandingWorkRequests == 2)
  }

  // MARK: - Further boundary cases

  @Test func anActivationNeverCreatesTheZoneUnlessAskedTo() async throws {
    let database = try AppDatabase.inMemory()
    let resolution = try await resolution(
      database: database, anchor: FakePodcastCloudInstallationAnchor())

    let implicit = PodcastCloudActivation(
      resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: false)
    let creating = PodcastCloudActivation(
      resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: false,
      zone: .create)

    #expect(implicit.zone == .expectExisting)
    #expect(creating.zone == .create)
    #expect(implicit != creating)
  }

  @Test func scriptedEventsArriveWhileTheFetchIsStillAwaited() async throws {
    let database = try AppDatabase.inMemory()
    let resolution = try await resolution(
      database: database, anchor: FakePodcastCloudInstallationAnchor())
    let handler = FakePodcastCloudSyncHandling()
    let cloud = FakePodcastCloudSyncing(handler: handler)
    try await cloud.start(
      PodcastCloudActivation(
        resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: false))

    cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    cloud.scriptSend([.zoneSave(succeeded: true)])
    try await cloud.sendChanges()
    try await cloud.fetchChanges()
    // The script is consumed: a second fetch delivers nothing.
    try await cloud.fetchChanges()

    #expect(handler.events == [.zoneSave(succeeded: true), .fetchCompleted(succeeded: true)])
  }

  @Test func schedulingIsRecordedOnlyWhileStarted() async throws {
    let database = try AppDatabase.inMemory()
    let resolution = try await resolution(
      database: database, anchor: FakePodcastCloudInstallationAnchor())
    let cloud = FakePodcastCloudSyncing(handler: FakePodcastCloudSyncHandling())
    let work = PodcastCloudPendingWork(saves: ["v1.globals"], deletions: [])

    await cloud.schedule(work)
    #expect(cloud.calls.isEmpty)

    try await cloud.start(
      PodcastCloudActivation(
        resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: true))
    await cloud.schedule(work)
    try await cloud.deleteZone()

    #expect(cloud.scheduledWork == [work])
    #expect(cloud.calls.last == .deleteZone)
  }

  @Test func sentRecordsCountEveryRecordTheBatchCarried() {
    let sent = PodcastCloudSentRecords(
      saved: [PodcastCloudAcknowledgedRecord(recordName: "a", systemFields: Data())],
      failed: [PodcastCloudFailedRecord(recordName: "b", failure: .batchRequestFailed)],
      deleted: ["c"],
      failedDeletions: [PodcastCloudFailedRecord(recordName: "d", failure: .other)])

    #expect(sent.recordCount == 4)
  }

  @Test func aFetchedRecordDefaultsItsPlaintextAuditToItsOwnClearCompartment() throws {
    let fields = try PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: "v1.globals"
    ).build()

    let record = PodcastCloudFetchedRecord(fields: fields, systemFields: Data())

    #expect(record.plaintextFieldNames == [PodcastCloudRecordLayout.schemaFieldName])
    #expect(record.serverModificationDate == nil)
  }

  // MARK: - Ownership (ADR 0018)

  /// The session owns the coordinator and the coordinator owns its engine. The engine's reference
  /// back is weak, so dropping the coordinator frees the engine and the database with it.
  @Test func aDisabledCoordinatorIsFreedWithItsEngineAndDatabase() async throws {
    weak var freedDatabase: AppDatabase?
    weak var freedCoordinator: PodcastCloudSyncCoordinator?
    weak var freedEngine: FakePodcastCloudEngine?
    do {
      let database = try AppDatabase.inMemory()
      let resolution = try await resolution(
        database: database, anchor: FakePodcastCloudInstallationAnchor())
      let coordinator = PodcastCloudSyncCoordinator(database: database)
      let engine = FakePodcastCloudEngine(server: FakePodcastCloudServer(), handler: coordinator)
      await coordinator.attach(engine)
      try await coordinator.enable(resolution: resolution, fence: fence())
      await coordinator.disable()
      freedDatabase = database
      freedCoordinator = coordinator
      freedEngine = engine
    }
    #expect(freedCoordinator == nil)
    #expect(freedEngine == nil)
    #expect(freedDatabase == nil)
  }

  @Test func theBoundaryFakeDoesNotKeepItsCoordinatorAlive() async throws {
    weak var freedCoordinator: PodcastCloudSyncCoordinator?
    do {
      let coordinator = PodcastCloudSyncCoordinator(database: try AppDatabase.inMemory())
      await coordinator.attach(FakePodcastCloudSyncing(handler: coordinator))
      freedCoordinator = coordinator
    }
    #expect(freedCoordinator == nil)
  }

  /// A handler outlived by its engine is a session that has ended, which the App adapter answers
  /// by serving nothing. The fake must not be more lenient than that.
  @Test func aFakeWhoseHandlerIsGoneServesNothing() async throws {
    let database = try AppDatabase.inMemory()
    let resolution = try await resolution(
      database: database, anchor: FakePodcastCloudInstallationAnchor())
    var handler: FakePodcastCloudSyncHandling? = FakePodcastCloudSyncHandling()
    let fields = try PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: "v1.globals"
    ).build()
    handler?.stubBatches([PodcastCloudRecordBatch(saves: [fields])])
    handler?.stubPendingWork(PodcastCloudPendingWork(saves: ["v1.globals"], deletions: []))
    let cloud = FakePodcastCloudSyncing(handler: try #require(handler))
    try await cloud.start(
      PodcastCloudActivation(
        resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: true))

    weak let released = handler
    handler = nil
    #expect(released == nil)
    try await cloud.deliver(.fetchCompleted(succeeded: true))
    #expect(try await cloud.requestBatch() == nil)
    #expect(try await cloud.requestOutstandingWork().isEmpty)
  }

  @Test func anEngineWhoseHandlerIsGoneSendsNothing() async throws {
    let database = try AppDatabase.inMemory()
    let resolution = try await resolution(
      database: database, anchor: FakePodcastCloudInstallationAnchor())
    let server = FakePodcastCloudServer()
    var coordinator: PodcastCloudSyncCoordinator? = PodcastCloudSyncCoordinator(database: database)
    let engine = FakePodcastCloudEngine(server: server, handler: try #require(coordinator))

    weak let released = coordinator
    coordinator = nil
    #expect(released == nil)
    try await engine.start(
      PodcastCloudActivation(
        resolution: resolution, fence: fence(), stateSerialization: nil, automaticallySync: true))
    await engine.schedule(PodcastCloudPendingWork(saves: ["v1.globals"], deletions: []))
    try await engine.sendChanges()
    #expect(server.saveCount == 0, "no handler, so no batch")
    #expect(engine.pendingSaves == ["v1.globals"], "the change stays pending, as CKSyncEngine keeps it")
  }
}
