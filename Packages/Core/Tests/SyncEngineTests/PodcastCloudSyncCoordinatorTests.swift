import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// Deterministic fake-cloud matrix: the coordinator driven through `FakePodcastCloudSyncing`,
/// with a real in-memory database behind it. No iCloud account, no simulator sign-in, no CloudKit.
@Suite struct PodcastCloudSyncCoordinatorTests {
  private static let installation = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Harness {
    let database: AppDatabase
    let anchor: FakePodcastCloudInstallationAnchor
    let coordinator: PodcastCloudSyncCoordinator
    let cloud: FakePodcastCloudSyncing
    let resolution: PodcastCloudInstallationResolution
    let transport: PodcastCloudTransportStore
    let fence: PodcastCloudAccountFence
    let namespace: Data
  }

  private enum HarnessFailure: Error { case unresolved }

  private static func fence(user: String? = "_user", epoch: Int64 = 1) -> PodcastCloudAccountFence {
    PodcastCloudAccountFence(
      container: "iCloud.com.remoteconcern.whirr", environment: "development", zone: "PodcastState",
      iCloudUserRecordID: user, accountEpoch: epoch)
  }

  private func harness(
    database existing: AppDatabase? = nil,
    anchor existingAnchor: FakePodcastCloudInstallationAnchor? = nil,
    applier: any PodcastCloudRemoteApplying = PodcastCloudHoldingApplier(),
    fence: PodcastCloudAccountFence = PodcastCloudSyncCoordinatorTests.fence(),
    now: @escaping @Sendable () -> Date = { PodcastCloudSyncCoordinatorTests.fixedNow }
  ) async throws -> Harness {
    let database = try existing ?? AppDatabase.inMemory()
    let anchor = existingAnchor ?? FakePodcastCloudInstallationAnchor()
    guard
      case .resolved(let resolution) = try await PodcastCloudInstallationResolver.resolve(
        database: database, anchor: anchor)
    else { throw HarnessFailure.unresolved }
    let coordinator = PodcastCloudSyncCoordinator(
      database: database, applier: applier, now: now)
    let cloud = FakePodcastCloudSyncing(handler: coordinator)
    await coordinator.attach(cloud)
    return Harness(
      database: database, anchor: anchor, coordinator: coordinator, cloud: cloud,
      resolution: resolution, transport: PodcastCloudTransportStore(database: database),
      fence: fence, namespace: try PodcastCloudSyncCoordinator.namespace(for: fence))
  }

