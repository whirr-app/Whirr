import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

@Suite("Podcast progress hydration")
struct PodcastProgressHydrationTests {
  /// The login gap itself: the account holds episode-level progress the library pull cannot land,
  /// because a minified podcast page carries no episodes to hang it off. One expanded request
  /// fixes the show, and the `/api/me` rows the caller already fetched are handed down, so this
  /// pass never re-asks for them.
  @Test("a partially played episode on a never-opened show is expanded and its progress lands")
  func partiallyPlayedShowIsHydrated() async throws {
    let harness = try await HydrationHarness()
    try await harness.insertShow("show-1")
    harness.http.enqueue(Self.expandedItemResponse(itemID: "show-1"))

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [Self.episodeProgress(show: "show-1", episode: "show-1-episode", currentTime: 90)])

    #expect(harness.http.requests.map(\.url.path) == ["/api/items/show-1"])
    #expect(
      try harness.episodeProgressRows() == [
        EpisodeProgress(episodeID: "show-1-episode", currentTime: 90, isFinished: false)
      ])
  }

  @Test("a show that already carries that episode's progress sends no request")
  func alreadyCoveredShowSendsNoRequest() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertHydratedEpisode(itemID: showID, serverEpisodeID: "show-1-episode")

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [Self.episodeProgress(show: "show-1", episode: "show-1-episode", currentTime: 90)])

    #expect(harness.http.requests.isEmpty)
  }

  @Test("known episodes reconcile a newer finished server snapshot without expanding the show")
  func knownEpisodesReconcileFinishedSnapshotWithoutExpansion() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    for number in 1...8 {
      try await harness.insertHydratedEpisode(
        itemID: showID, serverEpisodeID: "episode-\(number)", currentTime: 599,
        serverUpdatedAt: Self.now.addingTimeInterval(TimeInterval(-number)))
    }

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: (1...8).map {
        Self.episodeProgress(
          show: "show-1", episode: "episode-\($0)", currentTime: 600, isFinished: true,
          lastUpdate: Self.now)
      })

    #expect(harness.http.requests.isEmpty)
    #expect(
      try harness.episodeProgressRows()
        == (1...8).map {
          EpisodeProgress(episodeID: "episode-\($0)", currentTime: 600, isFinished: true)
        })
  }

  @Test("a known episode persists a newer server hidden state without expanding the show")
  func knownEpisodeReconcilesHiddenStateWithoutExpansion() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertHydratedEpisode(
      itemID: showID, serverEpisodeID: "episode-1", currentTime: 90,
      serverUpdatedAt: Self.now.addingTimeInterval(-10))

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [
        Self.episodeProgress(
          show: "show-1", episode: "episode-1", currentTime: 90, hidden: true,
          lastUpdate: Self.now)
      ])

    #expect(harness.http.requests.isEmpty)
    #expect(try harness.hiddenFlags() == [true])
  }

  /// Only partially played episodes justify a request. Finished ones have nothing to resume, a
  /// zero position is not listening, and `hideFromContinueListening` means the server does not
  /// want it surfaced. Hydrating those would expand every show the account ever touched on
  /// every launch.
  @Test("finished, zero-position and hidden rows never trigger a request")
  func onlyPartiallyPlayedEpisodesAreHydrated() async throws {
    let harness = try await HydrationHarness()
    try await harness.insertShow("show-finished")
    try await harness.insertShow("show-zero")
    try await harness.insertShow("show-hidden")

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [
        Self.episodeProgress(show: "show-finished", episode: "ep", currentTime: 90, isFinished: true),
        Self.episodeProgress(show: "show-zero", episode: "ep", currentTime: 0),
        Self.episodeProgress(show: "show-hidden", episode: "ep", currentTime: 90, hidden: true),
      ])

    #expect(harness.http.requests.isEmpty)
  }

  @Test("item-level book progress is ignored")
  func bookProgressIsIgnored() async throws {
    let harness = try await HydrationHarness()
    try await harness.insertShow("a-book", mediaKind: "book")

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [
        MediaProgress(
          libraryItemID: "a-book", episodeID: nil, mediaItemID: nil, mediaItemType: nil,
          duration: nil, progress: nil, currentTime: 90, isFinished: false,
          hideFromContinueListening: false, ebookLocation: nil, ebookProgress: nil,
          lastUpdate: nil, startedAt: nil, finishedAt: nil)
      ])

    #expect(harness.http.requests.isEmpty)
  }

  /// The bound is per pass, and it spends its requests on what the account listened to most
  /// recently, the shows a user expects to see waiting for them.
  @Test("the show budget bounds the pass, most recently listened first")
  func budgetBoundsThePassInRecencyOrder() async throws {
    let harness = try await HydrationHarness(showBudget: 2)
    for name in ["show-old", "show-newest", "show-middle"] { try await harness.insertShow(name) }
    harness.http.enqueue(Self.expandedItemResponse(itemID: "show-newest"))
    harness.http.enqueue(Self.expandedItemResponse(itemID: "show-middle"))

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [
        Self.episodeProgress(show: "show-old", episode: "e1", currentTime: 90, lastUpdate: Self.now),
        Self.episodeProgress(
          show: "show-newest", episode: "e2", currentTime: 90,
          lastUpdate: Self.now.addingTimeInterval(200)),
        Self.episodeProgress(
          show: "show-middle", episode: "e3", currentTime: 90,
          lastUpdate: Self.now.addingTimeInterval(100)),
      ])

    #expect(
      harness.http.requests.map(\.url.path) == ["/api/items/show-newest", "/api/items/show-middle"])
  }

  /// A show the server cannot answer for is that show's problem: it earns a backoff entry in the
  /// shared show-failure store, so it stops costing a request on every foreground, and the rest
  /// of the pass still runs.
  @Test("a show-level failure records backoff and does not stop the remaining shows")
  func showLevelFailureIsIsolated() async throws {
    let harness = try await HydrationHarness()
    let missingID = try await harness.insertShow("show-missing")
    try await harness.insertShow("show-ok")
    harness.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))
    harness.http.enqueue(Self.expandedItemResponse(itemID: "show-ok"))

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [
        Self.episodeProgress(
          show: "show-missing", episode: "e1", currentTime: 90, lastUpdate: Self.now.addingTimeInterval(10)),
        Self.episodeProgress(show: "show-ok", episode: "show-ok-episode", currentTime: 90, lastUpdate: Self.now),
      ])

    #expect(
      harness.http.requests.map(\.url.path) == ["/api/items/show-missing", "/api/items/show-ok"])
    #expect(try harness.nextEligibleAttempt(itemID: missingID) != nil)
    #expect(try harness.episodeProgressRows().map(\.episodeID) == ["show-ok-episode"])
  }

  /// A server that is down says nothing about any individual show, so nothing is checkpointed as
  /// failing.
  @Test("a whole-pass failure stops the pass without recording per-show backoff")
  func transportFailureDoesNotPoisonBackoff() async throws {
    let harness = try await HydrationHarness()
    let brokenID = try await harness.insertShow("show-1")
    try await harness.insertShow("show-2")
    harness.http.enqueue(HTTPResponse(statusCode: 503, headers: [:], body: Data()))

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [
        Self.episodeProgress(
          show: "show-1", episode: "e1", currentTime: 90, lastUpdate: Self.now.addingTimeInterval(10)),
        Self.episodeProgress(show: "show-2", episode: "e2", currentTime: 90, lastUpdate: Self.now),
      ])

    #expect(harness.http.requests.map(\.url.path) == ["/api/items/show-1"])
    #expect(try harness.nextEligibleAttempt(itemID: brokenID) == nil)
  }

  /// Through the real entry point: signing in and pulling is enough. The pull's own `/api/me`
  /// response is handed straight to the hydration pass, so the episode and its progress are both
  /// on disk when the refresh reports done, with no need to open the show.
  @Test("a login refresh lands a part-heard episode without the show being opened")
  func loginRefreshHydratesWithoutOpeningTheShow() async throws {
    let harness = try await HydrationHarness()
    harness.enqueueLibraries([(id: "podcasts", name: "Podcasts", mediaType: "podcast")])
    harness.enqueueEpisodeProgress(show: "show-1", episode: "show-1-episode", currentTime: 90)
    harness.enqueuePodcastPage(showIDs: ["show-1"])
    harness.http.enqueue(Self.expandedItemResponse(itemID: "show-1"))

    await harness.syncEngine.refresh()

    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/libraries", "/api/me", "/api/libraries/podcasts/items", "/api/items/show-1",
      ])
    #expect(
      try harness.episodeProgressRows() == [
        EpisodeProgress(episodeID: "show-1-episode", currentTime: 90, isFinished: false)
      ])
  }

  // MARK: - Another device's reset

  static let observedAt = now.addingTimeInterval(-3_600)

  @Test("an episode this device observed that a complete snapshot omits is reset")
  func absentObservedEpisodeIsReset() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertHydratedEpisode(
      itemID: showID, serverEpisodeID: "episode-1", currentTime: 1_200,
      serverUpdatedAt: Self.observedAt, serverProgressId: "row-x")

    await harness.coordinator.hydrate(
      accountId: harness.accountID, progress: [], progressIsComplete: true)

    #expect(
      try harness.episodeProgressRows()
        == [EpisodeProgress(episodeID: "episode-1", currentTime: 0, isFinished: false)])
    #expect(try harness.conflictCount() == 0)
  }

  @Test("a recreated episode row resets it; a zero on the same row conflicts")
  func recreatedRowResetsAndSameRowConflicts() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertHydratedEpisode(
      itemID: showID, serverEpisodeID: "episode-1", currentTime: 1_200,
      serverUpdatedAt: Self.observedAt, serverProgressId: "row-x")
    try await harness.insertHydratedEpisode(
      itemID: showID, serverEpisodeID: "episode-2", currentTime: 1_200,
      serverUpdatedAt: Self.observedAt, serverProgressId: "row-z")

    await harness.coordinator.hydrate(
      accountId: harness.accountID,
      progress: [
        Self.episodeProgress(
          show: "show-1", episode: "episode-1", currentTime: 0, lastUpdate: Self.now,
          startedAt: Self.now, id: "row-y"),
        Self.episodeProgress(
          show: "show-1", episode: "episode-2", currentTime: 0, lastUpdate: Self.now,
          startedAt: Self.observedAt.addingTimeInterval(-86_400), id: "row-z"),
      ],
      progressIsComplete: true)

    #expect(
      try harness.episodeProgressRows() == [
        EpisodeProgress(episodeID: "episode-1", currentTime: 0, isFinished: false),
        EpisodeProgress(episodeID: "episode-2", currentTime: 1_200, isFinished: false),
      ])
    #expect(try harness.conflictCount() == 1)
  }

  @Test("an incomplete snapshot never resets an absent episode")
  func incompleteSnapshotNeverResetsAnAbsentEpisode() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertHydratedEpisode(
      itemID: showID, serverEpisodeID: "episode-1", currentTime: 1_200,
      serverUpdatedAt: Self.observedAt, serverProgressId: "row-x")

    await harness.coordinator.hydrate(
      accountId: harness.accountID, progress: [], progressIsComplete: false)

    #expect(
      try harness.episodeProgressRows()
        == [EpisodeProgress(episodeID: "episode-1", currentTime: 1_200, isFinished: false)])
  }

  @Test("a show refresh on a complete snapshot resets an episode the snapshot omits")
  func showRefreshResetsAnAbsentEpisode() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertHydratedEpisode(
      itemID: showID, serverEpisodeID: "show-1-episode", currentTime: 1_200,
      serverUpdatedAt: Self.observedAt, serverProgressId: "row-x")
    harness.http.enqueue(Self.expandedItemResponse(itemID: "show-1"))

    _ = try await harness.showRefresh.refresh(
      itemID: "show-1", prefetchedDetail: nil, progressSnapshot: [],
      progressSnapshotIsComplete: true)

    #expect(
      try harness.episodeProgressRows()
        == [EpisodeProgress(episodeID: "show-1-episode", currentTime: 0, isFinished: false)])
    #expect(try harness.conflictCount() == 0)
  }

  /// A row the mapping cannot use is still a row: its episode must not read as deleted.
  @Test("a show refresh never resets an episode whose row it could not map")
  func showRefreshKeepsAnEpisodeWhoseRowItCouldNotMap() async throws {
    let harness = try await HydrationHarness()
    let showID = try await harness.insertShow("show-1")
    try await harness.insertHydratedEpisode(
      itemID: showID, serverEpisodeID: "show-1-episode", currentTime: 1_200,
      serverUpdatedAt: Self.observedAt, serverProgressId: "row-x")
    harness.http.enqueue(Self.expandedItemResponse(itemID: "show-1"))

    _ = try await harness.showRefresh.refresh(
      itemID: "show-1", prefetchedDetail: nil,
      progressSnapshot: [
        MediaProgress(
          libraryItemID: "show-1", episodeID: "show-1-episode", mediaItemID: nil,
          mediaItemType: nil, duration: nil, progress: nil, currentTime: nil, isFinished: false,
          hideFromContinueListening: false, ebookLocation: nil, ebookProgress: nil,
          lastUpdate: Self.now, startedAt: nil, finishedAt: nil, serverProgressID: "row-x")
      ],
      progressSnapshotIsComplete: true)

    #expect(
      try harness.episodeProgressRows()
        == [EpisodeProgress(episodeID: "show-1-episode", currentTime: 1_200, isFinished: false)])
  }

  // MARK: - Fixtures

  fileprivate static let now = Date(timeIntervalSince1970: 1_700_000_000)

  private static func episodeProgress(
    show: String,
    episode: String,
    currentTime: Double,
    isFinished: Bool = false,
    hidden: Bool = false,
    lastUpdate: Date? = nil,
    startedAt: Date? = nil,
    id: String? = nil
  ) -> MediaProgress {
    MediaProgress(
      libraryItemID: show, episodeID: episode, mediaItemID: nil, mediaItemType: nil,
      duration: nil, progress: nil, currentTime: currentTime, isFinished: isFinished,
      hideFromContinueListening: hidden, ebookLocation: nil, ebookProgress: nil,
      lastUpdate: lastUpdate, startedAt: startedAt, finishedAt: nil, serverProgressID: id)
  }

  private static func expandedItemResponse(itemID: String) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: [
        "id": itemID, "libraryId": "podcasts", "mediaType": "podcast",
        "media": [
          "metadata": ["title": "A Show", "author": "An Author"],
          "episodes": [["id": "\(itemID)-episode", "title": "An Episode"]],
        ],
      ]))
  }
}

