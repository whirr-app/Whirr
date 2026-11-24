import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// A run that does not finish cleanly (a page that fails mid-traversal, or pagination the server
/// reports inconsistently) leaves deletion untouched and paces the next attempt through
/// `BackoffPolicy`. Each gated surface (library list, `/api/me` progress, per-library recent
/// episodes) closes, reopens at its next-attempt instant, and resets on success.
@Suite("Library pull: failure backoff and incomplete runs")
struct LibraryRefreshBackoffTests {

  @Test("a page failure mid-run applies only whole pages; a later trigger restarts cleanly")
  func aPageFailureMidRunNeverHalfAppliesAPageAndLaterRestartsCleanly() async throws {
    let h = try await Harness(pageLimit: 2)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [(id: "a", title: "A", author: nil), (id: "b", title: "B", author: nil)], total: 4, limit: 2, page: 0)
    h.enqueueTransportFailure()  // page 1 never applies

    await h.engine.refresh()

    let library = try #require(try h.fetchLibrary(serverLibraryId: "lib1"))
    let libraryRowId = try #require(library.id)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "a") != nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "b") != nil)

    let firstRun = try #require(try h.fetchSyncRuns().first)
    #expect(firstRun.state == .incomplete)
    let pages = try h.fetchPages(runId: try #require(firstRun.id))
    // Only page 0's checkpoint exists; page 1 was never half-applied.
    #expect(pages.map(\.pageNumber) == [0])

    // Bypass backoff pacing (not this test's concern) and trigger again: a fresh run starts
    // cleanly from page 0 under a new generation.
    h.clock.advance(by: 1000)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [(id: "a", title: "A", author: nil), (id: "b", title: "B", author: nil)], total: 4, limit: 2, page: 0)
    h.enqueuePage(
      items: [(id: "c", title: "C", author: nil), (id: "d", title: "D", author: nil)], total: 4, limit: 2, page: 1)

    await h.engine.refresh()

