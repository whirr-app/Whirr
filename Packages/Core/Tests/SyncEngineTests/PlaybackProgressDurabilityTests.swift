import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Durability of the resume position across the ways a playback session can end while the audio
/// keeps running: what would the app resume at, asserted against the durable `MediaProgress` row
/// `resolveStartPosition` reads. Lifecycle wiring and the close protocol live in
/// `PlaybackLifecycleTests`, the throttle in `PlaybackProgressTickTests`.
///
/// Uses an advanceable `FakeSyncClock`: the throttle's persist decision depends on elapsed time,
/// so a frozen clock would hold every tick in memory and make the assertions tautologies.
@Suite("Playback progress durability", .timeLimit(.minutes(1)))
struct PlaybackProgressDurabilityTests {

  /// The cadence phase folds `.preparing`/`.buffering`/`.seeking` into one `.buffering`
  /// (`PlaybackModel.mapCadencePhase`), so a scrub or a stall on a slow connection looks like a
  /// stop. Backgrounding in that window must not end the session: the audio carries on under the
  /// background-audio mode, and rule 7a says a still-playing session stays open. Otherwise every
  /// later tick lands on a missing session and the resume position freezes at screen lock.
  @Test("backgrounding mid-buffer keeps recording progress while the audio plays on")
  func backgroundingWhileBufferingDoesNotFreezeProgress() async throws {
    let h = try await ProgressDurabilityHarness()
    try await h.startPlayingSession()
    await h.tick(currentTime: 100, delta: 100)
    #expect(try h.currentProgress()?.currentTime == 100)

    // A scrub (or a buffering stall) drops the phase out of `.playing`, and the screen locks in
    // that same second.
    await h.coordinator.notifyPlaybackPhase(.buffering)
    await h.stubOK(path: ProgressDurabilityHarness.closePath)
    await h.stubOK(path: ProgressDurabilityHarness.syncPath)
    await h.coordinator.handleAppBackgrounded()

    // Five more minutes of audio, ticked at the ordinary persist cadence.
    for step in 1...20 {
      h.clock.advance(by: 15)
      await h.tick(currentTime: 100 + Double(step) * 15, delta: 15)
    }

    let progress = try #require(try h.currentProgress())
    #expect(
      progress.currentTime == 400,
      "five minutes of listening after backgrounding must not be lost")
  }

  /// The other half of the same gate: a paused session still closes on backgrounding, or it leaks
  /// open (rule 7). `PlaybackLifecycleTests` asserts the close protocol; this pins the phase gate.
  @Test("backgrounding while paused still closes the session")
  func backgroundingWhilePausedStillCloses() async throws {
    let h = try await ProgressDurabilityHarness()
    try await h.startPlayingSession()
    await h.tick(currentTime: 100, delta: 100)

    await h.coordinator.notifyPlaybackPhase(.paused)
    await h.stubOK(path: ProgressDurabilityHarness.syncPath)
    await h.coordinator.notifyImmediateSyncTrigger(.paused)
    await h.stubOK(path: ProgressDurabilityHarness.closePath)
    await h.coordinator.handleAppBackgrounded()

    #expect(try h.sessionStore.fetchActiveSession(accountId: h.accountId) == nil)
    #expect(await h.http.requestCount(forPath: ProgressDurabilityHarness.closePath) == 1)
  }

  /// The safety net under the phase gate. A session can end while the audio plays on in ways no
  /// lifecycle handling covers: the server 404s it and the drainer marks it gone, a replacement
  /// `/play` fails, the process is killed between a close and a restart. `persistTick` must keep
  /// writing the resume position after the session row leaves `.active`.
  ///
  /// The coordinator's cached tick target still resolves the `.gone` row here, so this is the
  /// boundary where the cache stops covering a missing session (the next test is where it matters).
  @Test("progress keeps persisting after the session is marked gone mid-playback")
  func ticksAfterSessionGoneStillPersistProgress() async throws {
    let h = try await ProgressDurabilityHarness()
    try await h.startPlayingSession()
    await h.tick(currentTime: 100, delta: 100)

    let sessionId = try #require(try h.sessionStore.fetchActiveSession(accountId: h.accountId)?.id)
    _ = try h.sessionStore.markSessionGone(sessionId: sessionId, now: h.clock.now())
    #expect(try h.sessionStore.fetchActiveSession(accountId: h.accountId) == nil)

    for step in 1...20 {
      h.clock.advance(by: 15)
      await h.tick(currentTime: 100 + Double(step) * 15, delta: 15)
    }

    let progress = try #require(try h.currentProgress())
    #expect(
      progress.currentTime == 400,
      "a dead session must not take the resume position down with it")
  }

  /// `recoverFromSessionGone` opens a replacement session and swallows the failure if `/play`
  /// cannot be reached (the common case, since whatever killed the session usually fails the
  /// replacement too). That attempt also invalidates the cached tick target, leaving no session
  /// and no cache, so ticks must still persist while the audio plays on from local files.
  @Test("progress keeps persisting when the replacement session cannot be opened")
  func ticksAfterAFailedReplacementSessionStillPersistProgress() async throws {
    let h = try await ProgressDurabilityHarness()
    try await h.startPlayingSession()
    await h.tick(currentTime: 100, delta: 100)

    let sessionId = try #require(try h.sessionStore.fetchActiveSession(accountId: h.accountId)?.id)
    _ = try h.sessionStore.markSessionGone(sessionId: sessionId, now: h.clock.now())
    // No `/play` stub: the replacement attempt fails as it would offline.
    await h.coordinator.recoverFromSessionGone(
      itemID: ProgressDurabilityHarness.itemID, episodeID: nil)
    #expect(try h.sessionStore.fetchActiveSession(accountId: h.accountId) == nil)

    for step in 1...20 {
      h.clock.advance(by: 15)
      await h.tick(currentTime: 100 + Double(step) * 15, delta: 15)
    }

    let progress = try #require(try h.currentProgress())
    #expect(
      progress.currentTime == 400,
      "no session and no cached target must still leave the resume position correct")
  }

  /// The limit on the safety net: a straggler tick for an item this device is no longer playing
  /// (PlayerCore emitting one last observation as a switch displaces it, or after a deliberate
  /// stop) must be ignored, or the net resurrects positions never listened to.
  @Test("a tick after a deliberate stop is still ignored")
  func ticksAfterAStopAreIgnored() async throws {
    let h = try await ProgressDurabilityHarness()
    try await h.startPlayingSession()
    await h.tick(currentTime: 100, delta: 100)

    await h.stubOK(path: ProgressDurabilityHarness.syncPath)
    await h.stubOK(path: ProgressDurabilityHarness.closePath)
    try await h.coordinator.stopSession()

    h.clock.advance(by: 15)
    await h.tick(currentTime: 999, delta: 15)

    #expect(try h.currentProgress()?.currentTime == 100)
  }

  /// The same phase gate as `handleAppBackgrounded`, here deciding whether listening stats can be
  /// restored as well as the position. Declining a replacement during `.buffering` would keep the
  /// position but never record the listen (rule 6). The gate separates "someone is still
  /// listening" from "playback ended", and `.buffering` is the former.
  @Test("a session gone during a buffering stall still opens a replacement")
  func recoveryOpensAReplacementWhileBuffering() async throws {
    let h = try await ProgressDurabilityHarness()
    try await h.startPlayingSession()
    await h.tick(currentTime: 100, delta: 100)

    let sessionId = try #require(try h.sessionStore.fetchActiveSession(accountId: h.accountId)?.id)
    _ = try h.sessionStore.markSessionGone(sessionId: sessionId, now: h.clock.now())
    await h.coordinator.notifyPlaybackPhase(.buffering)
    await h.enqueuePlayResponse(serverSessionID: "server-session-2")

    await h.coordinator.recoverFromSessionGone(
      itemID: ProgressDurabilityHarness.itemID, episodeID: nil)

    let replacement = try #require(try h.sessionStore.fetchActiveSession(accountId: h.accountId))
    #expect(replacement.id != sessionId)
  }

  /// The counterpart: a stopped player declines a replacement, so the gate still discriminates.
  @Test("a session gone while stopped opens no replacement")
  func recoveryDeclinesAReplacementWhileStopped() async throws {
    let h = try await ProgressDurabilityHarness()
    try await h.startPlayingSession()
    await h.tick(currentTime: 100, delta: 100)

    let sessionId = try #require(try h.sessionStore.fetchActiveSession(accountId: h.accountId)?.id)
    _ = try h.sessionStore.markSessionGone(sessionId: sessionId, now: h.clock.now())
    await h.coordinator.notifyPlaybackPhase(.stopped)

    await h.coordinator.recoverFromSessionGone(
      itemID: ProgressDurabilityHarness.itemID, episodeID: nil)

    #expect(try h.sessionStore.fetchActiveSession(accountId: h.accountId) == nil)
  }
}

