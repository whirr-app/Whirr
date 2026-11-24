import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Collections and playlists service.
@Suite(.timeLimit(.minutes(1))) struct LibraryCollectionServiceTests {
  @Test func bookLibraryAsksForBothKindsAndPodcastLibraryOnlyForPlaylists() async throws {
    let harness = try await Harness(libraries: [("books", "book"), ("pods", "podcast")])
    harness.http.enqueue(page([list("col")]))
    harness.http.enqueue(page([list("pl-book")]))
    harness.http.enqueue(page([list("pl-pod", episode: true)]))

    await harness.service.refreshAll(force: true)

    #expect(
      harness.http.requests.map(\.routeTemplate) == [
        "/api/libraries/:id/collections", "/api/libraries/:id/playlists",
        "/api/libraries/:id/playlists",
      ])
    #expect(harness.http.requests.map(\.url.path).last == "/api/libraries/pods/playlists")
    let stored = await harness.store.listings(accountID: harness.accountID).map(\.key.serverID)
    #expect(Set(stored) == ["col", "pl-book", "pl-pod"])
  }

  @Test func walksPagesUntilTotalAndStoresInOrder() async throws {
    let harness = try await Harness(pageSize: 2)
    harness.http.enqueue(page([list("a"), list("b")], total: 3, limit: 2))
    harness.http.enqueue(page([list("c")], total: 3, limit: 2, page: 1))

    let outcome = try await harness.service.refresh(libraryID: "books", kind: .collection)

    #expect(outcome == .replaced(listCount: 3))
    #expect(Self.queryPages(harness.http) == ["0", "1"])
  }

  @Test func fullLastPageStopsAtTotalWithoutAnExtraRequest() async throws {
    let harness = try await Harness(pageSize: 2)
    harness.http.enqueue(page([list("a"), list("b")], total: 2, limit: 2))

    let outcome = try await harness.service.refresh(libraryID: "books", kind: .collection)

    #expect(outcome == .replaced(listCount: 2))
    #expect(harness.http.requests.count == 1)
  }

  @Test(
    "an incomplete walk is lossy and keeps the old rows",
    arguments: LossyCase.allCases)
  func lossyPassKeepsRows(_ lossy: LossyCase) async throws {
    let harness = try await Harness(pageSize: 2)
    harness.http.enqueue(page([list("old")]))
    _ = try await harness.service.refresh(libraryID: "books", kind: .collection)

    for response in lossy.responses { harness.http.enqueue(response) }
    let outcome = try await harness.service.refresh(libraryID: "books", kind: .collection)

    #expect(outcome == .lossy)
    #expect(await harness.store.listings(accountID: harness.accountID).map(\.key.serverID) == ["old"])
  }

  @Test func transportFailureKeepsRowsAndDoesNotStopSiblings() async throws {
    let harness = try await Harness(libraries: [("books", "book"), ("more", "book")])
    harness.http.enqueue(page([list("old")]))
    _ = try await harness.service.refresh(libraryID: "books", kind: .collection)

    harness.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))
    harness.http.enqueue(page([]))  // books playlists
    harness.http.enqueue(page([list("more-col")]))
    harness.http.enqueue(page([]))
    await harness.service.refreshAll(force: true)

    let stored = await harness.store.listings(accountID: harness.accountID).map(\.key.serverID)
    #expect(Set(stored) == ["old", "more-col"])
  }

  @Test func unforcedRefreshSkipsKindsThatAlreadyHaveASnapshot() async throws {
    let harness = try await Harness()
    harness.http.enqueue(page([list("col")]))
    _ = try await harness.service.refresh(libraryID: "books", kind: .collection)
    harness.http.enqueue(page([]))

    await harness.service.refreshAll(force: false)

    #expect(harness.http.requests.last?.routeTemplate == "/api/libraries/:id/playlists")
    #expect(harness.http.requests.count == 2)
  }

  @Test func overlappingCallersShareOneFlightPerLibraryAndKind() async throws {
    let joined = AsyncStream<Void>.makeStream()
    let harness = try await Harness(flightJoined: { joined.continuation.yield() })
    let gate = TestGate<Void>(label: "refresh request", ignoresCancellation: true)
    gate.hold()
    harness.http.setRequestHook { _ in await gate.pass() }
    harness.http.enqueue(page([list("col")]))
    harness.http.enqueue(page([list("col")]))

    let first = Task { try await harness.service.refresh(libraryID: "books", kind: .collection) }
    await harness.http.waitForRequests { $0.count == 1 }
    let second = Task { try await harness.service.refresh(libraryID: "books", kind: .collection) }
    var joins = joined.stream.makeAsyncIterator()
    _ = await joins.next()
    gate.release()

    #expect(
      try await [first.value, second.value] == [.replaced(listCount: 1), .replaced(listCount: 1)])
    #expect(harness.http.requests.count == 1)
  }

  // MARK: - Lossy cases

  enum LossyCase: String, CaseIterable, Sendable {
    case repeatedID, changedTotal, shortDeduplicatedCount, droppedElement

    var responses: [HTTPResponse] {
      switch self {
      case .repeatedID:
        [
          page([list("a"), list("b")], total: 3, limit: 2),
          page([list("b")], total: 3, limit: 2, page: 1),
        ]
      case .changedTotal:
        [
          page([list("a"), list("b")], total: 3, limit: 2),
          page([list("c")], total: 4, limit: 2, page: 1),
        ]
      case .shortDeduplicatedCount:
        [page([list("a")], total: 3, limit: 2)]
      case .droppedElement:
        [
          HTTPResponse(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: try! JSONSerialization.data(withJSONObject: [
              "results": [["id": "a", "books": [["no": "id"]]]], "total": 1, "limit": 2,
              "page": 0,
            ]))
        ]
      }
    }
  }

  // MARK: - Fixture

  private static func queryPages(_ http: FakeHTTPClient) -> [String] {
    http.requests.compactMap { request in
      URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "page" }?.value
    }
  }

  private final class Harness: @unchecked Sendable {
    let http = FakeHTTPClient()
    let service: LibraryCollectionService
    let store: LibraryCollectionStore
    let accountID: Int64

    init(
      libraries: [(id: String, mediaType: String)] = [("books", "book")], pageSize: Int = 20,
      flightJoined: (@Sendable () -> Void)? = nil
    ) async throws {
      let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
      let tokenStore = InMemoryTokenStore()
      let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
      let database = try AppDatabase.inMemory()
      let accountRecord = try await database.writeAsync { db in
        var record = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: server.baseURL.absoluteString,
          serverUserId: "user_fixture", serverVersion: "2.35.1")
        try record.save(db)
        for library in libraries {
          var row = LibraryRecord(
            accountId: record.id!, serverLibraryId: library.id, mediaType: library.mediaType,
            name: library.id, isIncluded: true)
          try row.insert(db)
        }
        return record
      }
      try tokenStore.save(
        TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"),
        for: try accountRecord.credentialTokenAccount)
      accountID = try #require(accountRecord.id)
      store = LibraryCollectionStore(database: database)
      service = LibraryCollectionService(
        database: database, client: client, pageSize: pageSize, flightJoined: flightJoined)
    }
  }
}

private func list(_ id: String, episode: Bool = false) -> [String: Any] {
  episode
    ? ["id": id, "name": id, "items": [["libraryItemId": "show", "episodeId": "ep"]]]
    : ["id": id, "name": id, "books": [["id": "book-\(id)"]]]
}

private func page(
  _ results: [[String: Any]], total: Int? = nil, limit: Int = 20, page: Int = 0
) -> HTTPResponse {
  HTTPResponse(
    statusCode: 200, headers: ["Content-Type": "application/json"],
    body: try! JSONSerialization.data(withJSONObject: [
      "results": results, "total": total ?? results.count, "limit": limit, "page": page,
    ]))
}
