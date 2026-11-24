import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// One test per row of the resolution table, plus the write-back guards. The core property (a
/// re-minted identity still sorts after the stamps the source device published) needs
/// `PodcastCloudClock`, so it lives in `PodcastCloudInstallationClockTests`.
@Suite struct PodcastCloudInstallationStoreTests {
  private typealias Anchor = FakePodcastCloudInstallationAnchor

  private func makeStore(
    _ database: AppDatabase, _ anchor: Anchor, minting identities: [UUID] = []
  ) -> PodcastCloudInstallationStore {
    let remaining = Mutex(identities)
    return PodcastCloudInstallationStore(database: database, anchor: anchor) {
      remaining.withLock { queue in queue.isEmpty ? UUID() : queue.removeFirst() }
    }
  }

  /// A minimal `Mutex` stand-in so the identity factory stays `@Sendable` without importing
  /// Synchronization into a test target that targets older platforms.
  private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body(&value)
    }
  }

  /// Builds the flat clock value from a `UUID`, which is what every case here starts from.
  private func fields(
    _ identity: UUID, physicalMilliseconds: Int64 = 0, logicalCounter: Int64 = 0,
    anchorServerMilliseconds: Int64? = nil, lastAdmittedPhysicalMilliseconds: Int64 = 0,
    lastAdmittedLogicalCounter: Int64 = 0, repairRequired: Bool = false
  ) -> PodcastCloudClockFields {
    PodcastCloudClockFields(
      installationUUID: identity.uuidString.lowercased(),
      physicalMilliseconds: physicalMilliseconds, logicalCounter: logicalCounter,
      anchorServerMilliseconds: anchorServerMilliseconds,
      lastAdmittedPhysicalMilliseconds: lastAdmittedPhysicalMilliseconds,
      lastAdmittedLogicalCounter: lastAdmittedLogicalCounter, repairRequired: repairRequired)
  }

  private func seed(
    _ database: AppDatabase, _ record: PodcastCloudClockFields
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO podcastCloudInstallation
            (id, installationUUID, physicalMilliseconds, logicalCounter, anchorServerMilliseconds,
             lastAdmittedPhysicalMilliseconds, lastAdmittedLogicalCounter, repairRequired)
          VALUES (1, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          record.installationUUID, record.physicalMilliseconds, record.logicalCounter,
          record.anchorServerMilliseconds, record.lastAdmittedPhysicalMilliseconds,
          record.lastAdmittedLogicalCounter, record.repairRequired,
        ])
    }
  }

  @Test func freshInstallMintsOnceAndIsStableAcrossReopen() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = Anchor()
    let store = makeStore(database, anchor)
    let first = try #require(try await store.clock())
    #expect(anchor.value == first.installationIdentity)
    #expect(first.physicalMilliseconds == 0)
    let again = try #require(try await makeStore(database, anchor).clock())
    #expect(again.installationUUID == first.installationUUID)
    #expect(anchor.writes == 1, "an ordinary launch adopts without rewriting the anchor")
  }

  @Test func reinstallOverASurvivingAnchorMintsAndOverwritesIt() async throws {
    let database = try AppDatabase.inMemory()
    let survivor = UUID()
    let anchor = Anchor(stored: survivor)
    let minted = UUID()
    let resolved = try #require(try await makeStore(database, anchor, minting: [minted]).clock())
    #expect(resolved.installationIdentity == minted)
    #expect(anchor.value == minted)
  }

  @Test func restoreSignatureReMintsAndWritesTheAnchorBack() async throws {
    let database = try AppDatabase.inMemory()
    let source = UUID()
    try await seed(
      database,
      fields(source, physicalMilliseconds: 500, logicalCounter: 7))
    let anchor = Anchor()
    let minted = UUID()
    let resolved = try #require(try await makeStore(database, anchor, minting: [minted]).clock())
    #expect(resolved.installationIdentity == minted)
    #expect(resolved.installationIdentity != source)
    #expect(anchor.value == minted)
  }

  @Test func anAnchorFromAnotherInstallationAlsoReMints() async throws {
    let database = try AppDatabase.inMemory()
    try await seed(database, fields(UUID()))
    let anchor = Anchor(stored: UUID())
    let minted = UUID()
    let resolved = try #require(try await makeStore(database, anchor, minting: [minted]).clock())
    #expect(resolved.installationIdentity == minted)
  }

  @Test func reMintCarriesEveryNumericFieldForward() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = fields(
      UUID(), physicalMilliseconds: 9_000, logicalCounter: 42,
      anchorServerMilliseconds: 8_500, lastAdmittedPhysicalMilliseconds: 8_900,
      lastAdmittedLogicalCounter: 3, repairRequired: true)
    try await seed(database, seeded)
    let resolved = try #require(try await makeStore(database, Anchor()).clock())
    #expect(resolved.installationUUID != seeded.installationUUID)
    #expect(resolved.physicalMilliseconds == 9_000)
    #expect(resolved.logicalCounter == 42)
    #expect(resolved.anchorServerMilliseconds == 8_500)
    #expect(resolved.lastAdmittedPhysicalMilliseconds == 8_900)
    #expect(resolved.lastAdmittedLogicalCounter == 3)
    #expect(resolved.repairRequired, "a new identity does not repair a quarantined clock")
  }

  @Test func anUnreadableAnchorRefusesAndWritesNothing() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = fields(UUID())
    try await seed(database, seeded)
    let anchor = Anchor()
    anchor.setReadsFail(true)
    await #expect(throws: PodcastCloudInstallationError.anchorUnreadable) {
      _ = try await makeStore(database, anchor).clock()
    }
    let after = try await database.readAsync { db in
      try String.fetchOne(db, sql: "SELECT installationUUID FROM podcastCloudInstallation")
    }
    #expect(after == seeded.installationUUID)
    #expect(anchor.value == nil)
    // Nothing was persisted, so the outage resolves itself without a repair control.
    anchor.setReadsFail(false)
    try anchor.write(try #require(seeded.installationIdentity))
    let recovered = try #require(try await makeStore(database, anchor).clock())
    #expect(recovered.installationUUID == seeded.installationUUID)
  }

  @Test func aFailingAnchorWriteRollsTheRowBack() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = Anchor()
    anchor.setWritesFail(true)
    await #expect(throws: (any Error).self) { _ = try await makeStore(database, anchor).clock() }
    let rows = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudInstallation") ?? -1
    }
    #expect(rows == 0, "a half-resolved install must not commit")
  }

  @Test func nonMintingResolutionNeverWritesAndReportsOnlyAdoption() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = Anchor()
    #expect(try await makeStore(database, anchor).clock(mint: false) == nil)
    let rows = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudInstallation") ?? -1
    }
    #expect(rows == 0)
    #expect(anchor.value == nil)

    let seeded = fields(UUID())
    try await seed(database, seeded)
    // Row present, anchor absent: the restore signature. `mint: false` reports nothing rather than
    // handing back an identity this installation has not accepted.
    #expect(try await makeStore(database, anchor).clock(mint: false) == nil)
    try anchor.write(try #require(seeded.installationIdentity))
    let adopted = try #require(try await makeStore(database, anchor).clock(mint: false))
    #expect(adopted.installationUUID == seeded.installationUUID)
  }

  @Test func reMintClosesTheBarrierAndStrandsTheRestoredOutbox() async throws {
    let database = try AppDatabase.inMemory()
    let namespace = Data("development-account-a-epoch-1".utf8)
    let transport = PodcastCloudTransportStore(database: database)
    try await transport.activate(namespace: namespace)
    try await transport.completeBootstrap(namespace: namespace, engineState: Data([1]))
    _ = try await transport.enqueue(recordName: "v1.globals", payload: Data([1]))
    #expect(try await transport.pendingSends(namespace: namespace).count == 1)

    try await seed(database, fields(UUID()))
    _ = try await makeStore(database, Anchor()).clock()

    #expect(try await transport.engineState(namespace: namespace) == nil)
    #expect(try await transport.pendingSends(namespace: namespace).isEmpty)
    // Re-enabling into the same fence must not resurrect the source device's work.
    try await transport.activate(namespace: namespace)
    try await transport.completeBootstrap(namespace: namespace, engineState: Data([2]))
    #expect(try await transport.pendingSends(namespace: namespace).isEmpty)
    let stranded = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudOutbox") ?? -1
    }
    #expect(stranded == 1, "the rows stay in the file for diagnostics; they are unsendable")
  }

  @Test func advanceRejectsASupersededIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let stale = fields(UUID(), physicalMilliseconds: 10)
    try await seed(database, fields(UUID()))
    let store = makeStore(database, Anchor())
    await #expect(throws: PodcastCloudInstallationError.identityChanged) {
      try await store.advance(stale)
    }
  }

  @Test func advanceRejectsABackwardsMoveUnlessTheClockIsQuarantined() async throws {
    let database = try AppDatabase.inMemory()
    let identity = UUID()
    try await seed(
      database,
      fields(identity, physicalMilliseconds: 1_000, logicalCounter: 5))
    let store = makeStore(database, Anchor())
    let backwards = fields(identity, physicalMilliseconds: 1_000, logicalCounter: 4)
    await #expect(throws: PodcastCloudInstallationError.nonMonotonicAdvance) {
      try await store.advance(backwards)
    }
    try await store.advance(
      fields(identity, physicalMilliseconds: 1_000, logicalCounter: 6))

    // A repair is the one sanctioned backwards move: `generate` throws throughout the quarantined
    // interval, so no stamp can have been produced behind the value being rewound.
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE podcastCloudInstallation
          SET physicalMilliseconds = 2000, logicalCounter = 5, repairRequired = 1 WHERE id = 1
          """)
    }
    try await store.advance(
      fields(identity, physicalMilliseconds: 1_500, logicalCounter: 0))
  }

  @Test func aStampAndItsOutboxRowCommitTogether() async throws {
    struct Abort: Error {}
    let database = try AppDatabase.inMemory()
    let namespace = Data("development-account-a-epoch-1".utf8)
    let transport = PodcastCloudTransportStore(database: database)
    try await transport.activate(namespace: namespace)
    try await transport.completeBootstrap(namespace: namespace, engineState: Data([1]))
    let resolved = try #require(try await makeStore(database, Anchor()).clock())

    let advanced = PodcastCloudClockFields(
      installationUUID: resolved.installationUUID, physicalMilliseconds: 1, logicalCounter: 0)
    await #expect(throws: Abort.self) {
      try await database.writeAsync { db in
        try PodcastCloudTransportStore.enqueue(
          in: db, recordName: "v1.globals", payload: Data([1]))
        try PodcastCloudInstallationStore.advance(in: db, clock: advanced)
        throw Abort()
      }
    }
    #expect(try await transport.pendingSends(namespace: namespace).isEmpty)
    let persisted = try #require(try await makeStore(database, Anchor(stored: resolved.installationIdentity)).clock())
    #expect(persisted.physicalMilliseconds == 0, "neither the stamp nor its row survived")
  }

  // MARK: - Relocated from the registry suite, which no longer owns this table

  @Test func theMigrationMintsNoIdentitySoARestoredDeviceTakesAFreshOne() async throws {
    let database = try AppDatabase.inMemory()
    let rows = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastCloudInstallation") ?? -1
    }
    #expect(rows == 0)
  }

  @Test func theWholeClockRoundTripsThroughAdvance() async throws {
    let database = try AppDatabase.inMemory()
    let store = makeStore(database, Anchor())
    let minted = try #require(try await store.clock())

    try await store.advance(
      PodcastCloudClockFields(
        installationUUID: minted.installationUUID, physicalMilliseconds: 1_700_000_000_000,
        logicalCounter: 7, anchorServerMilliseconds: 1_700_000_000_500,
        lastAdmittedPhysicalMilliseconds: 1_699_999_999_000, lastAdmittedLogicalCounter: 3,
        repairRequired: true))

    let reloaded = try #require(
      try await makeStore(database, Anchor(stored: minted.installationIdentity)).clock())
    #expect(reloaded.installationUUID == minted.installationUUID)
    #expect(reloaded.physicalMilliseconds == 1_700_000_000_000)
    #expect(reloaded.logicalCounter == 7)
    #expect(reloaded.anchorServerMilliseconds == 1_700_000_000_500)
    #expect(reloaded.lastAdmittedPhysicalMilliseconds == 1_699_999_999_000)
    #expect(reloaded.lastAdmittedLogicalCounter == 3)
    #expect(reloaded.repairRequired)
  }
}
