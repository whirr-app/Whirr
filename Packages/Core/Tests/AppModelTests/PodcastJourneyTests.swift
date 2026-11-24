import Foundation
import GRDB
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// Composed podcast journeys. Keeps the real stores and coordinators between the two actual
/// system boundaries: HTTP and background transfer.
@MainActor
@Suite("Podcast journeys", .timeLimit(.minutes(1)))
struct PodcastJourneyTests {
  @Test(
    "paginated discovery through refresh, device download, offline resume/finish, local-all, and queue advance"
  )
  func fullOfflineJourney() async throws {
    let environment = try await PodcastJourneyTestEnvironment()

    try await environment.discoverShowOnSecondPage()
    let discovered = await environment.firstBrowseEmission()
    #expect(
      discovered.map(\.serverItemId) == [
        "another-show", PodcastJourneyTestEnvironment.showID,
      ])
    #expect(discovered.allSatisfy { $0.category == .podcast })

    try environment.seedCachedEpisode()
    let showModel = PodcastShowModel(
      itemID: PodcastJourneyTestEnvironment.showID,
      reading: DefaultPodcastReading(database: environment.database),
      refreshing: environment.makeRefreshCoordinator(progress: nil))
    await environment.waitUntilMainActor { showModel.episodes.map(\.id) == ["cached"] }
    #expect(showModel.state == .loaded, "opening is cache-first")

    await showModel.refresh()
    await environment.waitUntilMainActor {
      Set(showModel.episodes.map(\.id)) == Set(["episode-a", "episode-b"])
    }
    #expect(showModel.state == .loaded)

    let download = try environment.makeDownloadHarness()
    try await download.coordinator.requestEpisodeDownload(
      itemID: PodcastJourneyTestEnvironment.showID, episodeID: "episode-a")
    try await download.coordinator.requestEpisodeDownload(
      itemID: PodcastJourneyTestEnvironment.showID, episodeID: "episode-b")
    await TestSupport.waitUntil { download.background.calls.count == 2 }
    try environment.finishAllDownloads(download)
    await TestSupport.waitUntil {
      (try? download.store.fetchDownloads(itemId: environment.showRowID))
        .map { $0.count == 2 && $0.allSatisfy { $0.state == .completed } } ?? false
    }

