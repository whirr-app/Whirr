import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite("OutboxDrainer acknowledgement")
struct OutboxDrainerAcknowledgementTests {
  @Test("a failed sessionSync acknowledgement requeues the row")
  func failedSessionSyncAcknowledgementRequeuesTheRow() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    let operationId = try #require(try harness.sessionRows(sessionId).first?.id)
    try await installAcknowledgementFailure(on: harness.database, operationId: operationId)
    await harness.http.stub(
      path: "/api/session/server-session-1/sync",
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let recovered = try #require(try harness.outbox.fetchOperation(id: operationId))
    #expect(recovered.state == .pending)
  }

  @Test("a failed sessionClose acknowledgement requeues the row")
  func failedSessionCloseAcknowledgementRequeuesTheRow() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.close(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 53, deltaSecondsSinceLastSend: 3, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_013)))
    let operationId = try #require(
      try harness.sessionRows(sessionId)
        .first(where: { $0.operationKind == OutboxOperationKind.sessionClose.rawValue })?.id)
    try await installAcknowledgementFailure(on: harness.database, operationId: operationId)
    await harness.http.stub(
      path: "/api/session/server-session-1/close",
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let recovered = try #require(try harness.outbox.fetchOperation(id: operationId))
    #expect(recovered.state == .pending)
    #expect(try harness.sessionStore.fetchSession(id: sessionId) != nil)
  }

  @Test("a failed default outbox acknowledgement requeues the row")
  func failedDefaultOutboxAcknowledgementRequeuesTheRow() async throws {
    let harness = try await SessionDrainHarness()
    let operation = try harness.outbox.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil,
      coalescingKey: "ack-failure", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 42, isFinished: false, accumulatedDeltaSeconds: 5))
    let operationId = try #require(operation.id)
    try await installAcknowledgementFailure(on: harness.database, operationId: operationId)
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let recovered = try #require(try harness.outbox.fetchOperation(id: operationId))
    #expect(recovered.state == .pending)
  }
}

private func installAcknowledgementFailure(
  on database: AppDatabase, operationId: Int64
) async throws {
  let triggerName = "fail_outbox_ack_\(operationId)"
  try await database.writeAsync { db in
    try db.execute(
      sql: """
        CREATE TRIGGER \(triggerName)
        BEFORE DELETE ON outboxOperation
        WHEN OLD.id = \(operationId)
        BEGIN
          SELECT RAISE(ABORT, 'injected acknowledgement failure');
        END
        """)
  }
}

// MARK: - `progressReset` phased send (ADR 0011)

@Suite("progressReset phased send")
struct ProgressResetDrainTests {

  @Test("a GET 404 during resolve acknowledges without ever sending a DELETE")
  func aGET404DuringResolveAcknowledgesWithoutDelete() async throws {
    let harness = try await makeProgressResetHarness()
    try await harness.intents.resetProgressAsync(
      itemID: ProgressResetHarness.serverItemID, originKey: "fixture-client")
    harness.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(harness.http.requests.map(\.method) == [.get])
    #expect(try harness.queuedOperations().isEmpty)
  }

