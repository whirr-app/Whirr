import Foundation
import SyncEngine

/// One private CloudKit zone, in memory, shared by any number of `FakePodcastCloudEngine`s.
///
/// The other half of the fake-cloud matrix beside `FakePodcastCloudSyncing`: a server with real
/// change tags, so two devices driving the actual `PodcastCloudSyncCoordinator` race as two
/// iPhones race CloudKit. It keeps only the rules the coordinator depends on:
///
/// - Saves are conditional. A save whose system-field archive does not carry the stored change
///   tag fails with `serverRecordChanged` and the server's record, as `.ifServerRecordUnchanged`
///   does. A save with no archive to a name that already exists fails the same way.
/// - A batch is atomic, as `atomicByZone: true` makes it: one failure fails every sibling with
///   `batchRequestFailed` and nothing is written.
/// - Fetches are incremental from an opaque token, so a device whose engine state is lost
///   refetches everything, and a device that kept it sees only what changed.
/// - The zone must exist before anything is written to it, and a user can delete it.
///
/// It stores `PodcastCloudRecordFields`, so no `CKRecord` is involved and it runs on the host.
public final class FakePodcastCloudServer: @unchecked Sendable {
  public struct StoredRecord: Sendable, Equatable {
    public let fields: PodcastCloudRecordFields
    public let changeTag: Int
    public let modifiedAt: Date
    let sequence: Int
  }

  /// A save or a physical deletion the server refused before writing anything.
  public enum Refusal: Sendable, Equatable {
    case none
    case zoneNotFound
    case userDeletedZone
  }

  private struct State {
    var records: [String: StoredRecord] = [:]
    /// Physical deletions, by record name, with the sequence they happened at.
    var deletions: [String: Int] = [:]
    var sequence = 0
    var zoneExists = false
    /// Bumped by every zone creation. A token or archive from an earlier zone is stale.
    var zoneGeneration = 0
    var userDeletedZone = false
    var now: Date
    var saveCount = 0
  }

  private let state: Locked<State>

