import Foundation
import SyncEngine

/// `PodcastCloudSyncing`'s fake. Every call is recorded in order and stubbable, and events are
/// delivered on demand, so the fake-cloud matrix can drive the boundary without CloudKit or an
/// iCloud account. The real conformance is the App target's `CKSyncEngineDelegate` adapter.
///
/// It refuses what the boundary forbids: `fetchChanges`/`sendChanges` before `start`, and a second
/// `start` without an intervening `stop`, throw `Misuse`, so a test relying on either fails here
/// rather than passing against a laxer double than production.
public final class FakePodcastCloudSyncing: PodcastCloudSyncing, @unchecked Sendable {
  public enum RecordedCall: Sendable, Equatable {
    case start(PodcastCloudActivation)
    case fetchChanges
    case sendChanges
    case schedule(PodcastCloudPendingWork)
    case deleteZone
    case stop
  }

  public enum Misuse: Error, Sendable, Equatable {
    /// A command arrived with no engine running.
    case notStarted
    /// `start` while already started. Configuration is a construction-time value, so a
    /// reconfiguration is a `stop` and a fresh `start`, never a second `start`.
    case alreadyStarted
  }

  private struct State {
    var calls: [RecordedCall] = []
    var isStarted = false
    var fetchError: Error?
    var sendError: Error?
    var startError: Error?
    var deleteZoneError: Error?
    var fetchScripts: [[PodcastCloudSyncEvent]] = []
    var sendScripts: [[PodcastCloudSyncEvent]] = []
    var deleteZoneScripts: [[PodcastCloudSyncEvent]] = []
  }

  private let state = Locked(State())
  /// Weak, as in the App adapter (ADR 0018): once the handler is gone the fake serves nothing.
  private weak let handler: (any PodcastCloudSyncHandling)?

  /// The handler receives whatever `deliver` is asked to send. Supplying it at construction, not
  /// per activation, mirrors the App adapter: the delegate is bound before the engine exists.
  public init(handler: any PodcastCloudSyncHandling) {
    self.handler = handler
  }

  public var calls: [RecordedCall] { state.value.calls }
  public var isStarted: Bool { state.value.isStarted }

  /// The activations seen so far, in order. The two-engine bootstrap rule shows here as an
  /// `automaticallySync: false` activation followed by a `true` one.
  public var activations: [PodcastCloudActivation] {
    calls.compactMap {
      if case .start(let activation) = $0 { return activation }
      return nil
    }
  }

  public func stubStart(throwing error: Error?) { state.withValue { $0.startError = error } }
  public func stubFetchChanges(throwing error: Error?) { state.withValue { $0.fetchError = error } }
  public func stubSendChanges(throwing error: Error?) { state.withValue { $0.sendError = error } }
  public func stubDeleteZone(throwing error: Error?) { state.withValue { $0.deleteZoneError = error } }

  /// Events the next `fetchChanges()` delivers to the handler before it returns, the way
  /// `CKSyncEngine` posts a fetch's events to its delegate while the fetch is still awaited. Each
  /// call consumes one script; an exhausted queue delivers nothing.
  public func scriptFetch(_ events: [PodcastCloudSyncEvent]) {
    state.withValue { $0.fetchScripts.append(events) }
  }

  /// Events the next `sendChanges()` delivers before it returns (a zone save's result, say).
  public func scriptSend(_ events: [PodcastCloudSyncEvent]) {
    state.withValue { $0.sendScripts.append(events) }
  }

  /// Events the next `deleteZone()` delivers before it returns.
  public func scriptDeleteZone(_ events: [PodcastCloudSyncEvent]) {
    state.withValue { $0.deleteZoneScripts.append(events) }
  }

  /// The pending work handed to `schedule`, in order.
  public var scheduledWork: [PodcastCloudPendingWork] {
    calls.compactMap {
      if case .schedule(let work) = $0 { return work }
      return nil
    }
  }

  public func start(_ activation: PodcastCloudActivation) async throws {
    // `Locked.withValue` takes a non-throwing body, so the refusal travels out as a value and is
    // thrown once the lock is released.
    let outcome: Result<Void, Error> = state.withValue { current in
      guard current.isStarted == false else { return .failure(Misuse.alreadyStarted) }
      current.calls.append(.start(activation))
      if let error = current.startError { return .failure(error) }
      current.isStarted = true
      return .success(())
    }
    try outcome.get()
  }

  public func fetchChanges() async throws {
    try await run(.fetchChanges, error: { $0.fetchError }, script: \.fetchScripts)
  }

  public func sendChanges() async throws {
    try await run(.sendChanges, error: { $0.sendError }, script: \.sendScripts)
  }

