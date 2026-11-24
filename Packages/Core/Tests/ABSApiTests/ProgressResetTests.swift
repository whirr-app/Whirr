import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// The outbox drainer's read-then-delete leg of a progress reset (ADR 0011). `fetchMediaProgress` is the `GET` that captures
/// the row id and surviving-medium values before a reset; `deleteMediaProgress` is the `DELETE`
/// that performs it.
@Suite("Progress reset endpoints")
struct ProgressResetTests {

  // MARK: - fetchMediaProgress

  @Test("GETs /api/me/progress/{libraryItemId} and maps 200 to a row with its serverProgressID")
  func fetchesSingleRowAndDecodesServerProgressID() async throws {
    let entry: [String: Any] = [
      "id": "progress_fixture",
      "libraryItemId": "item_fixture",
      "currentTime": 1200,
      "isFinished": false,
    ]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: entry)])

    let progress = try await client.fetchMediaProgress(
      account: account, libraryItemID: "item_fixture", episodeID: nil)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .get)
    #expect(http.requests[0].url.path == "/api/me/progress/item_fixture")
    #expect(http.requests[0].routeTemplate == "/api/me/progress/:id")
    #expect(http.requests[0].transportClass == .progressSync)

    let row = try #require(progress)
    #expect(row.libraryItemID == "item_fixture")
    #expect(row.serverProgressID == "progress_fixture")
    #expect(row.currentTime == 1200)
  }

  @Test("uses the episode-scoped route when given an episodeID")
  func fetchesEpisodeScopedRoute() async throws {
    let entry: [String: Any] = [
      "id": "progress_episode_fixture",
      "libraryItemId": "item_fixture",
      "episodeId": "episode_fixture",
    ]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: entry)])

    let progress = try await client.fetchMediaProgress(
      account: account, libraryItemID: "item_fixture", episodeID: "episode_fixture")

    #expect(http.requests[0].url.path == "/api/me/progress/item_fixture/episode_fixture")
    #expect(http.requests[0].routeTemplate == "/api/me/progress/:id/:episodeId")
    #expect(progress?.episodeID == "episode_fixture")
  }

  @Test("a 404 maps to nil rather than throwing")
  func notFoundMapsToNil() async throws {
    let (client, http, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    let progress = try await client.fetchMediaProgress(
      account: account, libraryItemID: "item_fixture", episodeID: nil)

    #expect(progress == nil)
    #expect(http.requests.count == 1)
  }

  @Test("a 500 throws serverFailure")
  func serverFailureThrows() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())])

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.fetchMediaProgress(
        account: account, libraryItemID: "item_fixture", episodeID: nil)
    }
  }

  @Test("a body missing libraryItemId falls back to the requested libraryItemID")
  func fallsBackToRequestedLibraryItemIDWhenBodyOmitsIt() async throws {
    let entry: [String: Any] = ["id": "progress_fixture"]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: entry)])

    let progress = try await client.fetchMediaProgress(
      account: account, libraryItemID: "item_fixture", episodeID: nil)

    #expect(progress?.libraryItemID == "item_fixture")
  }

  // MARK: - deleteMediaProgress

  @Test("DELETEs /api/me/progress/{progressId} with the row id, not the library item id")
  func deletesUsingTheRowID() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    let outcome = try await client.deleteMediaProgress(account: account, progressID: "progress_fixture")

    #expect(outcome == .deleted)
    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .delete)
    #expect(http.requests[0].url.path == "/api/me/progress/progress_fixture")
    #expect(http.requests[0].routeTemplate == "/api/me/progress/:progressId")
    #expect(http.requests[0].transportClass == .progressSync)
  }

  @Test("a 404 maps to alreadyGone")
  func notFoundMapsToAlreadyGone() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    let outcome = try await client.deleteMediaProgress(account: account, progressID: "progress_fixture")

    #expect(outcome == .alreadyGone)
  }

  @Test("a 500 throws serverFailure")
  func deleteServerFailureThrows() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())])

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.deleteMediaProgress(account: account, progressID: "progress_fixture")
    }
  }

  @Test(
    "an id that is not one usable path segment is refused before any request",
    arguments: ["", "abc/../other", "a/b", "..", "a%2", "a#b", "a b"])
  func refusesMultiSegmentIDs(progressID: String) async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    await #expect(throws: RequestBuilderError.invalidURL) {
      _ = try await client.deleteMediaProgress(account: account, progressID: progressID)
    }
    #expect(http.requests.isEmpty)
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

private func emptyResponse() -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: [:], body: Data())
}
