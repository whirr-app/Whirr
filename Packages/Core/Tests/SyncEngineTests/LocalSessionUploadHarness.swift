import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Shared test harness for the `OutboxDrainer.drainLocalSessionUploads` suites
/// (`LocalSessionReconciliationTests`, `SkewClampTests`). Mirrors `SessionDrainHarness`
/// (SessionOutboxDrainTests.swift) but seeds offline sessions and stubs `/api/session/local-all`
/// instead of `/sync`/`/close`.
final class LocalSessionUploadHarness: @unchecked Sendable {
  static let localAllPath = "/api/session/local-all"

  let http: LocalAllScriptedHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let observedServerTime: ObservedServerTimeStore
  let client: ABSClient
  let server: ABSServerConfig
  let account: TokenAccount
  let accountId: Int64
  let itemRowId: Int64
  let diagnostics: FakeDiagnosticsRecording
  let drainer: OutboxDrainer

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://drain.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "access-token", refreshToken: "refresh-token"), for: account)
    let http = LocalAllScriptedHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let database = try AppDatabase.inMemory()
    let savedAccount = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    let accountId = try #require(savedAccount.id)

    let libraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(accountId: accountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let itemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "item_fixture", mediaKind: "book",
          title: "Title", sortTitle: "title")
      ).id)

    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let observedServerTime = ObservedServerTimeStore(database: database)
    let diagnostics = FakeDiagnosticsRecording()

    self.http = http
    self.database = database
    self.outbox = outbox
    self.sessionStore = sessionStore
    self.observedServerTime = observedServerTime
    self.client = client
    self.server = server
    self.account = account
    self.accountId = accountId
    self.itemRowId = itemRowId
    self.diagnostics = diagnostics
    drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId,
      diagnostics: diagnostics)
  }

  /// Seeds one fully-closed offline session (`.closedAwaitingUpload`, its one `localSessionUpload`
  /// row queued) and returns everything a test needs to assert against it.
  @discardableResult
  func seedClosedLocalSession(
    clientSessionId: String = UUID().uuidString,
    currentTime: Double = 120,
    deltaSeconds: Double = 120,
    isFinished: Bool = false,
    durationSeconds: Double? = nil,
    startPosition: Double? = nil,
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_120)
  ) async throws -> (sessionId: Int64, operationId: Int64) {
    try await database.writeAsync { db in
      var session = PlaybackSessionRecord(
        accountId: accountId,
        clientSessionId: clientSessionId,
        itemId: itemRowId,
        startedAt: startedAt,
        updatedAt: updatedAt,
        listenedDeltaSeconds: deltaSeconds,
        isOffline: true,
        globalPosition: currentTime,
        duration: durationSeconds,
        startPosition: startPosition,
        state: .closedAwaitingUpload,
        lastLocalSequence: 1)
      try session.insert(db)

      var progress =
        try MediaProgressRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemRowId)
        .filter(Column("podcastEpisodeId") == nil)
        .fetchOne(db)
        ?? MediaProgressRecord(
          accountId: accountId,
          itemId: itemRowId,
          currentTime: currentTime,
          isFinished: isFinished,
          localSequence: 1,
          origin: .local,
          originKey: "device-uuid")
      progress.currentTime = currentTime
      progress.isFinished = isFinished
      progress.localSequence = 1
      progress.origin = .local
      progress.originKey = "device-uuid"
      try progress.save(db)

      var operation = OutboxOperationRecord(
        accountId: accountId,
        clientOperationId: UUID().uuidString,
        entityKey: "session:\(clientSessionId)",
        podcastEpisodeId: nil,
        operationKind: OutboxOperationKind.localSessionUpload.rawValue,
        coalescingKey: "session:\(clientSessionId):local-upload",
        payloadVersion: 1,
        localSequence: 1,
        payloadCurrentTime: currentTime,
        payloadAccumulatedDeltaSeconds: deltaSeconds,
        payloadDurationSeconds: durationSeconds,
        playbackSessionId: session.id)
      try operation.insert(db)
      return (session.id!, operation.id!)
    }
  }

  func fetchOperation(_ operationId: Int64) throws -> OutboxOperationRecord? {
    try database.read { db in try OutboxOperationRecord.fetchOne(db, key: operationId) }
  }
}

func makeLocalAllResponse(_ results: [(id: String, success: Bool)]) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: [
      "results": results.map { ["id": $0.id, "success": $0.success] }
    ])
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

