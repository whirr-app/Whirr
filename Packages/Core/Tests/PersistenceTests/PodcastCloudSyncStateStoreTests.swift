import Foundation
import GRDB
import Testing

@testable import Persistence

/// Durable sync state: zone establishment, status, held records, conflict bookkeeping and
/// the quarantined-clock republish debt.
@Suite struct PodcastCloudSyncStateStoreTests {
  private let namespace = Data("development-account-a-epoch-1".utf8)
  private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private func openStore() async throws -> (AppDatabase, PodcastCloudTransportStore) {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([1]))
    return (database, store)
  }

  // MARK: - Zone establishment

  @Test func zoneEstablishmentSurvivesReactivationOfTheSameNamespaceOnly() async throws {
    let (_, store) = try await openStore()
    #expect(try await store.state().zoneEstablished == false)

    try await store.markZoneEstablished(namespace: namespace)
    try await store.activate(namespace: namespace)
    #expect(try await store.state().zoneEstablished)
    // Re-activation still closes the barrier, even for the same namespace.
    #expect(try await store.state().bootstrapComplete == false)

    // Another account's container says nothing about this one's zone.
    try await store.activate(namespace: Data("development-account-b-epoch-1".utf8))
    #expect(try await store.state().zoneEstablished == false)
  }

  @Test func aStaleNamespaceCannotMarkTheZoneOrSaveEngineState() async throws {
    let (_, store) = try await openStore()
    let stale = Data("development-account-a-epoch-0".utf8)

    try await store.markZoneEstablished(namespace: stale)
    try await store.saveEngineState(namespace: stale, engineState: Data([9]))

    let state = try await store.state()
    #expect(state.zoneEstablished == false)
    #expect(state.engineState == Data([1]))
  }

  @Test func savingEngineStateLeavesTheBarrierAlone() async throws {
    let database = try AppDatabase.inMemory()
    let store = PodcastCloudTransportStore(database: database)
    try await store.activate(namespace: namespace)

    try await store.saveEngineState(namespace: namespace, engineState: Data([4]))

    let state = try await store.state()
    #expect(state.engineState == Data([4]))
    #expect(state.bootstrapComplete == false)
  }

  @Test func forgettingTheZoneClosesTheBarrierAndDropsArchivesButKeepsTheOutbox() async throws {
    let (database, store) = try await openStore()
    try await store.markZoneEstablished(namespace: namespace)
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    let send = try #require(try await store.pendingSends(namespace: namespace).first)
    try await store.acknowledge(send, systemFields: Data([7]))
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([2]))

    try await store.forgetZone(namespace: namespace)

    let state = try await store.state()
    #expect(state.zoneEstablished == false)
    #expect(state.bootstrapComplete == false)
    #expect(state.engineState == nil)
    let archives = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudSystemFields")
    }
    #expect(archives == 0)
    let outbox = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudOutbox")
    }
    #expect(outbox == 1)
  }

  @Test func quarantiningANamespaceStrandsItsRowsForever() async throws {
    let (database, store) = try await openStore()
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))

    try await store.quarantine(namespace: namespace)
    try await store.completeBootstrap(namespace: namespace, engineState: Data([2]))

    #expect(try await store.pendingSends(namespace: namespace).isEmpty)
    let stranded = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudOutbox WHERE namespace IS NULL")
    }
    #expect(stranded == 1)
  }

  @Test func statusIsStoredPerNamespace() async throws {
    let (_, store) = try await openStore()
    let until = Date(timeIntervalSince1970: 1_700_000_600)

    try await store.setStatus("waiting", retryAfter: until, namespace: namespace)
    #expect(try await store.state().status == "waiting")
    #expect(try await store.state().statusRetryAfter == until)

    try await store.setStatus("ignored", retryAfter: nil, namespace: Data("stale".utf8))
    #expect(try await store.state().status == "waiting")
  }

  // MARK: - Held records

  @Test func aHeldRowIsNotOfferedUntilANewerGenerationReplacesIt() async throws {
    let (_, store) = try await openStore()
    let held = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    _ = try await store.enqueue(recordName: "v1.sub.a", payload: Data([2]))

    try await store.hold(
      namespace: namespace, recordName: "v1.globals", generation: held, category: "malformed",
      observedAt: observedAt)

    #expect(try await store.pendingSends(namespace: namespace).map(\.recordName) == ["v1.sub.a"])
    #expect(try await store.outstandingWork(namespace: namespace).saves == ["v1.sub.a"])

    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([3]))
    #expect(
      try await store.pendingSends(namespace: namespace).map(\.recordName)
        == ["v1.globals", "v1.sub.a"])
    #expect(try await store.heldRecords(namespace: namespace).map(\.category) == ["malformed"])
  }

  @Test func heldRecordsAreBoundedToTheNewest() async throws {
    let (database, _) = try await openStore()
    let limit = PodcastCloudTransportStore.heldRecordLimit
    try await database.writeAsync { db in
      for index in 0..<(limit + 5) {
        try PodcastCloudTransportStore.hold(
          in: db, namespace: namespace, recordName: "v1.sub.\(index)", generation: nil,
          category: "plaintext", observedAt: observedAt.addingTimeInterval(Double(index)))
      }
    }
    let store = PodcastCloudTransportStore(database: database)
    let held = try await store.heldRecords(namespace: namespace)

    #expect(held.count == limit)
    #expect(held.contains { $0.recordName == "v1.sub.0" } == false)
    #expect(held.first?.recordName == "v1.sub.\(limit + 4)")
  }

  // MARK: - Conflict bookkeeping

  @Test func recordingServerSystemFieldsOverwritesTheArchiveButNotTheOrdering()
    async throws
  {
    let (database, store) = try await openStore()
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    let first = try #require(try await store.pendingSends(namespace: namespace).first)
    try await store.acknowledge(first, systemFields: Data([1]))

    try await database.writeAsync { db in
      try PodcastCloudTransportStore.recordSystemFields(
        in: db, namespace: namespace, recordName: "v1.globals", archive: Data([2]))
    }
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([3]))
    let next = try #require(try await store.pendingSends(namespace: namespace).first)
    #expect(next.systemFields == Data([2]))

    // The acknowledgement of the newer send still replaces it: recording a server archive kept the
    // generation where it was, so the ordering rule for later sends is unchanged.
    try await store.acknowledge(next, systemFields: Data([4]))
    let stored = try await database.readAsync { db in
      try PodcastCloudTransportStore.systemFields(in: db, namespace: namespace, recordName: "v1.globals")
    }
    #expect(stored == Data([4]))
  }

  @Test func supersedingSparesANewerLocalMutation() async throws {
    let (database, store) = try await openStore()
    let merged = try await store.enqueue(recordName: "v1.globals", payload: Data([1]))
    _ = try await store.enqueue(recordName: "v1.globals", payload: Data([2]))

    try await database.writeAsync { db in
      try PodcastCloudTransportStore.supersede(
        in: db, namespace: namespace, recordName: "v1.globals", generation: merged)
    }

    let remaining = try await database.readAsync { db in
      try PodcastCloudTransportStore.pendingSend(
        in: db, namespace: namespace, recordName: "v1.globals")
    }
    #expect(remaining?.payload == Data([2]))
  }

  @Test func acknowledgingADeletionDropsTheRowAndTheArchive() async throws {
    let (database, store) = try await openStore()
    try await database.writeAsync { db in
      try PodcastCloudTransportStore.recordSystemFields(
        in: db, namespace: namespace, recordName: "v1.sub.a", archive: Data([5]))
    }
    _ = try await store.enqueue(recordName: "v1.sub.a", payload: Data([1]), isPhysicalDeletion: true)
    let send = try #require(try await store.pendingSends(namespace: namespace).first)
    #expect(send.isPhysicalDeletion)

    try await store.acknowledgeDeletion(send)

    #expect(try await store.pendingSends(namespace: namespace).isEmpty)
    let archive = try await database.readAsync { db in
      try PodcastCloudTransportStore.systemFields(in: db, namespace: namespace, recordName: "v1.sub.a")
    }
    #expect(archive == nil)
  }

  // MARK: - Republish debt

  @Test func debtIsRecordedOncePerIdentityAndSettledExactly() async throws {
    let database = try AppDatabase.inMemory()
    let debt = PodcastCloudRepublishDebt(
      recordKind: "saved", subscriptionUUID: "sub", identityKey: "guid:one", recordedAt: observedAt)
    let later = PodcastCloudRepublishDebt(
      recordKind: "saved", subscriptionUUID: "sub", identityKey: "guid:one", guid: "one",
      recordedAt: observedAt.addingTimeInterval(1))

    try await database.writeAsync { db in
      try PodcastCloudRepublishDebtStore.record(in: db, debt)
      try PodcastCloudRepublishDebtStore.record(in: db, later)
    }
    let recorded = try await database.readAsync { db in try PodcastCloudRepublishDebtStore.all(in: db) }
    #expect(recorded == [later])

    try await database.writeAsync { db in try PodcastCloudRepublishDebtStore.settle(in: db, debt) }
    let settled = try await database.readAsync { db in try PodcastCloudRepublishDebtStore.all(in: db) }
    #expect(settled.isEmpty)
  }
}
