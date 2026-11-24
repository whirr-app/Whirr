import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /api/me/listening-stats`. The fixture is a sanitized capture from a disposable 2.35.1
/// server.
@Suite("Listening stats endpoint")
struct ListeningStatsTests {

  @Test("GETs /api/me/listening-stats with its route template and auth, and decodes the capture")
  func fetchesAndDecodesFixture() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "listening-stats-response"))])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .get)
    #expect(http.requests[0].url.path == "/api/me/listening-stats")
    #expect(http.requests[0].routeTemplate == "/api/me/listening-stats")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")

    #expect(stats.totalSeconds == 3165)
    #expect(
      stats.days == [
        ListeningStatsDay(date: "2026-10-27", seconds: 1200),
        ListeningStatsDay(date: "2026-11-02", seconds: 900),
        ListeningStatsDay(date: "2026-11-03", seconds: 45),
        ListeningStatsDay(date: "2026-11-04", seconds: 600),
        ListeningStatsDay(date: "2026-11-05", seconds: 420),
      ])
    #expect(stats.weekdays == [.monday: 900, .tuesday: 1245, .wednesday: 600, .thursday: 420])
    #expect(
      stats.items == [
        ListeningStatsItem(
          id: "item_book_fixture", title: "Stats Fixture Book", author: "Ada Fixture", seconds: 2220),
        ListeningStatsItem(
          id: "item_other_fixture", title: "Second Fixture Book", author: "Ben Fixture", seconds: 945),
      ])
  }

  @Test("accepts numeric strings and fractional seconds, as the server itself coerces them")
  func acceptsStringAndFractionalSeconds() async throws {
    let body: [String: Any] = [
      "totalTime": "61.5",
      "days": ["2026-11-05": "61.5"],
      "dayOfWeek": ["Thursday": 61.5],
      "items": ["a": ["id": "a", "timeListening": "61.5", "mediaMetadata": ["title": "A"]]],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(stats.totalSeconds == 61.5)
    #expect(stats.days == [ListeningStatsDay(date: "2026-11-05", seconds: 61.5)])
    #expect(stats.weekdays == [.thursday: 61.5])
    #expect(stats.items.map(\.seconds) == [61.5])
  }

  @Test("degrades missing or wrong-typed maps to empty rather than failing the response")
  func degradesMissingMapsToEmpty() async throws {
    let body: [String: Any] = ["totalTime": 10, "days": "nope", "items": NSNull()]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(stats.totalSeconds == 10)
    #expect(stats.days.isEmpty)
    #expect(stats.weekdays.isEmpty)
    #expect(stats.items.isEmpty)
  }

  @Test("drops malformed day keys, unknown weekdays, and negative or non-numeric values")
  func dropsMalformedEntries() async throws {
    let body: [String: Any] = [
      "totalTime": 100,
      "days": [
        "2026-11-05": 30, "2026-13-01": 10, "2026-02-30": 10, "11/05/2026": 10, "2026-11-04": -5,
        "2026-11-03": "x", "2026-11-02": 0,
      ],
      "dayOfWeek": ["Thursday": 30, "Funday": 10, "Friday": -1],
      "items": [
        "good": ["id": "good", "timeListening": 30, "mediaMetadata": ["title": "Good"]],
        "noid": ["timeListening": 30],
        "negative": ["id": "negative", "timeListening": -1],
        "notanobject": 5,
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(stats.days == [ListeningStatsDay(date: "2026-11-05", seconds: 30)])
    #expect(stats.weekdays == [.thursday: 30])
    #expect(stats.items.map(\.id) == ["good"])
  }

  @Test("a negative or missing total degrades to the sum of the days")
  func totalFallsBackToDays() async throws {
    let body: [String: Any] = ["days": ["2026-11-05": 30, "2026-11-04": 12]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(stats.totalSeconds == 42)
  }

  @Test("takes a podcast's plain author string when there is no authors array")
  func podcastAuthorString() async throws {
    let body: [String: Any] = [
      "items": ["show": ["id": "show", "timeListening": 5, "mediaMetadata": ["title": "Show", "author": "Host"]]]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(stats.items == [ListeningStatsItem(id: "show", title: "Show", author: "Host", seconds: 5)])
  }

  @Test("items are ordered by time listened, largest first, ties by id")
  func itemOrder() async throws {
    let body: [String: Any] = [
      "items": [
        "b": ["id": "b", "timeListening": 5], "a": ["id": "a", "timeListening": 5],
        "c": ["id": "c", "timeListening": 9],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(stats.items.map(\.id) == ["c", "a", "b"])
  }

  @Test("keeps only the most recent days and the largest items beyond the admission bounds")
  func appliesBounds() async throws {
    var days: [String: Any] = [:]
    var items: [String: Any] = [:]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var date = DateComponents(calendar: calendar, year: 2020, month: 1, day: 1).date!
    for index in 0..<(ListeningStatsBounds.maximumDays + 3) {
      days[dayKey(date)] = index + 1
      date = calendar.date(byAdding: .day, value: 1, to: date)!
    }
    for index in 0..<(ListeningStatsBounds.maximumItems + 2) {
      items["i\(index)"] = ["id": "i\(index)", "timeListening": index + 1]
    }
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(object: ["days": days, "items": items])])

    let stats = try await client.fetchListeningStats(account: account)

    #expect(stats.days.count == ListeningStatsBounds.maximumDays)
    #expect(stats.days.first?.date == "2020-01-04")
    #expect(stats.items.count == ListeningStatsBounds.maximumItems)
    #expect(stats.items.contains { $0.id == "i0" } == false)
    #expect(stats.items.contains { $0.id == "i1" } == false)
  }

  @Test("a body that is not an object is a decoding error")
  func nonObjectIsDecodingError() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data("[]".utf8))])

    await #expect(throws: APIError.decoding) {
      try await client.fetchListeningStats(account: account)
    }
  }

  @Test("a server error is surfaced")
  func serverErrorSurfaces() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await #expect(throws: APIError.notFound) {
      try await client.fetchListeningStats(account: account)
    }
  }
}

private func dayKey(_ date: Date) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let parts = calendar.dateComponents([.year, .month, .day], from: date)
  return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
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
