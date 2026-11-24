import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// The bookmark write routes and the `bookmarks` part of the `/api/me` snapshot. The server keys a
/// bookmark on `(libraryItemId, time)` and matches `time` with numeric equality, so the tests pin
/// that the exact decoded double goes back out in both the body and the delete path.
@Suite("Audio bookmark endpoints")
struct AudioBookmarksTests {

  // MARK: - Create

  @Test("POSTs {time, title} to /api/me/item/{id}/bookmark on the progress transport")
  func createSendsTimeAndTitle() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.createAudioBookmark(
      account: account, libraryItemID: "item_fixture", time: 1234.567, title: "Chapter 3")

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .post)
    #expect(request.url.path == "/api/me/item/item_fixture/bookmark")
    #expect(request.routeTemplate == "/api/me/item/:id/bookmark")
    #expect(request.transportClass == .progressSync)
    let body = try #require(request.body)
    #expect(String(decoding: body, as: UTF8.self) == #"{"time":1234.567,"title":"Chapter 3"}"#)
  }

  @Test("the body carries the time back exactly as a double")
  func createBodyRoundTripsTimeExactly() async throws {
    let time = try decodedTime(fromRawJSON: "0.30000000000000004")
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.createAudioBookmark(
      account: account, libraryItemID: "item_fixture", time: time, title: "Exact")

    let body = try #require(http.requests.first?.body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == ["time", "title"])
    let echoed = try JSONDecoder().decode(TimeOnly.self, from: body).time
    #expect(echoed == time)
  }

  @Test("a 404 from create throws, because the item is gone")
  func createNotFoundThrows() async throws {
    let (client, _, account) = try makeClient(responses: [status(404)])

    await #expect(throws: APIError.notFound) {
      try await client.createAudioBookmark(
        account: account, libraryItemID: "item_fixture", time: 10, title: "Gone")
    }
  }

  @Test("an empty title, a negative or non-finite time, or a multi-segment id never reaches the server")
  func createRejectsInvalidInputsLocally() async throws {
    let (client, http, account) = try makeClient(responses: [])

    for (id, time, title) in [
      ("item_fixture", 10.0, ""),
      ("item_fixture", -1.0, "Negative"),
      ("item_fixture", Double.nan, "NaN"),
      ("item_fixture", Double.infinity, "Infinite"),
      ("item/../other", 10.0, "Traversal"),
      ("", 10.0, "Empty id"),
    ] {
      await #expect(throws: RequestBuilderError.self) {
        try await client.createAudioBookmark(
          account: account, libraryItemID: id, time: time, title: title)
      }
    }
    #expect(http.requests.isEmpty)
  }

  // MARK: - Rename

  @Test("PATCHes {time, title} to the same route and maps 2xx to .renamed")
  func renameSendsPatch() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    let outcome = try await client.renameAudioBookmark(
      account: account, libraryItemID: "item_fixture", time: 42, title: "Renamed")

    #expect(outcome == .renamed)
    let request = try #require(http.requests.first)
    #expect(request.method == .patch)
    #expect(request.url.path == "/api/me/item/item_fixture/bookmark")
    #expect(request.routeTemplate == "/api/me/item/:id/bookmark")
    #expect(request.transportClass == .progressSync)
    let body = try #require(request.body)
    #expect(String(decoding: body, as: UTF8.self) == #"{"time":42,"title":"Renamed"}"#)
  }

  @Test("a 404 from rename maps to .notFound")
  func renameNotFoundMaps() async throws {
    let (client, _, account) = try makeClient(responses: [status(404)])

    let outcome = try await client.renameAudioBookmark(
      account: account, libraryItemID: "item_fixture", time: 42, title: "Renamed")

    #expect(outcome == .notFound)
  }

  @Test("a 403 from rename throws forbidden")
  func renameForbiddenThrows() async throws {
    let (client, _, account) = try makeClient(responses: [status(403)])

    await #expect(throws: APIError.forbidden) {
      _ = try await client.renameAudioBookmark(
        account: account, libraryItemID: "item_fixture", time: 42, title: "Renamed")
    }
  }

  // MARK: - Delete

  @Test("DELETEs /api/me/item/{id}/bookmark/{time} and maps 2xx to .deleted")
  func deleteSendsTimeInPath() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    let outcome = try await client.deleteAudioBookmark(
      account: account, libraryItemID: "item_fixture", time: 1234.567)

    #expect(outcome == .deleted)
    let request = try #require(http.requests.first)
    #expect(request.method == .delete)
    #expect(request.url.path == "/api/me/item/item_fixture/bookmark/1234.567")
    #expect(request.routeTemplate == "/api/me/item/:id/bookmark/:time")
    #expect(request.transportClass == .progressSync)
  }

  @Test("a 404 from delete maps to .alreadyGone")
  func deleteNotFoundMaps() async throws {
    let (client, _, account) = try makeClient(responses: [status(404)])

    let outcome = try await client.deleteAudioBookmark(
      account: account, libraryItemID: "item_fixture", time: 10)

    #expect(outcome == .alreadyGone)
  }

  @Test("a 500 from delete throws serverFailure")
  func deleteServerFailureThrows() async throws {
    let (client, _, account) = try makeClient(responses: [status(500)])

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.deleteAudioBookmark(
        account: account, libraryItemID: "item_fixture", time: 10)
    }
  }

  @Test("a negative time or a multi-segment id never reaches the server")
  func deleteRejectsInvalidInputsLocally() async throws {
    let (client, http, account) = try makeClient(responses: [])

    await #expect(throws: RequestBuilderError.self) {
      _ = try await client.deleteAudioBookmark(
        account: account, libraryItemID: "item_fixture", time: -5)
    }
    await #expect(throws: RequestBuilderError.self) {
      _ = try await client.deleteAudioBookmark(
        account: account, libraryItemID: "a/b", time: 5)
    }
    #expect(http.requests.isEmpty)
  }

  @Test(
    "the time path segment is the shortest form that parses back to the same double",
    arguments: [
      (1234.0, "1234.0"),
      (0.1, "0.1"),
      (1234.567, "1234.567"),
      (0.0, "0.0"),
      (-0.0, "0.0"),
      (0.30000000000000004, "0.30000000000000004"),
    ])
  func timePathSegmentRoundTrips(time: Double, expected: String) {
    let segment = ABSClient.audioBookmarkTimePathSegment(time)
    #expect(segment == expected)
    #expect(Double(segment) == time)
  }

  // MARK: - Snapshot decode

  @Test("a clean bookmarks array decodes in full and is complete")
  func snapshotDecodesBookmarks() async throws {
    let json = """
      {"mediaProgress": [], "bookmarks": [
        {"libraryItemId": "item_a", "time": 1234.567, "title": "Chapter 3", "createdAt": 1700000000000},
        {"libraryItemId": "item_b", "time": 0, "title": "Start"}
      ]}
      """
    let (client, _, account) = try makeClient(responses: [rawJSON(json)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.bookmarksAreComplete == true)
    #expect(
      snapshot.bookmarks == [
        ServerAudioBookmark(
          libraryItemID: "item_a", time: 1234.567, title: "Chapter 3",
          createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ServerAudioBookmark(libraryItemID: "item_b", time: 0, title: "Start", createdAt: nil),
      ])
  }

  @Test("an empty bookmarks array is complete")
  func snapshotEmptyBookmarksIsComplete() async throws {
    let (client, _, account) = try makeClient(responses: [rawJSON(#"{"mediaProgress": [], "bookmarks": []}"#)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.bookmarks.isEmpty)
    #expect(snapshot.bookmarksAreComplete == true)
  }

  @Test("an absent, null or wrong-typed bookmarks key is incomplete, never an empty list")
  func snapshotMissingBookmarksIsIncomplete() async throws {
    for json in [
      #"{"mediaProgress": []}"#,
      #"{"mediaProgress": [], "bookmarks": null}"#,
      #"{"mediaProgress": [], "bookmarks": "nope"}"#,
    ] {
      let (client, _, account) = try makeClient(responses: [rawJSON(json)])

      let snapshot = try await client.fetchUserProgressSnapshot(account: account)

      #expect(snapshot.bookmarks.isEmpty)
      #expect(snapshot.bookmarksAreComplete == false, "\(json)")
    }
  }

  @Test(
    "an unusable element is dropped and marks the list incomplete",
    arguments: [
      #"{"libraryItemId": "item_x", "time": "12", "title": "String time"}"#,
      #"{"libraryItemId": "item_x", "time": -3, "title": "Negative"}"#,
      #"{"libraryItemId": "item_x", "title": "No time"}"#,
      #"{"libraryItemId": "item_x", "time": 12}"#,
      #"{"libraryItemId": "item_x", "time": 12, "title": 7}"#,
      #"{"time": 12, "title": "No item"}"#,
      #"{"libraryItemId": "", "time": 12, "title": "Empty item"}"#,
      #""not-an-object""#,
    ])
  func snapshotDropsUnusableElement(element: String) async throws {
    let json = """
      {"mediaProgress": [], "bookmarks": [{"libraryItemId": "item_ok", "time": 5, "title": "Kept"}, \(element)]}
      """
    let (client, _, account) = try makeClient(responses: [rawJSON(json)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.bookmarks.map(\.libraryItemID) == ["item_ok"])
    #expect(snapshot.bookmarksAreComplete == false)
  }

  @Test("a bookmark's time decodes to exactly the double the server stored")
  func snapshotTimeIsExact() async throws {
    let json = #"""
      {"mediaProgress": [],
       "bookmarks": [{"libraryItemId": "item_a", "time": 0.30000000000000004, "title": "t"}]}
      """#
    let (client, _, account) = try makeClient(responses: [rawJSON(json)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.bookmarks.first?.time == 0.30000000000000004)
    #expect(snapshot.bookmarks.first?.time != 0.3)
  }

  @Test("a snapshot built outside a decode defaults to an incomplete empty bookmark list")
  func snapshotInitDefaultsAreIncomplete() {
    let snapshot = UserProgressSnapshot(progress: [], hiddenSeriesIDs: [])

    #expect(snapshot.bookmarks.isEmpty)
    #expect(snapshot.bookmarksAreComplete == false)
  }
}

private struct TimeOnly: Decodable {
  let time: Double
}

private func decodedTime(fromRawJSON literal: String) throws -> Double {
  try JSONDecoder().decode(TimeOnly.self, from: Data(#"{"time": \#(literal)}"#.utf8)).time
}

private func makeClient(
  responses: [HTTPResponse]
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(responses: responses, serverURL: serverURL)
}

private func rawJSON(_ json: String) -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: Data(json.utf8)
  )
}

private func status(_ code: Int) -> HTTPResponse {
  HTTPResponse(statusCode: code, headers: [:], body: Data())
}

private func emptyResponse() -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: [:], body: Data())
}
