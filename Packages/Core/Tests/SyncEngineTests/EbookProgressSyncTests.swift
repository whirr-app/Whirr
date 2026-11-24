import ABSApi
import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The one-shot legs. The fixtures assert the exact bytes emitted at the ABSClient boundary:
/// the ebook position is not allowed to fall through the audio sender, and the shared finish is a
/// separate `{isFinished:true}` operation rather than an audio reset or a coalesced position.
@Suite("EbookProgressSyncTests")
struct EbookProgressSyncTests {

  @Test("ebook PATCH body is ebook-only and omits location without a genuine CFI")
  func ebookPatchBodyIsEbookOnlyWithoutCFI() async throws {
    let harness = try await makeEbookDrainHarness()
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/chapter.xhtml\"}",
      ebookProgress: 0.42,
      ebookLocation: "not-a-cfi",
      originKey: "fixture-client")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    let request = try #require(harness.http.requests.first)
    #expect(request.method == .patch)
    #expect(request.url.path == "/api/me/progress/ebook-item")
    #expect(request.body == Data(#"{"ebookProgress":0.42}"#.utf8))
  }

  @Test("ebook PATCH includes a genuine CFI and never includes id or audio fields")
  func ebookPatchBodyIncludesGenuineCFIOnly() async throws {
    let harness = try await makeEbookDrainHarness()
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/chapter.xhtml\"}",
      ebookProgress: 0.42,
      ebookLocation: "epubcfi(/6/4!/4/2/1:0)",
      originKey: "fixture-client")
    harness.http.enqueue(HTTPResponse(statusCode: 204, headers: [:], body: Data()))

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    let request = try #require(harness.http.requests.first)
    let expected = Data(#"{"ebookLocation":"epubcfi(\/6\/4!\/4\/2\/1:0)","ebookProgress":0.42}"#.utf8)
    #expect(request.body == expected)
  }

  @Test("a 2xx ebook acknowledgement updates state and deletes the row atomically")
  func ebookAcknowledgementUpdatesAuthoritativeStateAndDeletesRow() async throws {
    let harness = try await makeEbookDrainHarness()
    let result = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/chapter.xhtml\"}",
      ebookProgress: 0.42,
      ebookLocation: "epubcfi(/6/4!/4/2/1:0)",
      originKey: "fixture-client")
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    let acknowledgedAt = Date(timeIntervalSince1970: 1_700_000_123)

    await harness.drainer.drainOutbox(now: acknowledgedAt)

    let progress = try #require(
      await harness.dao.fetchCurrentAsync(
        accountId: harness.accountId, identity: .item(itemId: harness.itemId)))
    #expect(progress.ebookProgress == 0.42)
    #expect(progress.ebookLocation == "epubcfi(/6/4!/4/2/1:0)")
    #expect(progress.serverUpdatedAt == acknowledgedAt)
    #expect(try harness.store.fetchOperation(id: try #require(result.operation.id)) == nil)
  }

  @Test("a drain that finds its entity mid-send waits for that send, then sends what queued behind it")
  func drainJoinsAnInFlightEntityPassAndSendsTheNewerRow() async throws {
    let harness = try await makeEbookDrainHarness()
    let gate = SendGate()
    harness.http.setRequestHook { _ in await gate.holdFirst() }
    harness.http.enqueue(contentsOf: [
      HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      HTTPResponse(statusCode: 200, headers: [:], body: Data()),
    ])
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/first.xhtml\"}",
      ebookProgress: 0.2,
      ebookLocation: nil,
      originKey: "fixture-client")

    let first = Task { await harness.drainer.drainOutbox() }
    await harness.http.waitForRequests { $0.count == 1 }

    // The background flush commits a newer position while the first send is in flight.
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/second.xhtml\"}",
      ebookProgress: 0.8,
      ebookLocation: nil,
      originKey: "fixture-client")
    let secondReturned = ReturnFlag()
    let second = Task {
      await harness.drainer.drainOutbox()
      await secondReturned.set()
    }

    await awaitQuiescence("second drain waits") { "\(await secondReturned.value)" }
    #expect(await secondReturned.value == false)

    await gate.release()
    await second.value
    await first.value
    #expect(harness.http.requests.count == 2)
    #expect(try harness.store.fetchQueued(accountId: harness.accountId, entityKey: harness.serverItemID).isEmpty)
  }

  @Test("acknowledging an older in-flight ebook row never rolls back a newer local write")
  func olderInFlightAcknowledgementPreservesNewerLocalWrite() async throws {
    let harness = try await makeEbookDrainHarness()
    let first = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/first.xhtml\"}",
      ebookProgress: 0.2,
      ebookLocation: nil,
      originKey: "fixture-client")
    let firstID = try #require(first.operation.id)
    _ = try harness.store.transition(operationId: firstID, to: .sending)

    let second = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/second.xhtml\"}",
      ebookProgress: 0.8,
      ebookLocation: nil,
      originKey: "fixture-client")

    try await harness.dao.acknowledgeEbookOutboxOperationAsync(
      operationId: firstID, acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_123))

    let progress = try #require(
      await harness.dao.fetchCurrentAsync(
        accountId: harness.accountId, identity: .item(itemId: harness.itemId)))
    #expect(progress.ebookProgress == 0.8)
    #expect(progress.readingPositionJSON == "{\"href\":\"Text/second.xhtml\"}")
    #expect(progress.origin == .local)
    #expect(try harness.store.fetchOperation(id: firstID) == nil)
    #expect(try harness.store.fetchOperation(id: try #require(second.operation.id))?.state == .pending)
  }

  @Test("finish sends only true after the pending ebook position and never coalesces")
  func finishIsOrderedAfterPositionAndHasExactBody() async throws {
    let harness = try await makeEbookDrainHarness()
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/chapter.xhtml\"}",
      ebookProgress: 0.8,
      ebookLocation: nil,
      originKey: "fixture-client")
    _ = try await harness.dao.markEbookAsFinishedAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      originKey: "fixture-client")
    _ = try await harness.dao.markEbookAsFinishedAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      originKey: "fixture-client")
    harness.http.enqueue(contentsOf: [
      HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      HTTPResponse(statusCode: 200, headers: [:], body: Data()),
    ])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    let progressRequests = harness.http.requests.filter { $0.url.path == "/api/me/progress/ebook-item" }
    #expect(
      progressRequests.map(\.body) == [
        Data(#"{"ebookProgress":0.8}"#.utf8),
        Data(#"{"isFinished":true}"#.utf8),
        Data(#"{"isFinished":true}"#.utf8),
      ])
  }

  /// ADR 0011: an ebook reset is the phased `progressReset` leg, not a fixed
  /// `{ebookProgress:0, isFinished:false}` PATCH (`OutboxOperationKind.ebookReset` is kept only
  /// for rows queued earlier). GET the row, capture the server's audio position (none here),
  /// DELETE the row, confirm with a follow-up GET. No restore PATCH is sent, as the captured audio
  /// position is trivial (0, never seeded).
  @Test("ebook reset with no audio position deletes the server row and sends no restore PATCH")
  func ebookResetWithNoAudioPositionDeletesTheRowWithNoRestore() async throws {
    let harness = try await makeEbookDrainHarness()
    try ItemProgressIntentStore(database: harness.database).resetEbookProgress(
      itemID: harness.serverItemID, originKey: "fixture-client")
    harness.http.enqueue(contentsOf: [
      HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"id":"row-1"}"#.utf8)),
      HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      HTTPResponse(statusCode: 404, headers: [:], body: Data()),
    ])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(harness.http.requests.map(\.method) == [.get, .delete, .get])
    #expect(harness.http.requests[0].url.path == "/api/me/progress/ebook-item")
    #expect(harness.http.requests[1].url.path == "/api/me/progress/row-1")
    #expect(harness.http.requests[2].url.path == "/api/me/progress/ebook-item")
    #expect(try harness.store.fetchQueued(accountId: harness.accountId, entityKey: harness.serverItemID).isEmpty)
  }

  @Test("ebook and audio pending-write protection is field-scoped")
  func pendingWriteProtectionIsFieldScoped() async throws {
    let harness = try await makeEbookDrainHarness()
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/chapter.xhtml\"}",
      ebookProgress: 0.42,
      ebookLocation: nil,
      originKey: "fixture-client")

    #expect(
      try await harness.dao.hasUnacknowledgedLocalOperationAsync(
        accountId: harness.accountId,
        identity: .item(itemId: harness.itemId),
        field: .ebookPosition))
    #expect(
      try await harness.dao.hasUnacknowledgedLocalOperationAsync(
        accountId: harness.accountId,
        identity: .item(itemId: harness.itemId),
        field: .audioPosition) == false)

    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId,
      entityKey: harness.serverItemID,
      podcastEpisodeId: nil,
      coalescingKey: "audio-position",
      localSequence: 2,
      payload: OutboxProgressPayload(currentTime: 12, isFinished: false, accumulatedDeltaSeconds: 0))
    #expect(
      try await harness.dao.hasUnacknowledgedLocalOperationAsync(
        accountId: harness.accountId,
        identity: .item(itemId: harness.itemId),
        field: .audioPosition))
    #expect(
      try await harness.dao.hasUnacknowledgedLocalOperationAsync(
        accountId: harness.accountId,
        identity: .item(itemId: harness.itemId),
        field: .ebookPosition))

    let audioOnly = try await makeEbookDrainHarness()
    _ = try audioOnly.store.enqueueProgress(
      accountId: audioOnly.accountId,
      entityKey: audioOnly.serverItemID,
      podcastEpisodeId: nil,
      coalescingKey: "audio-only",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 12, isFinished: false, accumulatedDeltaSeconds: 0))
    #expect(
      try await audioOnly.dao.hasUnacknowledgedLocalOperationAsync(
        accountId: audioOnly.accountId,
        identity: .item(itemId: audioOnly.itemId),
        field: .audioPosition))
    #expect(
      try await audioOnly.dao.hasUnacknowledgedLocalOperationAsync(
        accountId: audioOnly.accountId,
        identity: .item(itemId: audioOnly.itemId),
        field: .ebookPosition) == false)
  }

  @Test("429 and 5xx use the standard retry table, while permanent 4xx dead-letters safely")
  func retryAndPermanentFailureTable() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let auth = try await makeEbookDrainHarness()
    let authResult = try await auth.dao.writeEbookPositionAndEnqueueAsync(
      accountId: auth.accountId,
      identity: .item(itemId: auth.itemId),
      entityKey: auth.serverItemID,
      readingPositionJSON: "{}",
      ebookProgress: 0.2,
      ebookLocation: nil,
      originKey: "fixture-client")
    auth.http.enqueue(contentsOf: [
      HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      HTTPResponse(statusCode: 401, headers: [:], body: Data()),
    ])
    await auth.drainer.drainOutbox(now: now, randomUnit: { 1 })
    let authOperationID = try #require(authResult.operation.id)
    let authOperation = try #require(try auth.store.fetchOperation(id: authOperationID))
    #expect(authOperation.state == .pending, "a 401 waits for re-authentication, never dead-letters")
    #expect(authOperation.deadLetterReason == nil)

    for responses in [
      [HTTPResponse(statusCode: 429, headers: [:], body: Data())],
      [HTTPResponse(statusCode: 503, headers: [:], body: Data())],
    ] {
      let harness = try await makeEbookDrainHarness()
      let result = try await harness.dao.writeEbookPositionAndEnqueueAsync(
        accountId: harness.accountId,
        identity: .item(itemId: harness.itemId),
        entityKey: harness.serverItemID,
        readingPositionJSON: "{}",
        ebookProgress: 0.2,
        ebookLocation: nil,
        originKey: "fixture-client")
      harness.http.enqueue(contentsOf: responses)
      await harness.drainer.drainOutbox(now: now, randomUnit: { 1 })
      #expect(try harness.store.fetchOperation(id: try #require(result.operation.id))?.state == .retryWaiting)
    }

    let transport = try await makeEbookDrainHarness(
      http: FakeHTTPClient(failure: FakeHTTPClientError(message: "transport")))
    let transportResult = try await transport.dao.writeEbookPositionAndEnqueueAsync(
      accountId: transport.accountId,
      identity: .item(itemId: transport.itemId),
      entityKey: transport.serverItemID,
      readingPositionJSON: "{}",
      ebookProgress: 0.2,
      ebookLocation: nil,
      originKey: "fixture-client")
    await transport.drainer.drainOutbox(now: now, randomUnit: { 1 })
    #expect(
      try transport.store.fetchOperation(id: try #require(transportResult.operation.id))?.state
        == .retryWaiting)

    let permanent = try await makeEbookDrainHarness()
    let result = try await permanent.dao.writeEbookPositionAndEnqueueAsync(
      accountId: permanent.accountId,
      identity: .item(itemId: permanent.itemId),
      entityKey: permanent.serverItemID,
      readingPositionJSON: "{}",
      ebookProgress: 0.2,
      ebookLocation: nil,
      originKey: "fixture-client")
    permanent.http.enqueue(HTTPResponse(statusCode: 400, headers: [:], body: Data()))
    await permanent.drainer.drainOutbox(now: now)
    let operationID = try #require(result.operation.id)
    let operation = try #require(try permanent.store.fetchOperation(id: operationID))
    #expect(operation.state == .deadLetter)
    #expect(operation.deadLetterReason == "badRequest")
  }

  @Test("ebook drain diagnostics use closed privacy-safe categories")
  func ebookDrainDiagnosticsArePrivacySafe() async throws {
    let harness = try await makeEbookDrainHarness()
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{}",
      ebookProgress: 0.2,
      ebookLocation: nil,
      originKey: "fixture-client")
    harness.http.enqueue(HTTPResponse(statusCode: 400, headers: [:], body: Data()))

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    let event = try #require(harness.diagnostics.recorded.first)
    #expect(event.category == .ebookProgress)
    #expect(event.statusClass == .clientError)
    #expect(event.endpointTemplate?.path == "/api/me/progress/:id")
  }

  @Test("a queued ebook operation survives a fresh store and drains after relaunch")
  func queuedEbookOperationSurvivesRelaunchAndDrains() async throws {
    let harness = try await makeEbookDrainHarness()
    _ = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemId),
      entityKey: harness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/relaunch.xhtml\"}",
      ebookProgress: 0.55,
      ebookLocation: nil,
      originKey: "fixture-client")

    let relaunchedStore = try OutboxStore(database: harness.database)
    let relaunchedDrainer = OutboxDrainer(
      outboxStore: relaunchedStore,
      database: harness.database,
      absClient: try makeClient(for: harness.account, server: harness.server, http: harness.http),
      account: harness.account,
      accountId: harness.accountId,
      diagnostics: harness.diagnostics)
    harness.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))

    await relaunchedDrainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(harness.http.requests.contains { $0.url.path == "/api/me/progress/ebook-item" })
    #expect(try relaunchedStore.fetchQueued(accountId: harness.accountId, entityKey: harness.serverItemID).isEmpty)
  }
}