  @Test("a DELETE 404 counts as done and the reset acknowledges once nothing remains")
  func aDELETE404CountsAsDoneAndAcknowledges() async throws {
    let harness = try await makeProgressResetHarness()
    try await harness.intents.resetProgressAsync(
      itemID: ProgressResetHarness.serverItemID, originKey: "fixture-client")
    harness.http.enqueue(
      contentsOf: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-1"}"#.utf8)),
        HTTPResponse(statusCode: 404, headers: [:], body: Data()),  // DELETE: already gone
        HTTPResponse(statusCode: 404, headers: [:], body: Data()),  // confirming GET: nothing left
      ])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(harness.http.requests.map(\.method) == [.get, .delete, .get])
    #expect(try harness.queuedOperations().isEmpty)
  }

  @Test("a DELETE transport failure is retried and never repeats the resolve capture")
  func aDELETETransportFailureIsRetried() async throws {
    let http = FakeHTTPClient()
    let harness = try await makeProgressResetHarness(http: http)
    try await harness.intents.resetProgressAsync(
      itemID: ProgressResetHarness.serverItemID, originKey: "fixture-client")
    failNextRequest(http, matching: .delete)
    http.enqueue(
      contentsOf: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-1"}"#.utf8)),  // resolve GET
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-1"}"#.utf8)),  // resumed delete GET
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),  // DELETE succeeds this time
        HTTPResponse(statusCode: 404, headers: [:], body: Data()),  // confirming GET
      ])

    let firstPass = Date(timeIntervalSince1970: 1_700_000_000)
    await harness.drainer.drainOutbox(now: firstPass, randomUnit: { 1 })

    let afterFirstPass = try #require(try harness.queuedOperations().first)
    #expect(afterFirstPass.state == .retryWaiting)
    #expect(afterFirstPass.progressResetPhase == .delete, "the capture already landed before the failed DELETE")

    await harness.drainer.drainOutbox(
      now: firstPass.addingTimeInterval(BackoffPolicy.baseDelay), randomUnit: { 1 })

    #expect(try harness.queuedOperations().isEmpty)
    #expect(harness.http.requests.map(\.method) == [.get, .delete, .get, .delete, .get])
  }

  @Test(
    "a restore-leg failure resumes at restore with no second DELETE, whether the failure is a live retry or a simulated relaunch"
  )
  func aRestoreLegFailureResumesAtRestoreWithNoSecondDelete() async throws {
    let http = FakeHTTPClient()
    let harness = try await makeProgressResetHarness(http: http)
    // An ebook reset's captured medium is the audio position, so a non-zero server `currentTime`
    // makes the capture non-trivial and guarantees a restore PATCH is actually sent.
    try await harness.intents.resetEbookProgressAsync(
      itemID: ProgressResetHarness.serverItemID, originKey: "fixture-client")
    failNextRequest(http, matching: .patch)
    http.enqueue(
      contentsOf: [
        HTTPResponse(
          statusCode: 200, headers: [:],
          body: Data(#"{"id":"row-1","currentTime":1234,"progress":0.5}"#.utf8)),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),  // DELETE
        HTTPResponse(statusCode: 404, headers: [:], body: Data()),  // confirming GET
      ])

    let firstPass = Date(timeIntervalSince1970: 1_700_000_000)
    await harness.drainer.drainOutbox(now: firstPass, randomUnit: { 1 })

    let afterFirstPass = try #require(try harness.queuedOperations().first)
    #expect(afterFirstPass.state == .retryWaiting)
    #expect(afterFirstPass.progressResetPhase == .restore)

    // Simulates a relaunch: a new `OutboxDrainer` over the same store/database, not the one that
    // just failed, so resumption must read the persisted phase rather than in-memory drainer
    // state.
    let reopenedDrainer = OutboxDrainer(
      outboxStore: harness.store, database: harness.database, absClient: harness.client,
      account: harness.account, accountId: harness.accountId, diagnostics: harness.diagnostics)
    http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))  // restore PATCH succeeds
    await reopenedDrainer.drainOutbox(
      now: firstPass.addingTimeInterval(BackoffPolicy.baseDelay), randomUnit: { 1 })

    #expect(try harness.queuedOperations().isEmpty)
    #expect(http.requests.filter { $0.method == .delete }.count == 1, "no second DELETE")
    #expect(http.requests.map(\.method) == [.get, .delete, .get, .patch, .patch])
  }

  @Test("duplicate server rows loop at most three DELETEs before dead-lettering")
  func duplicateRowsLoopAtMostThreeTimes() async throws {
    let harness = try await makeProgressResetHarness()
    try await harness.intents.resetProgressAsync(
      itemID: ProgressResetHarness.serverItemID, originKey: "fixture-client")
    harness.http.enqueue(
      contentsOf: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-1"}"#.utf8)),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),  // DELETE row-1
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-2"}"#.utf8)),  // duplicate
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),  // DELETE row-2
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-3"}"#.utf8)),  // duplicate
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),  // DELETE row-3 (the third)
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-4"}"#.utf8)),  // still there
      ])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(harness.http.requests.filter { $0.method == .delete }.count == 3)
    let operation = try await harness.database.readAsync { db in try OutboxOperationRecord.fetchOne(db) }
    #expect(operation?.state == .deadLetter)
    #expect(operation?.deadLetterReason == "progressResetRowPersists")
  }

  @Test("the captured surviving value comes from the GET response, never this device's own local row")
  func capturedValueComesFromTheGETNotTheLocalRow() async throws {
    // Local ebook progress is stale (0.9); the server's own row (read at resolve time) is 0.3.
    // The capture, and the eventual restore, must use the server's value.
    let harness = try await makeProgressResetHarness(seedEbookProgress: 0.9, seedEbookLocation: "epubcfi(/6/4!/local)")
    try await harness.intents.resetProgressAsync(
      itemID: ProgressResetHarness.serverItemID, originKey: "fixture-client")
    harness.http.enqueue(
      contentsOf: [
        HTTPResponse(
          statusCode: 200, headers: [:],
          body: Data(#"{"id":"row-1","ebookProgress":0.3,"ebookLocation":"epubcfi(/6/4!/server)"}"#.utf8)),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),  // DELETE
        HTTPResponse(statusCode: 404, headers: [:], body: Data()),  // confirming GET
      ])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    let restorePATCH = try #require(harness.http.requests.last { $0.method == .patch })
    let object = try #require(
      JSONSerialization.jsonObject(with: restorePATCH.body ?? Data()) as? [String: Any])
    #expect(object["ebookProgress"] as? Double == 0.3)
    #expect(object["ebookLocation"] as? String == "epubcfi(/6/4!/server)")
    #expect(object["currentTime"] == nil, "an audio reset's restore never carries the audio field it just reset")
  }

  @Test("this device's stored serverProgressId is cleared once the reset acknowledges")
  func serverProgressIdIsClearedOnAcknowledgement() async throws {
    let harness = try await makeProgressResetHarness(seedServerProgressId: "row-1")
    try await harness.intents.resetProgressAsync(
      itemID: ProgressResetHarness.serverItemID, originKey: "fixture-client")
    harness.http.enqueue(
      contentsOf: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-1"}"#.utf8)),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),  // DELETE
        HTTPResponse(statusCode: 404, headers: [:], body: Data()),  // confirming GET
      ])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    let progress = try #require(
      await harness.dao.fetchCurrentAsync(accountId: harness.accountId, identity: .item(itemId: harness.itemId)))
    #expect(progress.serverProgressId == nil)
    #expect(progress.serverUpdatedAt == nil)
  }
}