    let secondRun = try #require(try h.fetchSyncRuns().sorted { $0.generation < $1.generation }.last)
    #expect(secondRun.state == .completed)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "c") != nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "d") != nil)
  }

  @Test("an incomplete run gates at exact backoff instants and clears after a successful traversal")
  func incompleteRunsLeaveDeletionUntouchedAndGateOnBackoffThenResetAfterSuccess() async throws {
    let h = try await Harness(pageLimit: 2, randomUnit: 1.0)
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "missing-item", generation: 1)

    func enqueueIncompleteTraversal() {
      h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
      h.enqueueEmptyProgress()
      h.enqueuePage(
        items: [(id: "a", title: "A", author: nil), (id: "b", title: "B", author: nil)], total: 6, limit: 2, page: 0)
      // Reported total changes on the next page and then ends short: `.incomplete`, never `.abort`.
      h.enqueuePage(items: [(id: "c", title: "C", author: nil)], total: 8, limit: 2, page: 1)
    }

    func enqueueCompletedTraversal() {
      h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
      h.enqueueEmptyProgress()
      h.enqueuePage(items: [], total: 0, limit: 2, page: 0)
    }

    func enqueueBlockedTrigger() {
      h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
      h.enqueueEmptyProgress()
    }

    func itemListRequestCount() -> Int {
      h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count
    }

    let firstRetryAt = h.clock.now().addingTimeInterval(BackoffPolicy.baseDelay)
    enqueueIncompleteTraversal()

    await h.engine.refresh()

    // `seedItem` creates its own bookkeeping "seed" run first. The real pull is the "explicit"
    // one.
    let run = try #require(try h.fetchSyncRuns().first { $0.reason == "explicit" })
    #expect(run.state == .incomplete)
    let missing = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "missing-item"))
    #expect(missing.softDeleted == false)

    let itemRequestsBeforeRetry = itemListRequestCount()

    // The first failure schedules exactly one second. A trigger just before that instant remains
    // gated, including though the library-list/progress calls above it still happen.
    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    enqueueBlockedTrigger()
    await h.engine.refresh()
    #expect(itemListRequestCount() == itemRequestsBeforeRetry)

    // Equality with the concrete next-attempt instant is admitted. The second incomplete
    // traversal must then use the exponent's base-2 step, scheduling two seconds.
    h.clock.advance(by: 0.001)
    #expect(h.clock.now() == firstRetryAt)
    enqueueIncompleteTraversal()
    await h.engine.refresh()
    let itemRequestsAfterSecondFailure = itemListRequestCount()
    #expect(itemRequestsAfterSecondFailure == itemRequestsBeforeRetry + 2)

    let secondRetryAt = firstRetryAt.addingTimeInterval(BackoffPolicy.baseDelay * 2)
    h.clock.advance(by: BackoffPolicy.baseDelay * 2 - 0.001)
    enqueueBlockedTrigger()
    await h.engine.refresh()
    #expect(itemListRequestCount() == itemRequestsAfterSecondFailure)

    h.clock.advance(by: 0.001)
    #expect(h.clock.now() == secondRetryAt)
    enqueueCompletedTraversal()
    await h.engine.refresh()
    let itemRequestsAfterFirstSuccess = itemListRequestCount()
    #expect(itemRequestsAfterFirstSuccess == itemRequestsAfterSecondFailure + 1)

    // A failure immediately after success must start at the one-second delay again, proving the
    // stateful policy was reset rather than continuing at the third exponent step.
    enqueueIncompleteTraversal()
    await h.engine.refresh()
    let itemRequestsAfterResetProbeFailure = itemListRequestCount()
    #expect(itemRequestsAfterResetProbeFailure == itemRequestsAfterFirstSuccess + 2)

    let resetRetryAt = secondRetryAt.addingTimeInterval(BackoffPolicy.baseDelay)
    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    enqueueBlockedTrigger()
    await h.engine.refresh()
    #expect(itemListRequestCount() == itemRequestsAfterResetProbeFailure)

    h.clock.advance(by: 0.001)
    #expect(h.clock.now() == resetRetryAt)
    enqueueCompletedTraversal()
    await h.engine.refresh()
    let itemRequestsAfterSecondSuccess = itemListRequestCount()
    #expect(itemRequestsAfterSecondSuccess == itemRequestsAfterResetProbeFailure + 1)

    // SyncClock is a wall clock, so a rollback into the old window makes a stale
    // nextAttemptAllowedAt observable. A successful traversal must clear that gate as well as the
    // policy counter; with the reset line missing, this final attempt is still blocked.
    h.clock.advance(by: -0.5)
    #expect(h.clock.now() < resetRetryAt)
    enqueueCompletedTraversal()
    await h.engine.refresh()
    #expect(itemListRequestCount() == itemRequestsAfterSecondSuccess + 1)
  }

  @Test("library-list failure backoff closes, reopens, and resets")
  func libraryListFailureBackoffClosesReopensAndResets() async throws {
    let h = try await Harness()
    func libraryListRequestCount() -> Int {
      h.http.requests.filter { $0.routeTemplate == "/api/libraries" }.count
    }

    let firstRetryAt = h.clock.now().addingTimeInterval(BackoffPolicy.baseDelay)
    h.enqueueTransportFailure()
    await h.engine.refresh()
    #expect(libraryListRequestCount() == 1)

    await h.engine.refresh()
    #expect(libraryListRequestCount() == 1, "a gated library-list request never reaches the client")

    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    await h.engine.refresh()
    #expect(libraryListRequestCount() == 1)

    h.clock.advance(by: 0.001)
    #expect(h.clock.now() == firstRetryAt)
    h.enqueueLibraries([])
    await h.engine.refresh()
    #expect(libraryListRequestCount() == 2, "the library-list gate reopens at its next attempt")

    let resetRetryAt = h.clock.now().addingTimeInterval(BackoffPolicy.baseDelay)
    h.enqueueTransportFailure()
    await h.engine.refresh()
    #expect(libraryListRequestCount() == 3)

    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    h.enqueueLibraries([])
    await h.engine.refresh()
    #expect(libraryListRequestCount() == 3)

    h.clock.advance(by: 0.001)
    #expect(h.clock.now() == resetRetryAt)
    h.enqueueLibraries([])
    await h.engine.refresh()
    #expect(libraryListRequestCount() == 4, "a success resets the policy to its first delay")

    // The next-attempt instant is cleared as well as the exponent counter. A clock rollback must
    // not strand a successful gate in the old window.
    h.clock.advance(by: -0.5)
    h.enqueueLibraries([])
    await h.engine.refresh()
    #expect(libraryListRequestCount() == 5)
  }

  @Test("a scheduled library-list backoff skips podcast surfaces")
  func scheduledLibraryListBackoffSkipsPodcastSurfaces() async throws {
    let h = try await TopLevelRefreshBackoffHarness()
    h.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    await h.engine.refresh()

    #expect(
      h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/recent-episodes" }.isEmpty)
  }

  @Test("no saved library row skips podcast surfaces")
  func noSavedLibraryRowSkipsPodcastSurfaces() async throws {
    let h = try await TopLevelRefreshBackoffHarness()
    try await h.database.writeAsync { db in
      try db.execute(sql: "DROP TABLE library")
    }
    h.enqueuePodcastTraversal(libraryIDs: ["podcasts"])

    await h.engine.refresh()

    #expect(
      h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/recent-episodes" }.isEmpty)
  }

  @Test("a gated library list still lets the local-session upload drain run")
  func gatedLibraryListStillLetsLocalSessionUploadDrainRun() async throws {
    let drainCalls = DrainCallCounter()
    let h = try await Harness(localSessionUploadDrain: { drainCalls.increment() })
    #expect(await waitUntil { drainCalls.value >= 1 }, "the launch drain has been installed")

    h.enqueueTransportFailure()
    await h.engine.refresh()
    let callsAfterFailure = drainCalls.value

    await h.engine.refresh()
    #expect(await waitUntil { drainCalls.value > callsAfterFailure })
    #expect(h.http.requests.filter { $0.routeTemplate == "/api/libraries" }.count == 1)
  }

  @Test("progress failure backoff closes, reopens, and resets without blocking library traversal")
  func progressFailureBackoffClosesReopensAndResetsWithoutBlockingLibraryTraversal() async throws {
    let h = try await Harness()
    func progressRequestCount() -> Int {
      h.http.requests.filter { $0.routeTemplate == "/api/me" }.count
    }
    func itemRequestCount() -> Int {
      h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count
    }

    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueTransportFailure()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()
    #expect(progressRequestCount() == 1)
    #expect(itemRequestCount() == 1)

    // The enrichment request is gated, but the library list and traversal still run.
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()
    #expect(progressRequestCount() == 1, "a gated /api/me request never reaches the client")
    #expect(itemRequestCount() == 2, "a failed progress pull must not block library traversal")

    h.clock.advance(by: BackoffPolicy.baseDelay)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()
    #expect(progressRequestCount() == 2, "the /api/me gate reopens at its next attempt")
    #expect(itemRequestCount() == 3)

    let resetRetryAt = h.clock.now().addingTimeInterval(BackoffPolicy.baseDelay)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueTransportFailure()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()
    #expect(progressRequestCount() == 3)

    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()
    #expect(progressRequestCount() == 3)
    #expect(itemRequestCount() == 5)

    h.clock.advance(by: 0.001)
    #expect(h.clock.now() == resetRetryAt)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()
    #expect(progressRequestCount() == 4, "a successful /api/me pull resets the policy")

    h.clock.advance(by: -0.5)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [], total: 0, limit: 100, page: 0)
    await h.engine.refresh()
    #expect(progressRequestCount() == 5, "the successful gate clears its old next-attempt instant")
  }

  @Test("recent-episode failure backoff closes, reopens, and resets per library")
  func recentEpisodeFailureBackoffClosesReopensAndResetsPerLibrary() async throws {
    let h = try await TopLevelRefreshBackoffHarness()
    let libraries = ["broken-podcasts", "healthy-podcasts"]
    func enqueueTraversal() {
      h.enqueuePodcastTraversal(libraryIDs: libraries)
    }
    func recentPaths() -> [String] {
      h.http.requests
        .filter { $0.routeTemplate == "/api/libraries/:id/recent-episodes" }
        .map(\.url.path)
    }

    enqueueTraversal()
    h.enqueueShelfFailure()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(
      recentPaths() == [
        "/api/libraries/broken-podcasts/recent-episodes",
        "/api/libraries/healthy-podcasts/recent-episodes",
      ])

    // The failed library is gated, while the healthy library is still requested.
    enqueueTraversal()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(Array(recentPaths().suffix(1)) == ["/api/libraries/healthy-podcasts/recent-episodes"])
    #expect(recentPaths().contains("/api/libraries/broken-podcasts/recent-episodes") == true)
    #expect(recentPaths().count == 3)

    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    enqueueTraversal()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(recentPaths().count == 4)
    #expect(recentPaths().last == "/api/libraries/healthy-podcasts/recent-episodes")

    h.clock.advance(by: 0.001)
    enqueueTraversal()
    h.enqueueEmptyShelf()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(
      Array(recentPaths().suffix(2)) == [
        "/api/libraries/broken-podcasts/recent-episodes",
        "/api/libraries/healthy-podcasts/recent-episodes",
      ], "the failed shelf gate reopens at its next attempt")

    let resetRetryAt = h.clock.now().addingTimeInterval(BackoffPolicy.baseDelay)
    enqueueTraversal()
    h.enqueueShelfFailure()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(recentPaths().count == 8)

    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    enqueueTraversal()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(recentPaths().count == 9)
    #expect(recentPaths().last == "/api/libraries/healthy-podcasts/recent-episodes")

    h.clock.advance(by: 0.001)
    #expect(h.clock.now() == resetRetryAt)
    enqueueTraversal()
    h.enqueueEmptyShelf()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(recentPaths().count == 11, "a successful shelf fetch resets its policy")

    h.clock.advance(by: -0.5)
    enqueueTraversal()
    h.enqueueEmptyShelf()
    h.enqueueEmptyShelf()
    await h.engine.refresh()
    #expect(recentPaths().count == 13, "a successful shelf fetch clears its next-attempt instant")
  }
}