  public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    state = Locked(State(now: now))
  }

  // MARK: - Test controls

  /// The server's wall clock, which becomes each written record's modification date.
  public var now: Date { state.value.now }

  public func advance(by seconds: TimeInterval) {
    state.withValue { $0.now = $0.now.addingTimeInterval(seconds) }
  }

  public var zoneExists: Bool { state.value.zoneExists }
  public var records: [String: StoredRecord] { state.value.records }
  public var fields: [String: PodcastCloudRecordFields] { records.mapValues(\.fields) }
  /// Every accepted record save so far; a converged system stops adding to it.
  public var saveCount: Int { state.value.saveCount }

  /// A save by a device the test does not run, such as one on an older build whose records lack
  /// fields this build added. It reaches every device's next fetch as a remote change.
  public func saveAsAnotherDevice(_ fields: PodcastCloudRecordFields) {
    state.withValue {
      $0.sequence += 1
      $0.saveCount += 1
      let tag = ($0.records[fields.recordName]?.changeTag ?? 0) + 1
      $0.records[fields.recordName] = StoredRecord(
        fields: fields, changeTag: tag, modifiedAt: $0.now, sequence: $0.sequence)
      $0.deletions.removeValue(forKey: fields.recordName)
    }
  }

  /// The user deleted the zone from Settings › iCloud, on another device or on the web.
  public func deleteZoneAsUser() {
    state.withValue {
      $0.zoneExists = false
      $0.userDeletedZone = true
      $0.records = [:]
      $0.deletions = [:]
    }
  }

  // MARK: - Engine operations

  func saveZone() {
    state.withValue {
      guard $0.zoneExists == false else { return }
      $0.zoneExists = true
      $0.userDeletedZone = false
      $0.zoneGeneration += 1
    }
  }

  func deleteZone() {
    state.withValue {
      $0.zoneExists = false
      $0.records = [:]
      $0.deletions = [:]
    }
  }

  /// Applies one atomic batch.
  func apply(_ batch: PodcastCloudRecordBatch) -> (PodcastCloudSentRecords, Refusal) {
    state.withValue { current in
      guard current.zoneExists else {
        let refusal: Refusal = current.userDeletedZone ? .userDeletedZone : .zoneNotFound
        let failure = PodcastCloudSendFailure.other
        return (
          PodcastCloudSentRecords(
            saved: [],
            failed: batch.saves.map { PodcastCloudFailedRecord(recordName: $0.recordName, failure: failure) },
            failedDeletions: batch.deletions.map {
              PodcastCloudFailedRecord(recordName: $0, failure: failure)
            }),
          refusal
        )
      }

      var conflicts: [String: PodcastCloudFailedRecord] = [:]
      for record in batch.saves {
        let stored = current.records[record.recordName]
        let archive = batch.systemFields[record.recordName].flatMap(Archive.init)
        guard let stored else { continue }
        if let archive, archive.changeTag == stored.changeTag,
          archive.zoneGeneration == current.zoneGeneration
        {
          continue
        }
        conflicts[record.recordName] = PodcastCloudFailedRecord(
          recordName: record.recordName, failure: .serverRecordChanged,
          serverRecord: Self.fetched(stored, zoneGeneration: current.zoneGeneration))
      }

      guard conflicts.isEmpty else {
        let failed = batch.saves.map {
          conflicts[$0.recordName]
            ?? PodcastCloudFailedRecord(recordName: $0.recordName, failure: .batchRequestFailed)
        }
        let failedDeletions = batch.deletions.map {
          PodcastCloudFailedRecord(recordName: $0, failure: .batchRequestFailed)
        }
        return (
          PodcastCloudSentRecords(saved: [], failed: failed, failedDeletions: failedDeletions), .none
        )
      }

      var saved: [PodcastCloudAcknowledgedRecord] = []
      for record in batch.saves {
        current.sequence += 1
        current.saveCount += 1
        let tag = (current.records[record.recordName]?.changeTag ?? 0) + 1
        current.records[record.recordName] = StoredRecord(
          fields: record, changeTag: tag, modifiedAt: current.now, sequence: current.sequence)
        current.deletions.removeValue(forKey: record.recordName)
        saved.append(
          PodcastCloudAcknowledgedRecord(
            recordName: record.recordName,
            systemFields: Archive(
              recordName: record.recordName, changeTag: tag, zoneGeneration: current.zoneGeneration
            ).data))
      }
      var deleted: [String] = []
      for recordName in batch.deletions {
        current.sequence += 1
        current.records.removeValue(forKey: recordName)
        current.deletions[recordName] = current.sequence
        deleted.append(recordName)
      }
      return (PodcastCloudSentRecords(saved: saved, failed: [], deleted: deleted), .none)
    }
  }

  /// Everything after `token`, and the token that follows it. A token from an earlier zone
  /// generation, or none, fetches the zone from the beginning.
  func changes(since token: Token?) -> (PodcastCloudFetchedChanges, Token, Refusal) {
    state.withValue { current in
      guard current.zoneExists else {
        return (
          PodcastCloudFetchedChanges(modifications: [], deletions: []),
          token ?? Token(zoneGeneration: 0, sequence: 0),
          current.userDeletedZone ? .userDeletedZone : .zoneNotFound
        )
      }
      let after = token?.zoneGeneration == current.zoneGeneration ? token?.sequence ?? 0 : 0
      let modifications = current.records.values
        .filter { $0.sequence > after }
        .sorted { $0.sequence < $1.sequence }
        .map { Self.fetched($0, zoneGeneration: current.zoneGeneration) }
      let deletions = current.deletions
        .filter { $0.value > after }
        .sorted { $0.value < $1.value }
        .map(\.key)
      return (
        PodcastCloudFetchedChanges(modifications: modifications, deletions: deletions),
        Token(zoneGeneration: current.zoneGeneration, sequence: current.sequence),
        .none
      )
    }
  }

  private static func fetched(_ stored: StoredRecord, zoneGeneration: Int) -> PodcastCloudFetchedRecord {
    PodcastCloudFetchedRecord(
      fields: stored.fields,
      systemFields: Archive(
        recordName: stored.fields.recordName, changeTag: stored.changeTag,
        zoneGeneration: zoneGeneration
      ).data,
      serverModificationDate: stored.modifiedAt)
  }

  // MARK: - Opaque values

  /// Stands in for `CKRecord.encodeSystemFields`: opaque to the coordinator, meaningful here.
  struct Archive: Codable, Equatable {
    let recordName: String
    let changeTag: Int
    let zoneGeneration: Int

    init(recordName: String, changeTag: Int, zoneGeneration: Int) {
      self.recordName = recordName
      self.changeTag = changeTag
      self.zoneGeneration = zoneGeneration
    }

    init?(_ data: Data) {
      guard let decoded = try? JSONDecoder().decode(Archive.self, from: data) else { return nil }
      self = decoded
    }

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
  }

  /// Stands in for `CKSyncEngine.State.Serialization`'s change token.
  struct Token: Codable, Equatable {
    let zoneGeneration: Int
    let sequence: Int
  }
}

