import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct PodcastCloudTransportStoreTests {
  private let namespace = Data("development-account-a-epoch-1".utf8)

  @Test func acknowledgementRetainsNewerMutationAndRebasesSystemFields() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    let first = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    let sends = try await store.pendingSends(namespace: namespace)
    #expect(sends.map(\.generation) == [first])
    let second = try await store.enqueue(recordName: "v1.globals", payload: Data([2]))
    #expect(second > first)
    try await store.acknowledge(sends[0], systemFields: Data([9]))
    let pending = try await store.pendingSends(namespace: namespace)
    #expect(pending.count == 1)
    #expect(pending[0].payload == Data([2]))
    #expect(pending[0].systemFields == Data([9]))
    try await store.acknowledge(pending[0], systemFields: Data([8]))
    #expect(try await store.pendingSends(namespace: namespace).isEmpty)
    let third = try await store.enqueue(recordName: "v1.globals", payload: Data([3]))
    #expect(third > second)
    #expect(try await store.pendingSends(namespace: namespace)[0].systemFields == Data([8]))
  }

  @Test func bootstrapAndAccountChangeFenceSendsAndLateCallbacks() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    #expect(try await store.pendingSends(namespace: namespace).isEmpty)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    let oldSend = try await store.pendingSends(namespace: namespace)[0]
    let other = Data("development-account-b-epoch-2".utf8)
    try await store.activate(namespace: other)
    #expect(try await store.pendingSends(namespace: namespace).isEmpty)
    #expect(try await store.engineState(namespace: namespace) == nil)
    try await store.acknowledge(oldSend, systemFields: Data([9]))
    try await store.completeBootstrap(namespace: other, engineState: Data([2]))
    #expect(try await store.pendingSends(namespace: other).isEmpty)
    // Only a new explicitly accepted mutation may enter the new namespace.
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([2]))
    let next = try await store.pendingSends(namespace: other)
    #expect(next.count == 1)
    #expect(next[0].systemFields == nil)
  }

  @Test func lostEngineStateClosesBarrierButRetainsDurableOutbox() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    try await store.discardEngineState(namespace: namespace)
    #expect(try await store.pendingSends(namespace: namespace).isEmpty)
    let reopened = PodcastCloudTransportStore(database: database)
    try await reopened.completeBootstrap(namespace: namespace, engineState: Data([2]))
    #expect(try await reopened.pendingSends(namespace: namespace).count == 1)
  }

  @Test func sourceAndOutboxRollbackTogether() throws {
    let database = try AppDatabase.inMemory()
    enum Abort: Error { case injected }
    #expect(throws: Abort.injected) {
      try database.write { db in
        try db.execute(sql: "CREATE TABLE sourceMutation (value INTEGER)")
        try db.execute(sql: "INSERT INTO sourceMutation VALUES (1)")
        _ = try PodcastCloudTransportStore.enqueue(in: db, recordName: "v1.globals", payload: Data([1]))
        throw Abort.injected
      }
    }
    #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM podcastCloudOutbox") } == 0)
    #expect(try database.read { try $0.tableExists("sourceMutation") } == false)
  }

  @Test func byteBoundAndDeterministicBatchLimit() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    await #expect(throws: PodcastCloudTransportError.invalidPayload) {
      _ = try await store.enqueue(recordName: "v1.globals", payload: Data(repeating: 0, count: 65_537))
    }
    for name in ["v1.sub.b", "v1.sub.a", "v1.globals"] {
      _ = try await store.enqueue(recordName: name, payload: Data(repeating: 0, count: 10))
    }
    let batch = try await store.pendingSends(namespace: namespace, maximumRecords: 2, maximumBytes: 20)
    #expect(batch.map(\.recordName) == ["v1.globals", "v1.sub.a"])
  }

  // MARK: - Outstanding work, for engine rehydration

  @Test func outstandingWorkSeparatesSavesFromDeletions() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    _ = try await store.enqueue(recordName: "v1.sub.a", payload: Data([2]))
    _ = try await store.enqueue(
      recordName: "v1.sub.b", payload: Data([3]), isPhysicalDeletion: true)

    let work = try await store.outstandingWork(namespace: namespace)

    #expect(work.saves == ["v1.globals", "v1.sub.a"])
    #expect(work.deletions == ["v1.sub.b"])
    #expect(work.isEmpty == false)
  }

  /// The barrier is the authority on whether work may be sent, so an engine built while it is
  /// closed must not be seeded with any.
  @Test func outstandingWorkIsEmptyWhileTheBootstrapBarrierIsClosed() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))

    #expect(try await store.outstandingWork(namespace: namespace).isEmpty)

    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    #expect(try await store.outstandingWork(namespace: namespace).saves == ["v1.globals"])
  }

  @Test func outstandingWorkIsEmptyForASupersededNamespace() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    try await store.activate(namespace: Data("other".utf8))

    #expect(try await store.outstandingWork(namespace: namespace).isEmpty)
  }

  /// Rehydration carries no payloads, so unlike `pendingSends` it is not clamped: an engine seeded
  /// with only the first 200 names would strand the rest until some later write woke it.
  @Test func outstandingWorkIsNotClampedTheWayABatchIs() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    for index in 0..<220 {
      _ = try await store.enqueue(
        recordName: "v1.sub.\(String(format: "%03d", index))", payload: Data(repeating: 7, count: 64))
    }

    #expect(try await store.outstandingWork(namespace: namespace).saves.count == 220)
    #expect(try await store.pendingSends(namespace: namespace).count == 200)
  }

  @Test func outstandingWorkReflectsTheOutboxCoalescingOnePerRecord() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([2]))

    #expect(try await store.outstandingWork(namespace: namespace).saves == ["v1.globals"])
  }

  /// A record re-enqueued as a deletion after a pending save reports as a deletion only: the
  /// outbox holds one row per record, and seeding both would ask the engine to save and delete the
  /// same name in one pass.
  @Test func aRecordReplacedByADeletionReportsOnlyAsADeletion() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    _ = try await store.enqueue(recordName: "v1.sub.a", payload: Data([1]))
    _ = try await store.enqueue(
      recordName: "v1.sub.a", payload: Data([2]), isPhysicalDeletion: true)

    let work = try await store.outstandingWork(namespace: namespace)

    #expect(work.saves.isEmpty)
    #expect(work.deletions == ["v1.sub.a"])
  }
}