// MARK: - Harness

private final class ProgressDurabilityHarness: @unchecked Sendable {
  static let itemID = "item_progress_durability"
  static let libraryID = "lib-progress-durability"
  static let playPath = "/api/items/\(itemID)/play"
  static let syncPath = "/api/session/server-session-1/sync"
  static let closePath = "/api/session/server-session-1/close"

  let http: SessionScriptedHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let mediaProgressDAO: MediaProgressDAO
  let scheduler: FakePlaybackCadenceScheduling
  let clock: FakeSyncClock
  let accountId: Int64
  let itemRowId: Int64
  let clientUUID: String
  let coordinator: PlaybackSessionCoordinator
  let drainer: OutboxDrainer

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://durability.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "access-token", refreshToken: "refresh-token"), for: account)
    let http = SessionScriptedHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let database = try AppDatabase.inMemory()
    let savedAccount = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let accountId = try #require(savedAccount.id)

    let libraryRowId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let itemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title", sortTitle: "title")
      ).id)

    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let scheduler = FakePlaybackCadenceScheduling()
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId)

    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, clock: clock, scheduler: scheduler,
      requestDrain: { await drainer.drainOutbox() })

    self.http = http
    self.database = database
    self.outbox = outbox
    self.sessionStore = sessionStore
    self.mediaProgressDAO = MediaProgressDAO(database: database)
    self.scheduler = scheduler
    self.clock = clock
    self.accountId = accountId
    self.itemRowId = itemRowId
    self.clientUUID = clientUUID
    self.coordinator = coordinator
    self.drainer = drainer
  }

  func startPlayingSession() async throws {
    await enqueuePlayResponse()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    await coordinator.notifyPlaybackPhase(.playing)
  }

  func tick(currentTime: Double, delta: Double, isFinished: Bool = false, isSeek: Bool = false) async {
    await coordinator.recordProgressTick(
      itemID: Self.itemID, episodeID: nil, currentTime: currentTime, listenedDelta: delta,
      isFinished: isFinished, isSeek: isSeek)
  }

  func currentProgress() throws -> MediaProgressRecord? {
    try mediaProgressDAO.fetchCurrent(accountId: accountId, identity: .item(itemId: itemRowId))
  }

  func stubOK(path: String) async {
    await http.stub(path: path, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
  }

  func enqueuePlayResponse(serverSessionID: String = "server-session-1") async {
    let object: [String: Any] = [
      "id": serverSessionID,
      "libraryItemId": Self.itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": 3600,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": clientUUID],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 3600, "title": "Track 1",
          "contentUrl": "/api/items/\(Self.itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    await http.stub(
      path: Self.playPath,
      responses: [
        HTTPResponse(
          statusCode: 200, headers: ["Content-Type": "application/json"],
          body: try! JSONSerialization.data(withJSONObject: object))
      ])
  }
}
