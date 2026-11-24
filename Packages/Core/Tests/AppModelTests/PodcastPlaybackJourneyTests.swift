import Foundation
import GRDB
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

@MainActor
@Suite("Podcast playback journey", .timeLimit(.minutes(1)))
struct PodcastPlaybackJourneyTests {
  @Test(
    "cached episode resumes and progresses independently, then closes before advancing Up Next")
  func cachedEpisodeThroughQueueAdvance() async throws {
    let environment = try await PodcastJourneyEnvironment()
    let harness = try environment.makeHarness()
    let episodeA = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-a"))
    let episodeB = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-b"))

    try await harness.queue.append(identity: episodeA)
    try await harness.queue.append(identity: episodeB)

    await harness.model.start(itemID: "show-1", episodeID: "episode-a")

    let firstLoad = try #require(
      harness.player.intents.compactMap { intent -> (String?, Double)? in
        guard case .load(let item, let position, _, _) = intent else { return nil }
        return (item.episodeID, position)
      }.first)
    #expect(firstLoad.0 == "episode-a")
    #expect(firstLoad.1 == 40, "episode resume uses its own cached progress")
    #expect(
      harness.http.requests.map(\.url.path).contains("/api/items/show-1/play/episode-a"))

    harness.player.pushProgress(
      Self.event(episodeID: "episode-a", phase: .playing, currentTime: 50, listenedDelta: 10))
    await environment.waitForEpisodeProgress(episodeRowID: harness.episodeARowID, position: 50)
    await harness.scheduler.waitForInterval(15)
    #expect(await harness.scheduler.fire())
    await harness.http.waitForRequests { $0.contains { $0.url.path.hasSuffix("/sync") } }

    harness.model.seek(toGlobalOffset: 70)
    harness.player.pushProgress(
      Self.event(episodeID: "episode-a", phase: .seeking, currentTime: 50, listenedDelta: 0))
    harness.player.pushProgress(
      Self.event(episodeID: "episode-a", phase: .playing, currentTime: 70, listenedDelta: 0))
    await environment.waitForEpisodeProgress(episodeRowID: harness.episodeARowID, position: 70)

    harness.player.send(.setRate(2))
    harness.player.pushProgress(
      Self.event(episodeID: "episode-a", phase: .playing, currentTime: 80, listenedDelta: 5))
    await environment.waitForEpisodeProgress(episodeRowID: harness.episodeARowID, position: 80)
    harness.model.togglePlayPause()
    harness.player.pushProgress(
      Self.event(episodeID: "episode-a", phase: .paused, currentTime: 80, listenedDelta: 0))
    await environment.waitForPhase(harness.model, .paused)

    let showProgress = try #require(
      try environment.progress(identity: .item(itemId: harness.showRowID)))
    #expect(showProgress.currentTime == 700, "episode ticks never collide with show progress")
    #expect(harness.player.intents.contains(.seek(toGlobalOffset: 70)))
    #expect(harness.player.intents.contains(.setRate(2)))
    #expect(harness.player.intents.contains(.toggle))

    harness.player.pushProgress(
      Self.event(episodeID: "episode-a", phase: .ended, currentTime: 100, listenedDelta: 5))
    await harness.http.waitForRequests {
      $0.contains { $0.url.path == "/api/items/show-1/play/episode-b" }
    }
    await environment.waitForLoadedEpisode(harness.model, episodeID: "episode-b")

    let paths = harness.http.requests.map(\.url.path)
    let closeIndex = try #require(paths.firstIndex(of: "/api/session/session-a/close"))
    let nextPlayIndex = try #require(paths.firstIndex(of: "/api/items/show-1/play/episode-b"))
    #expect(closeIndex < nextPlayIndex, "the former session closes before the next /play")
    // `acknowledgeStarted` is the last step of a successful start, so the loaded-episode wait above
    // can observe the queue mid-consumption.
    await environment.waitForEmptyQueue(harness.queue)
    #expect(
      await harness.queue.fetchQueue().isEmpty,
      "the completed row and the successfully started next one are both consumed")
    #expect(harness.model.activeEpisodeID == "episode-b")
    #expect(harness.model.loadedEpisodeID == "episode-b")
  }

  private static func event(
    episodeID: String, phase: PlayerPhase, currentTime: Double, listenedDelta: Double
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: Int(currentTime), itemId: "show-1", episodeID: episodeID, phase: phase,
      currentTime: currentTime, listenedDelta: listenedDelta)
  }
}

private struct PodcastJourneyHarness {
  let model: PlaybackModel
  let player: FakePlaybackControlling
  let queue: ListeningQueueStore
  let scheduler: FakePlaybackCadenceScheduling
  let http: FakeHTTPClient
  let showRowID: Int64
  let episodeARowID: Int64
}

private final class PodcastJourneyEnvironment: @unchecked Sendable {
  let database: AppDatabase
  let accountID: Int64
  let showRowID: Int64
  let episodeARowID: Int64
  let episodeBRowID: Int64
  let server: ABSServerConfig
  let account: TokenAccount
  let http = FakeHTTPClient(handler: podcastJourneyResponse)

