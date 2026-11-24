import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `PlaybackSessionCoordinator`'s wiring of `PlaybackSyncing.recordProgressTick` (called by
/// `PlaybackModel`) onto `PlaybackSessionStore.recordTick`. Atomicity is covered by
/// `PlaybackProgressTransactionTests`; here the coordinator only has to call it correctly (right
/// session, right segment boundaries, silent no-op with nothing to attribute the tick to).
@Suite struct PlaybackProgressTickTests {

  @Test func recordsAnOrdinaryTickAgainstTheLocallyActiveSession() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 42, listenedDelta: 5, isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 42)
    #expect(session.listenedDeltaSeconds == 5)
    #expect(session.lastLocalSequence == 1)
    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 1)
  }

  @Test func repeatedOrdinaryTicksCoalesceIntoOneUnsentOutboxRow() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: PlaybackSessionCoordinator.progressPersistInterval)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false, isSeek: false)

    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 1, "ordinary ticks for the same segment coalesce into one unsent row")
    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 20)
    #expect(session.listenedDeltaSeconds == 10)
    #expect(session.lastLocalSequence == 2, "local sequence still advances per tick even though the row merges")
  }

  @Test func firstTickOfAReplacementSessionContinuesTheItemsExistingLocalSequence() async throws {
    let h = try await TickHarness()
    try await h.seedProgress(currentTime: 120, localSequence: 41)
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 125, listenedDelta: 5, isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 125)
    #expect(session.lastLocalSequence == 42, "a new session must not restart below the item's durable sequence")
    #expect(try h.sessionSyncRows(sessionId).count == 1)
  }

  @Test func aSeekTickOpensAFreshSegmentThatDoesNotCoalesceWithThePrecedingOne() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 500, listenedDelta: 0, isFinished: false, isSeek: true)

    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 2, "a seek boundary must never merge into the segment that preceded it")
  }

  @Test func aFinishedTransitionOpensAFreshSegment() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 3595, listenedDelta: 5, isFinished: false, isSeek: false)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 3600, listenedDelta: 5, isFinished: true, isSeek: false)

    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 2, "a finished/un-finished transition must never merge into the prior segment")
  }

  @Test func aFailedCachedFinishedTickRestoresTheBoundaryStateBeforeRetrying() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false,
      isSeek: false)
    try h.failNextCachedSessionUpdate()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 3_600, listenedDelta: 5,
      isFinished: true, isSeek: false)

    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 2, "a failed cached write must retry in a fresh finished segment")
    #expect(rows.map(\.coalescingKey).count == Set(rows.map(\.coalescingKey)).count)
    #expect(
      try h.progressRows().contains {
        $0.operationKind == OutboxOperationKind.progress.rawValue && $0.payloadIsFinished == true
      })
  }

  @Test func aStartFlushesThePendingTickBeforeResolvingItsAccount() async throws {
    let h = try await TickHarness()
    let originalSessionID = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false,
      isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false,
      isSeek: false)
    try h.invalidateAccountServerURLAfterNextSessionUpdate()
    h.http.enqueue(contentsOf: [
      HTTPResponse(statusCode: 204, headers: [:], body: Data()),
      TickHarness.playResponse(itemID: TickHarness.otherItemID),
    ])

    await #expect(throws: APIError.invalidServerConfiguration(.missingHost)) {
      _ = try await h.coordinator.startSession(itemID: TickHarness.otherItemID, episodeID: nil)
    }

    let session = try #require(try h.sessionStore.fetchSession(id: originalSessionID))
    #expect(session.globalPosition == 20, "the pending tick must be durable before account resolution")
  }

  @Test func aFinishedTickEnqueuesAnOrdinaryFinishedProgressAssertionForTheExactEpisodeIdentity() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startEpisodeSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 100,
      listenedDelta: 10, isFinished: false, isSeek: false)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 120,
      listenedDelta: 10, isFinished: true, isSeek: false)

    let progressRows = try h.progressRows()
    let assertion = try #require(
      progressRows.first(where: { $0.operationKind == OutboxOperationKind.progress.rawValue }))
    #expect(assertion.entityKey == TickHarness.itemID)
    #expect(assertion.podcastEpisodeId == h.episodeRowID)
    #expect(assertion.payloadIsFinished == true)
    #expect(assertion.payloadCurrentTime == 120)
    #expect(try h.sessionSyncRows(sessionId).count == 2)
  }

  @Test func aSecondFinishedTickForTheSameIdentityEnqueuesNoSecondFinishedAssertion() async throws {
    let h = try await TickHarness()
    _ = try await h.startEpisodeSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 100,
      listenedDelta: 10, isFinished: false, isSeek: false)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 120,
      listenedDelta: 10, isFinished: true, isSeek: false)
    h.clock.advance(by: PlaybackSessionCoordinator.progressPersistInterval)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 120,
      listenedDelta: 0, isFinished: true, isSeek: false)

    #expect(try h.progressRows().filter { $0.operationKind == OutboxOperationKind.progress.rawValue }.count == 1)
  }

  @Test func drainedFinishedAssertionUsesEpisodeScopedPatchWithoutAnIdField() async throws {
    let h = try await TickHarness()
    _ = try await h.startEpisodeSession()
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 120,
      listenedDelta: 10, isFinished: true, isSeek: false)
    try await h.stopAndDrain()

    let request = try #require(
      h.http.requests.first(where: { $0.method == .patch && $0.url.path.contains(TickHarness.episodeID) }))
    #expect(request.url.path == "/api/me/progress/\(TickHarness.itemID)/\(TickHarness.episodeID)")
    let body = try #require(request.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["isFinished"] as? Bool == true)
    #expect(payload["currentTime"] as? Double == 120)
    #expect(payload["id"] == nil, "API-CONVENTIONS rule 11 forbids id in progress payloads")
  }

  @Test func finishedAssertionIsDrainedAsOrdinaryProgressWithoutWaitingForSessionClose() async throws {
    let h = try await TickHarness()
    _ = try await h.startEpisodeSession()
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 120,
      listenedDelta: 10, isFinished: true, isSeek: false)
    try await h.drainOnce()

    let request = try #require(
      h.http.requests.first(where: { $0.method == .patch && $0.url.path.contains(TickHarness.episodeID) }))
    let body = try #require(request.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(request.url.path == "/api/me/progress/\(TickHarness.itemID)/\(TickHarness.episodeID)")
    #expect(payload["isFinished"] as? Bool == true)
  }

  @Test func finishedAssertionUsesTheFinishedTickSequenceSoTheNextTickRemainsStrictlyNewer() async throws {
    let h = try await TickHarness()
    _ = try await h.startEpisodeSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 100,
      listenedDelta: 10, isFinished: false, isSeek: false)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 120,
      listenedDelta: 10, isFinished: true, isSeek: false)

    let assertion = try #require(
      try h.progressRows().first(where: { $0.operationKind == OutboxOperationKind.progress.rawValue }))
    #expect(assertion.localSequence == 2)

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: TickHarness.episodeID, currentTime: 120,
      listenedDelta: 0, isFinished: true, isSeek: true)
    let session = try #require(try h.sessionStore.fetchActiveSession(accountId: h.accountId))
    #expect(session.lastLocalSequence == 3)
    #expect(assertion.localSequence < session.lastLocalSequence)
  }

  @Test func ticksAfterASeekShareTheNewSegmentUntilTheNextBoundary() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 500, listenedDelta: 0, isFinished: false, isSeek: true)
    h.clock.advance(by: PlaybackSessionCoordinator.progressPersistInterval)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 510, listenedDelta: 5, isFinished: false, isSeek: false)

    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 2, "ticks after a seek join its fresh segment rather than each opening their own")
    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 510)
  }

  // MARK: - Persistence throttle

  @Test func ordinaryTicksWithinThePersistIntervalAccumulateInMemory() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 10, "an intra-interval tick stays in memory - no write per tick")
    #expect(session.listenedDeltaSeconds == 5)
    #expect(session.lastLocalSequence == 1, "no durable sequence advances for an accumulated tick")
  }

  @Test func theAccumulatedTickPersistsWithItsSummedDeltaOnceTheIntervalElapses() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: PlaybackSessionCoordinator.progressPersistInterval)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 30, listenedDelta: 5, isFinished: false, isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 30)
    #expect(session.listenedDeltaSeconds == 15, "every accumulated delta lands in the flush - none lost")
    #expect(session.lastLocalSequence == 2, "one flush write, not one write per swallowed tick")
    #expect(try h.sessionSyncRows(sessionId).count == 1)
  }

  @Test func aSeekFlushesTheAccumulationIntoItsOwnSegmentBeforeOpeningTheFreshOne() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 500, listenedDelta: 0, isFinished: false, isSeek: true)

    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 2, "the flushed accumulation joins the pre-seek segment; the seek opens its own")
    #expect(
      rows.first?.payloadAccumulatedDeltaSeconds == 10,
      "the pre-seek segment carries the accumulated delta - not just the leading tick's")
    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 500)
    #expect(session.listenedDeltaSeconds == 10)
  }

  @Test func aFinishedTransitionFlushesTheAccumulationAndPersistsImmediately() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 3_590, listenedDelta: 5, isFinished: false, isSeek: false
    )
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 3_595, listenedDelta: 5, isFinished: false, isSeek: false
    )
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 3_600, listenedDelta: 5, isFinished: true, isSeek: false)

    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 2, "the finished transition never merges into the segment it flushed")
    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 3_600, "the finish itself is never held back by the throttle")
    #expect(session.listenedDeltaSeconds == 15)
  }

  @Test func aPausePhaseFlushesDurablyBeforeItsImmediateDrainRuns() async throws {
    let h = try await TickHarness()
    _ = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false, isSeek: false)
    await h.coordinator.notifyPlaybackPhase(.paused)
    await h.coordinator.notifyImmediateSyncTrigger(.paused)

    #expect(
      h.drainObservedPositions.value == [20],
      "the drain must see the last ticked position already durable, or the /sync it sends is stale")
  }

  @Test func aTickRecordedWhilePausedPersistsDurablyImmediately() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false,
      isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false,
      isSeek: false)
    await h.coordinator.notifyPlaybackPhase(.paused)

    // Inside the normal interval: it must be durable because playback is paused, not because
    // the throttle's deadline elapsed.
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 21, listenedDelta: 1, isFinished: false,
      isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 21, "a paused tick must update the durable position immediately")
    #expect(session.lastLocalSequence == 3, "the paused tick must receive its own durable sequence")
  }

  @Test func anImmediateSyncTriggerFlushesDurablyBeforeItsDrainRuns() async throws {
    let h = try await TickHarness()
    _ = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 25, listenedDelta: 5, isFinished: false, isSeek: false)
    await h.coordinator.notifyImmediateSyncTrigger(.backgrounded)

    #expect(h.drainObservedPositions.value == [25])
  }

  @Test func stopSessionFlushesTheAccumulatedPositionIntoTheFrozenClose() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 10, listenedDelta: 5, isFinished: false, isSeek: false)
    h.clock.advance(by: 1)
    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 20, listenedDelta: 5, isFinished: false, isSeek: false)
    try await h.coordinator.stopSession()

    let closed = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(closed.globalPosition == 20, "close freezes the last *ticked* position, never a stale persisted one")
    #expect(closed.listenedDeltaSeconds == 10)
  }

  @Test func aTickWithNoLocallyActiveSessionAtAllIsASilentNoOp() async throws {
    let h = try await TickHarness()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.itemID, episodeID: nil, currentTime: 42, listenedDelta: 5, isFinished: false, isSeek: false)

    #expect(try h.sessionStore.fetchActiveSession(accountId: h.accountId) == nil)
  }

  @Test func aTickForAnItemOtherThanTheLocallyActiveSessionIsIgnored() async throws {
    let h = try await TickHarness()
    let sessionId = try await h.startSession()

    await h.coordinator.recordProgressTick(
      itemID: TickHarness.otherItemID, episodeID: nil, currentTime: 999, listenedDelta: 50, isFinished: false,
      isSeek: false)

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 0, "a stale/foreign tick must never write into this session")
    #expect(session.listenedDeltaSeconds == 0)
    #expect(try h.sessionSyncRows(sessionId).isEmpty)
  }
}

