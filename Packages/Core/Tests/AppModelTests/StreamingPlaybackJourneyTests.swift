import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// Product journey 3 ("start/resume a single- or multi-file book, handle track/chapter
/// boundaries, seek, rate, pause, remote commands, ... app background/foreground without
/// backward progress or duplicate listening time") as one deterministic, composed-model test.
/// Drives the real `PlaybackModel` (AppModel) against a real `PlaybackSessionCoordinator` +
/// `OutboxDrainer` (SyncEngine), wired as `App/Whirr/AppEnvironment.swift` wires production
/// (`requestDrain` reaching a real drainer that calls the server), over a temporary on-disk
/// `AppDatabase`. Only the audio engine (`FakePlaybackControlling`) and the HTTP transport are
/// faked.
///
/// Boundary and seek arithmetic belong to `PlayerCoreTests`. This suite proves that engine events
/// flow through AppModel → SyncEngine → Persistence → server: final DB position/delta agree with
/// the fake server, and a completed seek fires exactly one immediate sync.
///
/// Waits are event-driven where the state has a mutation hook (`waitUntilRequestCount` via
/// `FakeHTTPClient.waitForRequests`, `waitUntilSchedulerInterval` via
/// `FakePlaybackCadenceScheduling.waitForInterval`). `waitUntilPosition`/`waitUntilSessionGone`
/// (a GRDB row) and `waitUntilPhase` (a plain `@Observable` property) have none, so they poll via
/// `TestSupport.waitUntil`.
@MainActor
@Suite("Streaming playback journey (PRODUCT journey 3)", .timeLimit(.minutes(1)))
struct StreamingPlaybackJourneyTests {

