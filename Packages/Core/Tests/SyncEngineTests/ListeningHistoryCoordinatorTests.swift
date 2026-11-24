import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `ListeningHistoryCoordinator` fetches `GET /api/me/listening-sessions` (API-CONVENTIONS.md
/// rule 6a, closed-session history only) and filters client-side by item, as the endpoint has no
/// confirmed per-item filter. It maps into `ListeningHistoryEntry`, upserts into the local cache
/// and serves it offline-first.
@Suite struct ListeningHistoryCoordinatorTests {

  @Test func audiobookRefreshUsesOnePerItemRequest() async throws {
    let (coordinator, http, _) = try await makeCoordinator()
    http.enqueue(
      jsonResponse(
        sessions: [Self.session(id: "s-1", itemId: "item-1", startedAt: 1_700_000_000)], total: 1))

    #expect(await coordinator.refreshListeningHistory(itemId: "item-1"))
    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.path == "/api/me/item/listening-sessions/item-1")
    #expect((await coordinator.cachedListeningHistory(itemId: "item-1")).map(\.sessionId) == ["s-1"])
  }

  @Test func perItemNotFoundFallsBackAndLatchesForTheNextRefresh() async throws {
    let (coordinator, http, _) = try await makeCoordinator()
    http.enqueue(contentsOf: [
      HTTPResponse(statusCode: 404, headers: [:], body: Data()),
      jsonResponse(sessions: [Self.session(id: "s-1", itemId: "item-1", startedAt: 1_700_000_000)], total: 1),
      jsonResponse(sessions: [Self.session(id: "s-2", itemId: "item-1", startedAt: 1_700_000_001)], total: 1),
    ])

    #expect(await coordinator.refreshListeningHistory(itemId: "item-1"))
    #expect(await coordinator.refreshListeningHistory(itemId: "item-1"))
    #expect(
      http.requests.map { $0.url.path } == [
        "/api/me/item/listening-sessions/item-1",
        "/api/me/listening-sessions",
        "/api/me/listening-sessions",
      ])
  }

  @Test func podcastRefreshNeverUsesPerItemRoute() async throws {
    let (coordinator, http, _) = try await makeCoordinator(mediaKind: "podcast")
    http.enqueue(
      jsonResponse(
        sessions: [Self.session(id: "s-1", itemId: "item-1", startedAt: 1_700_000_000)], total: 1))

    #expect(await coordinator.refreshListeningHistory(itemId: "item-1"))
    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.path == "/api/me/listening-sessions")
  }

  @Test func refreshFiltersAcrossMultiplePagesAndCachesOnlyTheMatchingItemsEntries() async throws {
    let (coordinator, http, _) = try await makeCoordinator()
    // Page 0: full (50 entries) so the coordinator requests page 1; mixes in an entry for a
    // different item to prove client-side filtering (rule 6a).
    http.enqueue(
      contentsOf: [
        jsonResponse(
          sessions: (0..<50).map { i in
            i == 0
              ? Self.session(id: "s-other", itemId: "item-other", startedAt: 1_700_000_000)
              : Self.session(id: "s-\(i)", itemId: "item-1", startedAt: 1_700_000_000 + Double(i))
          }, total: 51),
        // Page 1: short (1 entry), the observed stopping signal.
        jsonResponse(sessions: [Self.session(id: "s-last", itemId: "item-1", startedAt: 1_700_100_000)], total: 51),
      ])

    let refreshed = await coordinator.refreshListeningHistory(itemId: "item-1")
    #expect(refreshed)
    #expect(http.requests.count == 2)

    let entries = await coordinator.cachedListeningHistory(itemId: "item-1")
    // 49 matching entries on page 0 (index 0 is the other item) + 1 on page 1 = 50, none for
    // "item-other".
    #expect(entries.count == 50)
    #expect(entries.allSatisfy { $0.sessionId != "s-other" })
    // Newest session first.
    #expect(entries.first?.sessionId == "s-last")
  }

  @Test func refreshStopsAfterTheMaximumPageCapEvenIfEveryPageIsFull() async throws {
    let (coordinator, http, _) = try await makeCoordinator()
    http.enqueue(
      contentsOf: (0..<(ListeningHistoryCoordinator.maximumPages + 5)).map { page in
        jsonResponse(
          sessions: (0..<50).map { i in
            Self.session(id: "s-\(page)-\(i)", itemId: "item-1", startedAt: 1_700_000_000 + Double(page * 100 + i))
          }, total: 10_000)
      })

    let refreshed = await coordinator.refreshListeningHistory(itemId: "item-1")

    #expect(refreshed)
    #expect(http.requests.count == ListeningHistoryCoordinator.maximumPages)
  }

  @Test func refreshDegradesToFalseButKeepsPagesAlreadyPersisted() async throws {
    let (coordinator, http, _) = try await makeCoordinator()
    // Seed one cached entry via an earlier successful refresh.
    http.enqueue(
      jsonResponse(sessions: [Self.session(id: "s-1", itemId: "item-1", startedAt: 1_700_000_000)], total: 1))
    let seeded = await coordinator.refreshListeningHistory(itemId: "item-1")
    #expect(seeded)

    // Page 0 succeeds, then page 1 fails. The successful page must remain cached.
    http.enqueue(
      jsonResponse(
        sessions: (0..<50).map {
          Self.session(id: "s-2-\($0)", itemId: "item-1", startedAt: 1_700_000_001 + Double($0))
        }, total: 51))
    let refreshed = await coordinator.refreshListeningHistory(itemId: "item-1")

    #expect(refreshed == false)
    let entries = await coordinator.cachedListeningHistory(itemId: "item-1")
    #expect(entries.count == 51, "a failed refresh keeps pages already persisted")
    #expect(entries.contains { $0.sessionId == "s-2-0" })
  }

  @Test func eachPageIsPersistedAndPublishedBeforeTheNextPageIsFetched() async throws {
    let (coordinator, http, _) = try await makeCoordinator()
    http.enqueue(contentsOf: [
      jsonResponse(
        sessions: (0..<50).map { Self.session(id: "s-\($0)", itemId: "item-1", startedAt: 1_700_000_000 + Double($0)) },
        total: 51),
      jsonResponse(sessions: [Self.session(id: "s-last", itemId: "item-1", startedAt: 1_700_000_100)], total: 51),
    ])

    let callbackState = CallbackState()
    let refreshed = await coordinator.refreshListeningHistory(itemId: "item-1") {
      let callbackCount = callbackState.increment()
      let entries = await coordinator.cachedListeningHistory(itemId: "item-1")
      #expect(entries.count == (callbackCount == 1 ? 50 : 51))
      #expect(http.requests.count == callbackCount)
    }

    #expect(refreshed)
    #expect(callbackState.value == 2)
  }

  @Test func refreshReturnsFalseWhenTheItemHasNoLocalRow() async throws {
    let (coordinator, http, _) = try await makeCoordinator(seedItem: false)

    let refreshed = await coordinator.refreshListeningHistory(itemId: "item-1")

    #expect(refreshed == false)
    #expect(http.requests.isEmpty, "never calls the network for an item with no local identity to scope the cache to")
  }

  @Test func cachedListeningHistoryIsEmptyBeforeAnyRefreshHasEverRun() async throws {
    let (coordinator, _, _) = try await makeCoordinator()

    #expect(await coordinator.cachedListeningHistory(itemId: "item-1").isEmpty)
  }

  @Test func refreshUpsertsRatherThanDuplicatingOnASecondRefreshOfTheSameSessions() async throws {
    let (coordinator, http, _) = try await makeCoordinator()
    http.enqueue(
      jsonResponse(sessions: [Self.session(id: "s-1", itemId: "item-1", startedAt: 1_700_000_000)], total: 1))
    _ = await coordinator.refreshListeningHistory(itemId: "item-1")

    http.enqueue(
      jsonResponse(
        sessions: [
          Self.session(
            id: "s-1", itemId: "item-1", startedAt: 1_700_000_000, currentTime: 999, timeListening: 999)
        ], total: 1))
    _ = await coordinator.refreshListeningHistory(itemId: "item-1")

    let entries = await coordinator.cachedListeningHistory(itemId: "item-1")
    #expect(entries.count == 1)
    #expect(entries.first?.endPosition == 999)
  }

  @Test func oversizedLibraryItemIdEntryIsSkippedRatherThanAttributedToAnotherItem() async throws {
    let (coordinator, http, _) = try await makeCoordinator(mediaKind: "podcast")
    let oversized = String(
      repeating: "x", count: EndpointDecodeLimits.standard.maximumListStringBytes + 1)
    http.enqueue(
      jsonResponse(
        sessions: [
          Self.session(id: "s-1", itemId: "item-1", startedAt: 1_700_000_000),
          Self.session(id: "s-oversized", itemId: oversized, startedAt: 1_700_000_100),
        ], total: 2))

    #expect(await coordinator.refreshListeningHistory(itemId: "item-1"))

    let entries = await coordinator.cachedListeningHistory(itemId: "item-1")
    #expect(entries.map(\.sessionId) == ["s-1"])
  }

  // MARK: - Helpers

  private func makeCoordinator(seedItem: Bool = true, mediaKind: String = "book") async throws -> (
    coordinator: ListeningHistoryCoordinator, http: FakeHTTPClient, database: AppDatabase
  ) {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://history.example.test")))
    // The coordinator resolves tokens through the account row's credential namespace, so the
    // seeded pair has to live there rather than under the URL-keyed login account.
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try accountRecord.insert(db)

      if seedItem {
        var library = LibraryRecord(
          accountId: accountRecord.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
        try library.insert(db)
        var item = ItemRecord(
          accountId: accountRecord.id!, libraryId: library.id!, serverItemId: "item-1", mediaKind: mediaKind,
          title: "Title", sortTitle: "title")
        try item.insert(db)
      }
    }

    let coordinator = ListeningHistoryCoordinator(client: client, database: database)
    return (coordinator, http, database)
  }

  private static func session(
    id: String, itemId: String, startedAt: Double, currentTime: Double = 100, timeListening: Double = 100
  ) -> [String: Any] {
    [
      "id": id,
      "libraryItemId": itemId,
      "startTime": 0,
      "currentTime": currentTime,
      "timeListening": timeListening,
      "startedAt": startedAt * 1000,
      "updatedAt": (startedAt + timeListening) * 1000,
    ]
  }
}

private func jsonResponse(sessions: [[String: Any]], total: Int) -> HTTPResponse {
  let object: [String: Any] = ["sessions": sessions, "total": total]
  return HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: try! JSONSerialization.data(withJSONObject: object)
  )
}

private final class CallbackState: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
