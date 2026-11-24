import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// The deterministic half of the sync gate: two devices, each with its own database and a real
/// `PodcastCloudSyncCoordinator`, sharing one `FakePodcastCloudServer`. Every ordering of the four
/// operations (each device sending and fetching) is run, alone and with either device dying at
/// each durable edge, and the two must end with the server's accepted registers and nothing left
/// to send.
///
/// This works at the register level, through the holding applier, proving transport, merge and
/// bookkeeping converge. Projection into local tables is covered per entity by
/// `PodcastCloudEntitySyncTests`.
@Suite struct PodcastCloudConvergenceTests {
  private static let fence = PodcastCloudAccountFence(
    container: "iCloud.com.remoteconcern.whirr", environment: "development", zone: "PodcastState",
    iCloudUserRecordID: "_user", accountEpoch: 1)
  /// A little before the fake server's clock, so every stamp is admitted.
  private static let base: Int64 = 1_800_000_000_000 - 3_600_000

  enum Operation: CaseIterable, CustomStringConvertible {
    case sendA, sendB, fetchA, fetchB
    var description: String {
      switch self {
      case .sendA: "A↑"
      case .sendB: "B↑"
      case .fetchA: "A↓"
      case .fetchB: "B↓"
      }
    }
  }

  enum Crash: CaseIterable, CustomStringConvertible {
    case none, aAfterServerWrite, bAfterServerWrite, aAfterFetch, bAfterFetch
    var description: String {
      switch self {
      case .none: "no crash"
      case .aAfterServerWrite: "A dies after its write reaches the server"
      case .bAfterServerWrite: "B dies after its write reaches the server"
      case .aAfterFetch: "A dies after applying a fetch, before its checkpoint"
      case .bAfterFetch: "B dies after applying a fetch, before its checkpoint"
      }
    }
  }

  /// One device: a database that survives process death, and the coordinator and engine that do
  /// not.
  struct Device {
    let name: String
    let database: AppDatabase
    let anchor: FakePodcastCloudInstallationAnchor
    let installation: UUID
    var coordinator: PodcastCloudSyncCoordinator
    var engine: FakePodcastCloudEngine

    static func make(_ name: String, server: FakePodcastCloudServer) async throws -> Device {
      let database = try AppDatabase.inMemory()
      let anchor = FakePodcastCloudInstallationAnchor()
      let (coordinator, engine, resolution) = try await launch(database, anchor, server)
      try await coordinator.enable(resolution: resolution, fence: PodcastCloudConvergenceTests.fence)
      return Device(
        name: name, database: database, anchor: anchor, installation: resolution.clock.installationUUID,
        coordinator: coordinator, engine: engine)
    }

    private static func launch(
      _ database: AppDatabase, _ anchor: FakePodcastCloudInstallationAnchor,
      _ server: FakePodcastCloudServer
    ) async throws -> (PodcastCloudSyncCoordinator, FakePodcastCloudEngine, PodcastCloudInstallationResolution) {
      guard
        case .resolved(let resolution) = try await PodcastCloudInstallationResolver.resolve(
          database: database, anchor: anchor)
      else { throw ConvergenceFailure.unresolved }
      let coordinator = PodcastCloudSyncCoordinator(
        database: database, now: { [server] in server.now })
      let engine = FakePodcastCloudEngine(server: server, handler: coordinator)
      await coordinator.attach(engine)
      return (coordinator, engine, resolution)
    }

    /// Process death and relaunch: the database is all that survives.
    mutating func relaunch(server: FakePodcastCloudServer) async throws {
      await engine.stop()
      let (coordinator, engine, resolution) = try await Self.launch(database, anchor, server)
      try await coordinator.enable(resolution: resolution, fence: PodcastCloudConvergenceTests.fence)
      self.coordinator = coordinator
      self.engine = engine
    }

    /// A process that died is relaunched before it is asked to do anything else.
    mutating func ensureRunning(server: FakePodcastCloudServer) async throws {
      if engine.isStarted == false { try await relaunch(server: server) }
    }

    func enqueue(_ fields: PodcastCloudRecordFields) async throws {
      try await PodcastCloudTransportStore(database: database).enqueue(
        recordName: fields.recordName, payload: try PodcastCloudRecordPayload.encode(fields))
      await coordinator.outboxDidChange()
    }