  @Test("single-file: resume, play, seek, rate change, pause, remote resume, background cadence, stop")
  func singleFileJourney() async throws {
    let env = try await JourneyEnvironment()
    // `PlaybackModel.init` kicks off launch recovery immediately, which best-effort-queries
    // `/api/sessions/open` (API-CONVENTIONS rule 6a). Every `start()` call awaits it first, so
    // it is always the first request any harness makes.
    env.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))
    let h = try await env.makeHarness()

    // MARK: resume → play
    env.http.enqueue(
      JourneyEnvironment.playResponse(itemID: JourneyEnvironment.soloItemID, currentTime: 0, duration: 600))
    // Every later `/sync`/`/close` just needs a bare 200. `FakeHTTPClient`'s queue is a flat
    // FIFO, not per-path (unlike `SessionScriptedHTTPClient`), so over-provision.
    env.enqueueGenericOKResponses(count: 20)
    await h.model.start(itemID: JourneyEnvironment.soloItemID)
    #expect(h.player.intents.contains(.play))

    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.soloItemID, phase: .playing, currentTime: 10, listenedDelta: 10))
    await env.waitUntilPosition(h, equals: 10)
    var expectedServerDelta = 10.0

    // Drain this first tick now (simulating the first periodic 15 s cadence sync landing) so the
    // seek step starts from an empty queue. Otherwise its one immediate drain would also flush
    // this backlog row, which says nothing about how many triggers the seek fired.
    let requestsBeforeFirstPeriodicSync = h.http.requests.count
    await env.waitUntilSchedulerInterval(h, equals: 15)
    await h.scheduler.fire()
    await env.waitUntilRequestCount(h, atLeast: requestsBeforeFirstPeriodicSync + 1)

    // MARK: seek - a completed seek must fire exactly one immediate sync, and the drain it
    // requests must reach the (fake) server, sending the resolved position.
    let requestsBeforeSeek = h.http.requests.count
    h.model.seek(toGlobalOffset: 300)
    #expect(h.player.intents.contains(.seek(toGlobalOffset: 300)))
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.soloItemID, phase: .seeking, currentTime: 10, listenedDelta: 0))
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.soloItemID, phase: .playing, currentTime: 300, listenedDelta: 0))
    await env.waitUntilPosition(h, equals: 300)
    await env.waitUntilRequestCount(h, atLeast: requestsBeforeSeek + 1)
    let newRequestsFromSeek = Array(h.http.requests[requestsBeforeSeek...])
    #expect(newRequestsFromSeek.count == 1, "the completed seek fired exactly one immediate sync")
    #expect(newRequestsFromSeek[0].url.path == JourneyEnvironment.syncPath(h))
    let seekBody = try #require(
      JSONSerialization.jsonObject(with: newRequestsFromSeek[0].body ?? Data()) as? [String: Any])
    #expect(seekBody["currentTime"] as? Double == 300, "the drain sent the resolved (seeked) position")

    // MARK: rate change - 2× for a real 5 s of wall time: position advances 10 s but listened
    // delta only accrues the real 5 s elapsed. The event's delta, not its position delta, is
    // what the server must end up seeing.
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.soloItemID, phase: .playing, currentTime: 310, listenedDelta: 5))
    await env.waitUntilPosition(h, equals: 310)
    expectedServerDelta += 5

    // MARK: pause - requests one immediate sync of its own.
    let requestsBeforePause = h.http.requests.count
    h.model.togglePlayPause()
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.soloItemID, phase: .paused, currentTime: 310, listenedDelta: 0))
    await env.waitUntilPhase(h, equals: .paused)
    await env.waitUntilRequestCount(h, atLeast: requestsBeforePause + 1)

    // MARK: remote resume - a remote/lock-screen "play" reaches the model through the same
    // `start` entry point as an in-app control, exercised here at the AppModel/SyncEngine seam.
    await h.model.start(itemID: JourneyEnvironment.soloItemID)
    #expect(h.player.intents.last == .play, "resume never re-calls startSession for the already-active item")
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.soloItemID, phase: .playing, currentTime: 310, listenedDelta: 0))
    await env.waitUntilSchedulerInterval(h, equals: 15)

    // MARK: background cadence - the periodic 15 s deadline fires while still playing (rule 7a:
    // backgrounding never closes an actively-playing session) and drains another sync.
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.soloItemID, phase: .playing, currentTime: 325, listenedDelta: 15))
    await env.waitUntilPosition(h, equals: 325)
    expectedServerDelta += 15
    let requestsBeforeFire = h.http.requests.count
    await h.scheduler.fire()
    await env.waitUntilRequestCount(h, atLeast: requestsBeforeFire + 1)

    // MARK: stop - the final credited tick lands before `stop()`'s own immediate sync/close.
    h.player.pushProgress(
      JourneyEnvironment.event(itemID: JourneyEnvironment.soloItemID, phase: .idle, currentTime: 330, listenedDelta: 5))
    await env.waitUntilPosition(h, equals: 330)
    expectedServerDelta += 5
    await h.model.stop()
    await env.waitUntilSessionGone(h)

    #expect(h.model.activeItemID == nil)
    #expect(h.model.phase == .idle)

    // Final DB position/delta.
    let finalProgress = try #require(try env.fetchProgress(accountId: h.accountId, itemRowId: h.soloItemRowId))
    #expect(finalProgress.currentTime == 330, "final DB position matches the last credited tick")

    // Server-observed total: sum of every `timeListened` the fake server received across every
    // sync/close request. Proves the drain reached the server with the correct delta (rate never
    // counted), never lost or doubled.
    let observedDelta = h.http.requests.compactMap { request -> Double? in
      guard let object = try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] else {
        return nil
      }
      return object["timeListened"] as? Double
    }.reduce(0, +)
    #expect(observedDelta == expectedServerDelta, "no listened second lost or double-counted across the whole journey")
    #expect(h.http.requests.last?.url.path.hasSuffix("/close") == true, "stop's own close was the final request")
  }

  @Test("multi-file: resume mid-book on a later track, cross a track boundary, position and delta stay continuous")
  func multiFileJourneyResumesMidBookAndCrossesABoundary() async throws {
    let env = try await JourneyEnvironment()
    env.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))
    let h = try await env.makeHarness()

    // Resume part-way through the second of two tracks (currentTime 150 is inside track 2's
    // [100, 200) span). The server's `/play` response carries that resume position.
    env.http.enqueue(
      JourneyEnvironment.playResponse(
        itemID: JourneyEnvironment.multiItemID, currentTime: 150, duration: 200, trackCount: 2))
    env.enqueueGenericOKResponses(count: 20)
    await h.model.start(itemID: JourneyEnvironment.multiItemID)
    let prepared = try #require(
      h.player.intents.compactMap { intent -> Double? in
        if case .load(_, let initialGlobalPosition, _, _) = intent { return initialGlobalPosition }
        return nil
      }.first)
    #expect(prepared == 150, "playback resumed from the server's mid-book position, not track/book start")

    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.multiItemID, phase: .playing, currentTime: 170, listenedDelta: 20))
    await env.waitUntilPosition(h, equals: 170, itemRowId: h.multiItemRowId)

    // Crossing the track boundary: PlayerCore flushes the outgoing track, then briefly buffers
    // the next one (zero listening time) before resuming play. AppModel/SyncEngine only see the
    // resulting phase/position events, never track identity (one global timeline,
    // ARCHITECTURE.md), so this is what a real crossing looks like from here.
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.multiItemID, phase: .buffering, currentTime: 200, listenedDelta: 0))
    h.player.pushProgress(
      JourneyEnvironment.event(
        itemID: JourneyEnvironment.multiItemID, phase: .playing, currentTime: 205, listenedDelta: 5))
    await env.waitUntilPosition(h, equals: 205, itemRowId: h.multiItemRowId)

    h.player.pushProgress(
      JourneyEnvironment.event(itemID: JourneyEnvironment.multiItemID, phase: .idle, currentTime: 205, listenedDelta: 0)
    )
    await h.model.stop()
    await env.waitUntilSessionGone(h)

    let finalProgress = try #require(try env.fetchProgress(accountId: h.accountId, itemRowId: h.multiItemRowId))
    #expect(finalProgress.currentTime == 205, "position advanced continuously across the boundary, never backward")

    let observedDelta = h.http.requests.compactMap { request -> Double? in
      guard let object = try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] else {
        return nil
      }
      return object["timeListened"] as? Double
    }.reduce(0, +)
    #expect(observedDelta == 25, "20 s before the boundary + 5 s after; the buffering gap contributed nothing")
  }
}

