import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `PATCH /api/me/progress/{libraryItemId}[/{episodeId}]` and `/batch/update`
/// (API-CONVENTIONS rule 11).
///
/// The forbidden-`id` mutation check has two halves: (a) encode every progress payload type with
/// every field set and assert no top-level `id` key, and (b) assert each type's `CodingKeys` is
/// the documented allowed set. A future `case id` fails here, without a live server, instead of
/// triggering the corruption bug (issue #5188) in production.
@Suite("Progress patch endpoints")
struct ProgressPatchTests {

  // MARK: - Single progress PATCH

  @Test("PATCHes /api/me/progress/{libraryItemId} with only the intended fields")
  func patchesSingleProgressWithIntendedFieldsOnly() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.updateProgress(
      account: account,
      libraryItemID: "item_fixture",
      episodeID: nil,
      update: ProgressUpdate(currentTime: 42.5, progress: 0.5)
    )

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .patch)
    #expect(request.url.path == "/api/me/progress/item_fixture")
    #expect(request.routeTemplate == "/api/me/progress/:id")
    #expect(request.headers["Authorization"] == "Bearer canary-access")
    #expect(request.transportClass == .progressSync)
    #expect(request.timeout == 15)

    let body = try #require(request.body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == ["currentTime", "progress"])
    #expect(object["currentTime"] as? Double == 42.5)
    #expect(object["progress"] as? Double == 0.5)
  }

  @Test("PATCHes the episode-scoped path when an episodeID is supplied")
  func patchesEpisodeScopedPath() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.updateProgress(
      account: account,
      libraryItemID: "item_fixture",
      episodeID: "episode_fixture",
      update: ProgressUpdate(isFinished: true)
    )

    #expect(http.requests[0].url.path == "/api/me/progress/item_fixture/episode_fixture")
    #expect(http.requests[0].routeTemplate == "/api/me/progress/:id/:episodeId")
    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == ["isFinished"])
    #expect(object["isFinished"] as? Bool == true)
  }

  @Test("omits every unset field entirely rather than encoding null")
  func omitsUnsetFieldsEntirely() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.updateProgress(
      account: account,
      libraryItemID: "item_fixture",
      episodeID: nil,
      update: ProgressUpdate()
    )

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object.isEmpty)
  }

  @Test("encoding every field of ProgressUpdate produces no top-level id key")
  func progressUpdateNeverEncodesId() throws {
    let update = ProgressUpdate(
      currentTime: 1,
      progress: 0.5,
      isFinished: true,
      ebookProgress: 0.25,
      ebookLocation: "epubcfi(/6/4!/4/2/1:0)",
      hideFromContinueListening: false,
      duration: 3600
    )
    let data = try JSONEncoder().encode(update)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["id"] == nil)
    #expect(Set(object.keys) == Set(ProgressUpdate.CodingKeys.allCases.map(\.rawValue)))
  }

  @Test("ProgressUpdate.CodingKeys is exhaustively the documented allowed set, never id")
  func progressUpdateCodingKeysExhaustive() {
    let allowed: Set<String> = [
      "currentTime", "progress", "isFinished", "ebookProgress", "ebookLocation",
      "hideFromContinueListening", "duration",
    ]
    let actual = Set(ProgressUpdate.CodingKeys.allCases.map(\.rawValue))
    #expect(actual == allowed)
    #expect(actual.contains("id") == false)
  }

  // MARK: - Batch progress PATCH

  @Test("PATCHes /api/me/progress/batch/update identifying rows by libraryItemId/episodeId")
  func patchesBatchWithLibraryItemAndEpisodeIdentity() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.updateProgressBatch(
      account: account,
      entries: [
        ProgressBatchEntry(
          libraryItemID: "item_one",
          update: ProgressUpdate(isFinished: true)
        ),
        ProgressBatchEntry(
          libraryItemID: "item_two",
          episodeID: "episode_two",
          update: ProgressUpdate(currentTime: 10)
        ),
      ]
    )

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .patch)
    #expect(request.url.path == "/api/me/progress/batch/update")
    #expect(request.routeTemplate == "/api/me/progress/batch/update")
    #expect(request.transportClass == .progressSync)

    let body = try #require(request.body)
    let array = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    #expect(array.count == 2)
    #expect(array[0]["libraryItemId"] as? String == "item_one")
    #expect(array[0]["episodeId"] == nil)
    #expect(array[0]["isFinished"] as? Bool == true)
    #expect(array[1]["libraryItemId"] as? String == "item_two")
    #expect(array[1]["episodeId"] as? String == "episode_two")
    #expect(array[1]["currentTime"] as? Double == 10)
  }

  @Test("returns without a network call for an empty batch")
  func returnsEarlyForEmptyBatch() async throws {
    let (client, http, account) = try makeClient(responses: [])

    try await client.updateProgressBatch(account: account, entries: [])

    #expect(http.requests.isEmpty)
  }

  @Test("rejects a batch over the bound without a network call")
  func rejectsBatchOverTheBound() async throws {
    let (client, http, account) = try makeClient(responses: [])
    let entries = (0..<(ProgressBatchBounds.maximum + 1)).map {
      ProgressBatchEntry(libraryItemID: "item_\($0)", update: ProgressUpdate(currentTime: 1))
    }

    await #expect(
      throws: ProgressPatchError.tooManyEntries(requested: entries.count, maximum: ProgressBatchBounds.maximum)
    ) {
      try await client.updateProgressBatch(account: account, entries: entries)
    }
    #expect(http.requests.isEmpty)
  }

  @Test("encoding a fully-populated ProgressBatchEntry produces no top-level id key")
  func progressBatchEntryNeverEncodesId() throws {
    let entry = ProgressBatchEntry(
      libraryItemID: "item_fixture",
      episodeID: "episode_fixture",
      update: ProgressUpdate(
        currentTime: 1,
        progress: 0.5,
        isFinished: true,
        ebookProgress: 0.25,
        ebookLocation: "epubcfi(/6/4!/4/2/1:0)",
        hideFromContinueListening: false,
        duration: 3600
      )
    )
    let data = try JSONEncoder().encode(entry)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["id"] == nil)
    let allowed =
      Set(ProgressBatchEntry.CodingKeys.allCases.map(\.rawValue))
      .union(ProgressUpdate.CodingKeys.allCases.map(\.rawValue))
    #expect(Set(object.keys) == allowed)
  }

  @Test("ProgressBatchEntry.CodingKeys is exhaustively libraryItemId/episodeId, never id")
  func progressBatchEntryCodingKeysExhaustive() {
    let actual = Set(ProgressBatchEntry.CodingKeys.allCases.map(\.rawValue))
    #expect(actual == ["libraryItemId", "episodeId"])
    #expect(actual.contains("id") == false)
  }
}

private func makeClient(
  responses: [HTTPResponse]
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(responses: responses, serverURL: serverURL)
}

private func emptyResponse() -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: [:], body: Data())
}