private struct EbookDrainHarness: Sendable {
  static let serverItemID = "ebook-item"

  let server: ABSServerConfig
  let database: AppDatabase
  let account: TokenAccount
  let accountId: Int64
  let itemId: Int64
  let serverItemID: String
  let dao: MediaProgressDAO
  let store: OutboxStore
  let drainer: OutboxDrainer
  let http: FakeHTTPClient
  let diagnostics: FakeDiagnosticsRecording
}

private func makeEbookDrainHarness(http suppliedHTTP: FakeHTTPClient? = nil) async throws -> EbookDrainHarness {
  let database = try AppDatabase.inMemory()
  let accountId = try await database.writeAsync { db in
    var account = AccountRecord(
      clientUUID: "fixture-client",
      serverBaseURL: "https://books.example.test",
      serverUserId: "fixture-user",
      serverVersion: "2.35.1")
    try account.insert(db)
    var library = LibraryRecord(
      accountId: account.id!,
      serverLibraryId: "library-fixture",
      mediaType: "book",
      name: "Books")
    try library.insert(db)
    var item = ItemRecord(
      accountId: account.id!,
      libraryId: library.id!,
      serverItemId: EbookDrainHarness.serverItemID,
      mediaKind: "book",
      title: "Fixture",
      sortTitle: "fixture")
    try item.insert(db)
    return account.id!
  }
  let itemId = try await database.readAsync { db in
    try #require(
      ItemRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("serverItemId") == EbookDrainHarness.serverItemID)
        .fetchOne(db)?.id)
  }
  let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
  let clientUUID = "fixture-client"
  let account = try TokenAccount(
    credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "fixture-user")
  let tokenStore = InMemoryTokenStore()
  try tokenStore.save(
    TokenPair(accessToken: "fixture-access", refreshToken: "fixture-refresh"), for: account)
  let http = suppliedHTTP ?? FakeHTTPClient()
  let diagnostics = FakeDiagnosticsRecording()
  let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
  let store = try OutboxStore(database: database)
  let drainer = OutboxDrainer(
    outboxStore: store,
    database: database,
    absClient: client,
    account: account,
    accountId: accountId,
    diagnostics: diagnostics)
  return EbookDrainHarness(
    server: server,
    database: database,
    account: account,
    accountId: accountId,
    itemId: itemId,
    serverItemID: EbookDrainHarness.serverItemID,
    dao: MediaProgressDAO(database: database),
    store: store,
    drainer: drainer,
    http: http,
    diagnostics: diagnostics)
}

private func makeClient(
  for account: TokenAccount, server: ABSServerConfig, http: FakeHTTPClient
) throws -> ABSClient {
  let tokenStore = InMemoryTokenStore()
  try tokenStore.save(
    TokenPair(accessToken: "fixture-access", refreshToken: "fixture-refresh"), for: account)
  return ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
}

/// Holds the first request until released; later requests pass straight through.
private actor SendGate {
  private var held = false
  private var isReleased = false
  // Stays parked on task cancellation, as the request it stands in for runs to completion.
  private nonisolated let gate = TestGate<Void>(
    label: "SendGate first request", ignoresCancellation: true)

  func holdFirst() async {
    guard held == false, isReleased == false else { return }
    held = true
    gate.hold()
    await gate.pass()
  }

  func release() {
    isReleased = true
    gate.release()
  }
}

private actor ReturnFlag {
  private(set) var value = false
  func set() { value = true }
}