  /// A harness that has passed the barrier: zone created, bootstrap fetch succeeded, converging
  /// engine started.
  private func running(
    applier: any PodcastCloudRemoteApplying = PodcastCloudHoldingApplier(),
    now: @escaping @Sendable () -> Date = { PodcastCloudSyncCoordinatorTests.fixedNow }
  ) async throws -> Harness {
    let h = try await harness(applier: applier, now: now)
    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)
    return h
  }

  private func stamp(_ milliseconds: Int64, mutation: Int = 1) throws -> PodcastCloudMutationStamp {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: milliseconds, logicalCounter: 0, installationUUID: Self.installation,
      mutationUUID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", mutation))!)
  }

  private func globals(at milliseconds: Int64, keepLatest: Int = 3) throws -> PodcastCloudRecordFields {
    try PodcastCloudRecordCodec.encode(
      globalSettings: StampedGlobalSettings(
        autoDownloadEnabled: true, keepLatestCount: keepLatest, deleteAfterPlayed: false,
        allowCellularAutoDownload: false, showOrderMode: "custom",
        writeStamp: try stamp(milliseconds, mutation: keepLatest)),
      recordName: "v1.globals")
  }

  private func subscription(_ recordName: String, at milliseconds: Int64) throws
    -> PodcastCloudRecordFields
  {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.subscription, recordName: recordName)
    try builder.set(stamp: try stamp(milliseconds), prefix: "follow")
    return try builder.build()
  }

  private func fetched(
    _ fields: PodcastCloudRecordFields, modifiedAt milliseconds: Int64,
    plaintext: Set<String>? = nil
  ) -> PodcastCloudFetchedRecord {
    PodcastCloudFetchedRecord(
      fields: fields, systemFields: Data("server:\(fields.recordName):\(milliseconds)".utf8),
      serverModificationDate: Date(timeIntervalSince1970: Double(milliseconds) / 1000),
      plaintextFieldNames: plaintext)
  }

  @discardableResult
  private func enqueue(_ fields: PodcastCloudRecordFields, in h: Harness) async throws -> Int64 {
    try await h.transport.enqueue(
      recordName: fields.recordName, payload: try PodcastCloudRecordPayload.encode(fields))
  }

  private func acceptedStamp(_ recordName: String, in h: Harness) async throws
    -> PodcastCloudMutationStamp?
  {
    try await PodcastCloudRegistryStore(database: h.database).acceptedStamp(recordName: recordName)
      .flatMap { PodcastCloudMutationStamp($0) }
  }

  private func archive(_ recordName: String, in h: Harness) async throws -> Data? {
    let namespace = h.namespace
    return try await h.database.readAsync { db in
      try PodcastCloudTransportStore.systemFields(in: db, namespace: namespace, recordName: recordName)
    }
  }

  // MARK: - Bootstrap barrier

  @Test func firstEnableCreatesTheZoneFetchesThenReplacesTheEngine() async throws {
    let h = try await harness()
    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.scriptFetch([.stateSerialization(Data([7])), .fetchCompleted(succeeded: true)])

    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)

    let activations = h.cloud.activations
    #expect(activations.map(\.automaticallySync) == [false, true])
    #expect(activations.map(\.zone) == [.create, .expectExisting])
    #expect(activations.last?.stateSerialization == Data([7]))
    #expect(
      h.cloud.calls == [
        .start(activations[0]), .sendChanges, .fetchChanges, .stop, .start(activations[1]),
      ])
    let state = try await h.transport.state()
    #expect(state.bootstrapComplete)
    #expect(state.zoneEstablished)
    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  @Test func aFailedFetchKeepsTheBarrierClosedUntilARetrySucceeds() async throws {
    let h = try await harness()
    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.scriptFetch([.fetchCompleted(succeeded: false)])
    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)
    try await enqueue(try globals(at: 1_000), in: h)

    #expect(h.cloud.activations.count == 1)
    #expect(try await h.cloud.requestBatch() == nil)
    #expect(try await h.cloud.requestOutstandingWork().isEmpty)
    #expect(try await h.transport.state().bootstrapComplete == false)

    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await h.coordinator.syncNow()

    #expect(h.cloud.activations.map(\.automaticallySync) == [false, true])
    #expect(try await h.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.globals"])
  }

  @Test func aThrownFetchKeepsTheBarrierClosedAndReportsWaiting() async throws {
    let h = try await harness()
    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.stubFetchChanges(throwing: CancellationError())

    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)

    #expect(h.cloud.activations.count == 1)
    #expect(await h.coordinator.currentStatus == .waiting(until: nil))
    #expect(try await h.transport.state().bootstrapComplete == false)
  }

  @Test func aFailedZoneSaveNeverReachesTheFetch() async throws {
    let h = try await harness()
    h.cloud.scriptSend([.zoneSave(succeeded: false)])

    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)

    #expect(h.cloud.calls.contains(.fetchChanges) == false)
    #expect(try await h.transport.state().zoneEstablished == false)
    #expect(await h.coordinator.currentStatus == .interrupted)
  }

  @Test func aFailedZoneSaveClearsOnceARetryCompletesTheBarrier() async throws {
    let h = try await harness()
    h.cloud.scriptSend([.zoneSave(succeeded: false)])
    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)

    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await h.coordinator.syncNow()

    #expect(try await h.transport.state().bootstrapComplete)
    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  @Test func aRelaunchInTheSameNamespaceResumesWithoutRepeatingTheBarrier() async throws {
    let first = try await harness()
    first.cloud.scriptSend([.zoneSave(succeeded: true)])
    first.cloud.scriptFetch([.stateSerialization(Data([7])), .fetchCompleted(succeeded: true)])
    try await first.coordinator.enable(resolution: first.resolution, fence: first.fence)

    let relaunch = try await harness(database: first.database, anchor: first.anchor)
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)

    #expect(relaunch.cloud.activations.map(\.automaticallySync) == [true])
    #expect(relaunch.cloud.activations.first?.stateSerialization == Data([7]))
    #expect(relaunch.cloud.calls.contains(.fetchChanges) == false)
  }

  @Test func aCrashMidBootstrapRepeatsTheBarrierWithoutRecreatingTheZone() async throws {
    let first = try await harness()
    first.cloud.scriptSend([.zoneSave(succeeded: true)])
    first.cloud.scriptFetch([])  // the process dies before the fetch completes
    try await first.coordinator.enable(resolution: first.resolution, fence: first.fence)

    let relaunch = try await harness(database: first.database, anchor: first.anchor)
    relaunch.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)

    #expect(relaunch.cloud.activations.map(\.zone) == [.expectExisting, .expectExisting])
    #expect(relaunch.cloud.activations.map(\.automaticallySync) == [false, true])
    #expect(relaunch.cloud.calls.contains(.sendChanges) == false)
  }

  @Test func anUnavailableAccountStillConstructsAListenerButFetchesNothing() async throws {
    let h = try await harness(fence: Self.fence(user: nil))

    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)

    #expect(h.cloud.activations.map(\.automaticallySync) == [false])
    #expect(h.cloud.isStarted)
    #expect(h.cloud.calls.contains(.fetchChanges) == false)
    #expect(await h.coordinator.currentStatus == .accountUnavailable)
  }

  @Test func enableWithoutAnEngineIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    guard
      case .resolved(let resolution) = try await PodcastCloudInstallationResolver.resolve(
        database: database, anchor: FakePodcastCloudInstallationAnchor())
    else { throw HarnessFailure.unresolved }
    let coordinator = PodcastCloudSyncCoordinator(database: database)

    await #expect(throws: PodcastCloudSyncCoordinatorError.notAttached) {
      try await coordinator.enable(resolution: resolution, fence: Self.fence())
    }
  }

  // MARK: - Batch supply

  @Test func batchesAreOrderedParentsFirstAndRespectTheRecordCeiling() async throws {
    let h = try await running()
    try await enqueue(try subscription("v1.state.z", at: 1_000), in: h)
    try await enqueue(try subscription("v1.sub.a", at: 1_000), in: h)
    try await enqueue(try globals(at: 1_000), in: h)
    let limits = PodcastCloudBatchLimits(
      maximumRecords: 2, maximumBytes: 1_048_576, maximumRecordBytes: 65_536)

    let first = try await h.cloud.requestBatch(within: limits)
    let second = try await h.cloud.requestBatch(within: limits)
    let third = try await h.cloud.requestBatch(within: limits)

    #expect(first?.saves.map(\.recordName) == ["v1.globals", "v1.sub.a"])
    // In flight and not yet reported on: not offered twice.
    #expect(second?.saves.map(\.recordName) == ["v1.state.z"])
    #expect(third == nil)
  }

  @Test func aBatchStopsAtTheByteCeiling() async throws {
    let h = try await running()
    try await enqueue(try subscription("v1.sub.a", at: 1_000), in: h)
    try await enqueue(try subscription("v1.sub.b", at: 1_000), in: h)
    let one = PodcastCloudRecordMerge.estimatedBytes(of: try subscription("v1.sub.a", at: 1_000))
    let limits = PodcastCloudBatchLimits(
      maximumRecords: 200, maximumBytes: one + one / 2, maximumRecordBytes: 65_536)

    let batch = try await h.cloud.requestBatch(within: limits)

    #expect(batch?.saves.map(\.recordName) == ["v1.sub.a"])
  }

  @Test func anOversizeRecordIsHeldWithoutBlockingTheRest() async throws {
    let h = try await running()
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.subscription, recordName: "v1.sub.big")
    try builder.set("title", .string(String(repeating: "x", count: 4_000)))
    try builder.set(stamp: try stamp(1_000), prefix: "follow")
    try await enqueue(try builder.build(), in: h)
    try await enqueue(try subscription("v1.sub.small", at: 1_000), in: h)
    let limits = PodcastCloudBatchLimits(
      maximumRecords: 200, maximumBytes: 1_048_576, maximumRecordBytes: 2_000)

    let batch = try await h.cloud.requestBatch(within: limits)

    #expect(batch?.saves.map(\.recordName) == ["v1.sub.small"])
    let held = try await h.transport.heldRecords(namespace: h.namespace)
    #expect(held.map(\.recordName) == ["v1.sub.big"])
    #expect(held.map(\.category) == [PodcastCloudHoldCategory.recordTooLarge.rawValue])
    #expect(await h.coordinator.currentStatus == .needsAttention)
  }

  @Test func aBatchCarriesEachRecordsArchiveSoTheSaveIsConditional() async throws {
    let h = try await running()
    let fields = try globals(at: 1_000)
    await h.coordinator.handle(
      .fetchedChanges(
        PodcastCloudFetchedChanges(modifications: [fetched(fields, modifiedAt: 1_000)], deletions: [])))
    try await enqueue(try globals(at: 2_000, keepLatest: 5), in: h)

    let batch = try await h.cloud.requestBatch()

    #expect(batch?.systemFields["v1.globals"] == Data("server:v1.globals:1000".utf8))
  }

  // MARK: - Sent records

  @Test func anAcknowledgementRemovesOnlyTheGenerationThatWasSent() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()
    try await enqueue(try globals(at: 2_000, keepLatest: 5), in: h)

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [PodcastCloudAcknowledgedRecord(recordName: "v1.globals", systemFields: Data([1]))],
          failed: [])))

    let next = try await h.cloud.requestBatch()
    #expect(next?.saves.first == (try globals(at: 2_000, keepLatest: 5)))
    #expect(next?.systemFields["v1.globals"] == Data([1]))
  }

  @Test func anAtomicBatchFailureAcknowledgesNothingAndHoldsOnlyTheCulprit() async throws {
    let h = try await running()
    try await enqueue(try subscription("v1.sub.a", at: 1_000), in: h)
    try await enqueue(try subscription("v1.sub.b", at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [],
          failed: [
            PodcastCloudFailedRecord(recordName: "v1.sub.a", failure: .batchRequestFailed),
            PodcastCloudFailedRecord(recordName: "v1.sub.b", failure: .malformedRecord),
          ])))

    // The sibling goes again; the culprit stays in the outbox, held at its generation.
    #expect(try await h.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.sub.a"])
    #expect(try await h.transport.outstandingWork(namespace: h.namespace).saves == ["v1.sub.a"])
    #expect(try await h.transport.heldRecords(namespace: h.namespace).map(\.recordName) == ["v1.sub.b"])
    // The engine retries `batchRequestFailed` itself; nothing is handed back for it.
    #expect(h.cloud.scheduledWork.isEmpty)
  }

  @Test func limitExceededHalvesTheCeilingAndHandsTheRecordsBack() async throws {
    let h = try await running()
    for name in ["v1.sub.a", "v1.sub.b", "v1.sub.c", "v1.sub.d"] {
      try await enqueue(try subscription(name, at: 1_000), in: h)
    }
    let batch = try #require(try await h.cloud.requestBatch())
    #expect(batch.saves.count == 4)

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [],
          failed: batch.saves.map {
            PodcastCloudFailedRecord(recordName: $0.recordName, failure: .limitExceeded)
          })))

    #expect(h.cloud.scheduledWork.last?.saves.sorted() == ["v1.sub.a", "v1.sub.b", "v1.sub.c", "v1.sub.d"])
    #expect(try await h.cloud.requestBatch()?.saves.count == 2)
    #expect(try await h.transport.heldRecords(namespace: h.namespace).isEmpty)
  }

  @Test func limitExceededOnABatchOfOneProvesTheRecordTooLarge() async throws {
    let h = try await running()
    try await enqueue(try subscription("v1.sub.a", at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [], failed: [PodcastCloudFailedRecord(recordName: "v1.sub.a", failure: .limitExceeded)])))

    #expect(try await h.cloud.requestBatch() == nil)
    #expect(
      try await h.transport.heldRecords(namespace: h.namespace).map(\.category)
        == [PodcastCloudHoldCategory.recordTooLarge.rawValue])
  }

  @Test func aConflictTheLocalValueWinsIsRebasedOnTheServerRecordAndSentAgain() async throws {
    let h = try await running()
    let local = try globals(at: 2_000, keepLatest: 5)
    try await enqueue(local, in: h)
    _ = try await h.cloud.requestBatch()
    let server = fetched(try globals(at: 1_000), modifiedAt: 1_000)

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [],
          failed: [
            PodcastCloudFailedRecord(
              recordName: "v1.globals", failure: .serverRecordChanged, serverRecord: server)
          ])))

    #expect(h.cloud.scheduledWork.last?.saves == ["v1.globals"])
    let retry = try await h.cloud.requestBatch()
    #expect(retry?.saves == [local])
    #expect(retry?.systemFields["v1.globals"] == server.systemFields)
  }

  @Test func aConflictTheServerWinsDropsTheLocalSendAndAcceptsTheServerValue() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()
    let serverFields = try globals(at: 2_000, keepLatest: 5)

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [],
          failed: [
            PodcastCloudFailedRecord(
              recordName: "v1.globals", failure: .serverRecordChanged,
              serverRecord: fetched(serverFields, modifiedAt: 2_000))
          ])))

    #expect(try await h.cloud.requestBatch() == nil)
    #expect(try await acceptedStamp("v1.globals", in: h) == (try stamp(2_000, mutation: 5)))
    #expect(h.cloud.scheduledWork.isEmpty)
  }

  @Test func aConflictWithoutAServerRecordIsHeldRatherThanGuessed() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [],
          failed: [PodcastCloudFailedRecord(recordName: "v1.globals", failure: .serverRecordChanged)])))

    #expect(
      try await h.transport.heldRecords(namespace: h.namespace).map(\.category)
        == [PodcastCloudHoldCategory.unmergeable.rawValue])
  }

  @Test func aSendPassThatReportedNothingReleasesItsRecords() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()
    #expect(try await h.cloud.requestBatch() == nil)

    try await h.cloud.deliver(.sendPassEnded)

    #expect(try await h.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.globals"])
  }

  @Test func aDeletionThatLostARaceIsSentAgainRatherThanDropped() async throws {
    let h = try await running()
    _ = try await h.transport.enqueue(
      recordName: "v1.sub.old", payload: Data([1]), isPhysicalDeletion: true)
    _ = try await h.cloud.requestBatch()

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [], failed: [],
          failedDeletions: [
            PodcastCloudFailedRecord(recordName: "v1.sub.old", failure: .serverRecordChanged)
          ])))

    #expect(h.cloud.scheduledWork.last == PodcastCloudPendingWork(saves: [], deletions: ["v1.sub.old"]))
    #expect(try await h.transport.heldRecords(namespace: h.namespace).isEmpty)
  }

  @Test func aConfirmedDeletionIsAcknowledged() async throws {
    let h = try await running()
    _ = try await h.transport.enqueue(
      recordName: "v1.sub.old", payload: Data([1]), isPhysicalDeletion: true)
    let batch = try await h.cloud.requestBatch()
    #expect(batch?.deletions == ["v1.sub.old"])

    try await h.cloud.deliver(
      .sentRecords(PodcastCloudSentRecords(saved: [], failed: [], deleted: ["v1.sub.old"])))

    #expect(try await h.transport.outstandingWork(namespace: h.namespace).isEmpty)
  }

  @Test func retryAfterIsShownAndSchedulesNothing() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()

    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [],
          failed: [PodcastCloudFailedRecord(recordName: "v1.globals", failure: .other, retryAfter: 60)])))

    #expect(await h.coordinator.currentStatus == .waiting(until: Self.fixedNow.addingTimeInterval(60)))
    #expect(h.cloud.scheduledWork.isEmpty)
    let persisted = try await h.transport.state()
    #expect(PodcastCloudSyncStatus(persisted) == .waiting(until: Self.fixedNow.addingTimeInterval(60)))
  }

  // MARK: - Fetched records

  @Test func aNewerFetchedRecordIsAcceptedAndAnOlderOrEchoedOneChangesNothing() async throws {
    let h = try await running()
    let newer = try globals(at: 5_000, keepLatest: 5)

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(modifications: [fetched(newer, modifiedAt: 5_000)], deletions: [])))
    #expect(try await acceptedStamp("v1.globals", in: h) == (try stamp(5_000, mutation: 5)))

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [
            fetched(try globals(at: 4_000), modifiedAt: 5_500), fetched(newer, modifiedAt: 5_000),
          ], deletions: [])))

    #expect(try await acceptedStamp("v1.globals", in: h) == (try stamp(5_000, mutation: 5)))
    #expect(try await h.transport.outstandingWork(namespace: h.namespace).isEmpty)
  }

  @Test func aFetchedRecordAdvancesTheLocalClock() async throws {
    let h = try await running()

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 9_000), modifiedAt: 9_000)], deletions: [])))

    let clock = try await PodcastCloudInstallationStore(database: h.database, anchor: h.anchor)
      .clock(mint: false)
    #expect(clock?.physicalMilliseconds == 9_000)
    #expect(clock?.anchorServerMilliseconds == 9_000)
  }

  @Test func aFetchedRecordMeetingANewerPendingSendKeepsTheLocalValue() async throws {
    let h = try await running()
    let local = try globals(at: 6_000, keepLatest: 5)
    try await enqueue(local, in: h)

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 5_000), modifiedAt: 5_000)], deletions: [])))

    let batch = try await h.cloud.requestBatch()
    #expect(batch?.saves == [local])
    #expect(batch?.systemFields["v1.globals"] == Data("server:v1.globals:5000".utf8))
  }

  @Test func aFetchedRecordNewerThanAPendingSendSupersedesIt() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 4_000), in: h)

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 5_000, keepLatest: 5), modifiedAt: 5_000)],
          deletions: [])))

    #expect(try await h.cloud.requestBatch() == nil)
    #expect(try await acceptedStamp("v1.globals", in: h) == (try stamp(5_000, mutation: 5)))
  }

  @Test func aFieldInTheClearIsHeldAndNotApplied() async throws {
    let h = try await running()

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [
            fetched(
              try globals(at: 5_000), modifiedAt: 5_000,
              plaintext: [PodcastCloudRecordLayout.schemaFieldName, "keepLatestCount"])
          ], deletions: [])))

    #expect(try await acceptedStamp("v1.globals", in: h) == nil)
    #expect(
      try await h.transport.heldRecords(namespace: h.namespace).map(\.category)
        == [PodcastCloudHoldCategory.plaintextViolation.rawValue])
    #expect(await h.coordinator.currentStatus == .needsAttention)

    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await h.coordinator.syncNow()
    #expect(await h.coordinator.currentStatus == .needsAttention, "a held record is not a hiccup")
  }

  @Test func aRecordWithoutAServerDateCannotBeAdmitted() async throws {
    let h = try await running()
    let record = PodcastCloudFetchedRecord(fields: try globals(at: 5_000), systemFields: Data())

    try await h.cloud.deliver(
      .fetchedChanges(PodcastCloudFetchedChanges(modifications: [record], deletions: [])))

    #expect(try await acceptedStamp("v1.globals", in: h) == nil)
    #expect(
      try await h.transport.heldRecords(namespace: h.namespace).map(\.category)
        == [PodcastCloudHoldCategory.missingServerDate.rawValue])
  }

  @Test func aStampFarAheadOfItsServerDateIsQuarantinedWithoutMovingTheClock() async throws {
    let h = try await running()
    let dayAndMore: Int64 = 25 * 60 * 60 * 1000

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 1_000 + dayAndMore), modifiedAt: 1_000)],
          deletions: [])))

    #expect(try await acceptedStamp("v1.globals", in: h) == nil)
    let clock = try await PodcastCloudInstallationStore(database: h.database, anchor: h.anchor)
      .clock(mint: false)
    #expect(clock?.physicalMilliseconds == 0)
    #expect(clock?.repairRequired == false)
    #expect(await h.coordinator.currentStatus == .needsAttention)
  }

  @Test func aLocalClockFarAheadOfTheServerRequiresRepair() async throws {
    let h = try await running()
    try await h.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudInstallation SET physicalMilliseconds = 900000000000 WHERE id = 1")
    }

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 1_000), modifiedAt: 1_000)], deletions: [])))

    let clock = try await PodcastCloudInstallationStore(database: h.database, anchor: h.anchor)
      .clock(mint: false)
    #expect(clock?.repairRequired == true)
    #expect(await h.coordinator.currentStatus == .clockRepairRequired)
  }

  private static let recordNameKey = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 7, count: 32))
  private static let fixedNowMilliseconds = Int64(fixedNow.timeIntervalSince1970 * 1000)

  /// A local clock far ahead of the first server date it meets: the admission quarantines it.
  private func quarantineClock(_ h: Harness) async throws {
    try await h.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudInstallation SET physicalMilliseconds = 900000000000 WHERE id = 1")
    }
    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 1_000), modifiedAt: 1_000)], deletions: [])))
  }

  private func clockRequiresRepair(_ h: Harness) async throws -> Bool? {
    try await PodcastCloudInstallationStore(database: h.database, anchor: h.anchor)
      .clock(mint: false)?.repairRequired
  }

  @Test func theExplicitClockRepairLeavesTheRepairStateAndAdmitsWhatArrivesNext() async throws {
    let h = try await running()
    h.coordinator.recordNameKeys.set(Self.recordNameKey)
    try await quarantineClock(h)
    #expect(await h.coordinator.currentStatus == .clockRepairRequired)

    try await h.coordinator.repairClock()

    #expect(try await clockRequiresRepair(h) == false)
    #expect(await h.coordinator.currentStatus == .upToDate)

    let current = Self.fixedNowMilliseconds
    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: current, keepLatest: 5), modifiedAt: current)],
          deletions: [])))
    #expect(try await acceptedStamp("v1.globals", in: h) == (try stamp(current, mutation: 5)))
    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  /// The quarantine is durable, so the status that offers its repair has to be too: a relaunch
  /// that read as up to date would leave a clock nothing can stamp with and no way to repair it.
  @Test func aQuarantinedClockStillRequiresRepairAfterARelaunchAndCanBeRepairedThere() async throws {
    let h = try await running()
    try await quarantineClock(h)

    let relaunch = try await harness(database: h.database, anchor: h.anchor)
    relaunch.coordinator.recordNameKeys.set(Self.recordNameKey)
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)
    #expect(await relaunch.coordinator.currentStatus == .clockRepairRequired)

    try await relaunch.coordinator.repairClock()
    #expect(try await clockRequiresRepair(relaunch) == false)
    #expect(await relaunch.coordinator.currentStatus == .upToDate)
  }

  @Test func aClockQuarantinedByTheBootstrapFetchRequiresRepairOnceThroughTheBarrier() async throws {
    let h = try await harness()
    _ = try await PodcastCloudInstallationStore(database: h.database, anchor: h.anchor).clock()
    try await h.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastCloudInstallation SET physicalMilliseconds = 900000000000 WHERE id = 1")
    }
    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.scriptFetch([
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 1_000), modifiedAt: 1_000)], deletions: [])),
      .fetchCompleted(succeeded: true),
    ])

    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)

    #expect(try await clockRequiresRepair(h) == true)
    #expect(await h.coordinator.currentStatus == .clockRepairRequired)
  }

  @Test func aClockRepairIsRefusedBeforeSyncIsRunning() async throws {
    let h = try await harness()
    await #expect(throws: PodcastCloudSyncCoordinatorError.notEnabled) {
      try await h.coordinator.repairClock()
    }
  }

  @Test func aFetchedEpisodeStateIsHeldUnderItsKeyedComponents() async throws {
    let h = try await running()
    let subscription = "0a0a0a0a-0a0a-8a0a-8a0a-0a0a0a0a0a0a"
    let generation = "0b0b0b0b-0b0b-8b0b-8b0b-0b0b0b0b0b0b"
    let recordName = "v1.state.\(subscription).\(generation).\(String(repeating: "c", count: 64))"
    let fields = try PodcastCloudRecordCodec.encode(
      episodeState: try PodcastCloudEpisodeState(
        position: 30, isFinished: false, isDismissed: false, writeStamp: try stamp(5_000)),
      identity: PodcastCloudEpisodeIdentityFields(identityKey: "guid:one"), recordName: recordName)

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(modifications: [fetched(fields, modifiedAt: 5_000)], deletions: [])))

    let held = try await PodcastCloudRegistryStore(database: h.database).unresolved(
      subscriptionUUID: subscription, generationUUID: generation)
    #expect(held.map(\.recordName) == [recordName])
    #expect(held.first?.episodeDigest == String(repeating: "c", count: 64))
  }

  @Test func aRemoteDeletionForgetsTheArchiveButNeverTheRegister() async throws {
    let h = try await running()
    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(try globals(at: 5_000), modifiedAt: 5_000)], deletions: [])))
    #expect(try await archive("v1.globals", in: h) != nil)

    try await h.cloud.deliver(
      .fetchedChanges(PodcastCloudFetchedChanges(modifications: [], deletions: ["v1.globals"])))

    #expect(try await archive("v1.globals", in: h) == nil)
    #expect(try await acceptedStamp("v1.globals", in: h) != nil)
  }

  @Test func undeclaredRecordsSurfaceAsNeedingAttention() async throws {
    let h = try await running()

    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [], deletions: [], undeclaredRecordNames: ["v2.future.a", "v2.future.b"])))

    #expect(await h.coordinator.currentStatus == .needsAttention)
    let held = try await h.transport.heldRecords(namespace: h.namespace)
    #expect(Set(held.map(\.recordName)) == ["v2.future.a", "v2.future.b"])
    #expect(Set(held.map(\.category)) == [PodcastCloudHoldCategory.undeclaredType.rawValue])

    // Held by name, so a relaunch still reports them rather than reading as up to date.
    let relaunch = try await harness(database: h.database, anchor: h.anchor)
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)
    #expect(await relaunch.coordinator.currentStatus == .needsAttention)
  }

  // MARK: - Recovering from holds

  private func reject(_ recordName: String, in h: Harness) async throws {
    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [],
          failed: [
            PodcastCloudFailedRecord(recordName: recordName, failure: .malformedRecord, serviceCode: 12)
          ])))
  }

  private func acknowledge(_ recordName: String, in h: Harness) async throws {
    try await h.cloud.deliver(
      .sentRecords(
        PodcastCloudSentRecords(
          saved: [PodcastCloudAcknowledgedRecord(recordName: recordName, systemFields: Data([1]))],
          failed: [])))
  }

  /// A rejection can be the service's doing (a schema not yet deployed), so a held send goes
  /// again once per launch instead of waiting for the listener to edit the record.
  @Test func aRejectedSendIsOfferedAgainAfterARelaunch() async throws {
    let h = try await running()
    try await enqueue(try subscription("v1.sub.a", at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()
    try await reject("v1.sub.a", in: h)
    #expect(await h.coordinator.currentStatus == .needsAttention)
    #expect(try await h.cloud.requestBatch() == nil)

    let relaunch = try await harness(database: h.database, anchor: h.anchor)
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)

    #expect(try await relaunch.transport.heldRecords(namespace: relaunch.namespace).isEmpty)
    #expect(try await relaunch.cloud.requestOutstandingWork().saves == ["v1.sub.a"])
    #expect(await relaunch.coordinator.currentStatus == .upToDate)
    #expect(try await relaunch.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.sub.a"])
  }

  @Test func tryAgainRetriesAHeldSendAndASuccessClearsTheStatus() async throws {
    let h = try await running()
    try await enqueue(try subscription("v1.sub.a", at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()
    try await reject("v1.sub.a", in: h)

    try await h.coordinator.syncNow()

    #expect(h.cloud.scheduledWork.last?.saves == ["v1.sub.a"])
    #expect(try await h.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.sub.a"])
    try await acknowledge("v1.sub.a", in: h)
    #expect(try await h.transport.heldRecords(namespace: h.namespace).isEmpty)
    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  @Test func aRetryThatIsRejectedAgainIsHeldAgain() async throws {
    let h = try await running()
    try await enqueue(try subscription("v1.sub.a", at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()
    try await reject("v1.sub.a", in: h)

    try await h.coordinator.syncNow()
    _ = try await h.cloud.requestBatch()
    try await reject("v1.sub.a", in: h)

    #expect(try await h.transport.heldRecords(namespace: h.namespace).map(\.recordName) == ["v1.sub.a"])
    #expect(await h.coordinator.currentStatus == .needsAttention)
    #expect(try await h.cloud.requestBatch() == nil)
  }

  /// A newer local edit of a held record is offered at its own generation; once the service takes
  /// it, the older hold describes nothing.
  @Test func anAcknowledgedSaveReleasesAnOlderHoldOnTheSameRecord() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    _ = try await h.cloud.requestBatch()
    try await reject("v1.globals", in: h)
    try await enqueue(try globals(at: 2_000, keepLatest: 5), in: h)
    #expect(try await h.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.globals"])

    try await acknowledge("v1.globals", in: h)

    #expect(try await h.transport.heldRecords(namespace: h.namespace).isEmpty)
    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  /// Nothing local can retry a record that arrived broken, so its hold outlasts a relaunch and
  /// goes only when the record arrives again and is admitted.
  @Test func aHeldFetchedRecordSurvivesARelaunchUntilItIsAdmitted() async throws {
    let h = try await running()
    let fields = try globals(at: 1_000)
    try await h.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(
          modifications: [fetched(fields, modifiedAt: 1_000, plaintext: ["schema", "showOrderMode"])],
          deletions: [])))
    #expect(try await h.transport.heldRecords(namespace: h.namespace).count == 1)

    let relaunch = try await harness(database: h.database, anchor: h.anchor)
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)
    #expect(try await relaunch.transport.heldRecords(namespace: relaunch.namespace).count == 1)
    #expect(await relaunch.coordinator.currentStatus == .needsAttention)

    try await relaunch.cloud.deliver(
      .fetchedChanges(
        PodcastCloudFetchedChanges(modifications: [fetched(fields, modifiedAt: 1_000)], deletions: [])))
    #expect(try await relaunch.transport.heldRecords(namespace: relaunch.namespace).isEmpty)
    #expect(await relaunch.coordinator.currentStatus == .upToDate)
  }

  @Test func holdsOfANamespaceThatCanNoLongerSyncArePrunedAtStart() async throws {
    let h = try await running()
    let dead = Data("dead".utf8)
    try await h.transport.hold(
      namespace: dead, recordName: "v1.sub.old", generation: 3,
      category: PodcastCloudHoldCategory.malformed.rawValue, observedAt: Self.fixedNow)

    let relaunch = try await harness(database: h.database, anchor: h.anchor)
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)

    #expect(try await relaunch.transport.heldRecords(namespace: dead).isEmpty)
  }

  /// The log says which kind of record was held, never which record.
  @Test func aHeldRecordIsLoggedByKindNotByName() {
    #expect(PodcastCloudSyncCoordinator.recordKind(of: "v1.settings.0a1b2c3d") == "settings")
    #expect(PodcastCloudSyncCoordinator.recordKind(of: "v1.globals") == "globals")
    #expect(PodcastCloudSyncCoordinator.recordKind(of: "anything else") == "unknown")
  }

  // MARK: - Quota, account and zone

  @Test func quotaPausesSendingUntilSyncNow() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)

    try await h.cloud.deliver(.quotaExceeded)
    #expect(try await h.cloud.requestBatch() == nil)
    #expect(await h.coordinator.currentStatus == .quotaExceeded)

    try await h.coordinator.syncNow()
    #expect(try await h.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.globals"])
  }

  // MARK: - Explicit sends and catch-up

  /// The commands a call issued, without the scheduling a drain may add alongside them.
  private func commands(after count: Int, in h: Harness) -> [FakePodcastCloudSyncing.RecordedCall] {
    h.cloud.calls.dropFirst(count).filter {
      if case .schedule = $0 { return false }
      return true
    }
  }

  @Test func sendingPendingChangesSendsWithoutWaitingForTheEngine() async throws {
    let h = try await running()
    let before = h.cloud.calls.count

    try await h.coordinator.sendPendingChanges()

    #expect(commands(after: before, in: h) == [.sendChanges])
  }

  @Test func catchingUpSendsThenFetchesUnlessAFetchJustCompleted() async throws {
    let h = try await running()
    var before = h.cloud.calls.count
    try await h.coordinator.catchUp(skippingFetchWithin: 30)
    #expect(commands(after: before, in: h) == [.sendChanges], "the barrier fetched a moment ago")

    before = h.cloud.calls.count
    try await h.coordinator.catchUp(skippingFetchWithin: 0)
    #expect(commands(after: before, in: h) == [.sendChanges, .fetchChanges])
  }

  /// CKSyncEngine reports a zone's fetch only when the database fetch found that zone changed, so
  /// a fetch that finds nothing new delivers no zone events. It still proves iCloud was reached.
  @Test func anExplicitFetchThatFindsNothingNewStillCountsAsASuccessfulSync() async throws {
    let clock = FakeSyncClock(now: Self.fixedNow)
    let h = try await running(now: { clock.now() })
    clock.advance(by: 3_600)

    try await h.coordinator.syncNow()
    #expect(await h.coordinator.lastSuccessfulFetch == Self.fixedNow.addingTimeInterval(3_600))

    clock.advance(by: 3_600)
    try await h.coordinator.catchUp(skippingFetchWithin: 0)
    #expect(await h.coordinator.lastSuccessfulFetch == Self.fixedNow.addingTimeInterval(7_200))
  }

  @Test func anExplicitFetchWhoseZoneFetchFailedIsNotCountedAsASuccessfulSync() async throws {
    let clock = FakeSyncClock(now: Self.fixedNow)
    let h = try await running(now: { clock.now() })
    clock.advance(by: 3_600)

    h.cloud.scriptFetch([.fetchCompleted(succeeded: false)])
    try await h.coordinator.syncNow()
    #expect(await h.coordinator.lastSuccessfulFetch == Self.fixedNow)

    h.cloud.stubFetchChanges(throwing: URLError(.notConnectedToInternet))
    await #expect(throws: URLError.self) { try await h.coordinator.syncNow() }
    #expect(await h.coordinator.lastSuccessfulFetch == Self.fixedNow)
  }

  @Test func nothingIsSentWhileStorageIsFull() async throws {
    let h = try await running()
    try await h.cloud.deliver(.quotaExceeded)
    let before = h.cloud.calls.count

    try await h.coordinator.sendPendingChanges()
    try await h.coordinator.catchUp(skippingFetchWithin: 0)

    #expect(commands(after: before, in: h) == [.fetchChanges])
    #expect(await h.coordinator.currentStatus == .quotaExceeded)
  }

  /// Being offline is not a sync fault, so a catch-up that cannot reach iCloud reports the error
  /// to its caller and leaves the status as it was.
  @Test func aCatchUpThatCannotReachICloudLeavesTheStatusAlone() async throws {
    let h = try await running()
    h.cloud.stubFetchChanges(throwing: URLError(.notConnectedToInternet))

    await #expect(throws: URLError.self) { try await h.coordinator.catchUp(skippingFetchWithin: 0) }

    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  @Test func explicitSendsWaitForTheBarrier() async throws {
    let h = try await harness()

    try await h.coordinator.sendPendingChanges()
    try await h.coordinator.catchUp(skippingFetchWithin: 0)

    #expect(h.cloud.calls.isEmpty)
  }

  @Test func signingOutFencesSendsAndQuarantinesTheNamespace() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)

    try await h.cloud.deliver(.accountChanged(.signOut))

    #expect(try await h.cloud.requestBatch() == nil)
    #expect(await h.coordinator.currentStatus == .accountUnavailable)
    #expect(try await h.transport.pendingSends(namespace: h.namespace).isEmpty)
    // The engine stays constructed so a later sign-in is heard.
    #expect(h.cloud.isStarted)
  }

  @Test func reEnablingForANewAccountRunsTheBarrierAgainInItsOwnNamespace() async throws {
    let h = try await running()
    try await h.cloud.deliver(.accountChanged(.switchAccounts))

    let other = Self.fence(user: "_other", epoch: 2)
    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await h.coordinator.enable(resolution: h.resolution, fence: other)

    #expect(h.cloud.activations.suffix(2).map(\.fence) == [other, other])
    #expect(h.cloud.activations.suffix(2).map(\.zone) == [.create, .expectExisting])
    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  @Test func losingAnEstablishedZoneIsJ7AndNeverRecreatesIt() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)

    try await h.cloud.deliver(.zoneLost(.zoneNotFound))

    #expect(await h.coordinator.currentStatus == .zoneLost(.zoneNotFound))
    #expect(try await h.cloud.requestBatch() == nil)
    let state = try await h.transport.state()
    #expect(state.bootstrapComplete == false)
    #expect(state.zoneEstablished)

    // A relaunch reaches the same conclusion rather than creating a fresh zone.
    let relaunch = try await harness(database: h.database, anchor: h.anchor)
    relaunch.cloud.scriptFetch([.zoneLost(.zoneNotFound), .fetchCompleted(succeeded: false)])
    try await relaunch.coordinator.enable(resolution: relaunch.resolution, fence: relaunch.fence)
    #expect(relaunch.cloud.activations.map(\.zone) == [.expectExisting])
    #expect(await relaunch.coordinator.currentStatus == .zoneLost(.zoneNotFound))
  }

  @Test func theUsersExplicitRecoveryCreatesTheZoneAndSendsTheRetainedOutbox() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    try await h.cloud.deliver(.zoneLost(.userDeletedZone))

    h.cloud.scriptSend([.zoneSave(succeeded: true)])
    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await h.coordinator.recoverFromZoneLoss()

    #expect(h.cloud.activations.suffix(2).map(\.zone) == [.create, .expectExisting])
    #expect(try await h.cloud.requestBatch()?.saves.map(\.recordName) == ["v1.globals"])
  }

  @Test func zoneNotFoundDuringFirstCreationIsNotJ7() async throws {
    let h = try await harness()
    h.cloud.scriptSend([.zoneLost(.zoneNotFound), .zoneSave(succeeded: true)])
    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])

    try await h.coordinator.enable(resolution: h.resolution, fence: h.fence)

    #expect(await h.coordinator.currentStatus == .upToDate)
  }

  @Test func deletingCloudDataStopsSyncAndStrandsTheNamespace() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)
    h.cloud.scriptDeleteZone([.zoneDeletion(succeeded: true)])

    try await h.coordinator.deleteCloudData()

    #expect(h.cloud.isStarted == false)
    #expect(await h.coordinator.currentStatus == .off)
    let state = try await h.transport.state()
    #expect(state.zoneEstablished == false)
    #expect(state.bootstrapComplete == false)
    let stranded = try await h.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudOutbox WHERE namespace IS NULL")
    }
    #expect(stranded == 1)
  }

  @Test func aFailedZoneDeletionLeavesSyncRunning() async throws {
    let h = try await running()
    h.cloud.scriptDeleteZone([.zoneDeletion(succeeded: false)])

    try await h.coordinator.deleteCloudData()

    #expect(h.cloud.isStarted)
    #expect(await h.coordinator.currentStatus == .interrupted)

    h.cloud.scriptFetch([.fetchCompleted(succeeded: true)])
    try await h.coordinator.syncNow()
    #expect(await h.coordinator.currentStatus == .upToDate, "a clean fetch clears it")
  }

  // MARK: - Session edges

  @Test func aLocalMutationAfterConstructionIsScheduledOnTheRunningEngine() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)

    await h.coordinator.outboxDidChange()

    #expect(h.cloud.scheduledWork == [PodcastCloudPendingWork(saves: ["v1.globals"], deletions: [])])
  }

  @Test func theConvergingEngineIsSeededFromTheOutbox() async throws {
    let h = try await running()
    try await enqueue(try globals(at: 1_000), in: h)

    #expect(try await h.cloud.requestOutstandingWork().saves == ["v1.globals"])
  }

  @Test func disablingStopsTheEngineAndIgnoresLateCallbacks() async throws {
    let h = try await running()

    await h.coordinator.disable()
    await h.coordinator.handle(.zoneSave(succeeded: false))

    #expect(h.cloud.isStarted == false)
    #expect(await h.coordinator.currentStatus == .off)
  }

  @Test func theNamespaceIsDeterministicAndCoversTheWholeFence() throws {
    let base = try PodcastCloudSyncCoordinator.namespace(for: Self.fence())
    #expect(base == (try PodcastCloudSyncCoordinator.namespace(for: Self.fence())))
    #expect(base != (try PodcastCloudSyncCoordinator.namespace(for: Self.fence(epoch: 2))))
    #expect(base != (try PodcastCloudSyncCoordinator.namespace(for: Self.fence(user: "_other"))))
  }

  @Test func statusTokensRoundTrip() {
    let all: [PodcastCloudSyncStatus] = [
      .off, .bootstrapping, .upToDate, .waiting(until: Self.fixedNow), .accountUnavailable,
      .quotaExceeded, .zoneLost(.zoneNotFound), .zoneLost(.userDeletedZone), .clockRepairRequired,
      .needsAttention, .interrupted,
    ]
    for status in all {
      #expect(PodcastCloudSyncStatus(token: status.token, retryAfter: status.retryAfter) == status)
    }
    #expect(PodcastCloudSyncStatus(token: "fromTheFuture", retryAfter: nil) == nil)
    #expect(PodcastCloudSyncStatus(token: nil, retryAfter: nil) == nil)
  }
}