// MARK: - TickHarness

private final class TickHarness: @unchecked Sendable {
  static let itemID = "item_tick_fixture"
  static let otherItemID = "item_tick_other_fixture"
  static let episodeID = "episode_tick_fixture"

  let http: FakeHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let coordinator: PlaybackSessionCoordinator
  let accountId: Int64
  let episodeRowID: Int64
  let clock: FakeSyncClock
  let clientUUID: String
  /// The active session's durable `globalPosition` as seen from inside each `requestDrain` call,
  /// i.e. what a real drain's `/sync` would read from the outbox at that moment.
  let drainObservedPositions: Locked<[Double]>

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://tick.example.test")))
    let localClientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: localClientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let localDatabase = try AppDatabase.inMemory()
    let savedAccount = try await localDatabase.writeAsync { db in
      var record = AccountRecord(
        clientUUID: localClientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let localAccountId = try #require(savedAccount.id)

    let libraryId = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: localDatabase)
    let itemRowID = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title", sortTitle: "title")
      )
      .id)
    _ = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: localAccountId, libraryId: libraryId, serverItemId: Self.otherItemID, mediaKind: "book",
        title: "Other Title", sortTitle: "other title"))

    database = localDatabase
    accountId = localAccountId
    clientUUID = localClientUUID

    episodeRowID = try await localDatabase.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: localAccountId, itemId: itemRowID, serverEpisodeId: Self.episodeID,
        title: "Episode", durationSeconds: 120, lastSeenGeneration: 1)
      try episode.insert(db)
      return try #require(episode.id)
    }

    outbox = try OutboxStore(database: database)
    sessionStore = PlaybackSessionStore(database: database, outbox: outbox)

    let localClock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    clock = localClock
    let drainDatabase = localDatabase
    let drainBox = Locked<[Double]>([])
    drainObservedPositions = drainBox
    coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, clock: localClock,
      requestDrain: {
        let position = try? drainDatabase.read { db in
          try PlaybackSessionRecord.fetchAll(db).first?.globalPosition
        }
        drainBox.withValue { $0.append(position ?? -1) }
      })

    http.enqueue(Self.playResponse(itemID: Self.itemID))
  }

  @discardableResult
  func startSession() async throws -> Int64 {
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    await coordinator.notifyPlaybackPhase(.playing)
    return try #require(try sessionStore.fetchActiveSession(accountId: accountId)?.id)
  }

  @discardableResult
  func startEpisodeSession() async throws -> Int64 {
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: Self.episodeID)
    await coordinator.notifyPlaybackPhase(.playing)
    return try #require(try sessionStore.fetchActiveSession(accountId: accountId)?.id)
  }

  func progressRows() throws -> [OutboxOperationRecord] {
    try database.read { db in try OutboxOperationRecord.fetchAll(db) }
  }

  func stopAndDrain() async throws {
    try await coordinator.stopSession()
    try await drainOnce()
  }

  func drainOnce() async throws {
    http.enqueue(contentsOf: [
      HTTPResponse(statusCode: 204, headers: [:], body: Data()),
      HTTPResponse(statusCode: 204, headers: [:], body: Data()),
      HTTPResponse(statusCode: 204, headers: [:], body: Data()),
      HTTPResponse(statusCode: 204, headers: [:], body: Data()),
    ])
    let server = try ABSServerConfig(url: try #require(URL(string: "https://tick.example.test")))
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId)
    await drainer.drainOutbox(now: clock.now(), randomUnit: { 1 })
  }

  func sessionSyncRows(_ sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
  }

  func seedProgress(currentTime: Double, localSequence: Int64) async throws {
    let item = try #require(try ItemDAO(database: database).fetchOne(accountId: accountId, serverItemId: Self.itemID))
    let itemId = try #require(item.id)
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountId,
        itemId: itemId,
        currentTime: currentTime,
        isFinished: false,
        localSequence: localSequence,
        origin: .local,
        originKey: "prior-device-write")
      try progress.insert(db)
    }
  }

  func failNextCachedSessionUpdate() throws {
    let shouldFail = Locked(true)
    try database.write { db in
      db.add(
        function: DatabaseFunction("failCachedTickOnce", argumentCount: 0) { _ in
          shouldFail.withValue { value in
            guard value else { return 0 }
            value = false
            return 1
          }
        })
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER failCachedPlaybackTickOnce
          BEFORE UPDATE OF globalPosition ON playbackSession
          WHEN NEW.globalPosition = 3600 AND failCachedTickOnce() = 1
          BEGIN
            SELECT RAISE(ABORT, 'injected cached tick failure');
          END
          """)
    }
  }

  func invalidateAccountServerURLAfterNextSessionUpdate() throws {
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER invalidateAccountAfterPlaybackTick
          AFTER UPDATE OF globalPosition ON playbackSession
          BEGIN
            UPDATE account SET serverBaseURL = 'http://[invalid';
          END
          """)
    }
  }

  static func playResponse(itemID: String) -> HTTPResponse {
    let object: [String: Any] = [
      "id": "server-session-tick",
      "libraryItemId": itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": 3600,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 3600, "title": "Track 1",
          "contentUrl": "/api/items/\(itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}