/// Arms `http`'s request hook to fail the next request whose method matches, once, with a
/// transport-classed error, then disarms itself. `FakeHTTPClient.enqueueFailure` cannot target one
/// leg of a multi-request `progressReset` attempt (GET, DELETE, confirming GET inside one `send`):
/// its queue is consumed by whichever request comes first. The hook runs immediately before the
/// request's own failure check, so injecting from it fails the named leg.
private func failNextRequest(_ http: FakeHTTPClient, matching method: HTTPMethod) {
  let armed = Locked(true)
  http.setRequestHook { request in
    guard request.method == method else { return }
    let shouldFail = armed.withValue { value -> Bool in
      guard value else { return false }
      value = false
      return true
    }
    guard shouldFail else { return }
    http.enqueueFailure(FakeHTTPClientError(message: "transport"))
  }
}

private struct ProgressResetHarness: Sendable {
  static let serverItemID = "reset-item"

  let database: AppDatabase
  let account: TokenAccount
  let accountId: Int64
  let itemId: Int64
  let dao: MediaProgressDAO
  let intents: ItemProgressIntentStore
  let store: OutboxStore
  let client: ABSClient
  let drainer: OutboxDrainer
  let http: FakeHTTPClient
  let diagnostics: FakeDiagnosticsRecording

  func queuedOperations() throws -> [OutboxOperationRecord] {
    try store.fetchQueued(accountId: accountId, entityKey: Self.serverItemID)
  }
}

private func makeProgressResetHarness(
  http suppliedHTTP: FakeHTTPClient? = nil,
  seedCurrentTime: Double = 0,
  seedEbookProgress: Double? = nil,
  seedEbookLocation: String? = nil,
  seedServerProgressId: String? = nil
) async throws -> ProgressResetHarness {
  let database = try AppDatabase.inMemory()
  let accountId = try await database.writeAsync { db -> Int64 in
    var account = AccountRecord(
      clientUUID: "fixture-client", serverBaseURL: "https://reset.example.test",
      serverUserId: "fixture-user", serverVersion: "2.35.1")
    try account.insert(db)
    var library = LibraryRecord(
      accountId: account.id!, serverLibraryId: "library-fixture", mediaType: "book", name: "Books")
    try library.insert(db)
    var item = ItemRecord(
      accountId: account.id!, libraryId: library.id!, serverItemId: ProgressResetHarness.serverItemID,
      mediaKind: "book", title: "Fixture", sortTitle: "fixture")
    try item.insert(db)
    return account.id!
  }
  let itemId = try await database.readAsync { db in
    try #require(
      ItemRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("serverItemId") == ProgressResetHarness.serverItemID)
        .fetchOne(db)?.id)
  }
  try await database.writeAsync { db in
    var progress = MediaProgressRecord(
      accountId: accountId, itemId: itemId, currentTime: seedCurrentTime, isFinished: false,
      localSequence: 1, origin: .local, originKey: "fixture-client",
      ebookProgress: seedEbookProgress, ebookLocation: seedEbookLocation,
      serverProgressId: seedServerProgressId)
    try progress.insert(db)
  }
  let server = try ABSServerConfig(url: URL(string: "https://reset.example.test")!)
  let clientUUID = "fixture-client"
  let account = try TokenAccount(
    credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "fixture-user")
  let tokenStore = InMemoryTokenStore()
  try tokenStore.save(TokenPair(accessToken: "fixture-access", refreshToken: "fixture-refresh"), for: account)
  let http = suppliedHTTP ?? FakeHTTPClient()
  let diagnostics = FakeDiagnosticsRecording()
  let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
  let store = try OutboxStore(database: database)
  let drainer = OutboxDrainer(
    outboxStore: store, database: database, absClient: client, account: account, accountId: accountId,
    diagnostics: diagnostics)
  return ProgressResetHarness(
    database: database, account: account, accountId: accountId, itemId: itemId,
    dao: MediaProgressDAO(database: database), intents: try ItemProgressIntentStore(database: database),
    store: store, client: client, drainer: drainer, http: http, diagnostics: diagnostics)
}
