import ABSApi
import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Each bookmark kind's drain leg against the server's 2xx, 404, 403 and transport outcomes.
@Suite("Outbox drainer: audio bookmarks")
struct OutboxDrainerAudioBookmarkTests {
  private static let item = "item_book"
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  enum Kind: String, CaseIterable, Sendable {
    case create, rename, delete
  }

  enum Expected: Equatable, Sendable {
    case acknowledged
    case deadLetter(String)
    case retryWaiting
  }

  struct Case: Sendable, CustomTestStringConvertible {
    let kind: Kind
    let answer: Answer
    let expected: Expected

    init(_ kind: Kind, _ answer: Answer, _ expected: Expected) {
      self.kind = kind
      self.answer = answer
      self.expected = expected
    }

    var testDescription: String { "\(kind.rawValue) answered \(answer)" }
  }

  @Test(
    "each kind's outcome for each server answer",
    arguments: [
      Case(.create, .status(200), .acknowledged),
      Case(.create, .status(404), .deadLetter("notFound")),
      Case(.create, .status(403), .deadLetter("forbidden")),
      Case(.create, .transport, .retryWaiting),
      Case(.rename, .status(200), .acknowledged),
      Case(.rename, .status(404), .acknowledged),
      Case(.rename, .status(403), .deadLetter("forbidden")),
      Case(.rename, .transport, .retryWaiting),
      Case(.delete, .status(200), .acknowledged),
      Case(.delete, .status(404), .acknowledged),
      Case(.delete, .status(403), .deadLetter("forbidden")),
      Case(.delete, .transport, .retryWaiting),
    ])
  func outcomes(_ testCase: Case) async throws {
    let (kind, answer, expected) = (testCase.kind, testCase.answer, testCase.expected)
    let harness = try await Harness()
    try await harness.queue(kind, time: 30)
    harness.answer(answer)

    await harness.drainer.drainOutbox(now: Self.now, randomUnit: { 0 })

    let rows = try await harness.outboxRows()
    switch expected {
    case .acknowledged:
      #expect(rows.isEmpty)
    case .deadLetter(let reason):
      #expect(rows.map(\.state) == [.deadLetter])
      #expect(rows.first?.deadLetterReason == reason)
    case .retryWaiting:
      #expect(rows.map(\.state) == [.retryWaiting])
    }
    let request = try #require(harness.http.requests.first)
    #expect(harness.http.requests.count == 1)
    switch kind {
    case .create:
      #expect(request.method == .post)
      #expect(request.url.path == "/api/me/item/\(Self.item)/bookmark")
    case .rename:
      #expect(request.method == .patch)
      #expect(request.url.path == "/api/me/item/\(Self.item)/bookmark")
    case .delete:
      #expect(request.method == .delete)
      #expect(request.url.path == "/api/me/item/\(Self.item)/bookmark/30.0")
    }
  }

  @Test("a create replayed after a lost response is sent again unchanged and acknowledged")
  func replayedCreateIsAcknowledged() async throws {
    let harness = try await Harness()
    try await harness.queue(.create, time: 30)
    harness.answer(.transport)
    await harness.drainer.drainOutbox(now: Self.now, randomUnit: { 0 })
    #expect(try await harness.outboxRows().map(\.state) == [.retryWaiting])

    // The server upserts: the replay of a create that did land answers 200 like the first.
    harness.answer(.status(200))
    await harness.drainer.drainOutbox(now: Self.now.addingTimeInterval(3_600), randomUnit: { 0 })

    #expect(try await harness.outboxRows().isEmpty)
    let bodies = harness.http.requests.map(\.body)
    #expect(bodies.count == 2)
    #expect(bodies[0] == bodies[1])
    #expect(bodies[0].map { String(decoding: $0, as: UTF8.self) } == #"{"time":30,"title":"Title"}"#)
  }

  @Test("a delete sends a server-made fractional time back exactly")
  func deleteSendsFractionalTimeExactly() async throws {
    let harness = try await Harness()
    try await harness.queue(.delete, time: 1234.567)
    harness.answer(.status(200))

    await harness.drainer.drainOutbox(now: Self.now, randomUnit: { 0 })

    #expect(harness.http.requests.first?.url.path == "/api/me/item/\(Self.item)/bookmark/1234.567")
    #expect(harness.http.requests.first?.routeTemplate == "/api/me/item/:id/bookmark/:time")
  }

