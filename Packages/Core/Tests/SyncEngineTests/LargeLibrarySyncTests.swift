import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// An 8,000-item synthetic library exercises the `SyncEngine` pull at scale. Builds its own
/// minimal harness (rather than reusing `Harness`/`FakeHTTPClient`) because the synthetic server
/// needs to vend pages lazily from arithmetic instead of a pre-enqueued response queue, and needs
/// a request-arrival hook for DB sampling that `FakeHTTPClient` has no seam for.
@Suite("8,000-item synthetic library sync")
struct LargeLibrarySyncTests {

  @Test(
    "an 8,000-item library syncs to completion with bounded pagination throughout, progressive monotonic visibility, bounded fake-side page handout, and no main-thread database writes"
  )
  func largeLibrarySyncsBoundedAndProgressive() async throws {
    let totalItems = 8_000
    let pageLimit = 100

    let server = try ABSServerConfig(url: try #require(URL(string: "https://large.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let database = try AppDatabase.inMemory()
    let saved = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1"
      )
      try record.insert(db)
      return record
    }
    let accountId = try #require(saved.id)

    let libraryDAO = LibraryDAO(database: database)
    let itemDAO = ItemDAO(database: database)

    // (d) a GRDB transaction observer, not a production instrumentation hook, records which
    // thread every `item`-table write lands on.
    let threadObserver = MainThreadRecordingObserver()
    database.dbWriter.add(transactionObserver: threadObserver)

    // (b) sampled the instant each items-list request arrives. Pages are fetched and applied
    // sequentially (never concurrently), so this reflects exactly what the previous page's
    // transactional upsert persisted, never a partial page.
    let visibilitySamples = SampleRecorder()

    let http = SyntheticLibraryHTTPClient(
      libraryId: "lib-large",
      totalItems: totalItems,
      onItemsRequested: {
        let libraryRowId = try? libraryDAO.fetchOneAccessible(accountId: accountId, serverLibraryId: "lib-large")?.id
        let count =
          libraryRowId.flatMap { rowId in
            try? database.read { db in
              try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM item WHERE libraryId = ? AND softDeleted = 0",
                arguments: [rowId])
            }
          } ?? 0
        visibilitySamples.record(count)
      }
    )

    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let diagnostics = FakeDiagnosticsRecording()
    let appLifecycle = FakeAppLifecycle()
    let clock = FakeSyncClock()

    let engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: diagnostics,
      appLifecycle: appLifecycle,
      clock: clock,
      randomSource: { 1.0 },
      pageLimit: pageLimit
    )

    await engine.refresh()

    // (a) every item-list request carried a bounded, present limit/page, never an unpaginated
    // sweep. `LibraryItemsBounds` is ABSApi's own client-side bound (internal, via
    // `@testable import`), keeping this anchored to the production constant.
    #expect(http.boundsViolations.isEmpty, "\(http.boundsViolations)")

    // The traversal actually reached every item.
    let libraryRowId = try #require(
      try libraryDAO.fetchOneAccessible(accountId: accountId, serverLibraryId: "lib-large")?.id)
    let finalItems = try itemDAO.fetchBrowseList(libraryId: libraryRowId)
    #expect(finalItems.count == totalItems)

    // (b) progressive, monotonic visibility across many intermediate snapshots, not one final
    // jump from 0 to 8,000.
    let samples = visibilitySamples.all
    #expect(samples.count == totalItems / pageLimit)
    #expect(samples == samples.sorted())
    #expect(Set(samples).count > 2)
    #expect(samples.first == 0)
    #expect(samples.last == totalItems - pageLimit)

    // (c) the fake never handed out more than one page of item data at a time.
    #expect(http.maxOutstandingPageHandouts <= 1)

    // (d) writes happened, and never on the main thread.
    #expect(threadObserver.changeCount > 0)
    #expect(threadObserver.mainThreadChangeCount == 0)
  }
}

/// Vends an 8,000-item library page by page, computed on demand from arithmetic (never
/// pre-materialized as one big collection), so the test itself cannot cheat its own memory-bound
/// assertion. Every non-item-list route the refresh touches is served a minimal canned response.
// Stays: it is the scenario (arithmetic page generation plus outstanding-handout and bounds
// tracking that the test asserts on), not a canned-response stub FakeHTTPClient could replace.
private final class SyntheticLibraryHTTPClient: HTTPClienting, @unchecked Sendable {
  private let libraryId: String
  private let totalItems: Int
  private let onItemsRequested: @Sendable () -> Void