  /// Scheduling on a stopped engine is dropped rather than refused, as the App adapter drops it:
  /// there is no pending set to add to, and the next construction rehydrates from the outbox.
  public func schedule(_ work: PodcastCloudPendingWork) async {
    state.withValue { current in
      guard current.isStarted else { return }
      current.calls.append(.schedule(work))
    }
  }

  public func deleteZone() async throws {
    try await run(.deleteZone, error: { $0.deleteZoneError }, script: \.deleteZoneScripts)
  }

  public func stop() async {
    state.withValue {
      $0.calls.append(.stop)
      $0.isStarted = false
    }
  }

  /// Hands the handler one event, as the engine's serial delegate callback would. Delivery is
  /// permitted only while started: an event from a torn-down engine is a stale callback the
  /// handler's fence must discard, and a fake that delivered it would hide a missing fence.
  public func deliver(_ event: PodcastCloudSyncEvent) async throws {
    guard isStarted else { throw Misuse.notStarted }
    await handler?.handle(event)
  }

  /// Asks the handler for a batch the way the engine's batch supplier would.
  public func requestBatch(
    within limits: PodcastCloudBatchLimits = .standard
  ) async throws -> PodcastCloudRecordBatch? {
    guard isStarted else { throw Misuse.notStarted }
    return await handler?.nextBatch(within: limits)
  }

  /// Asks the handler what the outbox owes, as the App adapter does once per construction.
  public func requestOutstandingWork() async throws -> PodcastCloudPendingWork {
    guard isStarted else { throw Misuse.notStarted }
    return await handler?.outstandingWork() ?? PodcastCloudPendingWork.none
  }

  private func run(
    _ call: RecordedCall, error selectError: (State) -> Error?,
    script: WritableKeyPath<State, [[PodcastCloudSyncEvent]]>
  ) async throws {
    let outcome: Result<[PodcastCloudSyncEvent], Error> = state.withValue { current in
      guard current.isStarted else { return .failure(Misuse.notStarted) }
      current.calls.append(call)
      if let error = selectError(current) { return .failure(error) }
      guard current[keyPath: script].isEmpty == false else { return .success([]) }
      return .success(current[keyPath: script].removeFirst())
    }
    // Delivered outside the lock and one at a time, each awaited, as the engine's serial delegate
    // callback would deliver them. A handler that stops this engine mid-script ends delivery.
    for event in try outcome.get() {
      guard isStarted else { break }
      await handler?.handle(event)
    }
  }
}

/// `PodcastCloudSyncHandling`'s fake: records what the engine reported and replays scripted
/// batches. The real outbox-backed handler is `PodcastCloudSyncCoordinator`; this remains for
/// tests of the engine side of the boundary.
public final class FakePodcastCloudSyncHandling: PodcastCloudSyncHandling, @unchecked Sendable {
  private struct State {
    var events: [PodcastCloudSyncEvent] = []
    var requestedLimits: [PodcastCloudBatchLimits] = []
    var batches: [PodcastCloudRecordBatch] = []
    var pendingWork = PodcastCloudPendingWork.none
    var outstandingWorkRequests = 0
  }

  private let state = Locked(State())

  public init() {}

  public var events: [PodcastCloudSyncEvent] { state.value.events }
  public var requestedLimits: [PodcastCloudBatchLimits] { state.value.requestedLimits }
  /// How many times the engine asked what the outbox still owes. An engine construction should
  /// ask exactly once.
  public var outstandingWorkRequests: Int { state.value.outstandingWorkRequests }

  /// Stands in for the durable outbox's contents. `.none` is the default, which is what an empty
  /// outbox and a closed bootstrap barrier both look like.
  public func stubPendingWork(_ work: PodcastCloudPendingWork) {
    state.withValue { $0.pendingWork = work }
  }

  /// Queues batches to return, in order. An exhausted queue answers `nil`, which is the same
  /// answer a closed bootstrap barrier gives, so a test must script what it means to assert.
  public func stubBatches(_ batches: [PodcastCloudRecordBatch]) {
    state.withValue { $0.batches = batches }
  }

  public func handle(_ event: PodcastCloudSyncEvent) async {
    state.withValue { $0.events.append(event) }
  }

  public func nextBatch(within limits: PodcastCloudBatchLimits) async -> PodcastCloudRecordBatch? {
    state.withValue { current in
      current.requestedLimits.append(limits)
      guard current.batches.isEmpty == false else { return nil }
      return current.batches.removeFirst()
    }
  }

  public func outstandingWork() async -> PodcastCloudPendingWork {
    state.withValue { current in
      current.outstandingWorkRequests += 1
      return current.pendingWork
    }
  }
}