  @Test("a bookmark row behind a progress row on the same item drains in the same pass")
  func sharesTheItemQueue() async throws {
    let harness = try await Harness()
    _ = try harness.store.enqueueContinueListeningVisibility(
      accountId: harness.accountId, entityKey: Self.item, podcastEpisodeId: nil, localSequence: 0,
      hideFromContinueListening: true)
    try await harness.queue(.create, time: 30)
    harness.answer(.status(200))
    harness.answer(.status(200))

    await harness.drainer.drainOutbox(now: Self.now, randomUnit: { 0 })

    #expect(try await harness.outboxRows().isEmpty)
    #expect(harness.http.requests.map(\.method) == [.patch, .post])
  }

  @Test("a dead-lettered create leaves the bookmark visible until a complete pull")
  func deadLetteredCreateKeepsLocalRow() async throws {
    let harness = try await Harness()
    try await harness.queue(.create, time: 30)
    harness.answer(.status(404))

    await harness.drainer.drainOutbox(now: Self.now, randomUnit: { 0 })

    let bookmarks = try harness.bookmarks.bookmarks(accountId: harness.accountId, serverItemId: Self.item)
    #expect(bookmarks.map(\.time) == [30])
  }

  // MARK: - Harness

  enum Answer: Sendable, CustomStringConvertible {
    case status(Int)
    case transport

    var description: String {
      switch self {
      case .status(let code): "\(code)"
      case .transport: "transport"
      }
    }
  }

  private struct Harness {
    let database: AppDatabase
    let accountId: Int64
    let store: OutboxStore
    let bookmarks: AudioBookmarkStore
    let http = FakeHTTPClient()
    let drainer: OutboxDrainer

    init() async throws {
      database = try AppDatabase.inMemory()
      let clientUUID = "fixture-client"
      accountId = try await database.writeAsync { db -> Int64 in
        var account = AccountRecord(
          clientUUID: clientUUID, serverBaseURL: "https://books.example.test",
          serverUserId: "fixture-user", serverVersion: "2.35.1")
        try account.insert(db)
        return account.id!
      }
      let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
      let account = try TokenAccount(
        credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID),
        userID: "fixture-user")
      let tokenStore = InMemoryTokenStore()
      try tokenStore.save(
        TokenPair(accessToken: "fixture-access", refreshToken: "fixture-refresh"), for: account)
      let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
      store = try OutboxStore(database: database)
      bookmarks = AudioBookmarkStore(database: database)
      drainer = OutboxDrainer(
        outboxStore: store, database: database, absClient: client, account: account,
        accountId: accountId, diagnostics: FakeDiagnosticsRecording())
    }

    func queue(_ kind: Kind, time: Double) async throws {
      if kind != .create {
        try await bookmarks.applyServerBookmarks(
          accountId: accountId,
          [
            AudioBookmark(
              serverItemID: OutboxDrainerAudioBookmarkTests.item, time: time, title: "Server",
              createdAt: nil)
          ],
          isComplete: false)
      }
      let item = OutboxDrainerAudioBookmarkTests.item
      switch kind {
      case .create:
        _ = try await bookmarks.create(
          accountId: accountId, serverItemId: item, time: time, title: "Title",
          createdAt: OutboxDrainerAudioBookmarkTests.now)
      case .rename:
        try await bookmarks.rename(accountId: accountId, serverItemId: item, time: time, title: "Title")
      case .delete:
        try await bookmarks.delete(accountId: accountId, serverItemId: item, time: time)
      }
    }

    func answer(_ answer: Answer) {
      switch answer {
      case .status(let code):
        http.enqueue(HTTPResponse(statusCode: code, headers: [:], body: Data()))
      case .transport:
        http.enqueueFailure(URLError(.notConnectedToInternet))
      }
    }

    func outboxRows() async throws -> [OutboxOperationRecord] {
      try await database.readAsync { db in
        try OutboxOperationRecord.order(Column("id")).fetchAll(db)
      }
    }
  }
}