// MARK: - Harness

private struct Harness {
  let model: PlaybackModel
  let player: FakePlaybackControlling
  let coordinator: PlaybackSessionCoordinator
  let sessionStore: PlaybackSessionStore
  let outbox: OutboxStore
  let scheduler: FakePlaybackCadenceScheduling
  let http: FakeHTTPClient
  let accountId: Int64
  let soloItemRowId: Int64
  let multiItemRowId: Int64
}

/// One journey's fixed identity (server/account/two items: a single-file and a multi-file
/// book), backed by a real temporary on-disk `AppDatabase`, wired as `AppEnvironment.swift`
/// wires production: `PlaybackSessionCoordinator`'s `requestDrain` closure reaches a real
/// `OutboxDrainer`, which calls the (fake) server.
private final class JourneyEnvironment: @unchecked Sendable {
  static let soloItemID = "item_journey_solo"
  static let multiItemID = "item_journey_multi"
  static let libraryID = "lib-journey"

  private let fixture: SuiteOnDiskDatabases
  let server: ABSServerConfig
  let account: TokenAccount
  let clientUUID: String
  let accountId: Int64
  let database: AppDatabase
  let http: FakeHTTPClient

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "StreamingPlaybackJourneyTests")
    self.fixture = fixture
    server = try ABSServerConfig(url: try #require(URL(string: "https://journey.example.test")))
    clientUUID = UUID().uuidString
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
    http = FakeHTTPClient()

    let database = try fixture.scope.open(fileAttributes: POSIXFileAttributeApplier())
    self.database = database
    let accountDAO = AccountDAO(database: database)
    let saved = try accountDAO.save(
      AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1"))
    accountId = try #require(saved.id)
  }

  @MainActor
  func makeHarness() async throws -> Harness {
    let libraryRowId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let soloItemRowId = try #require(
      try itemDAO.upsert(
        ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: Self.soloItemID, mediaKind: "book",
          title: "Solo Book", sortTitle: "solo book")
      ).id)
    let multiItemRowId = try #require(
      try itemDAO.upsert(
        ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: Self.multiItemID, mediaKind: "book",
          title: "Multi Book", sortTitle: "multi book")
      ).id)

    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access-token", refreshToken: "canary-refresh-token"), for: account)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let scheduler = FakePlaybackCadenceScheduling()
    let box = JourneyCoordinatorBox()

    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId,
      notifySessionGoneRecovery: { itemID, episodeID in
        await box.coordinator?.recoverFromSessionGone(itemID: itemID, episodeID: episodeID)
      }
    )
    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox,
      clientSessionIDGenerator: { UUID().uuidString }, scheduler: scheduler,
      requestDrain: { await drainer.drainOutbox() },
      // This suite proves the pipeline end to end, so every pushed tick must be durable as soon
      // as it is processed. The throttle's own coalescing is covered by
      // `PlaybackProgressTickTests`. `0` persists every ordinary tick immediately, so the
      // position barriers below do not wait on a real 15 s wall-clock interval.
      progressPersistInterval: 0
    )
    box.coordinator = coordinator

    let player = FakePlaybackControlling()
    let model = PlaybackModel(
      sync: coordinator, player: player, account: FakeAccountLifecycle(), appLifecycle: FakeAppLifecycle())

    return Harness(
      model: model, player: player, coordinator: coordinator, sessionStore: sessionStore, outbox: outbox,
      scheduler: scheduler, http: http, accountId: accountId, soloItemRowId: soloItemRowId,
      multiItemRowId: multiItemRowId)
  }

  // MARK: - Waits

  /// No mutation hook (a real on-disk GRDB row written by the real `OutboxDrainer`/
  /// `PlaybackSessionCoordinator`), so this polls via the shared `waitUntil`.
  func waitUntilPosition(_ h: Harness, equals expected: Double, itemRowId: Int64? = nil) async {
    let target = itemRowId ?? h.soloItemRowId
    await waitUntil {
      guard let progress = try? fetchProgress(accountId: h.accountId, itemRowId: target) else { return false }
      return progress.currentTime == expected
    }
  }

  /// No mutation hook: `phase` is a plain `@Observable` property on the real `PlaybackModel`,
  /// so this polls via the shared `waitUntil`.
  @MainActor
  func waitUntilPhase(_ h: Harness, equals expected: PlaybackModel.Phase) async {
    await waitUntil { h.model.phase == expected }
  }

  func waitUntilRequestCount(_ h: Harness, atLeast count: Int) async {
    await h.http.waitForRequests { $0.count >= count }
  }

  /// Waits on the scheduler's pending-deadline interval. `PlaybackModel.handle(progressEvent:)`
  /// sets `model.phase`/`currentTime` synchronously before the awaited
  /// `notifyPlaybackPhase`/cadence-report call that reschedules the deadline, so waiting on
  /// `model.phase` alone can race ahead of the cadence side effect. Event-driven via
  /// `FakePlaybackCadenceScheduling.waitForInterval`, not a poll.
  func waitUntilSchedulerInterval(_ h: Harness, equals expected: TimeInterval?) async {
    await h.scheduler.waitForInterval { $0 == expected }
  }

  /// No mutation hook (see `waitUntilPosition`), so this polls via the shared `waitUntil`.
  func waitUntilSessionGone(_ h: Harness) async {
    await waitUntil { (try? h.sessionStore.fetchActiveSession(accountId: h.accountId)) == nil }
  }

  func fetchProgress(accountId: Int64, itemRowId: Int64) throws -> MediaProgressRecord? {
    try MediaProgressDAO(database: database).fetchCurrent(
      accountId: accountId, identity: .item(itemId: itemRowId))
  }

  /// An over-provisioned run of bare `200`s for every `/sync`/`/close` the journey's drains
  /// make. `FakeHTTPClient`'s queue is flat FIFO (unlike the per-path
  /// `SessionScriptedHTTPClient`), and this journey only checks the order and content of a few
  /// requests, so it keeps the queue topped up rather than counting every drain.
  func enqueueGenericOKResponses(count: Int) {
    for _ in 0..<count {
      http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    }
  }

  static func syncPath(_ h: Harness) -> String { "/api/session/\(Self.playSessionID)/sync" }
  static let playSessionID = "server-session-journey"

  static func event(itemID: String, phase: PlayerPhase, currentTime: Double, listenedDelta: Double)
    -> PlaybackProgressEvent
  {
    PlaybackProgressEvent(
      sequence: 1, itemId: itemID, phase: phase, currentTime: currentTime, listenedDelta: listenedDelta)
  }

  static func playResponse(itemID: String, currentTime: Double, duration: Double, trackCount: Int = 1) -> HTTPResponse {
    let trackDuration = duration / Double(trackCount)
    let tracks: [[String: Any]] = (0..<trackCount).map { index in
      [
        "index": index + 1, "startOffset": Double(index) * trackDuration, "duration": trackDuration,
        "title": "Track \(index + 1)", "contentUrl": "/api/items/\(itemID)/file/10\(index)", "mimeType": "audio/mpeg",
      ]
    }
    let object: [String: Any] = [
      "id": playSessionID,
      "libraryItemId": itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": duration,
      "currentTime": currentTime,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": tracks,
      "chapters": [] as [Any],
    ]
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }

}

/// Mirrors `App/Whirr/Playback/PlaybackCoordinatorBox.swift`. Breaks the construction-order
/// cycle between the coordinator's `requestDrain` and the drainer's `notifySessionGoneRecovery`
/// (this Core-package test target cannot import the App target).
private final class JourneyCoordinatorBox: @unchecked Sendable {
  weak var coordinator: PlaybackSessionCoordinator?
}
