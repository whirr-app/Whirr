import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `OutboxDrainer`'s serialisation guarantees (the per-entity `drainingEntityKeys` set, the
/// per-operation in-flight set and `drainLocalSessionUploads`'s coalescing flag) are all instance
/// state. `SyncEngine.triggerLocalSessionUploadDrain` needs no guard of its own because "the
/// closure's own drainer instance owns the coalescing guarantee". Both hold only if one drainer
/// instance survives across triggers, which is what this type guarantees.
@Suite("OutboxDrainRequester")
struct OutboxDrainRequesterTests {

  @Test("repeated triggers of either drain reuse one drainer")
  func repeatedTriggersReuseOneDrainer() async throws {
    let harness = try await SessionDrainHarness()
    let factory = RecordingDrainerFactory(harness: harness)
    let requester = OutboxDrainRequester(
      accountDAO: AccountDAO(database: harness.database), makeDrainer: factory.make)

    await requester.drainOutbox()
    await requester.drainOutbox()
    await requester.drainLocalSessionUploads()

    #expect(factory.constructionCount == 1)
  }

  @Test("co-incident triggers still construct exactly one drainer")
  func concurrentTriggersConstructOneDrainer() async throws {
    let harness = try await SessionDrainHarness()
    let factory = RecordingDrainerFactory(harness: harness)
    let requester = OutboxDrainRequester(
      accountDAO: AccountDAO(database: harness.database), makeDrainer: factory.make)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { await requester.drainOutbox() }
      }
    }

    #expect(factory.constructionCount == 1)
  }

  @Test("a second trigger cannot open a concurrent pass over an entity already draining")
  func aSecondTriggerCannotOpenAConcurrentPassOverTheSameEntity() async throws {
    let harness = try await SessionDrainHarness()
    let entityKey = "item-serialised"
    let path = "/api/me/progress/\(entityKey)"
    try enqueueProgress(on: harness, entityKey: entityKey, coalescingKey: "first", localSequence: 1)
    try enqueueProgress(on: harness, entityKey: entityKey, coalescingKey: "second", localSequence: 2)
    await harness.http.hang(path: path)
    let requester = makeRequester(harness: harness)

    let firstTrigger = Task { await requester.drainOutbox(now: Date()) }
    await harness.http.waitUntilRequested(path: path)

    // The head row is in flight. A second trigger must find this entity already draining and wait
    // for that pass, not open one of its own: a per-trigger drainer would pick up the second
    // queued row and send it concurrently, breaking the entity's strict ordering. Nor may it
    // return early, or a background task awaiting it would end under the in-flight send.
    let secondReturned = CompletionFlag()
    let secondTrigger = Task {
      await requester.drainOutbox(now: Date())
      secondReturned.set()
    }
    await awaitQuiescence("second trigger waits") {
      "\(secondReturned.isSet)-\(await harness.http.requestCount(forPath: path))"
    }
    #expect(secondReturned.isSet == false, "the second trigger returned under the in-flight send")
    #expect(await harness.http.requestCount(forPath: path) == 1)

    await harness.http.stub(path: path, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.http.release(path: path, with: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    await firstTrigger.value
    await secondTrigger.value

    // Both rows still drain, sequentially, off the one pass.
    #expect(await harness.http.requestCount(forPath: path) == 2)
  }

  @Test("a changed account rebuilds the drainer")
  func aChangedAccountRebuildsTheDrainer() async throws {
    let harness = try await SessionDrainHarness()
    let factory = RecordingDrainerFactory(harness: harness)
    let requester = OutboxDrainRequester(
      accountDAO: AccountDAO(database: harness.database), makeDrainer: factory.make)

    await requester.drainOutbox()
    try await harness.database.writeAsync { db in
      try db.execute(sql: "UPDATE account SET serverUserId = 'user-2'")
    }
    await requester.drainOutbox()

    #expect(factory.constructionCount == 2)
    #expect(factory.accounts.map(\.userID) == ["user-1", "user-2"])
  }

  /// A requester re-reads the current account on every trigger and can outlive the account its
  /// client was built for. Moving the next account's rows through `sending` would count an
  /// attempt that never reached any server, so it must stop before touching them at all.
  @Test("a requester built for one account never drains another's rows")
  func aRequesterBuiltForOneAccountNeverDrainsAnother() async throws {
    let harness = try await SessionDrainHarness()
    let tokenStore = InMemoryTokenStore()
    let boundClient = ABSClient(
      server: try ABSServerConfig(url: try #require(URL(string: "https://drain.example.test"))),
      httpClient: harness.http, tokenStore: tokenStore, boundAccount: harness.account)
    let requester = OutboxDrainRequester(
      accountDAO: AccountDAO(database: harness.database),
      outboxStore: harness.outbox,
      database: harness.database,
      absClient: boundClient,
      diagnostics: harness.diagnostics)

    // The bound account is removed and the next one signs in, with a pair of its own.
    let nextClientUUID = UUID().uuidString
    let nextRecord = try await harness.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account")
      var record = AccountRecord(
        clientUUID: nextClientUUID, serverBaseURL: "https://drain.example.test", serverUserId: "user-2",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let nextAccountId = try #require(nextRecord.id)
    try tokenStore.save(
      TokenPair(accessToken: "next-access", refreshToken: "next-refresh"),
      for: try nextRecord.credentialTokenAccount)
    let operation = try harness.outbox.enqueueProgress(
      accountId: nextAccountId, entityKey: "item-next", podcastEpisodeId: nil,
      coalescingKey: "next", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 5))
    let operationId = try #require(operation.id)

    await requester.drainOutbox(now: Date())
    await requester.drainLocalSessionUploads(now: Date())

    let row = try #require(try harness.outbox.fetchOperation(id: operationId))
    #expect(row.state == .pending)
    #expect(row.attempts == 0)
    #expect(await harness.http.requests.isEmpty)
  }

  @Test("no account is a clean no-op")
  func noAccountIsACleanNoOp() async throws {
    let harness = try await SessionDrainHarness()
    let factory = RecordingDrainerFactory(harness: harness)
    try await harness.database.writeAsync { db in try db.execute(sql: "DELETE FROM account") }
    let requester = OutboxDrainRequester(
      accountDAO: AccountDAO(database: harness.database), makeDrainer: factory.make)

    await requester.drainOutbox()
    await requester.drainLocalSessionUploads()

    #expect(factory.constructionCount == 0)
  }

  private func makeRequester(harness: SessionDrainHarness) -> OutboxDrainRequester {
    OutboxDrainRequester(
      accountDAO: AccountDAO(database: harness.database),
      outboxStore: harness.outbox,
      database: harness.database,
      absClient: harness.client,
      diagnostics: harness.diagnostics)
  }

  private func enqueueProgress(
    on harness: SessionDrainHarness, entityKey: String, coalescingKey: String, localSequence: Int64
  ) throws {
    _ = try harness.outbox.enqueueProgress(
      accountId: harness.accountId, entityKey: entityKey, podcastEpisodeId: nil,
      coalescingKey: coalescingKey, localSequence: localSequence,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 5))
  }
}

/// Counts drainer constructions so a test can assert instance identity without reaching into
/// `OutboxDrainRequester`'s private cache.
private final class RecordingDrainerFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let harness: SessionDrainHarness
  private var constructions: [TokenAccount] = []

  init(harness: SessionDrainHarness) {
    self.harness = harness
  }

  var constructionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return constructions.count
  }

  var accounts: [TokenAccount] {
    lock.lock()
    defer { lock.unlock() }
    return constructions
  }

  var make: @Sendable (TokenAccount, Int64) -> OutboxDrainer {
    { [self] account, accountId in
      lock.lock()
      constructions.append(account)
      lock.unlock()
      return OutboxDrainer(
        outboxStore: harness.outbox, database: harness.database, absClient: harness.client,
        account: account, accountId: accountId, diagnostics: harness.diagnostics)
    }
  }
}

private final class CompletionFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }

  func set() {
    lock.lock()
    flag = true
    lock.unlock()
  }
}
