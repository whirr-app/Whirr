import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `POST /api/items/batch/get`, used instead of N sequential `GET /api/items/{id}` calls.
///
/// The server documents no bound, so by choice: empty input returns `[]` without a network
/// round-trip, and input over `BatchGetBounds.maximum` is rejected rather than clamped.
@Suite("Batch item-get endpoint")
struct BatchGetTests {

  @Test("POSTs the library item ids and decodes the returned expanded items")
  func postsIdsAndDecodesResponse() async throws {
    let bookObject = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    let podcastObject = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "podcast-item-expanded")) as? [String: Any]
    )
    let envelope: [String: Any] = ["libraryItems": [bookObject, podcastObject]]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let items = try await client.batchGetItems(
      account: account,
      ids: ["item_book_fixture", "item_podcast_fixture"]
    )

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .post)
    #expect(request.url.path == "/api/items/batch/get")
    #expect(request.routeTemplate == "/api/items/batch/get")
    #expect(request.headers["Authorization"] == "Bearer canary-access")

    let requestBody = try #require(request.body)
    let body = try #require(
      JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
    )
    #expect(body["libraryItemIds"] as? [String] == ["item_book_fixture", "item_podcast_fixture"])

    #expect(items.map(\.id) == ["item_book_fixture", "item_podcast_fixture"])
    #expect(items.map(\.mediaType) == ["book", "podcast"])
  }

  @Test("returns an empty array without a network call for empty input")
  func returnsEmptyArrayWithoutNetworkCall() async throws {
    let (client, http, account) = try makeClient(responses: [])

    let items = try await client.batchGetItems(account: account, ids: [])

    #expect(items.isEmpty)
    #expect(http.requests.isEmpty)
  }

  @Test("rejects input over the batch bound without a network call")
  func rejectsInputOverTheBatchBound() async throws {
    let (client, http, account) = try makeClient(responses: [])
    let ids = (0..<(BatchGetBounds.maximum + 1)).map { "item_\($0)" }

    await #expect(
      throws: BatchGetError.tooManyIDs(requested: ids.count, maximum: BatchGetBounds.maximum)
    ) {
      try await client.batchGetItems(account: account, ids: ids)
    }
    #expect(http.requests.isEmpty)
  }

  @Test("accepts input exactly at the batch bound")
  func acceptsInputExactlyAtTheBatchBound() async throws {
    let envelope: [String: Any] = ["libraryItems": []]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let ids = (0..<BatchGetBounds.maximum).map { "item_\($0)" }

    let items = try await client.batchGetItems(account: account, ids: ids)

    #expect(items.isEmpty)
    #expect(http.requests.count == 1)
    let requestBody = try #require(http.requests[0].body)
    let body = try #require(
      JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
    )
    #expect((body["libraryItemIds"] as? [String])?.count == BatchGetBounds.maximum)
  }

  @Test("skips returned elements missing their required identity, recording diagnostics")
  func skipsResultsMissingRequiredIdentity() async throws {
    let validObject = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    let missingId: [String: Any] = ["libraryId": "library_book_fixture", "mediaType": "book"]
    let wrongTypeId: [String: Any] = ["id": 12345, "libraryId": "library_book_fixture", "mediaType": "book"]
    let envelope: [String: Any] = ["libraryItems": [validObject, missingId, wrongTypeId]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let diagnostics = DecodeDiagnostics()

    let items = try await client.batchGetItems(
      account: account,
      ids: ["item_book_fixture", "item_missing", "item_wrong_type"],
      diagnostics: diagnostics
    )

    #expect(items.map(\.id) == ["item_book_fixture"])
    #expect(diagnostics.entries.isEmpty == false)
    #expect(diagnostics.entries.allSatisfy { $0.endpoint == "/api/items/batch/get" })
  }

  @Test("drops an element whose id exceeds the string bound, keeping the rest")
  func dropsOversizedIdElement() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let valid: [String: Any] = ["id": "item_valid_fixture", "libraryId": "library_book_fixture", "mediaType": "book"]
    let oversized: [String: Any] = [
      "id": String(repeating: "x", count: limit + 1),
      "libraryId": "library_book_fixture",
      "mediaType": "book",
    ]
    let envelope: [String: Any] = ["libraryItems": [valid, oversized]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let items = try await client.batchGetItems(
      account: account,
      ids: ["item_valid_fixture", "item_oversized"]
    )

    #expect(items.map(\.id) == ["item_valid_fixture"])
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
