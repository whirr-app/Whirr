import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Response bodies are trimmed from sanitized captures for Audiobookshelf 2.35.1 and 2.37.2,
/// inlined like the other podcast wire tests rather than copied
/// into the package resource bundle.
@Suite("PSA podcast automation settings endpoint")
struct PodcastAutomationSettingsEndpointTests {

  private static let allKeys: Set<String> = [
    "autoDownloadEpisodes", "autoDownloadSchedule", "maxNewEpisodesToDownload",
    "maxEpisodesToKeep",
  ]

  // MARK: Encoding

  @Test("each single field encodes as exactly one top-level key")
  func singleFieldKeySets() async throws {
    let cases: [(PodcastAutomationSettingsRequest, String, Any)] = [
      (.init(autoDownloadEpisodes: true), "autoDownloadEpisodes", true),
      (.init(autoDownloadEpisodes: false), "autoDownloadEpisodes", false),
      (.init(autoDownloadSchedule: .daily), "autoDownloadSchedule", "0 0 * * *"),
      (.init(maxNewEpisodesToDownload: 5), "maxNewEpisodesToDownload", 5),
      (.init(maxEpisodesToKeep: 0), "maxEpisodesToKeep", 0),
    ]
    for (request, key, expected) in cases {
      let (client, http, account) = try makeClient(responses: [okResponse()])
      _ = try await client.updatePodcastAutomationSettings(
        account: account, itemID: "show-one", request: request)
      let object = try sentObject(http)
      #expect(Set(object.keys) == [key])
      let sent = try #require(http.requests.first?.body)
      let text = String(decoding: sent, as: UTF8.self)
      let literal = (expected as? String).map { "\"\($0)\"" } ?? String(describing: expected)
      #expect(text == "{\"\(key)\":\(literal)}")
    }
  }

  @Test("combinations emit only the set keys and the all-four body is complete")
  func combinations() async throws {
    let (client, http, account) = try makeClient(responses: [okResponse(), okResponse()])
    _ = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one",
      request: .init(autoDownloadEpisodes: true, maxEpisodesToKeep: 10))
    #expect(Set(try sentObject(http).keys) == ["autoDownloadEpisodes", "maxEpisodesToKeep"])