/// A `PodcastCloudSyncing` conformer backed by a `FakePodcastCloudServer`, with the parts of
/// `CKSyncEngine` the coordinator relies on: a pending set seeded by `schedule`, a send loop that
/// asks the handler for batches until the set is empty or it answers `nil`, retry of
/// `batchRequestFailed` and transient failures by leaving the change pending, a state
/// serialization carrying the fetch token, and events delivered while the command is awaited.
///
/// `automaticallySync` is recorded but nothing runs by itself: a test decides when each device
/// sends and fetches, so it can choose delivery orders.
public final class FakePodcastCloudEngine: PodcastCloudSyncing, @unchecked Sendable {
  /// Where the next command dies with the process: the server has done its part, and the device
  /// hears nothing more. The engine is left stopped, as a dead process leaves it.
  public enum CrashPoint: Sendable, Equatable {
    /// A batch reached the server; the device never learns it was saved.
    case afterServerWrite
    /// A fetch delivered its records; the serialization and completion never arrive.
    case afterFetchedChanges
  }

  private struct State {
    var activation: PodcastCloudActivation?
    var token: FakePodcastCloudServer.Token?
    var pendingSaves: Set<String> = []
    var pendingDeletions: Set<String> = []
    var zoneSavePending = false
    var starts = 0
    var crash: CrashPoint?
  }

  private let server: FakePodcastCloudServer
  /// Weak, as in the App adapter (ADR 0018): once the handler is gone the engine serves nothing.
  private weak let handler: (any PodcastCloudSyncHandling)?
  private let state = Locked(State())

  public init(server: FakePodcastCloudServer, handler: any PodcastCloudSyncHandling) {
    self.server = server
    self.handler = handler
  }

  public var isStarted: Bool { state.value.activation != nil }
  public var activation: PodcastCloudActivation? { state.value.activation }
  public var starts: Int { state.value.starts }
  public var pendingSaves: Set<String> { state.value.pendingSaves }

  public func crash(at point: CrashPoint) {
    state.withValue { $0.crash = point }
  }

  /// Consumes the crash if it is armed for `point`, stopping the engine.
  private func crashes(at point: CrashPoint) -> Bool {
    state.withValue { current in
      guard current.crash == point else { return false }
      current.crash = nil
      current.activation = nil
      return true
    }
  }

  public func start(_ activation: PodcastCloudActivation) async throws {
    let alreadyStarted = state.withValue { current -> Bool in
      guard current.activation == nil else { return true }
      current.activation = activation
      current.starts += 1
      current.token = activation.stateSerialization.flatMap {
        try? JSONDecoder().decode(FakePodcastCloudServer.Token.self, from: $0)
      }
      current.pendingSaves = []
      current.pendingDeletions = []
      current.zoneSavePending = activation.zone == .create
      return false
    }
    if alreadyStarted { throw FakePodcastCloudSyncing.Misuse.alreadyStarted }
    let work = await handler?.outstandingWork() ?? PodcastCloudPendingWork.none
    add(work)
  }