/// Per-path FIFO canned responses plus a hang/release mode, scoped to `/api/session/local-all`
/// scenarios. Mirrors `SessionScriptedHTTPClient` (SessionOutboxDrainTests.swift) under its own
/// name, so each test file keeps its own copy rather than sharing visibility.
// Stays: SkewClampTests also drives it, and its per-path queues, release-with-response and
// cancellation-throwing hang have no FakeHTTPClient equivalent.
actor LocalAllScriptedHTTPClient: HTTPClienting {
  private var queues: [String: [HTTPResponse]] = [:]
  private var errorQueues: [String: [Error]] = [:]
  /// One gate per hanging path. A cancelled parked call throws `CancellationError`, as a real
  /// transport would; a released one returns the response it was released with.
  private var gates: [String: TestGate<Result<HTTPResponse, any Error>>] = [:]
  /// Calls that reached a held gate and calls released from it, per path, so a release can wait
  /// for every call it is meant to free to have parked.
  private var heldCounts: [String: Int] = [:]
  private var releasedCounts: [String: Int] = [:]
  /// Every request's path in arrival order. `waitUntilRequested` only proves at least one, so a
  /// second or third arrival in a multi-batch hang/release sequence needs `waitUntilRequestCount`.
  private let arrivals = CallRecorder<String>(label: "LocalAllScriptedHTTPClient arrivals")
  private(set) var requests: [HTTPRequest] = []

  func stub(path: String, responses: [HTTPResponse]) {
    queues[path, default: []].append(contentsOf: responses)
  }

  func stub(path: String, throwing errors: [Error]) {
    errorQueues[path, default: []].append(contentsOf: errors)
  }

  private func gate(for path: String) -> TestGate<Result<HTTPResponse, any Error>> {
    if let gate = gates[path] { return gate }
    let gate = TestGate<Result<HTTPResponse, any Error>>(
      label: "LocalAllScriptedHTTPClient \(path)")
    gates[path] = gate
    return gate
  }

  func hang(path: String) {
    gate(for: path).hold()
  }

  /// Frees every call hanging on `path`, once each has parked, and stops hanging the path.
  func release(path: String, with response: HTTPResponse) async {
    guard let gate = gates[path] else { return }
    let target = heldCounts[path, default: 0] - releasedCounts[path, default: 0]
    await gate.waitUntilParked(count: target)
    releasedCounts[path, default: 0] += target
    gate.release(.success(response))
  }

  /// Resumes only the oldest pending continuation for `path`, leaving `hangingPaths` membership
  /// intact, so the next request on this path hangs too. Proves "never concurrently": exactly one
  /// waiter may be pending at a time throughout a multi-batch drain.
  func releaseOldest(path: String, with response: HTTPResponse) async {
    guard let gate = gates[path],
      heldCounts[path, default: 0] > releasedCounts[path, default: 0]
    else { return }
    await gate.waitUntilParked()
    releasedCounts[path, default: 0] += 1
    gate.releaseNext(.success(response))
  }

  func pendingCount(path: String) -> Int {
    gates[path]?.parkedCount ?? 0
  }

  func requestCount(forPath path: String) -> Int {
    requests.filter { $0.url.path == path }.count
  }

  func requests(forPath path: String) -> [HTTPRequest] {
    requests.filter { $0.url.path == path }
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    let path = request.url.path
    arrivals.record(path)

    if let gate = gates[path], gate.isHeld {
      heldCounts[path, default: 0] += 1
      let result = await gate.pass(otherwise: { .failure(CancellationError()) })
      // A call that was cancelled while parked was never released, so it no longer counts as held.
      if case .failure = result { heldCounts[path, default: 0] -= 1 }
      return try result.get()
    }

    if var errors = errorQueues[path], errors.isEmpty == false {
      let error = errors.removeFirst()
      errorQueues[path] = errors
      throw error
    }

    guard var queue = queues[path], queue.isEmpty == false else {
      struct NoStubbedResponse: Error {}
      throw NoStubbedResponse()
    }
    let response = queue.removeFirst()
    queues[path] = queue
    return response
  }

  func waitUntilRequested(path: String) async {
    await arrivals.waitUntil { $0.contains(path) }
  }

  /// Waits for "at least `count` requests have arrived on `path`". Proves a specific later arrival
  /// (e.g. the second batch of a multi-batch drain), which `waitUntilRequested` cannot distinguish
  /// from the first.
  func waitUntilRequestCount(path: String, atLeast count: Int) async {
    await arrivals.waitUntil { $0.filter { $0 == path }.count >= count }
  }
}