    _ = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one",
      request: .init(
        autoDownloadEpisodes: false, autoDownloadSchedule: .weekly,
        maxNewEpisodesToDownload: 100, maxEpisodesToKeep: 1000))
    let object = try sentObject(http, index: 1)
    #expect(Set(object.keys) == Self.allKeys)
    #expect(object["autoDownloadSchedule"] as? String == "0 0 * * 0")
    #expect(object["maxNewEpisodesToDownload"] as? Int == 100)
    #expect(object["maxEpisodesToKeep"] as? Int == 1000)
  }

  @Test("the request targets the media route with PATCH")
  func route() async throws {
    let (client, http, account) = try makeClient(responses: [okResponse()])
    _ = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one", request: .init(autoDownloadEpisodes: true))
    let request = try #require(http.requests.first)
    #expect(request.method == .patch)
    #expect(request.url.path == "/api/items/show-one/media")
    #expect(request.routeTemplate == "/api/items/:id/media")
  }

  @Test("presets are the five cron strings in presentation order")
  func presets() {
    #expect(
      PodcastAutomationSchedulePreset.allCases.map(\.cronExpression) == [
        "0 * * * *", "0 */6 * * *", "0 */12 * * *", "0 0 * * *", "0 0 * * 0",
      ])
    #expect(PodcastAutomationSchedulePreset(cronExpression: "0 0 * * *") == .daily)
    #expect(PodcastAutomationSchedulePreset(cronExpression: "*/5 * * * *") == nil)
    #expect(PodcastAutomationSchedulePreset(cronExpression: "") == nil)
  }

  @Test("encoded bodies never contain null, an empty schedule, or a zero new-episode limit")
  func neverEmitsForbiddenValues() throws {
    let requests: [PodcastAutomationSettingsRequest] = [
      .init(autoDownloadEpisodes: true),
      .init(autoDownloadSchedule: .hourly),
      .init(maxNewEpisodesToDownload: 1),
      .init(maxEpisodesToKeep: 0),
      .init(
        autoDownloadEpisodes: true, autoDownloadSchedule: .daily, maxNewEpisodesToDownload: 3,
        maxEpisodesToKeep: 0),
    ]
    for request in requests {
      let data = try JSONEncoder().encode(request)
      let text = String(decoding: data, as: UTF8.self)
      #expect(text.contains("null") == false)
      #expect(text.contains("\"\"") == false)
      #expect(text.contains("\"maxNewEpisodesToDownload\":0") == false)
    }
  }

  @Test("descriptions and reflection carry no values beyond the setting names")
  func descriptionIsClosed() {
    let request = PodcastAutomationSettingsRequest(maxEpisodesToKeep: 7)
    #expect(String(describing: Mirror(reflecting: request).children.count) == "0")
    #expect(request.description.contains("show") == false)
  }

  // MARK: Validation

  @Test("an empty request fails validation and sends nothing")
  func emptyRequest() async throws {
    let (client, http, account) = try makeClient(responses: [])
    await #expect(throws: PodcastWriteError.invalidValue(field: .automationSettings)) {
      _ = try await client.updatePodcastAutomationSettings(
        account: account, itemID: "show-one", request: .init())
    }
    #expect(http.requests.isEmpty)
  }

  @Test("out-of-range limits fail validation and send nothing; the bounds themselves pass")
  func limitBounds() async throws {
    let invalidNew = [0, -1, 101, Int.max]
    let invalidKeep = [-1, 1001, Int.min]
    for value in invalidNew {
      let (client, http, account) = try makeClient(responses: [])
      await #expect(throws: PodcastWriteError.invalidValue(field: .maxNewEpisodesToDownload)) {
        _ = try await client.updatePodcastAutomationSettings(
          account: account, itemID: "show-one", request: .init(maxNewEpisodesToDownload: value))
      }
      #expect(http.requests.isEmpty)
    }
    for value in invalidKeep {
      let (client, http, account) = try makeClient(responses: [])
      await #expect(throws: PodcastWriteError.invalidValue(field: .maxEpisodesToKeep)) {
        _ = try await client.updatePodcastAutomationSettings(
          account: account, itemID: "show-one", request: .init(maxEpisodesToKeep: value))
      }
      #expect(http.requests.isEmpty)
    }
    let (client, http, account) = try makeClient(responses: [okResponse(), okResponse()])
    _ = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one",
      request: .init(maxNewEpisodesToDownload: 1, maxEpisodesToKeep: 0))
    _ = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one",
      request: .init(maxNewEpisodesToDownload: 100, maxEpisodesToKeep: 1000))
    #expect(http.requests.count == 2)
  }

  @Test("an unusable item id fails validation and sends nothing")
  func itemIDValidation() async throws {
    for id in ["", "a/b", "..", "a b/../c"] {
      let (client, http, account) = try makeClient(responses: [])
      await #expect(throws: PodcastWriteError.self) {
        _ = try await client.updatePodcastAutomationSettings(
          account: account, itemID: id, request: .init(autoDownloadEpisodes: true))
      }
      #expect(http.requests.isEmpty)
    }
  }

  @Test("a cancelled task never sends")
  func cancellation() async throws {
    let (client, http, account) = try makeClient(responses: [])
    let task = Task {
      try await client.updatePodcastAutomationSettings(
        account: account, itemID: "show-one", request: .init(autoDownloadEpisodes: true))
    }
    task.cancel()
    await #expect(throws: APIError.cancelled) { _ = try await task.value }
    #expect(http.requests.isEmpty)
  }

  // MARK: Status mapping

  @Test("400, 401, 403, 404, 429 and 500 map to distinct typed errors")
  func statusMapping() async throws {
    for status in [400, 401, 403, 404, 429, 500] {
      let (client, _, account) = try makeClient(
        responses: [HTTPResponse(statusCode: status, headers: [:], body: Data("Forbidden".utf8))],
        refreshToken: nil)
      let expected: APIError =
        switch status {
        case 400: .badRequest
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        default: .serverFailure(statusCode: status)
        }
      await #expect(throws: expected) {
        _ = try await client.updatePodcastAutomationSettings(
          account: account, itemID: "show-one", request: .init(autoDownloadEpisodes: true))
      }
    }
  }

  @Test("a transport failure maps to APIError.transport")
  func transportFailure() async throws {
    let (client, _, account) = try makeClient(
      responses: [], transportFailure: URLError(.timedOut))
    await #expect(throws: APIError.transport) {
      _ = try await client.updatePodcastAutomationSettings(
        account: account, itemID: "show-one", request: .init(autoDownloadEpisodes: true))
    }
  }

  // MARK: Response decoding

  @Test("decodes the stored values from the 2.35.1 and 2.37.2 response shapes")
  func decodesFixtureShapes() async throws {
    // c1/enable-only and c1/all-four, identical on both versions apart from the version label.
    let enableOnly = #"""
      {"updated":true,"libraryItem":{"id":"<show-c1>","mediaType":"podcast","media":{
        "autoDownloadEpisodes":true,"autoDownloadSchedule":"0 * * * *","lastEpisodeCheck":1,
        "maxEpisodesToKeep":0,"maxNewEpisodesToDownload":3,"episodes":[]}}}
      """#
    let allFour = #"""
      {"updated":true,"libraryItem":{"id":"<show-c1>","mediaType":"podcast","media":{
        "autoDownloadEpisodes":false,"autoDownloadSchedule":"0 0 * * *","lastEpisodeCheck":1,
        "maxEpisodesToKeep":10,"maxNewEpisodesToDownload":5,"episodes":[]}}}
      """#
    let noOp = #"""
      {"libraryItem":{"media":{"autoDownloadEpisodes":false,"autoDownloadSchedule":"0 0 * * *",
        "maxEpisodesToKeep":10,"maxNewEpisodesToDownload":5}}}
      """#
    let (client, _, account) = try makeClient(
      responses: [rawJSON(enableOnly), rawJSON(allFour), rawJSON(noOp)])
    let request = PodcastAutomationSettingsRequest(autoDownloadEpisodes: true)

    let first = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one", request: request)
    #expect(
      first
        == PodcastAutomationSettingsResult(
          autoDownloadEpisodes: true, autoDownloadSchedule: "0 * * * *",
          maxNewEpisodesToDownload: 3, maxEpisodesToKeep: 0))
    let second = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one", request: request)
    #expect(
      second
        == PodcastAutomationSettingsResult(
          autoDownloadEpisodes: false, autoDownloadSchedule: "0 0 * * *",
          maxNewEpisodesToDownload: 5, maxEpisodesToKeep: 10))
    // A repeated identical write answers without `updated`; the values still decode.
    let third = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one", request: request)
    #expect(third == second)
  }

  @Test("missing or mistyped fields decode as nil rather than failing")
  func toleratesMistypedFields() async throws {
    let body = #"""
      {"libraryItem":{"media":{"autoDownloadEpisodes":1,"autoDownloadSchedule":null,
        "maxNewEpisodesToDownload":"3","maxEpisodesToKeep":2.5}}}
      """#
    let (client, _, account) = try makeClient(responses: [rawJSON(body)])
    let result = try await client.updatePodcastAutomationSettings(
      account: account, itemID: "show-one", request: .init(autoDownloadEpisodes: true))
    #expect(result == PodcastAutomationSettingsResult())
    #expect(result.hasStoredValues == false)
  }

  @Test("a 200 with an undecodable or empty body is success with no stored values")
  func undecodableSuccessIsNotFailure() async throws {
    for body in ["<html>ok</html>", "", "[]", #"{"libraryItem":"x"}"#] {
      let (client, _, account) = try makeClient(responses: [rawJSON(body)])
      let result = try await client.updatePodcastAutomationSettings(
        account: account, itemID: "show-one", request: .init(autoDownloadEpisodes: true))
      #expect(result.hasStoredValues == false)
    }
  }
}

private func okResponse() -> HTTPResponse {
  rawJSON(
    #"{"updated":true,"libraryItem":{"media":{"autoDownloadEpisodes":true,"autoDownloadSchedule":"0 * * * *","maxEpisodesToKeep":0,"maxNewEpisodesToDownload":3}}}"#
  )
}

private func rawJSON(_ json: String) -> HTTPResponse {
  HTTPResponse(
    statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
}

private func sentObject(_ http: FakeHTTPClient, index: Int = 0) throws -> [String: Any] {
  let body = try #require(http.requests[index].body)
  return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func makeClient(
  responses: [HTTPResponse],
  refreshToken: String? = "canary-refresh",
  transportFailure: (any Error)? = nil
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(
    responses: responses, transportFailure: transportFailure, serverURL: serverURL,
    refreshToken: refreshToken)
}