private final class TopLevelRefreshBackoffHarness: @unchecked Sendable {
  let database: AppDatabase
  let http: FakeHTTPClient
  let clock: FakeSyncClock
  let engine: SyncEngine

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://shelf-sync.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let database = try AppDatabase.inMemory()
    self.database = database
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try record.insert(db)
    }

    http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let recentEpisodes = RecentEpisodeRefreshCoordinator(database: database, client: client)
    let diagnostics = FakeDiagnosticsRecording()
    let appLifecycle = FakeAppLifecycle()
    clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: diagnostics,
      appLifecycle: appLifecycle,
      clock: clock,
      randomSource: { 1 },
      pageLimit: 100,
      recentEpisodes: recentEpisodes)
  }

  func enqueuePodcastTraversal(libraryIDs: [String]) {
    http.enqueue(
      Harness.jsonResponse(object: [
        "libraries": libraryIDs.map {
          ["id": $0, "name": $0, "mediaType": "podcast"]
        }
      ]))
    http.enqueue(Harness.jsonResponse(object: ["mediaProgresses": []]))
    for _ in libraryIDs {
      http.enqueue(
        Harness.jsonResponse(object: [
          "results": [],
          "total": 0,
          "limit": 100,
          "page": 0,
        ]))
    }
  }

  func enqueueShelfFailure() {
    http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
  }

  func enqueueEmptyShelf() {
    http.enqueue(Harness.jsonResponse(object: ["episodes": []]))
  }
}