private struct EpisodeProgress: Equatable {
  let episodeID: String
  let currentTime: Double
  let isFinished: Bool
}

private final class HydrationHarness: @unchecked Sendable {
  let database: AppDatabase
  let http: FakeHTTPClient
  let coordinator: PodcastProgressHydrationCoordinator
  let showRefresh: PodcastRefreshCoordinator
  let syncEngine: SyncEngine
  private(set) var accountID: Int64 = 0
  private var libraryID: Int64 = 0

  init(showBudget: Int = 20) async throws {
    database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let clientUUID = "hydration-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let fake = FakeHTTPClient()
    http = fake
    let client = ABSClient(server: server, httpClient: fake, tokenStore: tokenStore)
    showRefresh = PodcastRefreshCoordinator(
      database: database,
      client: client,
      persistence: PodcastRefreshStore(database: database))
    coordinator = PodcastProgressHydrationCoordinator(
      database: database,
      showRefresh: showRefresh,
      showBudget: showBudget,
      now: { PodcastProgressHydrationTests.now },
      randomSource: { 1.0 })
    syncEngine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(),
      clock: FakeSyncClock(now: PodcastProgressHydrationTests.now),
      podcastProgressHydration: coordinator)

    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try account.insert(db)
      accountID = account.id!
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)
      libraryID = library.id!
    }
  }

  @discardableResult
  func insertShow(_ serverItemID: String, mediaKind: String = "podcast") async throws -> Int64 {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: serverItemID,
        mediaKind: mediaKind, title: serverItemID, sortTitle: serverItemID)
      try item.insert(db)
      return item.id!
    }
  }

  func insertHydratedEpisode(
    itemID: Int64,
    serverEpisodeID: String,
    currentTime: Double = 90,
    serverUpdatedAt: Date? = nil,
    serverProgressId: String? = nil
  ) async throws {
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountID, itemId: itemID, serverEpisodeId: serverEpisodeID,
        title: serverEpisodeID, lastSeenGeneration: 1)
      try episode.insert(db)
      var progress = MediaProgressRecord(
        accountId: accountID, itemId: itemID, podcastEpisodeId: episode.id!,
        currentTime: currentTime, isFinished: false, serverUpdatedAt: serverUpdatedAt,
        localSequence: 0, origin: .server,
        originKey: ProgressOrigin.serverOriginKey, serverProgressId: serverProgressId,
        serverProgressUpdatedAt: serverProgressId == nil ? nil : serverUpdatedAt)
      try progress.insert(db)
    }
  }

  func enqueueLibraries(_ libraries: [(id: String, name: String, mediaType: String)]) {
    http.enqueue(
      Self.jsonResponse([
        "libraries": libraries.map { ["id": $0.id, "name": $0.name, "mediaType": $0.mediaType] }
      ]))
  }

  func enqueueEpisodeProgress(show: String, episode: String, currentTime: Double) {
    http.enqueue(
      Self.jsonResponse([
        "mediaProgresses": [
          [
            "libraryItemId": show, "episodeId": episode, "currentTime": currentTime,
            "isFinished": false,
          ]
        ]
      ]))
  }

  func enqueuePodcastPage(showIDs: [String]) {
    http.enqueue(
      Self.jsonResponse([
        "results": showIDs.map {
          [
            "id": $0, "libraryId": "podcasts", "mediaType": "podcast",
            "media": ["metadata": ["title": "A Show"]],
          ]
        },
        "total": showIDs.count,
        "limit": 100,
        "page": 0,
      ]))
  }

  private static func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }

  func episodeProgressRows() throws -> [EpisodeProgress] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT e.serverEpisodeId AS episodeID, p.currentTime AS currentTime,
                 p.isFinished AS isFinished
          FROM mediaProgress p
          JOIN podcastEpisode e ON e.id = p.podcastEpisodeId
          ORDER BY e.serverEpisodeId
          """
      ).map {
        EpisodeProgress(
          episodeID: $0["episodeID"], currentTime: $0["currentTime"], isFinished: $0["isFinished"])
      }
    }
  }

  func conflictCount() throws -> Int {
    try database.read { db in try ProgressConflictRecord.fetchCount(db) }
  }

  func hiddenFlags() throws -> [Bool] {
    try database.read { db in
      try Bool.fetchAll(
        db,
        sql: "SELECT hideFromContinueListening FROM mediaProgress ORDER BY podcastEpisodeId")
    }
  }

  func nextEligibleAttempt(itemID: Int64) throws -> Date? {
    try database.read { db in
      try PodcastRefreshStateRecord.fetchOne(db, key: itemID)?.nextEligibleAttemptAt
    }
  }
}
