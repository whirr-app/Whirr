import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /api/libraries/{id}/authors` and `GET /api/libraries/{id}/series`, the two
/// navigable-entity listing routes an author/series search hit lands on.
@Suite("Author/series listing endpoints")
struct AuthorSeriesEndpointTests {

  @Test("library filter data returns the complete author and series indexes")
  func decodesLibraryFilterData() async throws {
    let response: [String: Any] = [
      "authors": [["id": "author_fixture", "name": "Fixture Author"]],
      "series": [["id": "series_fixture", "name": "Fixture Series"]],
      "genres": [],
      "tags": [],
    ]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: response)])

    let data = try await client.getLibraryFilterData(
      account: account, library: "library_book_fixture")

    #expect(
      data.authors == [
        LibraryAuthorSummary(id: "author_fixture", name: "Fixture Author", numBooks: nil)
      ])
    #expect(
      data.series == [
        LibrarySeriesSummary(id: "series_fixture", name: "Fixture Series")
      ])
    #expect(http.requests.first?.url.path == "/api/libraries/library_book_fixture/filterdata")
    #expect(http.requests.first?.routeTemplate == "/api/libraries/:id/filterdata")
  }

  // MARK: - Authors

  @Test("requests authors with the correct path, method, auth, and bounded limit/page")
  func requestsAuthorsCorrectly() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(object: ["authors": []])]
    )

    _ = try await client.listLibraryAuthors(
      account: account, library: "library_book_fixture", limit: 40, page: 2
    )

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .get)
    #expect(request.url.path == "/api/libraries/library_book_fixture/authors")
    #expect(request.routeTemplate == "/api/libraries/:id/authors")
    #expect(request.headers["Authorization"] == "Bearer canary-access")
    let query = queryItems(of: request)
    #expect(query["limit"] == "40")
    #expect(query["page"] == "2")
  }

  @Test("decodes the authors bucket leniently, keeping id/name/numBooks")
  func decodesAuthorsBucket() async throws {
    let envelope: [String: Any] = [
      "authors": [
        ["id": "author_fixture", "asin": "B0FIXTURE", "name": "Fixture Author", "numBooks": 3]
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryAuthors(account: account, library: "library_book_fixture")

    #expect(page.authors == [LibraryAuthorSummary(id: "author_fixture", name: "Fixture Author", numBooks: 3)])
  }

  @Test(
    "requesting a non-positive limit falls back to the default; an oversized one clamps to the maximum",
    arguments: [
      (requested: 0, expected: AuthorSeriesBounds.fallback),
      (requested: -5, expected: AuthorSeriesBounds.fallback),
      (requested: 10_000, expected: AuthorSeriesBounds.maximum),
      (requested: 30, expected: 30),
    ]
  )
  func authorsLimitIsBounded(_ scenario: (requested: Int, expected: Int)) async throws {
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: ["authors": []])])

    _ = try await client.listLibraryAuthors(
      account: account, library: "library_book_fixture", limit: scenario.requested
    )

    #expect(queryItems(of: http.requests[0])["limit"] == String(scenario.expected))
  }

  @Test("drops only the malformed elements of the authors bucket, keeping the valid one")
  func dropsMalformedAuthorsElements() async throws {
    let malformedAuthors = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "malformed-library-authors")) as? [Any]
    )
    let envelope: [String: Any] = ["authors": malformedAuthors]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let diagnostics = DecodeDiagnostics()

    let page = try await client.listLibraryAuthors(
      account: account, library: "library_book_fixture", diagnostics: diagnostics
    )

    #expect(page.authors.map(\.id) == ["author_valid"])
    let entries = diagnostics.entries
    #expect(entries.allSatisfy { $0.endpoint == "/api/libraries/:id/authors" })
    let formatted = entries.map(\.description).joined(separator: "\n")
    for secret in ["wrong-type-id"] {
      #expect(formatted.contains(secret) == false)
    }
  }

  @Test("drops an author whose id exceeds the string bound, keeping the rest")
  func dropsOversizedAuthorId() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "authors": [
        ["id": "author_valid", "name": "Valid Author"],
        ["id": String(repeating: "x", count: limit + 1), "name": "Oversized Author"],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryAuthors(account: account, library: "library_book_fixture")

    #expect(page.authors.map(\.id) == ["author_valid"])
  }

  @Test("throws when a present authors bucket has the wrong top-level type")
  func throwsForWrongTypeAuthorsBucket() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(object: ["authors": "not-an-array"])])

    await #expect(throws: APIError.decoding) {
      try await client.listLibraryAuthors(account: account, library: "library_book_fixture")
    }
  }

  enum AuthorsArrayPresenceState: String, CaseIterable {
    case absent, null
  }

  @Test(
    "treats an absent or null authors bucket as empty",
    arguments: AuthorsArrayPresenceState.allCases
  )
  func treatsMissingOrNullAuthorsBucketAsEmpty(state: AuthorsArrayPresenceState) async throws {
    var envelope: [String: Any] = [:]
    if state == .null {
      envelope["authors"] = NSNull()
    }
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryAuthors(
      account: account, library: "library_book_fixture")

    #expect(page.authors.isEmpty)
  }

  @Test("a page as full as the requested limit reports hasMore; a short page does not")
  func authorsHasMoreReflectsPageFullness() async throws {
    let fullPage: [String: Any] = [
      "authors": (0..<3).map { ["id": "author_\($0)", "name": "Author \($0)"] }
    ]
    let (fullClient, _, fullAccount) = try makeClient(responses: [jsonResponse(object: fullPage)])
    let full = try await fullClient.listLibraryAuthors(
      account: fullAccount, library: "library_book_fixture", limit: 3
    )
    #expect(full.hasMore)

    let shortPage: [String: Any] = [
      "authors": (0..<2).map { ["id": "author_\($0)", "name": "Author \($0)"] }
    ]
    let (shortClient, _, shortAccount) = try makeClient(responses: [jsonResponse(object: shortPage)])
    let short = try await shortClient.listLibraryAuthors(
      account: shortAccount, library: "library_book_fixture", limit: 3
    )
    #expect(short.hasMore == false)
  }

  // MARK: - Series

  @Test("requests series with the correct path, method, auth, and bounded limit/page")
  func requestsSeriesCorrectly() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(object: ["results": [], "total": 0, "limit": 40, "page": 2])]
    )

    _ = try await client.listLibrarySeries(
      account: account, library: "library_book_fixture", limit: 40, page: 2
    )

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .get)
    #expect(request.url.path == "/api/libraries/library_book_fixture/series")
    #expect(request.routeTemplate == "/api/libraries/:id/series")
    #expect(request.headers["Authorization"] == "Bearer canary-access")
    let query = queryItems(of: request)
    #expect(query["limit"] == "40")
    #expect(query["page"] == "2")
  }

  @Test("decodes the series bucket leniently, keeping id/name and pagination metadata")
  func decodesSeriesBucket() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "series_fixture", "name": "Fixture Series", "type": "series"]
      ],
      "total": 12,
      "limit": 50,
      "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibrarySeries(account: account, library: "library_book_fixture")

    #expect(page.series == [LibrarySeriesSummary(id: "series_fixture", name: "Fixture Series")])
    #expect(page.total == 12)
    #expect(page.limit == 50)
    #expect(page.page == 0)
  }

  @Test(
    "requesting a non-positive limit falls back to the default; an oversized one clamps to the maximum",
    arguments: [
      (requested: 0, expected: AuthorSeriesBounds.fallback),
      (requested: -5, expected: AuthorSeriesBounds.fallback),
      (requested: 10_000, expected: AuthorSeriesBounds.maximum),
      (requested: 30, expected: 30),
    ]
  )
  func seriesLimitIsBounded(_ scenario: (requested: Int, expected: Int)) async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(object: ["results": [], "total": 0, "limit": 50, "page": 0])]
    )

    _ = try await client.listLibrarySeries(
      account: account, library: "library_book_fixture", limit: scenario.requested
    )

    #expect(queryItems(of: http.requests[0])["limit"] == String(scenario.expected))
  }

  @Test("drops only the malformed elements of the series bucket, keeping the valid one")
  func dropsMalformedSeriesElements() async throws {
    let malformedSeries = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "malformed-library-series")) as? [Any]
    )
    let envelope: [String: Any] = ["results": malformedSeries, "total": 4, "limit": 4, "page": 0]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let diagnostics = DecodeDiagnostics()

    let page = try await client.listLibrarySeries(
      account: account, library: "library_book_fixture", diagnostics: diagnostics
    )

    #expect(page.series.map(\.id) == ["series_valid"])
    let entries = diagnostics.entries
    #expect(entries.allSatisfy { $0.endpoint == "/api/libraries/:id/series" })
    let formatted = entries.map(\.description).joined(separator: "\n")
    for secret in ["wrong-type-id"] {
      #expect(formatted.contains(secret) == false)
    }
  }

  @Test("drops a series whose id exceeds the string bound, keeping the rest")
  func dropsOversizedSeriesId() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "results": [
        ["id": "series_valid", "name": "Valid Series"],
        ["id": String(repeating: "x", count: limit + 1), "name": "Oversized Series"],
      ],
      "total": 2,
      "limit": 2,
      "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibrarySeries(account: account, library: "library_book_fixture")

    #expect(page.series.map(\.id) == ["series_valid"])
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

private func queryItems(of request: HTTPRequest) -> [String: String] {
  guard let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems else {
    return [:]
  }
  return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}
