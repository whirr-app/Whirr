import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Both playback-session status routes (API-CONVENTIONS.md rule 6a).
///
/// `GET /api/session/{id}` (live-confirmed: `200` while open, `404` once closed) is the reliable
/// lost-close recovery path, paired with persisting the session id as soon as `/play` returns
/// `200`.
///
/// `GET /api/sessions/open` is a best-effort supplement: it 404s for a normal account on the
/// tested server version, so `fetchOpenPlaybackSessions` treats `404` as an empty "no info"
/// result. Nothing may depend on it for correctness; other failure statuses still propagate.
@Suite("Playback session status endpoint")
struct PlaybackSessionStatusTests {

  @Test("GETs /api/session/{id} and decodes an open session")
  func fetchesOpenSession() async throws {
    let (client, http, account) = try makeStatusClient(
      responses: [jsonResponse(data: Fixtures.data(named: "session-play-response"))]
    )

    let session = try await client.fetchPlaybackSession(account: account, sessionID: "session_fixture")

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .get)
    #expect(http.requests[0].url.path == "/api/session/session_fixture")
    #expect(http.requests[0].routeTemplate == "/api/session/:id")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")
    #expect(session?.id == "session_fixture")
  }

  @Test("treats a 404 as an absent session rather than throwing")
  func treatsNotFoundAsAbsentSession() async throws {
    let (client, http, account) = try makeStatusClient(
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())]
    )

    let session = try await client.fetchPlaybackSession(account: account, sessionID: "session_fixture")

    #expect(session == nil)
    #expect(http.requests.count == 1)
  }

  @Test("still throws for a non-404 failure status rather than treating it as absent")
  func propagatesOtherFailureStatuses() async throws {
    let (client, _, account) = try makeStatusClient(
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())]
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      try await client.fetchPlaybackSession(account: account, sessionID: "session_fixture")
    }
  }

  @Test("preserves the session's deviceId, echoed back inside the response's deviceInfo")
  func preservesDeviceID() async throws {
    let (client, _, account) = try makeStatusClient(
      responses: [jsonResponse(data: Fixtures.data(named: "session-play-response"))]
    )

    let session = try await client.fetchPlaybackSession(account: account, sessionID: "session_fixture")

    #expect(session?.deviceID == "device_id_fixture")
  }

  @Test("decodes with no deviceId, rather than throwing, when deviceInfo is absent")
  func toleratesMissingDeviceInfo() async throws {
    let envelope: [String: Any] = [
      "id": "session_fixture",
      "audioTracks": [
        ["contentUrl": "/api/items/item_book_fixture/file/101"]
      ],
    ]
    let (client, _, account) = try makeStatusClient(responses: [jsonResponse(object: envelope)])

    let session = try await client.fetchPlaybackSession(account: account, sessionID: "session_fixture")

    #expect(session?.deviceID == nil)
  }

  @Test("decodes with no deviceId, rather than throwing, when deviceInfo is a hostile shape")
  func toleratesHostileDeviceInfoShape() async throws {
    let envelope: [String: Any] = [
      "id": "session_fixture",
      "audioTracks": [
        ["contentUrl": "/api/items/item_book_fixture/file/101"]
      ],
      "deviceInfo": "not-an-object",
    ]
    let (client, _, account) = try makeStatusClient(responses: [jsonResponse(object: envelope)])

    let session = try await client.fetchPlaybackSession(account: account, sessionID: "session_fixture")

    #expect(session?.deviceID == nil)
  }

  @Test("throws a decoding error when a fetched session id exceeds the string bound")
  func throwsWhenFetchedSessionIdIsOversized() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "id": String(repeating: "x", count: limit + 1),
      "audioTracks": [["contentUrl": "/api/items/item_book_fixture/file/101"]],
    ]
    let (client, _, account) = try makeStatusClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.fetchPlaybackSession(account: account, sessionID: "session_fixture")
    }
  }

  // MARK: - GET /api/sessions/open (best-effort list)

  @Test("GETs /api/sessions/open and decodes a bounded, ordered list of open sessions")
  func fetchesOpenSessionList() async throws {
    let envelope: [String: Any] = [
      "sessions": [
        [
          "id": "session_one",
          "audioTracks": [["contentUrl": "/api/items/item_one/file/1"]],
          "deviceInfo": ["deviceId": "device_one"],
        ],
        [
          "id": "session_two",
          "audioTracks": [["contentUrl": "/api/items/item_two/file/1"]],
          "deviceInfo": ["deviceId": "device_two"],
        ],
      ]
    ]
    let (client, http, account) = try makeStatusClient(responses: [jsonResponse(object: envelope)])

    let sessions = try await client.fetchOpenPlaybackSessions(account: account)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .get)
    #expect(http.requests[0].url.path == "/api/sessions/open")
    #expect(http.requests[0].routeTemplate == "/api/sessions/open")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")
    // Order is preserved and each element's deviceId round-trips across the list, not just for
    // a single session.
    #expect(sessions.map(\.id) == ["session_one", "session_two"])
    #expect(sessions.map(\.deviceID) == ["device_one", "device_two"])
  }

  @Test("drops an open session whose id exceeds the string bound, keeping the rest")
  func dropsOversizedOpenSessionId() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "sessions": [
        ["id": "session_one", "audioTracks": [["contentUrl": "/api/items/item_one/file/1"]]],
        [
          "id": String(repeating: "x", count: limit + 1),
          "audioTracks": [["contentUrl": "/api/items/item_two/file/1"]],
        ],
        ["id": "session_three", "audioTracks": [["contentUrl": "/api/items/item_three/file/1"]]],
      ]
    ]
    let (client, _, account) = try makeStatusClient(responses: [jsonResponse(object: envelope)])

    let sessions = try await client.fetchOpenPlaybackSessions(account: account)

    #expect(sessions.map(\.id) == ["session_one", "session_three"])
  }

  @Test("treats a 404 as a successful empty best-effort result, never throwing")
  func treatsNotFoundAsEmptyBestEffortList() async throws {
    let (client, http, account) = try makeStatusClient(
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())]
    )

    let sessions = try await client.fetchOpenPlaybackSessions(account: account)

    #expect(sessions.isEmpty)
    #expect(http.requests.count == 1)
  }

  @Test("still propagates a 500 rather than folding it into the best-effort empty result")
  func propagatesServerFailureFromOpenList() async throws {
    let (client, _, account) = try makeStatusClient(
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())]
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      try await client.fetchOpenPlaybackSessions(account: account)
    }
  }

  @Test("still propagates unauthorized (after a failed retry) rather than folding it into best-effort empty")
  func propagatesUnauthorizedFromOpenList() async throws {
    let (client, http, account) = try makeStatusClient(
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ]
    )

    await #expect(throws: APIError.unauthorized) {
      try await client.fetchOpenPlaybackSessions(account: account)
    }
    #expect(http.requests.count == 3)
  }

  @Test("drops a structurally malformed element and one missing an id or usable stream, keeping valid ones")
  func dropsMalformedListElementsLossily() async throws {
    let envelope: [String: Any] = [
      "sessions": [
        ["id": "session_one", "audioTracks": [["contentUrl": "/api/items/item_one/file/1"]]],
        "not-an-object",
        ["id": "session_missing_stream"],
        ["audioTracks": [["contentUrl": "/api/items/item_missing_id/file/1"]]],
        ["id": "session_four", "audioTracks": [["contentUrl": "/api/items/item_four/file/1"]]],
      ]
    ]
    let (client, _, account) = try makeStatusClient(responses: [jsonResponse(object: envelope)])

    let sessions = try await client.fetchOpenPlaybackSessions(account: account)

    #expect(sessions.map(\.id) == ["session_one", "session_four"])
  }

  @Test("stops decoding once the bounded maximum element count is reached")
  func enforcesBoundOnOpenSessionListElementCount() async throws {
    let overflow = OpenPlaybackSessionListBounds.maximum + 5
    let envelope: [String: Any] = [
      "sessions": (0..<overflow).map { index in
        ["id": "session_\(index)", "audioTracks": [["contentUrl": "/api/items/item_\(index)/file/1"]]]
      }
    ]
    let (client, _, account) = try makeStatusClient(responses: [jsonResponse(object: envelope)])

    let sessions = try await client.fetchOpenPlaybackSessions(account: account)

    #expect(sessions.count == OpenPlaybackSessionListBounds.maximum)
    #expect(sessions.map(\.id) == (0..<OpenPlaybackSessionListBounds.maximum).map { "session_\($0)" })
  }
}

// Duplicated from SessionTests.swift's private helpers rather than widening that file's
// visibility.
private func makeStatusClient(
  responses: [HTTPResponse]
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
  let account = try TokenAccount(server: server, userID: "user_fixture")
  let store = InMemoryTokenStore()
  try store.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
  let http = FakeHTTPClient(responses: responses)
  let client = ABSClient(server: server, httpClient: http, tokenStore: store)
  return (client, http, account)
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

// Duplicated from RefreshTests.swift's private helper rather than widening that file's
// visibility.
private func makeRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}