    let queue = ListeningQueueStore(
      database: environment.database, accountId: environment.accountID)
    let episodeA = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: PodcastJourneyTestEnvironment.showID, episodeID: "episode-a"))
    let episodeB = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: PodcastJourneyTestEnvironment.showID, episodeID: "episode-b"))
    try await queue.append(identity: episodeA)
    try await queue.append(identity: episodeB)

    do {
      let firstPlayback = try environment.makeOfflinePlayback(
        download: download, queue: queue, nextSessionID: "offline-a")
      await firstPlayback.model.start(
        itemID: PodcastJourneyTestEnvironment.showID, episodeID: "episode-a")
      #expect(firstPlayback.loadedPosition == 0)
      firstPlayback.player.pushProgress(
        environment.event(episodeID: "episode-a", phase: .playing, time: 35, delta: 35))
      await environment.waitForProgress(episodeID: "episode-a", position: 35)
      firstPlayback.player.pushProgress(
        environment.event(episodeID: "episode-a", phase: .paused, time: 35, delta: 0))
      await environment.waitUntilMainActor { firstPlayback.model.phase == .paused }
    }

    // A fresh coordinator/model over the same durable state is the deterministic relaunch seam.
    let resumed = try environment.makeOfflinePlayback(
      download: download, queue: queue, nextSessionID: "offline-b")
    await resumed.model.start(
      itemID: PodcastJourneyTestEnvironment.showID, episodeID: "episode-a")
    #expect(resumed.loadedPosition == 35)

    resumed.player.pushProgress(
      environment.event(episodeID: "episode-a", phase: .ended, time: 100, delta: 65))
    await environment.waitUntilMainActor { resumed.model.loadedEpisodeID == "episode-b" }
    // `acknowledgeStarted` is the last step of a successful start, so the loaded-episode wait above
    // can observe the queue mid-consumption.
    await TestSupport.waitUntil { await queue.fetchQueue().isEmpty }
    #expect(
      await queue.fetchQueue().isEmpty,
      "both the completed row and the successfully started next one are consumed")

    let closed = try #require(
      try await environment.database.readAsync { db in
        try PlaybackSessionRecord
          .filter(Column("accountId") == environment.accountID)
          .filter(Column("state") == PlaybackSessionState.closedAwaitingUpload.rawValue)
          .order(Column("id"))
          .fetchOne(db)
      })
    let episodeARowID = try environment.episodeRowID("episode-a")
    #expect(closed.podcastEpisodeId == episodeARowID)
    #expect(closed.globalPosition == 100)
    #expect(closed.listenedDeltaSeconds == 100)

    let reconnectHTTP = FakeHTTPClient()
    reconnectHTTP.enqueue(
      Self.jsonResponse([
        "results": [
          ["id": closed.clientSessionId, "success": true, "progressSynced": true]
        ]
      ]))
    let reconnectClient = ABSClient(
      server: environment.server, httpClient: reconnectHTTP,
      tokenStore: environment.tokenStore)
    let drainer = OutboxDrainer(
      outboxStore: environment.outbox, database: environment.database,
      absClient: reconnectClient, account: environment.tokenAccount,
      accountId: environment.accountID)
    await drainer.drainLocalSessionUploads(
      now: environment.clock.now(), randomUnit: { 1 })

    #expect(reconnectHTTP.requests.map(\.url.path) == ["/api/session/local-all"])
    #expect(try environment.sessionStore.fetchSession(id: try #require(closed.id)) == nil)
  }

  @Test("server episode progress reaches its row, projection, Home, and resume position")
  func serverProgressIngestsAndResumes() async throws {
    let environment = try await PodcastJourneyTestEnvironment()
    try await environment.discoverShowOnSecondPage()

    let coordinator = environment.makeRefreshCoordinator(
      progress: (episodeID: "episode-a", currentTime: 30))
    _ = try await coordinator.refresh(itemID: PodcastJourneyTestEnvironment.showID)

    let episodeRowID = try environment.episodeRowID("episode-a")
    let progress = try #require(
      try MediaProgressDAO(database: environment.database).fetchCurrent(
        accountId: environment.accountID,
        identity: .episode(
          itemId: environment.showRowID, podcastEpisodeId: episodeRowID)))
    #expect(progress.currentTime == 30)
    #expect(progress.origin == .server)

    var episodeIterator =
      DefaultPodcastReading(database: environment.database)
      .observeEpisodes(itemId: PodcastJourneyTestEnvironment.showID)
      .makeAsyncIterator()
    let episodes = try #require(await episodeIterator.next())
    #expect(episodes.first { $0.id == "episode-a" }?.progressSeconds == 30)

    let home = HomeModel(
      home: DefaultHomeReading(database: environment.database),
      sync: FakeSyncCoordinating(), filter: .podcasts)
    await environment.waitUntilMainActor {
      home.continueListening.first?.episodeID == "episode-a"
    }
    #expect(home.continueListening.first?.progressSeconds == 30)
    #expect(home.continueListening.first?.episodeTitle == "Episode A")

    let playbackHTTP = FakeHTTPClient()
    playbackHTTP.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))
    playbackHTTP.enqueue(environment.playResponse(episodeID: "episode-a"))
    let playbackClient = ABSClient(
      server: environment.server, httpClient: playbackHTTP,
      tokenStore: environment.tokenStore)
    let sync = PlaybackSessionCoordinator(
      client: playbackClient, database: environment.database,
      outbox: environment.outbox)
    let player = FakePlaybackControlling()
    let playback = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(),
      bookmarkStore: DefaultPlaybackBookmarkStoring(database: environment.database))
    await playback.start(
      itemID: PodcastJourneyTestEnvironment.showID, episodeID: "episode-a")

    let loadedPosition = player.intents.compactMap { intent -> Double? in
      guard case .load(_, let position, _, _) = intent else { return nil }
      return position
    }.last
    #expect(loadedPosition == 30)
    #expect(
      playbackHTTP.requests.map(\.url.path) == [
        "/api/sessions/open", "/api/items/show-journey/play/episode-a",
      ])
  }

  private static func jsonResponse(_ object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

private final class PodcastJourneyTestEnvironment: @unchecked Sendable {
  static let libraryID = "podcast-library"
  static let showID = "show-journey"

  let database: AppDatabase
  let server: ABSServerConfig
  let tokenAccount: TokenAccount
  let tokenStore: InMemoryTokenStore
  let accountID: Int64
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_800_000_000))

  private let fixture: SuiteOnDiskDatabases
  private var root: URL { fixture.scope.directoryURL }
  private let discoveryHTTP = FakeHTTPClient()

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "PodcastJourneyTests")
    self.fixture = fixture
    database = try fixture.scope.open(fileAttributes: InertFileAttributes())
    server = try ABSServerConfig(
      url: try #require(URL(string: "https://podcast-journey.example.test")))
    let clientUUID = "podcast-journey-client"
    tokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "journey-user")
    tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "journey-user", serverVersion: "2.35.1"))
    accountID = try #require(account.id)
    outbox = try OutboxStore(database: database)
    sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
  }

  var showRowID: Int64 {
    get throws {
      try #require(
        try ItemDAO(database: database)
          .fetchOne(accountId: accountID, serverItemId: Self.showID)?.id)
    }
  }

  func episodeRowID(_ episodeID: String) throws -> Int64 {
    try #require(
      try PodcastEpisodeDAO(database: database)
        .fetchOne(itemId: showRowID, serverEpisodeId: episodeID)?.id)
  }

  func discoverShowOnSecondPage() async throws {
    discoveryHTTP.enqueue(
      Self.jsonResponse([
        "libraries": [
          ["id": Self.libraryID, "name": "Podcasts", "mediaType": "podcast"]
        ]
      ]))
    discoveryHTTP.enqueue(Self.jsonResponse(["mediaProgresses": []]))
    discoveryHTTP.enqueue(
      Self.page(
        items: [("another-show", "Another Show")], total: 2, page: 0))
    discoveryHTTP.enqueue(
      Self.page(items: [(Self.showID, "Journey Show")], total: 2, page: 1))
    let client = ABSClient(
      server: server, httpClient: discoveryHTTP, tokenStore: tokenStore)
    let engine = SyncEngine.make(
      client: client, database: database, diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(), clock: clock, randomSource: { 1 },
      pageLimit: 1)
    await engine.refresh()
    #expect(
      discoveryHTTP.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }
        .map(\.url.query) == [
          "limit=1&page=0&minified=1&sort=id",
          "limit=1&page=1&minified=1&sort=id",
        ])
  }

  func firstBrowseEmission() async -> [ItemSummary] {
    var iterator =
      DefaultLibraryReading(database: database)
      .observeBrowseList(category: .podcast)
      .makeAsyncIterator()
    return await iterator.next() ?? []
  }

  func seedCachedEpisode() throws {
    _ = try PodcastEpisodeDAO(database: database).upsert(
      PodcastEpisodeRecord(
        accountId: accountID, itemId: showRowID,
        serverEpisodeId: "cached", title: "Cached Episode",
        durationSeconds: 80, lastSeenGeneration: 1))
  }

  func makeRefreshCoordinator(
    progress: (episodeID: String, currentTime: Double)?
  ) -> PodcastRefreshCoordinator {
    let http = FakeHTTPClient()
    http.enqueue(Self.expandedShowResponse())
    let progresses: [[String: Any]] =
      progress.map {
        [
          [
            "libraryItemId": Self.showID, "episodeId": $0.episodeID,
            "currentTime": $0.currentTime, "isFinished": false,
            "lastUpdate": 1_800_000_000_000,
          ]
        ]
      } ?? []
    http.enqueue(Self.jsonResponse(["mediaProgresses": progresses]))
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    return PodcastRefreshCoordinator(
      database: database, client: client,
      persistence: PodcastRefreshStore(database: database))
  }

  struct DownloadHarness {
    let store: DownloadStore
    let files: DownloadFileStore
    let background: FakeBackgroundTransferring
    let coordinator: DownloadCoordinator
  }

  func makeDownloadHarness() throws -> DownloadHarness {
    let store = try DownloadStore(database: database)
    let files = try DownloadFileStore(
      rootURL: root.appendingPathComponent("Downloads"),
      fileAttributes: InertFileAttributes(), downloadStore: store)
    let background = FakeBackgroundTransferring()
    let client = ABSClient(
      server: server, httpClient: FakeHTTPClient(), tokenStore: tokenStore)
    let coordinator = DownloadCoordinator.make(
      client: client, database: database, downloadStore: store,
      downloadFileStore: files, backgroundTransferring: background,
      downloadPreferences: FakeDownloadPreferences(),
      networkConditions: FakeNetworkConditions(),
      diagnostics: FakeDiagnosticsRecording(),
      freeSpaceReporting: FakeFreeSpaceReporting())
    return DownloadHarness(
      store: store, files: files, background: background, coordinator: coordinator)
  }

  func finishAllDownloads(_ harness: DownloadHarness) throws {
    for row in try harness.store.fetchDownloads(itemId: showRowID) {
      let id = try #require(row.id)
      let temporary = root.appendingPathComponent("transfer-\(id)")
      try Data(repeating: 0x42, count: Int(row.expectedBytes)).write(to: temporary)
      harness.background.pushEvent(
        .finished(
          identity: .abs(rowID: id), temporaryFileURL: temporary,
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: row.expectedMimeType,
            contentLength: row.expectedBytes)))
    }
  }

  @MainActor
  func makeOfflinePlayback(
    download: DownloadHarness, queue: ListeningQueueStore, nextSessionID: String
  ) throws -> PodcastJourneyPlaybackHarness {
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(failure: FakeHTTPClientError(message: "offline")),
      tokenStore: tokenStore)
    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, clock: clock,
      clientSessionIDGenerator: { nextSessionID },
      downloadStore: download.store, downloadFileStore: download.files)
    let player = FakePlaybackControlling()
    let model = PlaybackModel(
      sync: coordinator, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(),
      bookmarkStore: DefaultPlaybackBookmarkStoring(database: database),
      listeningQueue: queue)
    return PodcastJourneyPlaybackHarness(model: model, player: player)
  }

  func event(
    episodeID: String, phase: PlayerPhase, time: Double, delta: Double
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: Int(time), itemId: Self.showID, episodeID: episodeID,
      phase: phase, currentTime: time, listenedDelta: delta)
  }

  func playResponse(episodeID: String) -> HTTPResponse {
    Self.jsonResponse([
      "id": "server-session-\(episodeID)",
      "libraryItemId": Self.showID,
      "episodeId": episodeID,
      "mediaType": "podcast",
      "displayTitle": episodeID,
      "duration": 100,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": [
        [
          "index": 0, "startOffset": 0, "duration": 100,
          "title": episodeID,
          "contentUrl": "/api/items/\(Self.showID)/file/\(episodeID)",
          "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ])
  }

  func waitForProgress(episodeID: String, position: Double) async {
    await TestSupport.waitUntil {
      guard let episode = try? episodeRowID(episodeID),
        let row = try? MediaProgressDAO(database: database).fetchCurrent(
          accountId: accountID,
          identity: .episode(itemId: showRowID, podcastEpisodeId: episode))
      else { return false }
      return row.currentTime == position
    }
  }

  @MainActor
  func waitUntilMainActor(_ predicate: @escaping @MainActor () -> Bool) async {
    await TestSupport.waitUntil { predicate() }
  }

  private static func page(
    items: [(String, String)], total: Int, page: Int
  ) -> HTTPResponse {
    jsonResponse([
      "results": items.map { id, title in
        [
          "id": id, "libraryId": Self.libraryID, "mediaType": "podcast",
          "media": ["metadata": ["title": title]],
        ] as [String: Any]
      },
      "total": total, "limit": 1, "page": page,
    ])
  }

  private static func expandedShowResponse() -> HTTPResponse {
    jsonResponse([
      "id": Self.showID,
      "libraryId": Self.libraryID,
      "mediaType": "podcast",
      "media": [
        "metadata": ["title": "Journey Show", "author": "Journey Host"],
        "episodes": [
          episodeFixture(id: "episode-a", title: "Episode A", duration: 100),
          episodeFixture(id: "episode-b", title: "Episode B", duration: 120),
        ],
      ] as [String: Any],
    ])
  }

  private static func episodeFixture(
    id: String, title: String, duration: Double
  ) -> [String: Any] {
    [
      "id": id, "title": title, "duration": duration,
      "publishedAt": 1_800_000_000_000,
      "audioFile": [
        "ino": "ino-\(id)", "metadata": ["size": 8], "mimeType": "audio/mpeg",
        "duration": duration,
      ],
    ]
  }

  private static func jsonResponse(_ object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

@MainActor
private struct PodcastJourneyPlaybackHarness {
  let model: PlaybackModel
  let player: FakePlaybackControlling

  var loadedPosition: Double? {
    player.intents.compactMap { intent -> Double? in
      guard case .load(_, let position, _, _) = intent else { return nil }
      return position
    }.last
  }
}