  private let lock = NSLock()
  private var storedBoundsViolations: [String] = []
  private var outstandingHandouts = 0
  private var storedMaxOutstandingHandouts = 0

  var boundsViolations: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedBoundsViolations
  }

  var maxOutstandingPageHandouts: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedMaxOutstandingHandouts
  }

  init(libraryId: String, totalItems: Int, onItemsRequested: @escaping @Sendable () -> Void) {
    self.libraryId = libraryId
    self.totalItems = totalItems
    self.onItemsRequested = onItemsRequested
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    switch request.routeTemplate {
    case "/api/libraries":
      return Self.jsonResponse(object: [
        "libraries": [["id": libraryId, "name": "Large Library", "mediaType": "book"]]
      ])
    case "/api/me":
      return Self.jsonResponse(object: ["mediaProgresses": []])
    case "/api/libraries/:id/items":
      return try serveItemsPage(request)
    default:
      throw SyntheticFakeError.unexpectedRoute(request.routeTemplate)
    }
  }

  private func serveItemsPage(_ request: HTTPRequest) throws -> HTTPResponse {
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

    // Every request must carry a positive, bounded `limit` and a non-negative `page`. This is
    // the fake's own hard gate (throws rather than silently tolerating), anchored to the same
    // `LibraryItemsBounds.maximum` ABSApi's client already clamps to.
    guard
      let limitString = value("limit"), let limit = Int(limitString), limit > 0,
      limit <= LibraryItemsBounds.maximum,
      let pageString = value("page"), let page = Int(pageString), page >= 0
    else {
      let message = "unbounded or missing limit/page on request: \(request.url.absoluteString)"
      lock.lock()
      storedBoundsViolations.append(message)
      lock.unlock()
      throw SyntheticFakeError.unboundedRequest(message)
    }

    onItemsRequested()

    lock.lock()
    outstandingHandouts += 1
    storedMaxOutstandingHandouts = max(storedMaxOutstandingHandouts, outstandingHandouts)
    lock.unlock()
    defer {
      lock.lock()
      outstandingHandouts -= 1
      lock.unlock()
    }

    let start = page * limit
    let end = min(start + limit, totalItems)
    let items: [[String: Any]] =
      start < end
      ? (start..<end).map { index in
        let id = String(format: "item-%05d", index)
        return [
          "id": id,
          "libraryId": libraryId,
          "mediaType": "book",
          "media": ["metadata": ["title": "Title \(index)", "authorName": "Author \(index % 37)"]],
        ]
      } : []

    return Self.jsonResponse(object: [
      "results": items,
      "total": totalItems,
      "limit": limit,
      "page": page,
    ])
  }

  private static func jsonResponse(object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object)
    )
  }
}

private enum SyntheticFakeError: Error, Equatable {
  case unboundedRequest(String)
  case unexpectedRoute(String)
}

/// Records which thread every `item`-table write event lands on, via GRDB's own transaction
/// observer seam (`database.dbWriter.add(transactionObserver:)`) rather than any production
/// instrumentation.
private final class MainThreadRecordingObserver: TransactionObserver, @unchecked Sendable {
  private let lock = NSLock()
  private var storedChangeCount = 0
  private var storedMainThreadChangeCount = 0

  var changeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedChangeCount
  }

  var mainThreadChangeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedMainThreadChangeCount
  }

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    eventKind.tableName == "item"
  }

  func databaseDidChange(with event: DatabaseEvent) {
    lock.lock()
    storedChangeCount += 1
    if Thread.isMainThread {
      storedMainThreadChangeCount += 1
    }
    lock.unlock()
  }

  func databaseDidCommit(_ db: Database) {}
  func databaseDidRollback(_ db: Database) {}
}

/// Thread-safe accumulator for the progressive-visibility samples.
private final class SampleRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Int] = []

  func record(_ value: Int) {
    lock.lock()
    samples.append(value)
    lock.unlock()
  }

  var all: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return samples
  }
}
