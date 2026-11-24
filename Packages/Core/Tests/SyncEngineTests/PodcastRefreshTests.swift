import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

@Suite("Podcast refresh orchestration")
struct PodcastRefreshTests {
  @Test("one selected show produces one expanded item request and one persistence application")
  func oneSelectedShowProducesOneExpandedRequest() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(Self.progressResponse())

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    let request = try #require(harness.http.requests.first)
    #expect(harness.http.requests.count == 2)
    #expect(request.method == .get)
    #expect(request.url.path == "/api/items/show-1")
    #expect(request.url.query == "expanded=1")
    #expect(request.routeTemplate == "/api/items/:id")
    #expect(request.url.path.contains("/podcasts/") == false)
    #expect(harness.http.requests[1].url.path == "/api/me")

    let refresh = try #require(await harness.store.applied.first)
    #expect(refresh.itemID == "show-1")
    #expect(refresh.episodes.map(\.serverEpisodeID) == ["episode-1"])
    #expect(refresh.progressObservations.map(\.serverEpisodeId) == ["episode-1"])
    #expect(refresh.isComplete)
    #expect(refresh.requestStartedAt != nil)
  }

  /// `media.metadata.description` reaches Persistence as the server sent it, HTML included,
  /// because stripping is a presentation concern.
  @Test("the expanded show payload's description reaches the persistence application")
  func expandedShowDescriptionReachesPersistence() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(Self.progressResponse())

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    let refresh = try #require(await harness.store.applied.first)
    #expect(refresh.showDescription == "<p>A show about <b>shows</b>.</p>")
  }

  @Test("expanded podcast server settings survive the PodcastMedia to PodcastRefresh mapping")
  func expandedPodcastServerSettingsReachRefresh() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(Self.progressResponse())

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    let refresh = try #require(await harness.store.applied.first)
    #expect(refresh.autoDownloadSchedule == "0 0 * * *")
    #expect(refresh.maxEpisodesToKeep == 10)
    #expect(refresh.maxNewEpisodesToDownload == 3)
  }

  @Test("absent podcast server settings remain absent in the PodcastRefresh mapping")
  func absentPodcastServerSettingsRemainAbsentInRefresh() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(
      Self.podcastResponse(
        itemID: "show-1", episodeID: "episode-1", includeNewPodcastSettings: false))
    harness.http.enqueue(Self.progressResponse())

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    let refresh = try #require(await harness.store.applied.first)
    #expect(refresh.autoDownloadSchedule == nil)
    #expect(refresh.maxEpisodesToKeep == nil)
    #expect(refresh.maxNewEpisodesToDownload == nil)
  }

  @Test("podcast server settings survive both refresh mappings into the real store")
  func expandedPodcastServerSettingsReachPersistence() async throws {
    let harness = try await PodcastRefreshDatabaseHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(Self.progressResponse())

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    let settings = try harness.podcastServerSettings()
    #expect(settings.schedule == "0 0 * * *")
    #expect(settings.maxEpisodesToKeep == 10)
    #expect(settings.maxNewEpisodesToDownload == 3)
  }

  @Test("absent podcast server settings remain absent through both refresh mappings")
  func absentPodcastServerSettingsRemainAbsentInPersistence() async throws {
    let harness = try await PodcastRefreshDatabaseHarness()
    harness.http.enqueue(
      Self.podcastResponse(
        itemID: "show-1", episodeID: "episode-1", includeNewPodcastSettings: false))
    harness.http.enqueue(Self.progressResponse())

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    let settings = try harness.podcastServerSettings()
    #expect(settings.schedule == nil)
    #expect(settings.maxEpisodesToKeep == nil)
    #expect(settings.maxNewEpisodesToDownload == nil)
  }

  @Test("an injected progress snapshot skips the account-wide progress request")
  func injectedProgressSnapshotSkipsAccountProgressRequest() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))

    let outcome = try await harness.coordinator.refresh(
      itemID: "show-1",
      prefetchedDetail: nil,
      progressSnapshot: [])

    #expect(outcome == .complete)
    #expect(harness.http.requests.map(\.url.path) == ["/api/items/show-1"])
  }

  @Test("concurrent refreshes for the same account and show coalesce")
  func sameShowConcurrentCallsCoalesce() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(Self.progressResponse())
    await harness.store.blockApplications()

    let first = Task {
      try await harness.coordinator.refresh(itemID: "show-1")
    }
    await harness.store.waitForApplicationCount(1)
    let second = Task {
      try await harness.coordinator.refresh(itemID: "show-1")
    }
    await harness.contextResolutions.waitUntil(count: 2)

    #expect(harness.http.requests.count == 2)
    #expect(await harness.store.applied.count == 1)

    await harness.store.releaseApplications()
    _ = try await first.value
    _ = try await second.value

    #expect(harness.http.requests.count == 2)
    #expect(await harness.store.applied.count == 1)
  }

  @Test("different shows are distinct work under ABSClient's existing request gate")
  func differentShowsDoNotCoalesce() async throws {
    let routingHTTP = makePodcastRoutingHTTPClient()
    let harness = try PodcastRefreshHarness(httpClient: routingHTTP)

    async let first = harness.coordinator.refresh(itemID: "show-1")
    async let second = harness.coordinator.refresh(itemID: "show-2")
    _ = try await first
    _ = try await second

    #expect(
      Set(routingHTTP.requests.map(\.url.path))
        == ["/api/items/show-1", "/api/items/show-2", "/api/me"])
    #expect(routingHTTP.requests.filter { $0.routeTemplate == "/api/items/:id" }.count == 2)
    #expect(await harness.store.applied.count == 2)
  }

  @Test("transport, HTTP, and cancellation failures never apply a persistence mutation")
  func failuresRetainTheStore() async throws {
    let serverFailure = try PodcastRefreshHarness()
    serverFailure.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    await #expect(throws: APIError.self) {
      try await serverFailure.coordinator.refresh(
        itemID: "show-1")
    }
    #expect(await serverFailure.store.applied.isEmpty)

    let cancellation = try PodcastRefreshHarness(httpClient: makeCancellingHTTPClient())
    await #expect(throws: CancellationError.self) {
      try await cancellation.coordinator.refresh(
        itemID: "show-1")
    }
    #expect(await cancellation.store.applied.isEmpty)
  }

  @Test("cancelling the sole waiter cancels shared work before persistence")
  func soleWaiterCancellationRetainsStore() async throws {
    let http = makeBlockingPodcastHTTPClient()
    let harness = try PodcastRefreshHarness(httpClient: http)
    let task = Task { try await harness.coordinator.refresh(itemID: "show-1") }
    await http.recorder.waitUntil(count: 1)

    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await harness.store.applied.isEmpty)
  }

  @Test("one cancelled coalesced waiter does not cancel another waiter")
  func cancelledWaiterDoesNotCancelSharedWork() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(Self.progressResponse())
    await harness.store.blockApplications()
    let first = Task { try await harness.coordinator.refresh(itemID: "show-1") }
    await harness.store.waitForApplicationCount(1)
    let second = Task { try await harness.coordinator.refresh(itemID: "show-1") }
    await harness.contextResolutions.waitUntil(count: 2)

    second.cancel()
    await harness.store.releaseApplications()

    #expect(try await first.value == .complete)
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(await harness.store.applied.count == 1)
  }

  @Test("ordinary library refresh never expands podcast items")
  func libraryRefreshNeverInvokesPodcastRefresh() async throws {
    let harness = try await Harness()
    harness.enqueueLibraries([(id: "podcasts", name: "Podcasts", mediaType: "podcast")])
    harness.enqueueEmptyProgress()
    harness.enqueuePage(
      items: [(id: "show-1", title: "Show", author: nil)],
      total: 1,
      limit: 100,
      page: 0)

    await harness.engine.refresh()

    #expect(harness.http.requests.allSatisfy { $0.routeTemplate != "/api/items/:id" })
    #expect(harness.http.requests.allSatisfy { $0.url.query != "expanded=1" })
  }

  @Test("duplicate episode identities are last-wins and disable deletion inference")
  func duplicateEpisodesDisableCompleteness() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.duplicatePodcastResponse())
    harness.http.enqueue(Self.progressResponse())

    _ = try await harness.coordinator.refresh(itemID: "show-1")

    let refresh = try #require(await harness.store.applied.first)
    #expect(refresh.episodes.count == 1)
    #expect(refresh.episodes.first?.title == "Last")
    #expect(refresh.isComplete == false)
    #expect(
      harness.diagnostics.recorded.map(\.category)
        == [.decodeDiagnostic, .syncRun])
    #expect(
      harness.diagnostics.recorded.allSatisfy {
        $0.endpointTemplate == EndpointTemplate("/api/items/:id")
      })
    #expect(harness.diagnostics.recorded.allSatisfy { $0.statusClass == .success })
  }

  @Test("401 and 429 refresh failures never apply a persistence mutation")
  func authAndRateLimitFailuresRetainTheStore() async throws {
    let unauthorized = try PodcastRefreshHarness()
    // The reactive path spends one refresh and one retry (API-CONVENTIONS rule 3/4) before it
    // gives up, so the refusal has to be enqueued twice.
    unauthorized.http.enqueue(HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    unauthorized.http.enqueue(HTTPResponse(statusCode: 401, headers: [:], body: Data()))

    await #expect(throws: APIError.unauthorized) {
      try await unauthorized.coordinator.refresh(itemID: "show-1")
    }
    #expect(await unauthorized.store.applied.isEmpty)
    #expect(unauthorized.diagnostics.recorded.map(\.statusClass) == [.clientError])

    let rateLimited = try PodcastRefreshHarness()
    rateLimited.http.enqueue(HTTPResponse(statusCode: 429, headers: [:], body: Data()))

    await #expect(throws: APIError.rateLimited) {
      try await rateLimited.coordinator.refresh(itemID: "show-1")
    }
    #expect(await rateLimited.store.applied.isEmpty)
    #expect(rateLimited.diagnostics.recorded.map(\.statusClass) == [.serverError])
  }

  // MARK: - `/api/me` is best-effort

  /// `/api/me` is account-wide and best-effort everywhere in SyncEngine (`try?` in
  /// `SyncEngine.fetchProgressByIdentity` and `ResolutionCenter.takeServerSkew`). A progress
  /// blip must not discard a decoded episode list, since completeness is a property of this
  /// show's episode list and nothing else.
  @Test("a failed /api/me still lands this show's episode list")
  func progressFetchFailureStillLandsTheEpisodeList() async throws {
    let harness = try PodcastRefreshHarness()
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    let outcome = try await harness.coordinator.refresh(itemID: "show-1")

    // The episode list decoded whole, so it stays complete and deletion inference is safe.
    #expect(outcome == .complete)
    let refresh = try #require(await harness.store.applied.first)
    #expect(refresh.episodes.map(\.serverEpisodeID) == ["episode-1"])
    // No progress was readable, so none is claimed. `applyPodcastRefresh` leaves existing rows be.
    #expect(refresh.progressObservations.isEmpty)
    // Reported against the endpoint the problem is in, not as a statement about the episode list.
    #expect(
      harness.diagnostics.recorded.map(\.endpointTemplate)
        == [EndpointTemplate("/api/me"), EndpointTemplate("/api/items/:id")])
    #expect(harness.diagnostics.recorded.map(\.statusClass) == [.serverError, .success])
  }

  /// Best-effort must not mean "swallows cancellation": a cancelled progress fetch is the whole
  /// refresh being torn down, not a server that failed to answer, and it must still retain the
  /// store exactly like `soleWaiterCancellationRetainsStore`.
  @Test("a cancelled /api/me still aborts the refresh without persisting")
  func cancelledProgressFetchStillAbortsTheRefresh() async throws {
    let harness = try PodcastRefreshHarness(httpClient: makeCancellingProgressHTTPClient())

    await #expect(throws: CancellationError.self) {
      try await harness.coordinator.refresh(itemID: "show-1")
    }
    #expect(await harness.store.applied.isEmpty)
  }

  // MARK: - Deletion inference is a function of this show's episode list only

  /// `/api/me` carries progress for the whole account, so one malformed row belonging to an
  /// unrelated item must not disable this show's generation-based soft delete, and must not label
  /// the show as partially decoded. It is still recorded as a decode diagnostic against
  /// `/api/me`, where the problem is.
  @Test("an unrelated malformed progress row neither blocks deletion nor marks the show partial")
  func unrelatedProgressDecodeFailureDoesNotAffectEpisodeCompleteness() async throws {
    let harness = try await PodcastRefreshDatabaseHarness()
    let strandedID = try await harness.insertEpisode(serverEpisodeID: "server-deleted")
    harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
    harness.http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: Data(
          #"""
          {"mediaProgresses":[
            {"episodeId":"orphan","currentTime":5,"isFinished":false},
            {"libraryItemId":"unrelated-audiobook","currentTime":7,"isFinished":false}
          ]}
          """#.utf8)))

    let outcome = try await harness.coordinator.refresh(itemID: "show-1")

    #expect(outcome == .complete)
    #expect(try harness.isSoftDeleted(strandedID) == true)
    #expect(try harness.episodeExists(serverEpisodeID: "episode-1"))
    #expect(
      harness.diagnostics.recorded.map(\.category) == [.decodeDiagnostic, .syncRun])
    #expect(
      harness.diagnostics.recorded.map(\.endpointTemplate)
        == [EndpointTemplate("/api/me"), EndpointTemplate("/api/items/:id")])
  }

  /// The ways this show's own episode list can come back incomplete. None may infer deletion, and
  /// a real episode row is at risk in each, which the fake persistence used elsewhere in this
  /// suite cannot show. A blank id decodes without a diagnostic, but it cannot name the row it
  /// stands for, so it is held to the same rule the save and removal paths use.
  @Test(
    "a partially decoded episode list never infers deletion",
    arguments: [
      PartialEpisodePayload(
        name: "wrong-typed episodes key",
        media: #"{"metadata":{"title":"Show"},"episodes":"not-an-array"}"#,
        expectedEpisodeIDs: []),
      PartialEpisodePayload(
        name: "element missing its required id",
        media: #"""
          {"metadata":{"title":"Show"},"episodes":[
            {"id":"episode-1","title":"Kept"},
            {"title":"Dropped"}
          ]}
          """#,
        expectedEpisodeIDs: ["episode-1"]),
      PartialEpisodePayload(
        name: "element with a blank id",
        media: #"""
          {"metadata":{"title":"Show"},"episodes":[
            {"id":"episode-1","title":"Kept"},
            {"id":"   ","title":"Blank"}
          ]}
          """#,
        expectedEpisodeIDs: ["episode-1"]),
    ])
  func partialEpisodeListNeverInfersDeletion(payload: PartialEpisodePayload) async throws {
    let harness = try await PodcastRefreshDatabaseHarness()
    let survivorID = try await harness.insertEpisode(serverEpisodeID: "absent-from-this-response")
    harness.http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: Data(
          """
          {"id":"show-1","libraryId":"podcasts","mediaType":"podcast","media":\(payload.media)}
          """.utf8)))
    harness.http.enqueue(Self.progressResponse())

    let outcome = try await harness.coordinator.refresh(itemID: "show-1")

    #expect(outcome == .partial)
    #expect(try harness.isSoftDeleted(survivorID) == false)
    for episodeID in payload.expectedEpisodeIDs {
      #expect(try harness.episodeExists(serverEpisodeID: episodeID))
    }
  }

  @Test("duplicate progress selection is independent of server array order")
  func duplicateProgressIsOrderIndependent() async throws {
    var observed: [Double] = []
    for rows in [
      [(10.0, 1_700_000_000_000.0), (90.0, 1_800_000_000_000.0)],
      [(90.0, 1_800_000_000_000.0), (10.0, 1_700_000_000_000.0)],
    ] {
      let harness = try PodcastRefreshHarness()
      harness.http.enqueue(Self.podcastResponse(itemID: "show-1", episodeID: "episode-1"))
      harness.http.enqueue(Self.duplicateProgressResponse(rows))
      _ = try await harness.coordinator.refresh(itemID: "show-1")
      observed.append(try #require(await harness.store.applied.first?.progressObservations.first).currentTime)
    }
    #expect(observed == [90, 90])
  }

  private static func podcastResponse(
    itemID: String,
    episodeID: String,
    includeNewPodcastSettings: Bool = true
  ) -> HTTPResponse {
    var media: [String: Any] = [
      "metadata": [
        "title": "A Show", "author": "An Author",
        "description": "<p>A show about <b>shows</b>.</p>",
      ],
      "autoDownloadEpisodes": false,
      "lastEpisodeCheck": 1_751_000_000_000,
      "episodes": [
        [
          "id": episodeID,
          "title": "An Episode",
          "duration": 120.5,
          "publishedAt": 1_750_000_000_000,
          "audioFile": [
            "ino": "ino-\(episodeID)",
            "size": 1_024,
            "mimeType": "audio/mpeg",
            "duration": 120.5,
          ],
        ]
      ],
    ]
    if includeNewPodcastSettings {
      media["autoDownloadSchedule"] = "0 0 * * *"
      media["maxEpisodesToKeep"] = 10
      media["maxNewEpisodesToDownload"] = 3
    }
    return HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(
        withJSONObject: [
          "id": itemID,
          "libraryId": "podcasts",
          "mediaType": "podcast",
          "media": media,
        ])
    )
  }

  private static func progressResponse() -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(
        #"""
        {"mediaProgresses":[
          {"libraryItemId":"show-1","episodeId":"episode-1","currentTime":42,"isFinished":false},
          {"libraryItemId":"other-show","episodeId":"episode-1","currentTime":99,"isFinished":true},
          {"libraryItemId":"show-1","currentTime":88,"isFinished":true}
        ]}
        """#.utf8))
  }

  private static func duplicatePodcastResponse() -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(
        #"""
        {"id":"show-1","libraryId":"podcasts","mediaType":"podcast","media":{
          "metadata":{"title":"Show"},
          "episodes":[
            {"id":"duplicate","title":"First"},
            {"id":"duplicate","title":"Last"}
          ]
        }}
        """#.utf8))
  }

  private static func duplicateProgressResponse(_ rows: [(Double, Double)]) -> HTTPResponse {
    let entries = rows.map { currentTime, lastUpdate in
      """
      {"libraryItemId":"show-1","episodeId":"episode-1","currentTime":\(currentTime),
       "isFinished":false,"lastUpdate":\(lastUpdate)}
      """
    }.joined(separator: ",")
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: Data("{\"mediaProgresses\":[\(entries)]}".utf8))
  }
}

struct PartialEpisodePayload: Sendable, CustomTestStringConvertible {
  let name: String
  let media: String
  let expectedEpisodeIDs: [String]

  var testDescription: String { name }
}

/// The coordinator wired to a real `PodcastRefreshStore`, so an assertion about deletion inference
/// is made against an actual episode row rather than a captured value object.
private final class PodcastRefreshDatabaseHarness: @unchecked Sendable {
  let http = FakeHTTPClient()
  let diagnostics = FakeDiagnosticsRecording()
  let coordinator: PodcastRefreshCoordinator
  private let database: AppDatabase
  private let accountID: Int64
  private let itemID: Int64

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let clientUUID = "fixture-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    database = try AppDatabase.inMemory()
    (accountID, itemID) = try await database.writeAsync { db in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try accountRecord.insert(db)
      var library = LibraryRecord(
        accountId: accountRecord.id!, serverLibraryId: "podcasts", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountRecord.id!, libraryId: library.id!, serverItemId: "show-1",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
      return (accountRecord.id!, item.id!)
    }

    let localAccountID = accountID
    let localItemID = itemID
    coordinator = PodcastRefreshCoordinator(
      client: ABSClient(server: server, httpClient: http, tokenStore: tokenStore),
      persistence: PodcastRefreshStore(database: database),
      diagnostics: diagnostics,
      resolveContext: { _ in
        PodcastRefreshContext(
          accountID: localAccountID, localItemID: localItemID, tokenAccount: account)
      })
  }

  @discardableResult
  func insertEpisode(serverEpisodeID: String) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: accountID, itemId: itemID, serverEpisodeId: serverEpisodeID,
        title: serverEpisodeID, lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
  }

  func isSoftDeleted(_ episodeID: Int64) throws -> Bool? {
    try database.read { db in try PodcastEpisodeRecord.fetchOne(db, key: episodeID)?.softDeleted }
  }

  func episodeExists(serverEpisodeID: String) throws -> Bool {
    try database.read { db in
      try PodcastEpisodeRecord
        .filter(Column("itemId") == itemID)
        .filter(Column("serverEpisodeId") == serverEpisodeID)
        .fetchCount(db) == 1
    }
  }

  func podcastServerSettings() throws -> (
    schedule: String?, maxEpisodesToKeep: Int?, maxNewEpisodesToDownload: Int?
  ) {
    try database.read { db in
      let row = try #require(
        try Row.fetchOne(
          db,
          sql: """
            SELECT podcastAutoDownloadSchedule, podcastMaxEpisodesToKeep,
              podcastMaxNewEpisodesToDownload
            FROM item WHERE id = ?
            """,
          arguments: [itemID]))
      return (
        schedule: row["podcastAutoDownloadSchedule"],
        maxEpisodesToKeep: row["podcastMaxEpisodesToKeep"],
        maxNewEpisodesToDownload: row["podcastMaxNewEpisodesToDownload"]
      )
    }
  }
}

private final class PodcastRefreshHarness: @unchecked Sendable {
  let account: TokenAccount
  let http: FakeHTTPClient
  let store: FakePodcastRefreshApplying
  let contextResolutions: TestCountRecorder
  let diagnostics: FakeDiagnosticsRecording
  let coordinator: PodcastRefreshCoordinator

  init(httpClient: (any HTTPClienting)? = nil) throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let clientUUID = UUID().uuidString
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"),
      for: account)

    let fake = FakeHTTPClient()
    http = fake
    let client = ABSClient(
      server: server,
      httpClient: httpClient ?? fake,
      tokenStore: tokenStore)
    store = FakePodcastRefreshApplying()
    contextResolutions = TestCountRecorder(label: "podcast refresh context resolutions")
    diagnostics = FakeDiagnosticsRecording()
    coordinator = PodcastRefreshCoordinator(
      client: client,
      persistence: store,
      diagnostics: diagnostics,
      resolveContext: { [account, contextResolutions] itemID in
        contextResolutions.record()
        return PodcastRefreshContext(
          accountID: 1,
          localItemID: itemID == "show-1" ? 11 : 12,
          tokenAccount: account)
      })
  }
}

private actor FakePodcastRefreshApplying: PodcastRefreshApplying {
  private(set) var applied: [PodcastRefresh] = []
  // A blocked application runs to completion regardless of cancellation, as a write would.
  private nonisolated let gate = TestGate<Void>(
    label: "PodcastRefreshApplying applyPodcastRefresh", ignoresCancellation: true)
  private var blockedCount = 0
  private let applications = TestCountRecorder(label: "PodcastRefreshApplying applications")

  func applyPodcastRefresh(
    _ refresh: PodcastRefresh,
    decideProgress: @escaping PodcastProgressMergeDecider
  ) async throws {
    applied.append(refresh)
    applications.record()

    if gate.isHeld { blockedCount += 1 }
    await gate.pass()
  }

  func blockApplications() {
    gate.hold()
  }

  /// Opens the gate and frees every blocked application, once each has parked.
  func releaseApplications() async {
    let target = blockedCount
    blockedCount = 0
    await gate.waitUntilParked(count: target)
    gate.release()
  }

  func waitForApplicationCount(
    _ count: Int, sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await applications.waitUntil(count: count, sourceLocation: sourceLocation)
  }
}

private func makeCancellingHTTPClient() -> FakeHTTPClient {
  FakeHTTPClient(handler: { _ in throw CancellationError() })
}

/// Answers the expanded item request, then cancels on `/api/me`, the one shape that must not be
/// absorbed by the coordinator's best-effort progress handling.
private func makeCancellingProgressHTTPClient() -> FakeHTTPClient {
  FakeHTTPClient(handler: { request in
    guard request.url.path != "/api/me" else { throw CancellationError() }
    return HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(
        """
        {"id":"show-1","libraryId":"podcasts","mediaType":"podcast","media":{
          "metadata":{"title":"Show"},
          "episodes":[{"id":"episode-1","title":"Episode"}]
        }}
        """.utf8))
  })
}

/// Parks every request until its task is cancelled, then fails it with `CancellationError`.
/// Nothing releases the gate, so a request can only end by cancellation.
private func makeBlockingPodcastHTTPClient() -> FakeHTTPClient {
  let gate = TestGate<Void>(label: "podcast refresh request")
  gate.hold()
  return FakeHTTPClient(handler: { _ in
    await gate.pass(otherwise: {})
    try Task.checkCancellation()
    throw FakeHTTPClientError(message: "blocked request was released without cancellation")
  })
}

/// Answers `/api/me` with no progress and any other path with a one-episode show, picking
/// `show-2` when the path asks for it.
private func makePodcastRoutingHTTPClient() -> FakeHTTPClient {
  FakeHTTPClient(handler: { request in
    if request.url.path == "/api/me" {
      return HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"mediaProgresses":[]}"#.utf8))
    }
    let itemID = request.url.path.hasSuffix("show-2") ? "show-2" : "show-1"
    let episodeID = itemID == "show-2" ? "episode-2" : "episode-1"
    return HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(
        """
        {"id":"\(itemID)","libraryId":"podcasts","mediaType":"podcast","media":{
          "metadata":{"title":"Show"},
          "episodes":[{"id":"\(episodeID)","title":"Episode"}]
        }}
        """.utf8))
  })
}
