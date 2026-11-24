import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `ListeningStatsCoordinator` fetches `GET /api/me/listening-stats` at most at its minimum
/// refresh interval and keeps the trimmed result as the account's snapshot.
@Suite struct ListeningStatsCoordinatorTests {

  @Test func explicitRefreshFetchesMapsAndStores() async throws {
    let harness = try await Harness.make(now: Self.now)
    harness.http.enqueue(Self.response(days: ["2026-11-04": 600, "2026-11-05": 420]))

    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))

    #expect(harness.http.requests.map(\.url.path) == ["/api/me/listening-stats"])
    let snapshot = try #require(await harness.coordinator.cachedListeningStats())
    #expect(snapshot.fetchedAt == Self.now)
    #expect(snapshot.totalSeconds == 1020)
    #expect(snapshot.days == [.init(date: "2026-11-04", seconds: 600), .init(date: "2026-11-05", seconds: 420)])
    #expect(snapshot.weekdaySeconds == [4: 600, 5: 420])
    #expect(snapshot.titles == [.init(serverItemId: "item-1", title: "Book", author: "Ada", seconds: 1020)])
  }

  @Test func appearanceRefreshInsideTheIntervalMakesNoRequest() async throws {
    let clock = Clock(Self.now)
    let harness = try await Harness.make(clock: clock)
    harness.http.enqueue(Self.response())
    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))

    clock.advance(by: ListeningStatsCoordinator.appearanceRefreshInterval - 1)
    #expect(await harness.coordinator.refreshListeningStats(trigger: .appearance))

    #expect(harness.http.requests.count == 1)
  }

  @Test func appearanceRefreshAfterTheIntervalFetches() async throws {
    let clock = Clock(Self.now)
    let harness = try await Harness.make(clock: clock)
    harness.http.enqueue(contentsOf: [Self.response(), Self.response()])
    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))

    clock.advance(by: ListeningStatsCoordinator.appearanceRefreshInterval)
    #expect(await harness.coordinator.refreshListeningStats(trigger: .appearance))

    #expect(harness.http.requests.count == 2)
  }

  @Test func appearanceRefreshWithNoSnapshotFetches() async throws {
    let harness = try await Harness.make(now: Self.now)
    harness.http.enqueue(Self.response())

    #expect(await harness.coordinator.refreshListeningStats(trigger: .appearance))
    #expect(harness.http.requests.count == 1)
  }

  @Test func aSnapshotDatedInTheFutureCountsAsStale() async throws {
    let clock = Clock(Self.now)
    let harness = try await Harness.make(clock: clock)
    harness.http.enqueue(contentsOf: [Self.response(), Self.response()])
    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))

    clock.advance(by: -3600)
    #expect(await harness.coordinator.refreshListeningStats(trigger: .appearance))

    #expect(harness.http.requests.count == 2)
  }

  @Test func explicitRefreshAlwaysFetches() async throws {
    let harness = try await Harness.make(now: Self.now)
    harness.http.enqueue(contentsOf: [Self.response(), Self.response()])

    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))
    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))

    #expect(harness.http.requests.count == 2)
  }

  @Test func beforeFetchRunsOnlyWhenARequestIsMade() async throws {
    let harness = try await Harness.make(now: Self.now)
    harness.http.enqueue(Self.response())
    let calls = Counter()

    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit) { await calls.increment() })
    #expect(await harness.coordinator.refreshListeningStats(trigger: .appearance) { await calls.increment() })

    #expect(await calls.value == 1)
    #expect(harness.http.requests.count == 1)
  }

  @Test func aFailedFetchKeepsThePreviousSnapshot() async throws {
    let harness = try await Harness.make(now: Self.now)
    harness.http.enqueue(contentsOf: [
      Self.response(days: ["2026-11-05": 420]),
      HTTPResponse(statusCode: 500, headers: [:], body: Data()),
    ])
    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))

    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit) == false)

    #expect(await harness.coordinator.cachedListeningStats()?.totalSeconds == 420)
  }

  @Test func noAccountMeansNoRequest() async throws {
    let harness = try await Harness.make(now: Self.now, seedAccount: false)

    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit) == false)
    #expect(await harness.coordinator.cachedListeningStats() == nil)
    #expect(harness.http.requests.isEmpty)
  }

  @Test func overlappingRefreshesShareOneRequest() async throws {
    let harness = try await Harness.make(now: Self.now)
    harness.http.enqueue(Self.response())
    let gate = TestGate<Void>(label: "refresh beforeFetch", ignoresCancellation: true)
    gate.hold()

    async let first = harness.coordinator.refreshListeningStats(trigger: .explicit) { await gate.pass() }
    // The first refresh parks in its `beforeFetch`; the second must join it before it is released.
    #expect(await gate.waitUntilParked() == .observed)
    async let second = harness.coordinator.refreshListeningStats(trigger: .explicit)
    #expect(await waitUntil("second refresh joined") { await harness.coordinator.joinedRefreshCount == 1 })
    gate.release()

    #expect(await first)
    #expect(await second)
    #expect(harness.http.requests.count == 1)
  }

  @Test func storedSnapshotIsTrimmedToItsRetention() async throws {
    let harness = try await Harness.make(now: Self.now)
    var days: [String: Double] = [:]
    var date = DateComponents(calendar: Self.utc, year: 2024, month: 1, day: 1).date!
    for _ in 0..<(ListeningStatsCoordinator.retainedDays + 5) {
      let parts = Self.utc.dateComponents([.year, .month, .day], from: date)
      days[String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)] = 60
      date = Self.utc.date(byAdding: .day, value: 1, to: date)!
    }
    var items: [String: Any] = [:]
    for index in 0..<(ListeningStatsCoordinator.retainedTitles + 5) {
      items["i\(index)"] = ["id": "i\(index)", "timeListening": index + 1]
    }
    harness.http.enqueue(Self.response(totalTime: 99, days: days, items: items))

    #expect(await harness.coordinator.refreshListeningStats(trigger: .explicit))

    let snapshot = try #require(await harness.coordinator.cachedListeningStats())
    #expect(snapshot.days.count == ListeningStatsCoordinator.retainedDays)
    #expect(snapshot.days.first?.date == "2024-01-06")
    #expect(snapshot.titles.count == ListeningStatsCoordinator.retainedTitles)
    #expect(snapshot.titles.first?.serverItemId == "i\(ListeningStatsCoordinator.retainedTitles + 4)")
    // The all-time total is the server's, not the sum of what was kept.
    #expect(snapshot.totalSeconds == 99)
  }

  // MARK: - Fixtures

  private static let now = Date(timeIntervalSince1970: 1_793_885_230)

  private static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private static func response(
    totalTime: Double? = nil,
    days: [String: Double] = ["2026-11-04": 600, "2026-11-05": 420],
    items: [String: Any]? = nil
  ) -> HTTPResponse {
    let total = totalTime ?? days.values.reduce(0, +)
    var weekdays: [String: Double] = [:]
    if days["2026-11-04"] != nil { weekdays["Wednesday"] = days["2026-11-04"] }
    if days["2026-11-05"] != nil { weekdays["Thursday"] = days["2026-11-05"] }
    let body: [String: Any] = [
      "totalTime": total,
      "today": 0,
      "days": days,
      "dayOfWeek": weekdays,
      "items": items ?? [
        "item-1": [
          "id": "item-1", "timeListening": total,
          "mediaMetadata": ["title": "Book", "authors": [["id": "a", "name": "Ada"]]],
        ]
      ],
      "recentSessions": [],
    ]
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: body))
  }

  private struct Harness {
    let coordinator: ListeningStatsCoordinator
    let http: FakeHTTPClient

    static func make(now: Date, seedAccount: Bool = true) async throws -> Harness {
      try await make(clock: Clock(now), seedAccount: seedAccount)
    }

    static func make(clock: Clock, seedAccount: Bool = true) async throws -> Harness {
      let server = try ABSServerConfig(url: try #require(URL(string: "https://stats.example.test")))
      let clientUUID = UUID().uuidString
      let account = try TokenAccount(
        credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
      let tokenStore = InMemoryTokenStore()
      try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
      let http = FakeHTTPClient()
      let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

      let database = try AppDatabase.inMemory()
      if seedAccount {
        try await database.writeAsync { db in
          var accountRecord = AccountRecord(
            clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user_fixture",
            serverVersion: "2.35.1")
          try accountRecord.insert(db)
        }
      }
      let coordinator = ListeningStatsCoordinator(client: client, database: database, now: { clock.now })
      return Harness(coordinator: coordinator, http: http)
    }
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
  }

  private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
  }
}
