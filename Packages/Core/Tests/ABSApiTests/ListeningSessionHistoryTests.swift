import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /api/me/listening-sessions` (API-CONVENTIONS.md). The server returns closed-session history
/// only. A page-fetch primitive, mirroring `listLibraryItems`; per-item filtering and pagination
/// traversal are `SyncEngine`'s job.
@Suite("Listening-session history endpoint")
struct ListeningSessionHistoryTests {

  @Test("GETs the per-item listening-session route with its route template and auth")
  func fetchesItemHistoryPage() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "listening-sessions-response"))]
    )

    let page = try await client.fetchItemListeningSessionHistory(
      account: account, itemID: "item_book_fixture", page: 2, itemsPerPage: 50)

    #expect(http.requests[0].url.path == "/api/me/item/listening-sessions/item_book_fixture")
    #expect(http.requests[0].routeTemplate == "/api/me/item/listening-sessions/:libraryItemId")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")
    let query = try #require(URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "page" }?.value == "2")
    #expect(query.first { $0.name == "itemsPerPage" }?.value == "50")
    #expect(page.entries.count == 3)
    #expect(page.page == 2)
    #expect(page.itemsPerPage == 50)
  }

  @Test("uses the episode segment and route template when supplied")
  func fetchesEpisodeHistoryPage() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "listening-sessions-response"))]
    )

    _ = try await client.fetchItemListeningSessionHistory(
      account: account, itemID: "show-1", episodeID: "episode-1")

    #expect(http.requests[0].url.path == "/api/me/item/listening-sessions/show-1/episode-1")
    #expect(http.requests[0].routeTemplate == "/api/me/item/listening-sessions/:libraryItemId/:episodeId")
  }

  @Test("bounds an item route itemsPerPage request")
  func boundsItemHistoryPageSize() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "listening-sessions-response"))]
    )

    let page = try await client.fetchItemListeningSessionHistory(
      account: account, itemID: "item-1", itemsPerPage: ListeningSessionHistoryBounds.maximum + 50)

    let query = try #require(URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "itemsPerPage" }?.value == String(ListeningSessionHistoryBounds.maximum))
    #expect(page.itemsPerPage == ListeningSessionHistoryBounds.maximum)
  }

  @Test("surfaces a per-item 404")
  func itemHistoryNotFoundIsNotSwallowed() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await #expect(throws: APIError.notFound) {
      try await client.fetchItemListeningSessionHistory(account: account, itemID: "missing")
    }
  }

  @Test("GETs /api/me/listening-sessions with page/itemsPerPage query params and decodes entries")
  func fetchesAndDecodesHistoryPage() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "listening-sessions-response"))]
    )

    let page = try await client.fetchListeningSessionHistory(account: account, page: 0, itemsPerPage: 50)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .get)
    #expect(http.requests[0].url.path == "/api/me/listening-sessions")
    #expect(http.requests[0].routeTemplate == "/api/me/listening-sessions")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")

    let query = try #require(URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "page" }?.value == "0")
    #expect(query.first { $0.name == "itemsPerPage" }?.value == "50")

    #expect(page.total == 3)
    #expect(page.entries.count == 3)

    let first = try #require(page.entries.first)
    #expect(first.id == "history_session_1")
    #expect(first.libraryItemID == "item_book_fixture")
    #expect(first.episodeID == nil)
    #expect(first.startTime == 0)
    #expect(first.currentTime == 542.5)
    #expect(first.timeListening == 542.5)
    #expect(first.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(first.updatedAt == Date(timeIntervalSince1970: 1_700_000_600))

    // Entries for other items are still decoded here; client-side filtering is SyncEngine's job.
    #expect(page.entries.map(\.libraryItemID) == ["item_book_fixture", "item_book_fixture", "item_other_fixture"])
  }

  @Test("bounds a requested itemsPerPage into the client-side maximum")
  func boundsRequestedItemsPerPage() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "listening-sessions-response"))]
    )

    let page = try await client.fetchListeningSessionHistory(
      account: account, page: 0, itemsPerPage: ListeningSessionHistoryBounds.maximum + 50)

    let query = try #require(URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "itemsPerPage" }?.value == String(ListeningSessionHistoryBounds.maximum))
    #expect(page.itemsPerPage == ListeningSessionHistoryBounds.maximum)
  }

  @Test("drops a session element with no id while keeping the well-formed ones (lossy, never throws)")
  func dropsElementMissingIdLossily() async throws {
    let envelope: [String: Any] = [
      "sessions": [
        ["id": "history_session_1", "libraryItemId": "item_book_fixture"],
        ["libraryItemId": "item_book_fixture"],
        ["id": "history_session_2", "libraryItemId": "item_book_fixture"],
      ],
      "total": 3,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.fetchListeningSessionHistory(account: account)

    #expect(page.entries.map(\.id) == ["history_session_1", "history_session_2"])
  }

  @Test("drops a session element whose id exceeds the string bound, keeping the rest")
  func dropsOversizedIdLossily() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "sessions": [
        ["id": "history_session_1", "libraryItemId": "item_book_fixture"],
        [
          "id": String(repeating: "x", count: limit + 1),
          "libraryItemId": "item_book_fixture",
        ],
        ["id": "history_session_2", "libraryItemId": "item_book_fixture"],
      ],
      "total": 3,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.fetchListeningSessionHistory(account: account)

    #expect(page.entries.map(\.id) == ["history_session_1", "history_session_2"])
  }

  @Test("an oversized libraryItemId decodes as nil so the entry matches no item")
  func oversizedLibraryItemIdDecodesAsNil() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "sessions": [
        [
          "id": "history_session_1",
          "libraryItemId": String(repeating: "x", count: limit + 1),
        ]
      ],
      "total": 1,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.fetchListeningSessionHistory(account: account)

    let entry = try #require(page.entries.first)
    #expect(entry.id == "history_session_1")
    #expect(entry.libraryItemID == nil)
  }

  @Test("degrades a missing/malformed total to 0 rather than throwing (lenient decoding)")
  func degradesMissingTotalToZero() async throws {
    let envelope: [String: Any] = ["sessions": [[String: Any]]()]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.fetchListeningSessionHistory(account: account)

    #expect(page.total == 0)
    #expect(page.entries.isEmpty)
  }

  @Test("throws when a present sessions array has the wrong top-level type")
  func throwsForWrongTypeSessionsArray() async throws {
    let envelope: [String: Any] = ["sessions": "not-an-array", "total": 0]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.fetchListeningSessionHistory(account: account)
    }
  }

  enum SessionsArrayPresenceState: String, CaseIterable {
    case absent, null
  }

  @Test(
    "treats an absent or null sessions array as an empty page",
    arguments: SessionsArrayPresenceState.allCases
  )
  func treatsMissingOrNullSessionsArrayAsEmpty(state: SessionsArrayPresenceState) async throws {
    var envelope: [String: Any] = ["total": 0]
    if state == .null {
      envelope["sessions"] = NSNull()
    }
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.fetchListeningSessionHistory(account: account)

    #expect(page.entries.isEmpty)
  }
}

private func makeClient(
  responses: [HTTPResponse]
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(responses: responses, serverURL: serverURL)
}

private func jsonResponse(object: Any) throws -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: try JSONSerialization.data(withJSONObject: object)
  )
}

private func jsonResponse(data: Data) -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
}