    func acceptedStamp(_ recordName: String) async throws -> PodcastCloudMutationStamp? {
      try await PodcastCloudRegistryStore(database: database).acceptedStamp(recordName: recordName)
        .flatMap { PodcastCloudMutationStamp($0) }
    }

    /// The record this device holds as the value of `recordName`.
    func acceptedFields(_ recordName: String) async throws -> PodcastCloudRecordFields? {
      try await PodcastCloudRegistryStore(database: database).acceptedPayload(recordName: recordName)
        .map { try PodcastCloudRecordPayload.decode($0) }
    }

    func pendingWork() async throws -> PodcastCloudOutstandingWork {
      let namespace = try PodcastCloudSyncCoordinator.namespace(for: PodcastCloudConvergenceTests.fence)
      return try await PodcastCloudTransportStore(database: database).outstandingWork(namespace: namespace)
    }
  }

  enum ConvergenceFailure: Error { case unresolved }

  // MARK: - Records

  private static func stamp(_ offset: Int64, _ installation: UUID, mutation: UInt8) throws
    -> PodcastCloudMutationStamp
  {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: base + offset, logicalCounter: 0, installationUUID: installation,
      mutationUUID: UUID(uuid: (mutation, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, mutation)))
  }

  private static let subscriptionUUID = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
  private static let generationUUID = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000001")!

  static func globals(keepLatest: Int, at offset: Int64, by installation: UUID) throws
    -> PodcastCloudRecordFields
  {
    try PodcastCloudRecordCodec.encode(
      globalSettings: StampedGlobalSettings(
        autoDownloadEnabled: keepLatest > 2, keepLatestCount: keepLatest, deleteAfterPlayed: false,
        allowCellularAutoDownload: false, showOrderMode: "custom",
        writeStamp: try stamp(offset, installation, mutation: UInt8(keepLatest))),
      recordName: "v1.globals")
  }

  static func subscription(
    followed: Bool, order: Int?, followAt: Int64, orderAt: Int64, by installation: UUID
  ) throws -> PodcastCloudRecordFields {
    try PodcastCloudRecordCodec.encode(
      subscription: SubscriptionSnapshot(
        subscriptionUUID: subscriptionUUID, normalizedURL: "https://example.com/feed",
        title: followed ? "Followed" : "Retired",
        lifecycle: PodcastCloudFollowRegister(
          subscriptionUUID: subscriptionUUID, generationUUID: generationUUID, isFollowed: followed,
          stamp: try stamp(followAt, installation, mutation: 10)),
        customOrder: StampedCustomOrder(
          value: order, stamp: try stamp(orderAt, installation, mutation: 11))),
      recordName: "v1.sub.convergence")
  }

  static func episodeState(
    position: Double, finished: Bool, explicitAt: Int64?, writeAt: Int64, by installation: UUID
  ) throws -> PodcastCloudRecordFields {
    try PodcastCloudRecordCodec.encode(
      episodeState: try PodcastCloudEpisodeState(
        position: position, isFinished: finished, isDismissed: false,
        explicitEpoch: try explicitAt.map { try stamp($0, installation, mutation: 20) } ?? .bottom,
        writeStamp: try stamp(writeAt, installation, mutation: 21)),
      identity: PodcastCloudEpisodeIdentityFields(identityKey: "guid:one"),
      recordName: "v1.state.convergence")
  }

  static func saved(_ isSaved: Bool, at offset: Int64, by installation: UUID) throws
    -> PodcastCloudRecordFields
  {
    try PodcastCloudRecordCodec.encode(
      savedRegister: try PodcastCloudSavedRegister(
        isSaved: isSaved, savedAt: isSaved ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
        stamp: try stamp(offset, installation, mutation: 30)),
      identity: PodcastCloudEpisodeIdentityFields(identityKey: "guid:one"),
      recordName: "v1.saved.convergence")
  }

  static let recordNames = [
    "v1.globals", "v1.sub.convergence", "v1.state.convergence", "v1.saved.convergence",
  ]

  /// Conflicting offline edits on every register family: each device wins some.
  ///
  /// - Global settings: B's later write wins.
  /// - Subscription: A's later follow wins the lifecycle, B's later order wins the position, so
  ///   the converged record is a merge neither device wrote.
  /// - Episode state: B's explicit "finished" beats A's later playback tick.
  /// - Saved: A's later unsave beats B's earlier save.
  static func seed(_ a: Device, _ b: Device) async throws {
    try await a.enqueue(globals(keepLatest: 3, at: 1_000, by: a.installation))
    try await b.enqueue(globals(keepLatest: 5, at: 2_000, by: b.installation))
    try await a.enqueue(
      subscription(followed: true, order: 1, followAt: 3_000, orderAt: 1_000, by: a.installation))
    try await b.enqueue(
      subscription(followed: false, order: 7, followAt: 2_000, orderAt: 4_000, by: b.installation))
    try await a.enqueue(
      episodeState(position: 900, finished: false, explicitAt: nil, writeAt: 9_000, by: a.installation))
    try await b.enqueue(
      episodeState(position: 0, finished: true, explicitAt: 5_000, writeAt: 5_000, by: b.installation))
    try await a.enqueue(saved(false, at: 8_000, by: a.installation))
    try await b.enqueue(saved(true, at: 6_000, by: b.installation))
  }

  // MARK: - Driving

  static func run(
    _ operation: Operation, _ a: inout Device, _ b: inout Device, server: FakePodcastCloudServer
  ) async throws {
    switch operation {
    case .sendA:
      try await a.ensureRunning(server: server)
      try await a.engine.sendChanges()
    case .sendB:
      try await b.ensureRunning(server: server)
      try await b.engine.sendChanges()
    case .fetchA:
      try await a.ensureRunning(server: server)
      try await a.engine.fetchChanges()
    case .fetchB:
      try await b.ensureRunning(server: server)
      try await b.engine.fetchChanges()
    }
  }

  /// What `automaticallySync` would do eventually: alternate full sync passes until quiet.
  static func settle(_ a: inout Device, _ b: inout Device, server: FakePodcastCloudServer) async throws {
    for _ in 0..<4 {
      try await a.ensureRunning(server: server)
      try await a.coordinator.syncNow()
      try await b.ensureRunning(server: server)
      try await b.coordinator.syncNow()
    }
    try await a.engine.fetchChanges()
    try await b.engine.fetchChanges()
  }

  static func arm(_ crash: Crash, _ a: Device, _ b: Device) {
    switch crash {
    case .none: break
    case .aAfterServerWrite: a.engine.crash(at: .afterServerWrite)
    case .bAfterServerWrite: b.engine.crash(at: .afterServerWrite)
    case .aAfterFetch: a.engine.crash(at: .afterFetchedChanges)
    case .bAfterFetch: b.engine.crash(at: .afterFetchedChanges)
    }
  }

  /// The logical snapshot the gate compares: per record, the value each device has accepted, and
  /// the one the server holds.
  static func expectConverged(
    _ a: Device, _ b: Device, server: FakePodcastCloudServer, _ label: String
  ) async throws {
    for recordName in recordNames {
      let stored = try #require(server.fields[recordName], "\(label): \(recordName) never reached the server")
      let serverStamp = try PodcastCloudRecordMerge.governingStamp(of: stored)
      let aStamp = try await a.acceptedStamp(recordName)
      let bStamp = try await b.acceptedStamp(recordName)
      #expect(aStamp == serverStamp, "\(label): A disagrees on \(recordName)")
      #expect(bStamp == serverStamp, "\(label): B disagrees on \(recordName)")
      #expect(try await a.acceptedFields(recordName) == stored, "\(label): A holds another \(recordName)")
      #expect(try await b.acceptedFields(recordName) == stored, "\(label): B holds another \(recordName)")
    }
    #expect(try await a.pendingWork().isEmpty, "\(label): A still owes work")
    #expect(try await b.pendingWork().isEmpty, "\(label): B still owes work")
  }

  /// The values every run must reach, whatever the order.
  static func expectWinners(server: FakePodcastCloudServer, _ label: String) throws {
    let globals = try PodcastCloudRecordCodec.decodeGlobalSettings(
      try #require(server.fields["v1.globals"]))
    #expect(globals.keepLatestCount == 5, "\(label): global settings")

    let subscription = try PodcastCloudRecordCodec.decodeSubscription(
      try #require(server.fields["v1.sub.convergence"]), subscriptionUUID: subscriptionUUID)
    #expect(subscription.lifecycle.isFollowed, "\(label): follow lifecycle")
    #expect(subscription.customOrder?.value == 7, "\(label): custom order")

    // B's finish beats A's tick only when A's tick has already left A's outbox (as an accepted
    // register) by the time A learns of the finish. If the tick is still unsent, the admission
    // rule lets A's unsent listening outrank the finish and A republishes it as a fresh explicit
    // action. So which one reaches the server depends on delivery order for this register,
    // unlike every other family checked here.
    let state = try PodcastCloudRecordCodec.decodeEpisodeState(
      try #require(server.fields["v1.state.convergence"])
    ).state
    if state.isFinished {
      #expect(state.position == 0, "\(label): explicit finish beats an already-sent tick")
    } else {
      #expect(
        state.position == 900,
        "\(label): otherwise A's still-unsent tick outranks the finish")
    }

    let saved = try PodcastCloudRecordCodec.decodeSavedRegister(
      try #require(server.fields["v1.saved.convergence"]))
    #expect(saved.isSaved == false, "\(label): saved register")
  }

  static let orders: [[Operation]] = permutations(Operation.allCases)

  static func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index -> [[T]] in
      var rest = items
      let head = rest.remove(at: index)
      return permutations(rest).map { [head] + $0 }
    }
  }

  // MARK: - Tests

  @Test(arguments: Crash.allCases)
  func everyDeliveryOrderConverges(crash: Crash) async throws {
    for order in Self.orders {
      let label = "\(order.map(\.description).joined(separator: " ")) with \(crash)"
      let server = FakePodcastCloudServer()
      var a = try await Device.make("A", server: server)
      var b = try await Device.make("B", server: server)
      try await Self.seed(a, b)
      Self.arm(crash, a, b)

      for operation in order {
        try await Self.run(operation, &a, &b, server: server)
      }
      try await Self.settle(&a, &b, server: server)

      try await Self.expectConverged(a, b, server: server, label)
      try Self.expectWinners(server: server, label)
    }
  }

  @Test func aConvergedPairIsQuiet() async throws {
    let server = FakePodcastCloudServer()
    var a = try await Device.make("A", server: server)
    var b = try await Device.make("B", server: server)
    try await Self.seed(a, b)
    try await Self.settle(&a, &b, server: server)
    let saves = server.saveCount

    try await Self.settle(&a, &b, server: server)

    #expect(server.saveCount == saves, "applying a converged state again must not publish anything")
  }

  @Test func engineStateLossRefetchesWithoutChangingAnything() async throws {
    let server = FakePodcastCloudServer()
    var a = try await Device.make("A", server: server)
    var b = try await Device.make("B", server: server)
    try await Self.seed(a, b)
    try await Self.settle(&a, &b, server: server)
    let saves = server.saveCount

    // The serialization is a discardable cache: losing it costs a refetch from the start and a
    // repeated barrier, and every record it delivers again is an echo.
    let namespace = try PodcastCloudSyncCoordinator.namespace(for: Self.fence)
    try await PodcastCloudTransportStore(database: b.database).discardEngineState(namespace: namespace)
    try await b.relaunch(server: server)
    try await Self.settle(&a, &b, server: server)

    try await Self.expectConverged(a, b, server: server, "after engine-state loss")
    #expect(server.saveCount == saves)
  }

  @Test func aDeviceThatJoinsLateCatchesUp() async throws {
    let server = FakePodcastCloudServer()
    var a = try await Device.make("A", server: server)
    try await a.enqueue(Self.globals(keepLatest: 4, at: 1_000, by: a.installation))
    try await a.coordinator.syncNow()

    var b = try await Device.make("B", server: server)
    try await Self.settle(&a, &b, server: server)

    #expect(try await b.acceptedStamp("v1.globals") == (try await a.acceptedStamp("v1.globals")))
    #expect(try await b.acceptedStamp("v1.globals") != nil)
  }
}