  init() async throws {
    let localDatabase = try AppDatabase.inMemory()
    let localServer = try ABSServerConfig(
      url: try #require(URL(string: "https://podcast-journey.example.test")))
    database = localDatabase
    server = localServer
    let clientUUID = "podcast-journey-client"
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")

    let seeded = try await localDatabase.writeAsync { db -> (Int64, Int64, Int64, Int64) in
      var account = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: localServer.baseURL.absoluteString,
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show-1",
        mediaKind: "podcast", title: "The Show", sortTitle: "the show",
        durationSeconds: 9_999)
      try show.insert(db)
      var episodeA = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: "episode-a",
        title: "Episode A", durationSeconds: 100, lastSeenGeneration: 1)
      try episodeA.insert(db)
      var episodeB = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: "episode-b",
        title: "Episode B", durationSeconds: 120, lastSeenGeneration: 1)
      try episodeB.insert(db)
      var showProgress = MediaProgressRecord(
        accountId: account.id!, itemId: show.id!, currentTime: 700, isFinished: false,
        localSequence: 1, origin: .local, originKey: account.clientUUID)
      try showProgress.insert(db)
      var episodeProgress = MediaProgressRecord(
        accountId: account.id!, itemId: show.id!, podcastEpisodeId: episodeA.id!,
        currentTime: 40, isFinished: false, localSequence: 1, origin: .local,
        originKey: account.clientUUID)
      try episodeProgress.insert(db)
      return (account.id!, show.id!, episodeA.id!, episodeB.id!)
    }
    accountID = seeded.0
    showRowID = seeded.1
    episodeARowID = seeded.2
    episodeBRowID = seeded.3
  }

  @MainActor
  func makeHarness() throws -> PodcastJourneyHarness {
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let outbox = try OutboxStore(database: database)
    let scheduler = FakePlaybackCadenceScheduling()
    let coordinatorBox = PodcastJourneyCoordinatorBox()
    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account,
      accountId: accountID,
      notifySessionGoneRecovery: { itemID, episodeID in
        await coordinatorBox.coordinator?.recoverFromSessionGone(
          itemID: itemID, episodeID: episodeID)
      })
    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, scheduler: scheduler,
      requestDrain: { await drainer.drainOutbox() }, progressPersistInterval: 0)
    coordinatorBox.coordinator = coordinator
    let queue = ListeningQueueStore(database: database, accountId: accountID)
    let player = FakePlaybackControlling()
    let model = PlaybackModel(
      sync: coordinator, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(),
      bookmarkStore: DefaultPlaybackBookmarkStoring(database: database), listeningQueue: queue)
    return PodcastJourneyHarness(
      model: model, player: player, queue: queue, scheduler: scheduler, http: http,
      showRowID: showRowID, episodeARowID: episodeARowID)
  }

  func progress(identity: MediaProgressIdentity) throws -> MediaProgressRecord? {
    try MediaProgressDAO(database: database).fetchCurrent(accountId: accountID, identity: identity)
  }

  func waitForEpisodeProgress(episodeRowID: Int64, position: Double) async {
    await waitUntil {
      guard
        let row =
          try? progress(identity: .episode(itemId: showRowID, podcastEpisodeId: episodeRowID))
      else { return false }
      return row.currentTime == position
    }
  }

  @MainActor
  func waitForPhase(_ model: PlaybackModel, _ phase: PlaybackModel.Phase) async {
    await waitUntil { model.phase == phase }
  }

  func waitForEmptyQueue(_ queue: ListeningQueueStore) async {
    await waitUntil { await queue.fetchQueue().isEmpty }
  }

  @MainActor
  func waitForLoadedEpisode(_ model: PlaybackModel, episodeID: String) async {
    await waitUntil { model.loadedEpisodeID == episodeID }
  }
}

/// Answers the journey's `/play`, `/sync` and `/close` routes; anything else fails the request.
private func podcastJourneyResponse(_ request: HTTPRequest) throws -> HTTPResponse {
  let path = request.url.path
  switch path {
  case "/api/sessions/open":
    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
  case "/api/items/show-1/play/episode-a":
    return podcastJourneyPlayResponse(
      sessionID: "session-a", episodeID: "episode-a", currentTime: 10)
  case "/api/items/show-1/play/episode-b":
    return podcastJourneyPlayResponse(
      sessionID: "session-b", episodeID: "episode-b", currentTime: 0)
  default:
    if path.hasSuffix("/sync") || path.hasSuffix("/close") {
      return HTTPResponse(statusCode: 200, headers: [:], body: Data())
    }
    throw FakeHTTPClientError(message: "Unexpected request: \(path)")
  }
}

private func podcastJourneyPlayResponse(
  sessionID: String, episodeID: String, currentTime: Double
) -> HTTPResponse {
  let object: [String: Any] = [
    "id": sessionID,
    "libraryItemId": "show-1",
    "episodeId": episodeID,
    "mediaType": "podcast",
    "displayTitle": episodeID,
    "duration": episodeID == "episode-a" ? 100 : 120,
    "currentTime": currentTime,
    "playMethod": 0,
    "deviceInfo": ["deviceId": "server-echoed-id"],
    "audioTracks": [
      [
        "index": 1, "startOffset": 0, "duration": episodeID == "episode-a" ? 100 : 120,
        "title": episodeID, "contentUrl": "/api/items/show-1/file/\(episodeID)",
        "mimeType": "audio/mpeg",
      ]
    ],
    "chapters": [] as [Any],
  ]
  return HTTPResponse(
    statusCode: 200, headers: ["Content-Type": "application/json"],
    body: try! JSONSerialization.data(withJSONObject: object))
}

private final class PodcastJourneyCoordinatorBox: @unchecked Sendable {
  var coordinator: PlaybackSessionCoordinator?
}