  public func stop() async {
    state.withValue { $0.activation = nil }
  }

  public func schedule(_ work: PodcastCloudPendingWork) async {
    add(work)
  }

  private func add(_ work: PodcastCloudPendingWork) {
    state.withValue { current in
      guard current.activation != nil else { return }
      current.pendingSaves.formUnion(work.saves)
      current.pendingDeletions.formUnion(work.deletions)
    }
  }

  public func fetchChanges() async throws {
    guard isStarted else { throw FakePodcastCloudSyncing.Misuse.notStarted }
    let token = state.value.token
    let (changes, next, refusal) = server.changes(since: token)
    switch refusal {
    case .zoneNotFound:
      await deliver(.zoneLost(.zoneNotFound))
      await deliver(.fetchCompleted(succeeded: false))
      return
    case .userDeletedZone:
      await deliver(.zoneLost(.userDeletedZone))
      await deliver(.fetchCompleted(succeeded: false))
      return
    case .none:
      break
    }
    if changes.modifications.isEmpty == false || changes.deletions.isEmpty == false {
      await deliver(.fetchedChanges(changes))
    }
    if crashes(at: .afterFetchedChanges) { return }
    guard isStarted else { return }
    state.withValue { $0.token = next }
    if let blob = try? JSONEncoder().encode(next) {
      await deliver(.stateSerialization(blob))
    }
    await deliver(.fetchCompleted(succeeded: true))
  }

  public func sendChanges() async throws {
    guard isStarted else { throw FakePodcastCloudSyncing.Misuse.notStarted }
    if state.value.zoneSavePending {
      server.saveZone()
      state.withValue { $0.zoneSavePending = false }
      await deliver(.zoneSave(succeeded: true))
    }
    // A bound on passes, so a coordinator that keeps rescheduling a record it can never send
    // fails a test by not converging instead of hanging it.
    for _ in 0..<64 {
      guard isStarted else { return }
      let hasWork = state.value.pendingSaves.isEmpty == false || state.value.pendingDeletions.isEmpty == false
      guard hasWork, let batch = await handler?.nextBatch(within: .standard) else { break }
      let (sent, refusal) = server.apply(batch)
      if crashes(at: .afterServerWrite) { return }
      state.withValue { current in
        for record in sent.saved { current.pendingSaves.remove(record.recordName) }
        for recordName in sent.deleted { current.pendingDeletions.remove(recordName) }
        // `CKSyncEngine` keeps a change it will retry itself and drops one it will not; the
        // handler hands a dropped change back through `schedule` if it must still go.
        for failure in sent.failed where failure.failure != .batchRequestFailed && failure.failure != .other {
          current.pendingSaves.remove(failure.recordName)
        }
        for failure in sent.failedDeletions where failure.failure != .batchRequestFailed && failure.failure != .other {
          current.pendingDeletions.remove(failure.recordName)
        }
      }
      switch refusal {
      case .zoneNotFound: await deliver(.zoneLost(.zoneNotFound))
      case .userDeletedZone: await deliver(.zoneLost(.userDeletedZone))
      case .none: break
      }
      await deliver(.sentRecords(sent))
      if refusal != .none { break }
      // Transient failures stay pending, and the real engine would retry them later rather than
      // in this pass; so does this one.
      if sent.failed.contains(where: { $0.failure == .other }) { break }
    }
    await deliver(.sendPassEnded)
  }

  public func deleteZone() async throws {
    guard isStarted else { throw FakePodcastCloudSyncing.Misuse.notStarted }
    server.deleteZone()
    await deliver(.zoneDeletion(succeeded: true))
  }

  /// An account event, as the engine would report it.
  public func deliverAccountChange(_ change: PodcastCloudAccountChange) async {
    await deliver(.accountChanged(change))
  }

  private func deliver(_ event: PodcastCloudSyncEvent) async {
    guard isStarted else { return }
    await handler?.handle(event)
  }
}
