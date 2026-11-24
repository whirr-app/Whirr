import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The session/crash matrix: lose connectivity, background or terminate during playback, relaunch,
/// and reconcile final delta/close state without overlapping the same session. A force-quit or
/// crash at a tested durability boundary loses no acknowledged local progress and does not
/// double-count acknowledged listening time. Unlike the unit suites it builds on
/// (`PlaybackSessionStoreTests`, `SessionOutboxDrainTests`, `SessionGoneRecoveryTests`,
/// `PlaybackLifecycleTests`, `PlaybackCadenceTests`), every test cuts across a real on-disk
/// `AppDatabase`: it closes the file, reopens a fresh `AppDatabase`/`OutboxStore`/
/// `PlaybackSessionStore`/`PlaybackSessionCoordinator`/`OutboxDrainer` graph as a relaunch would,
/// then drains and recovers twice to prove idempotence on top of durability.
@Suite("Session recovery journey: crash matrix")
struct SessionRecoveryJourneyTests {

  // MARK: - 1. `/play` response before local persistence (compensating close)

  @Test("a /play response that never reached local persistence is closed as an orphan on next recovery")
  func playResponseBeforeLocalPersistenceIsClosedAsAnOrphanOnRecovery() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let first = try env.openIncarnation()
    await first.http.stub(
      path: RecoveryJourneyEnvironment.playPath,
      responses: [RecoveryJourneyEnvironment.playResponse(serverSessionID: "orphan-session")])

    // Simulate the crash boundary directly: the server call the coordinator would have made
    // inside `performStart` succeeded, but the process died before `sessionStore.startSession`
    // committed, so nothing local exists for this session.
    _ = try await first.client.startPlaybackSession(
      account: env.account, itemID: RecoveryJourneyEnvironment.itemID,
      options: StartPlaybackSessionOptions(deviceID: env.clientUUID))
    #expect(try first.sessionStore.fetchActiveSession(accountId: env.accountId) == nil)

    let second = try env.openIncarnation()
    await second.http.stub(
      path: "/api/sessions/open",
      responses: [
        RecoveryJourneyEnvironment.openSessionsListResponse(orphanDeviceID: env.clientUUID)
      ])
    await second.http.stub(path: "/api/session/orphan-session/close", responses: [RecoveryJourneyEnvironment.ok()])

    await second.coordinator.recoverOpenSessions()
    #expect(await second.http.requestCount(forPath: "/api/session/orphan-session/close") == 1)

    // A second recovery pass finds nothing left to do, so no repeat close. The orphan sweep is
    // always attempted best-effort (hence the `/api/sessions/open` GET), but this time nothing
    // matches this device's client id.
    let third = try env.openIncarnation()
    await third.http.stub(
      path: "/api/sessions/open", responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await third.coordinator.recoverOpenSessions()
    #expect(await third.http.requestCount(forPath: "/api/session/orphan-session/close") == 0, "no repeat close")
  }

  // MARK: - 2. Tick transaction before send

  @Test("a tick persisted but never drained survives a crash and drains exactly once on relaunch")
  func tickTransactionBeforeSendSurvivesACrashAndDrainsExactlyOnce() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
      _ = try first.sessionStore.recordTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 42, isFinished: false, deltaSecondsSinceLastTick: 7, localSequence: 1,
          originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      // Crash here: nothing has been sent.
    }

    let second = try env.openIncarnation()
    await second.http.stub(path: RecoveryJourneyEnvironment.syncPath, responses: [RecoveryJourneyEnvironment.ok()])
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.syncPath) == 1)
    let acked = try second.sessionStore.fetchSession(id: sessionId)
    #expect(acked?.listenedDeltaSeconds == 0, "the frozen delta was subtracted exactly once")
    #expect(acked?.globalPosition == 42)

    // Second drain in the same incarnation: idempotent, nothing left queued.
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_030))
    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.syncPath) == 1, "no duplicate send")
  }

  // MARK: - 3. Send before response (crash while the request is in flight)

  @Test("a request abandoned mid-flight reverts to pending on relaunch and is resent exactly once")
  func sendBeforeResponseRevertsToPendingAndResendsExactlyOnce() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
      _ = try first.sessionStore.recordTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 30, isFinished: false, deltaSecondsSinceLastTick: 4, localSequence: 1,
          originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      await first.http.hang(path: RecoveryJourneyEnvironment.syncPath)
      let inFlight = Task { await first.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020)) }
      await first.http.waitUntilRequested(path: RecoveryJourneyEnvironment.syncPath)
      // Crash: the request is still in flight (never resolved) when the process dies.
      inFlight.cancel()
      _ = await inFlight.value
    }

    let queuedAfterCrash = try await env.rawQueuedSyncRows(sessionId: sessionId)
    #expect(queuedAfterCrash.count == 1, "the row survives the crash - never lost")

    let second = try env.openIncarnation()
    #expect(
      try second.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
        .first?.state == .pending, "a fresh launch reverts the stranded `sending` row to `pending`")

    await second.http.stub(path: RecoveryJourneyEnvironment.syncPath, responses: [RecoveryJourneyEnvironment.ok()])
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_030))

    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.syncPath) == 1)
    let session = try second.sessionStore.fetchSession(id: sessionId)
    #expect(session?.listenedDeltaSeconds == 0, "acknowledged exactly once")

    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_040))
    #expect(
      await second.http.requestCount(forPath: RecoveryJourneyEnvironment.syncPath) == 1, "no second drain re-sends")
  }

  // MARK: - 4. Response before acknowledgement transaction

  @Test(
    "a response the process never got to acknowledge is durable and the eventual real ack still counts exactly once")
  func responseBeforeAcknowledgementTransactionStillCountsExactlyOnce() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
      _ = try first.sessionStore.recordTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 55, isFinished: false, deltaSecondsSinceLastTick: 9, localSequence: 1,
          originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      let row = try #require(
        try first.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
          .first)
      _ = try await first.outbox.transitionAsync(operationId: try #require(row.id), to: .sending)
      await first.http.stub(path: RecoveryJourneyEnvironment.syncPath, responses: [RecoveryJourneyEnvironment.ok()])
      // The response arrives, but the process dies before the acknowledgement transaction
      // (which would subtract the delta and delete the row) runs.
      try await first.client.syncPlaybackSession(
        account: env.account, sessionID: RecoveryJourneyEnvironment.serverSessionId,
        update: SessionSyncUpdate(currentTime: 55, deltaSeconds: 9))
    }

    // Nothing local recorded that the response landed. This is the documented risk window for a
    // non-idempotent send: the row is durable and unacknowledged, so it is correctly resent. The
    // invariant proved here is purely local: the eventual real acknowledgement subtracts this
    // row's delta once, never twice.
    let second = try env.openIncarnation()
    await second.http.stub(path: RecoveryJourneyEnvironment.syncPath, responses: [RecoveryJourneyEnvironment.ok()])
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    let session = try #require(try second.sessionStore.fetchSession(id: sessionId))
    #expect(session.listenedDeltaSeconds == 0, "subtracted exactly once by the eventual real ack")
    #expect(
      try second.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
        .isEmpty)

    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_030))
    #expect(
      await second.http.requestCount(forPath: RecoveryJourneyEnvironment.syncPath) == 1,
      "the second drain finds nothing left queued")
  }

  // MARK: - 5. Concurrent tick during acknowledgement

  @Test(
    "a tick recorded while an earlier row is in flight lands as its own row and both settle exactly once, never overlapping"
  )
  func concurrentTickDuringAcknowledgementSettlesBothRowsExactlyOnceWithoutOverlap() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
      _ = try first.sessionStore.recordTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
          originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      let rowA = try #require(
        try first.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
          .first)
      _ = try await first.outbox.transitionAsync(operationId: try #require(rowA.id), to: .sending)

      // A second tick lands while row A is (conceptually) in flight. It is a fresh segment, so
      // it cannot coalesce into the `.sending` row A.
      _ = try first.sessionStore.recordTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 25, isFinished: false, deltaSecondsSinceLastTick: 6, localSequence: 2,
          originKey: env.clientUUID, segmentKey: "seg-2", now: Date(timeIntervalSince1970: 1_700_000_016)))
      // Crash before row A's acknowledgement transaction runs.
    }

    let rowsAfterCrash = try await env.rawQueuedSyncRows(sessionId: sessionId)
    #expect(rowsAfterCrash.count == 2, "both rows survive - the in-flight one and the concurrent one")

    let second = try env.openIncarnation()
    await second.http.stub(
      path: RecoveryJourneyEnvironment.syncPath,
      responses: [RecoveryJourneyEnvironment.ok(), RecoveryJourneyEnvironment.ok()])
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    let requests = await second.http.requests(forPath: RecoveryJourneyEnvironment.syncPath)
    #expect(requests.count == 2, "each row sent its own request - never merged, never overlapping")
    let bodies = requests.compactMap { try? JSONSerialization.jsonObject(with: $0.body ?? Data()) as? [String: Any] }
    #expect(bodies.map { $0["currentTime"] as? Double } == [10, 25], "row A drained strictly before row B")

    let session = try #require(try second.sessionStore.fetchSession(id: sessionId))
    #expect(session.listenedDeltaSeconds == 0, "5 + 6 subtracted exactly once between them, nothing left over")
    #expect(session.globalPosition == 25)

    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_030))
    #expect(
      await second.http.requestCount(forPath: RecoveryJourneyEnvironment.syncPath) == 2,
      "idempotent - nothing left to resend")
  }

  // MARK: - 6. Close persisted before send

  @Test("a close persisted but never drained survives a crash and drains exactly once on relaunch")
  func closePersistedBeforeSendSurvivesACrashAndDrainsExactlyOnce() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
      _ = try first.sessionStore.close(
        sessionId: sessionId,
        tick: PlaybackSessionClose(
          globalPosition: 60, deltaSecondsSinceLastSend: 3, localSequence: 1,
          now: Date(timeIntervalSince1970: 1_700_000_010)))
      // Crash: the closePending write committed, but nothing was sent.
    }

    let second = try env.openIncarnation()
    let midway = try #require(try second.sessionStore.fetchSession(id: sessionId))
    #expect(midway.closePending == true, "the durable close survived the crash")

    await second.http.stub(path: RecoveryJourneyEnvironment.closePath, responses: [RecoveryJourneyEnvironment.ok()])
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.closePath) == 1)
    #expect(try second.sessionStore.fetchSession(id: sessionId) == nil, "fully closed and acknowledged")

    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_030))
    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.closePath) == 1, "no repeat close")
  }

  // MARK: - 7. Close accepted with response lost

  @Test("a close that landed server-side but whose response was lost is reconciled, never double-processed")
  func closeAcceptedWithResponseLostIsReconciledNeverDoubleProcessed() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
      _ = try first.sessionStore.close(
        sessionId: sessionId,
        tick: PlaybackSessionClose(
          globalPosition: 70, deltaSecondsSinceLastSend: 2, localSequence: 1,
          now: Date(timeIntervalSince1970: 1_700_000_010)))
      let row = try #require(
        try first.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
          .first)
      _ = try await first.outbox.transitionAsync(operationId: try #require(row.id), to: .sending)
      await first.http.stub(path: RecoveryJourneyEnvironment.closePath, responses: [RecoveryJourneyEnvironment.ok()])
      // The close lands server-side...
      try await first.client.closePlaybackSession(
        account: env.account, sessionID: RecoveryJourneyEnvironment.serverSessionId,
        finalPosition: SessionSyncUpdate(currentTime: 70, deltaSeconds: 2))
      // ...but the process dies before the acknowledgement transaction runs.
    }

    let second = try env.openIncarnation()
    // The resent close 404s (the server already closed it). Reconciliation confirms via
    // `GET /api/session/{id}` (also 404, gone) and authoritative `/api/me` progress, which
    // matches the position this device sent, so it resolves `.landedOnServer`.
    await second.http.stub(
      path: RecoveryJourneyEnvironment.closePath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())]
    )
    await second.http.stub(
      path: RecoveryJourneyEnvironment.getSessionPath,
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await second.http.stub(
      path: "/api/me",
      responses: [
        RecoveryJourneyEnvironment.mediaProgressResponse(currentTime: 70)
      ])

    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    #expect(
      try second.sessionStore.fetchSession(id: sessionId) == nil,
      "reconciled as landed - acknowledged, not dead-lettered")
    #expect(
      env.diagnostics.recorded.contains { $0.category == .sessionLostDelta } == false,
      "never treated as a session loss - it landed")

    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_030))
    #expect(
      await second.http.requestCount(forPath: RecoveryJourneyEnvironment.closePath) == 1,
      "never blindly replayed a second time")
  }

  // MARK: - 8. Background-task expiration

  @Test(
    "a close attempt cancelled by background-task expiration leaves the durable close intact and it drains on relaunch")
  func backgroundTaskExpirationLeavesTheDurableCloseIntactAndItDrainsOnRelaunch() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation(includeSyncEngine: true)
      sessionId = try first.seedActiveSession()
      _ = try first.sessionStore.recordTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 12, isFinished: false, deltaSecondsSinceLastTick: 3, localSequence: 1,
          originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      for row in try first.outbox.fetchQueued(
        accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
      {
        try first.sessionStore.acknowledgeSync(operationId: try #require(row.id), sessionId: sessionId)
      }
      await first.coordinator.notifyPlaybackPhase(.paused)

      await first.http.hang(path: RecoveryJourneyEnvironment.closePath)
      first.appLifecycle!.simulateBackground()
      await first.http.waitUntilRequested(path: RecoveryJourneyEnvironment.closePath)
      first.appLifecycle!.simulateBackgroundTaskExpiration()
      #expect(
        await TestSupport.waitUntil {
          (try? await env.rawSession(sessionId: sessionId))?.closePending == true
        })
      // Crash right after expiration: the durable close row must still be there.
    }

    let midway = try #require(try await env.rawSession(sessionId: sessionId))
    #expect(midway.closePending == true)
    #expect(midway.state == .active)

    let second = try env.openIncarnation()
    await second.http.stub(path: RecoveryJourneyEnvironment.closePath, responses: [RecoveryJourneyEnvironment.ok()])
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_030))

    #expect(try second.sessionStore.fetchSession(id: sessionId) == nil)
    await second.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_040))
    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.closePath) == 1)
  }

  // MARK: - 9. Relaunch with an open session

  @Test("relaunch confirms a still-open local session via GET and leaves it active across two recovery passes")
  func relaunchConfirmsStillOpenSessionAndLeavesItActiveAcrossTwoPasses() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
      // Crash mid-playback: no close, no compensating action.
    }

    let second = try env.openIncarnation()
    await second.http.stub(
      path: RecoveryJourneyEnvironment.getSessionPath, responses: [RecoveryJourneyEnvironment.openSessionResponse()])
    await second.coordinator.recoverOpenSessions()
    #expect(try second.sessionStore.fetchSession(id: sessionId)?.state == .active)

    await second.http.stub(
      path: RecoveryJourneyEnvironment.getSessionPath, responses: [RecoveryJourneyEnvironment.openSessionResponse()])
    await second.coordinator.recoverOpenSessions()
    #expect(
      try second.sessionStore.fetchSession(id: sessionId)?.state == .active, "a second recovery pass is idempotent")
    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.closePath) == 0)
  }

  @Test("relaunch closes a locally-open session the server confirms is gone, across two recovery passes")
  func relaunchClosesASessionTheServerConfirmsIsGoneAcrossTwoPasses() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let sessionId: Int64
    do {
      let first = try env.openIncarnation()
      sessionId = try first.seedActiveSession()
    }

    let second = try env.openIncarnation()
    await second.http.stub(
      path: RecoveryJourneyEnvironment.getSessionPath,
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await second.coordinator.recoverOpenSessions()
    #expect(try second.sessionStore.fetchSession(id: sessionId)?.state == .gone)

    // A second pass has nothing local left to reconcile against, so no repeat GET/close.
    await second.coordinator.recoverOpenSessions()
    #expect(await second.http.requestCount(forPath: RecoveryJourneyEnvironment.getSessionPath) == 1)
  }

  // MARK: - 15 s / 60 s cadence variants survive a relaunch

  @Test("normal network conditions schedule the 15 s cadence after a relaunch")
  func normalConditionsScheduleFifteenSecondsAfterRelaunch() async throws {
    let env = try await RecoveryJourneyEnvironment()
    do {
      let first = try env.openIncarnation()
      _ = try first.seedActiveSession()
    }
    let second = try env.openIncarnation(initialLowPowerMode: false, initialConstrainedOrCellular: false)
    await second.coordinator.notifyPlaybackPhase(.playing)
    #expect(second.scheduler.pendingInterval == 15)
  }

  @Test("degraded network conditions schedule the 60 s cadence after a relaunch")
  func degradedConditionsScheduleSixtySecondsAfterRelaunch() async throws {
    let env = try await RecoveryJourneyEnvironment()
    do {
      let first = try env.openIncarnation()
      _ = try first.seedActiveSession()
    }
    let second = try env.openIncarnation(initialLowPowerMode: true)
    await second.coordinator.notifyPlaybackPhase(.playing)
    #expect(second.scheduler.pendingInterval == 60)
  }

  // MARK: - Stale-tick / item-switch race

  @Test("a straggler tick for a just-displaced item is dropped, never misattributed to its successor")
  func staleTickForADisplacedItemIsDroppedNeverMisattributed() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let incarnation = try env.openIncarnation()
    await incarnation.http.stub(
      path: RecoveryJourneyEnvironment.playPath, responses: [RecoveryJourneyEnvironment.playResponse()])
    _ = try await incarnation.coordinator.startSession(itemID: RecoveryJourneyEnvironment.itemID, episodeID: nil)
    let formerSessionId = try #require(try incarnation.sessionStore.fetchActiveSession(accountId: env.accountId)?.id)

    await incarnation.http.stub(
      path: RecoveryJourneyEnvironment.closePath, responses: [RecoveryJourneyEnvironment.ok()])
    await incarnation.http.stub(
      path: "/api/items/\(RecoveryJourneyEnvironment.secondItemID)/play",
      responses: [
        RecoveryJourneyEnvironment.playResponse(
          itemID: RecoveryJourneyEnvironment.secondItemID, serverSessionID: "server-session-2")
      ])
    _ = try await incarnation.coordinator.startSession(itemID: RecoveryJourneyEnvironment.secondItemID, episodeID: nil)
    let newSessionId = try #require(try incarnation.sessionStore.fetchActiveSession(accountId: env.accountId)?.id)
    #expect(newSessionId != formerSessionId)

    // A straggler tick for the item that was just displaced must be silently dropped, never
    // attributed to the new session occupying the account's one active-session slot.
    await incarnation.coordinator.recordProgressTick(
      itemID: RecoveryJourneyEnvironment.itemID, episodeID: nil, currentTime: 999, listenedDelta: 50, isFinished: false,
      isSeek: false)

    let newSession = try #require(try incarnation.sessionStore.fetchSession(id: newSessionId))
    #expect(newSession.globalPosition == 0, "the stale tick's position never reached the new session")
    #expect(newSession.listenedDeltaSeconds == 0, "the stale tick's delta never reached the new session")
  }

  // MARK: - Non-crash concurrency case: session-gone 404 mid-playback

  @Test(
    "a session-gone 404 on /sync mid-playback preserves position, discards the delta once, and starts a zero-delta replacement"
  )
  func sessionGone404OnSyncPreservesPositionAndStartsAZeroDeltaReplacement() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let incarnation = try env.openIncarnation()
    let sessionId = try incarnation.seedActiveSession()
    _ = try incarnation.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 88, isFinished: false, deltaSecondsSinceLastTick: 11, localSequence: 1,
        originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    await incarnation.coordinator.notifyPlaybackPhase(.playing)

    await incarnation.http.stub(
      path: RecoveryJourneyEnvironment.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await incarnation.http.stub(
      path: "/api/me/progress/\(RecoveryJourneyEnvironment.itemID)", responses: [RecoveryJourneyEnvironment.ok()])
    await incarnation.http.stub(
      path: RecoveryJourneyEnvironment.playPath,
      responses: [RecoveryJourneyEnvironment.playResponse(serverSessionID: "server-session-replacement")])

    await incarnation.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))
    let sessionGone = await TestSupport.waitUntil {
      (try? incarnation.sessionStore.fetchSession(id: sessionId)?.state) == .gone
    }
    #expect(sessionGone)

    #expect(try incarnation.sessionStore.fetchSession(id: sessionId)?.state == .gone)
    #expect(
      env.diagnostics.recorded.filter { $0.category == .sessionLostDelta }.count == 1,
      "the lost delta is discarded exactly once")
    #expect(
      try incarnation.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
        .isEmpty, "no row dead-letters")

    let replacement = try #require(try incarnation.sessionStore.fetchActiveSession(accountId: env.accountId))
    #expect(replacement.id != sessionId)
    #expect(
      replacement.listenedDeltaSeconds == 0,
      "the replacement session starts at zero delta - never inherits the lost one")

    // Preserved position travels through the ordinary one-shot progress path, uploaded by the
    // same drain pass that rescued it rather than waiting for the next lifecycle trigger.
    let progressRequests = await incarnation.http.requests(
      forPath: "/api/me/progress/\(RecoveryJourneyEnvironment.itemID)")
    #expect(progressRequests.count == 1)
    let progressBody = try #require(
      JSONSerialization.jsonObject(with: progressRequests[0].body ?? Data()) as? [String: Any])
    #expect(progressBody["currentTime"] as? Double == 88)
    #expect(
      try incarnation.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.itemID)
        .isEmpty)
  }

  @Test("a session-gone 404 on /close mid-playback preserves position and never dead-letters")
  func sessionGone404OnClosePreservesPositionAndNeverDeadLetters() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let incarnation = try env.openIncarnation()
    let sessionId = try incarnation.seedActiveSession()
    _ = try incarnation.sessionStore.close(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 95, deltaSecondsSinceLastSend: 4, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_010)))

    // Ambiguity reconciliation resolves `.sessionGone`: the session is absent, and authoritative
    // progress does not corroborate the close having landed.
    await incarnation.http.stub(
      path: RecoveryJourneyEnvironment.closePath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())]
    )
    await incarnation.http.stub(
      path: RecoveryJourneyEnvironment.getSessionPath,
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await incarnation.http.stub(
      path: "/api/me", responses: [RecoveryJourneyEnvironment.mediaProgressResponse(currentTime: 0)])
    await incarnation.http.stub(
      path: "/api/me/progress/\(RecoveryJourneyEnvironment.itemID)", responses: [RecoveryJourneyEnvironment.ok()])

    await incarnation.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    #expect(try incarnation.sessionStore.fetchSession(id: sessionId)?.state == .gone)
    #expect(
      try incarnation.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
        .isEmpty)
    // The preserved position uploads in the same drain pass that rescued it.
    let progressRequests = await incarnation.http.requests(
      forPath: "/api/me/progress/\(RecoveryJourneyEnvironment.itemID)")
    #expect(progressRequests.count == 1)
    let progressBody = try #require(
      JSONSerialization.jsonObject(with: progressRequests[0].body ?? Data()) as? [String: Any])
    #expect(progressBody["currentTime"] as? Double == 95)
    #expect(
      try incarnation.outbox.fetchQueued(accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.itemID)
        .isEmpty)
  }

  // MARK: - Non-crash concurrency case: foreground pull during active playback

  @Test("a foreground pull carrying an older position never moves a live playing position backward")
  func foregroundPullWithOlderPositionNeverMovesBackward() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let incarnation = try env.openIncarnation(includeSyncEngine: true)
    let sessionId = try incarnation.seedActiveSession()
    _ = try incarnation.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 500, isFinished: false, deltaSecondsSinceLastTick: 50, localSequence: 1,
        originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))

    await env.enqueueLibraryPullCycle(on: incarnation.http, currentTime: 10, lastUpdateEpochMillis: 1_000_000_000_000)
    await incarnation.engine!.refresh()

    let progress = try #require(try incarnation.rawProgress())
    #expect(progress.currentTime == 500, "the playing position must never move backward")
  }

  @Test(
    "a foreground pull carrying a legitimately newer position resolves through ProgressMergePolicy once acknowledged")
  func foregroundPullWithLegitimatelyNewerPositionResolvesOnceAcknowledged() async throws {
    let env = try await RecoveryJourneyEnvironment()
    let incarnation = try env.openIncarnation(includeSyncEngine: true)
    let sessionId = try incarnation.seedActiveSession()
    _ = try incarnation.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 200, isFinished: false, deltaSecondsSinceLastTick: 20, localSequence: 1,
        originKey: env.clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    for row in try incarnation.outbox.fetchQueued(
      accountId: env.accountId, entityKey: RecoveryJourneyEnvironment.fixedEntityKey)
    {
      try incarnation.sessionStore.acknowledgeSync(operationId: try #require(row.id), sessionId: sessionId)
    }

    await env.enqueueLibraryPullCycle(on: incarnation.http, currentTime: 900, lastUpdateEpochMillis: 2_000_000_000_000)
    await incarnation.engine!.refresh()

    let progress = try #require(try incarnation.rawProgress())
    #expect(progress.currentTime == 900, "resolves through ProgressMergePolicy once nothing is left unacknowledged")
  }
}

// MARK: - Environment / incarnation harness

/// One journey's fixed identity (server/account/item), backed by a single temp-file database.
/// `openIncarnation()` opens a fresh `AppDatabase`/`OutboxStore`/`PlaybackSessionStore`/
/// `PlaybackSessionCoordinator`/`OutboxDrainer` graph over the same file each time, the "crash
/// and relaunch" boundary every test in `SessionRecoveryJourneyTests` cuts across. Account,
/// library and item rows are seeded once in `init`, since they persist in the file.
private final class RecoveryJourneyEnvironment: @unchecked Sendable {
  static let itemID = "item_recovery_fixture"
  static let secondItemID = "item_recovery_second_fixture"
  static let libraryID = "lib-recovery"
  static let serverSessionId = "server-session-1"
  static let syncPath = "/api/session/\(serverSessionId)/sync"
  static let closePath = "/api/session/\(serverSessionId)/close"
  static let getSessionPath = "/api/session/\(serverSessionId)"
  static let playPath = "/api/items/\(itemID)/play"
  /// Every test that seeds one session uses this fixed id. It is deterministic, so the matching
  /// outbox `entityKey` (`"session:<clientSessionId>"`, mirroring `PlaybackSessionStore`'s
  /// private formatting) is known ahead of time without a raw DB read.
  static let fixedClientSessionId = "fixed-recovery-client-session"
  static let fixedEntityKey = "session:\(fixedClientSessionId)"

  let databaseURL: URL
  let server: ABSServerConfig
  let account: TokenAccount
  let clientUUID: String
  let accountId: Int64
  let itemRowId: Int64
  let diagnostics = FakeDiagnosticsRecording()
  private let fixture: SuiteOnDiskDatabases
  private let scope: OnDiskDatabaseScope
  private var currentDatabase: AppDatabase?

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "RecoveryJourneyEnvironment")
    self.fixture = fixture
    scope = fixture.scope
    databaseURL = scope.url()
    server = try ABSServerConfig(url: try #require(URL(string: "https://recovery.example.test")))
    clientUUID = UUID().uuidString
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")

    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    let localClientUUID = clientUUID
    let serverBaseURL = server.baseURL.absoluteString
    let saved = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: localClientUUID, serverBaseURL: serverBaseURL, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let localAccountId = try #require(saved.id)
    let libraryRowId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let localItemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryRowId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title",
          sortTitle: "title")
      ).id)
    _ = try await itemDAO.upsertAsync(
      ItemRecord(
        accountId: localAccountId, libraryId: libraryRowId, serverItemId: Self.secondItemID, mediaKind: "book",
        title: "Second Title", sortTitle: "second title"))
    accountId = localAccountId
    itemRowId = localItemRowId
    scope.close(database)
  }

  deinit {}

  /// One "process lifetime": a fresh connection and in-memory object graph over the same on-disk
  /// file, the crash/relaunch boundary this suite is about. Mirrors `AppEnvironment.swift`'s
  /// wiring (`PlaybackCoordinatorBox` breaking the construction-order cycle between the
  /// coordinator's `requestDrain` and the drainer's `notifySessionGoneRecovery`), so
  /// `requestDrain` reaches a real `OutboxDrainer`.
  func openIncarnation(
    initialLowPowerMode: Bool = false, initialConstrainedOrCellular: Bool = false, includeSyncEngine: Bool = false
  ) throws -> Incarnation {
    let http = SessionScriptedHTTPClient()
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access-token", refreshToken: "canary-refresh-token"), for: account)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    if let currentDatabase {
      scope.close(currentDatabase)
      self.currentDatabase = nil
    }
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    currentDatabase = database
    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let scheduler = FakePlaybackCadenceScheduling()
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    let box = RecoveryCoordinatorBox()

    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId,
      diagnostics: diagnostics,
      notifySessionGoneRecovery: { itemID, episodeID in
        await box.coordinator?.recoverFromSessionGone(itemID: itemID, episodeID: episodeID)
      }
    )
    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, clock: clock,
      clientSessionIDGenerator: { UUID().uuidString }, scheduler: scheduler,
      initialNetworkConditions: NetworkConditionsSnapshot(
        isLowPowerMode: initialLowPowerMode, isConstrainedOrCellular: initialConstrainedOrCellular),
      requestDrain: { await drainer.drainOutbox() }
    )
    box.coordinator = coordinator

    var appLifecycle: FakeAppLifecycle?
    var engine: SyncEngine?
    if includeSyncEngine {
      let lifecycle = FakeAppLifecycle()
      appLifecycle = lifecycle
      engine = SyncEngine.make(
        client: client, database: database, diagnostics: diagnostics, appLifecycle: lifecycle,
        playback: coordinator, clock: clock, randomSource: { 1 })
    }

    return Incarnation(
      http: http, database: database, outbox: outbox, sessionStore: sessionStore, client: client,
      coordinator: coordinator, drainer: drainer, scheduler: scheduler, appLifecycle: appLifecycle, engine: engine,
      accountId: accountId, itemRowId: itemRowId
    )
  }

  func rawQueuedSyncRows(sessionId: Int64) async throws -> [OutboxOperationRecord] {
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    defer { scope.close(database) }
    return try await database.readAsync { db in
      try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionId).fetchAll(db)
    }
  }

  func rawSession(sessionId: Int64) async throws -> PlaybackSessionRecord? {
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    defer { scope.close(database) }
    return try await database.readAsync { db in try PlaybackSessionRecord.fetchOne(db, key: sessionId) }
  }

  func enqueueLibraryPullCycle(on http: SessionScriptedHTTPClient, currentTime: Double, lastUpdateEpochMillis: Double)
    async
  {
    await http.stub(
      path: "/api/libraries",
      responses: [
        Self.jsonResponse(object: ["libraries": [["id": Self.libraryID, "name": "Library", "mediaType": "book"]]])
      ])
    await http.stub(
      path: "/api/me",
      responses: [
        Self.jsonResponse(
          object: [
            "mediaProgresses": [
              [
                "libraryItemId": Self.itemID, "currentTime": currentTime, "isFinished": false,
                "lastUpdate": lastUpdateEpochMillis,
              ]
            ]
          ])
      ])
    await http.stub(
      path: "/api/libraries/\(Self.libraryID)/items",
      responses: [
        Self.jsonResponse(
          object: [
            "results": [
              [
                "id": Self.itemID, "libraryId": Self.libraryID, "mediaType": "book",
                "media": ["metadata": ["title": "Title", "authorName": NSNull()]],
              ]
            ],
            "total": 1, "limit": 100, "page": 0,
          ])
      ])
  }

  static func playResponse(itemID: String = itemID, serverSessionID: String = serverSessionId) -> HTTPResponse {
    let object: [String: Any] = [
      "id": serverSessionID,
      "libraryItemId": itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": 3600,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
          "contentUrl": "/api/items/\(itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    return jsonResponse(object: object)
  }

  static func openSessionResponse() -> HTTPResponse {
    jsonResponse(
      object: [
        "id": serverSessionId, "libraryItemId": itemID, "mediaType": "book",
        "audioTracks": [
          ["index": 1, "startOffset": 0, "duration": 100, "contentUrl": "/api/items/\(itemID)/file/101"]
        ],
        "chapters": [] as [Any],
      ])
  }

  static func openSessionsListResponse(orphanDeviceID: String) -> HTTPResponse {
    jsonResponse(
      object: [
        "sessions": [
          [
            "id": "orphan-session", "libraryItemId": itemID, "mediaType": "book",
            "deviceInfo": ["deviceId": orphanDeviceID],
            "audioTracks": [
              ["index": 1, "startOffset": 0, "duration": 100, "contentUrl": "/api/items/\(itemID)/file/101"]
            ],
            "chapters": [] as [Any],
          ]
        ]
      ])
  }

  static func mediaProgressResponse(currentTime: Double) -> HTTPResponse {
    jsonResponse(object: [
      "mediaProgresses": [["libraryItemId": itemID, "currentTime": currentTime, "isFinished": false]]
    ])
  }

  static func ok() -> HTTPResponse { HTTPResponse(statusCode: 200, headers: [:], body: Data()) }

  static func jsonResponse(object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

/// One opened process lifetime's full object graph, returned by `RecoveryJourneyEnvironment
/// .openIncarnation()`.
private struct Incarnation {
  let http: SessionScriptedHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let client: ABSClient
  let coordinator: PlaybackSessionCoordinator
  let drainer: OutboxDrainer
  let scheduler: FakePlaybackCadenceScheduling
  let appLifecycle: FakeAppLifecycle?
  let engine: SyncEngine?
  let accountId: Int64
  let itemRowId: Int64

  @discardableResult
  func seedActiveSession(
    clientSessionId: String = RecoveryJourneyEnvironment.fixedClientSessionId, itemRowId: Int64? = nil,
    serverSessionId: String? = RecoveryJourneyEnvironment.serverSessionId
  ) throws -> Int64 {
    let started = try sessionStore.startSession(
      accountId: accountId, clientSessionId: clientSessionId, itemId: itemRowId ?? self.itemRowId, duration: 3600,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let sessionId = try #require(started.id)
    if let serverSessionId {
      _ = try sessionStore.setServerSessionId(sessionId: sessionId, serverSessionId: serverSessionId)
    }
    return sessionId
  }

  func rawProgress() throws -> MediaProgressRecord? {
    try MediaProgressDAO(database: database).fetchCurrent(
      accountId: accountId, identity: .item(itemId: itemRowId))
  }
}

/// Breaks the construction-order cycle between `PlaybackSessionCoordinator` (needs `requestDrain`
/// at construction) and the `OutboxDrainer` that closure builds (needs
/// `notifySessionGoneRecovery` calling back into that same coordinator). Mirrors
/// `App/Whirr/Playback/PlaybackCoordinatorBox.swift`'s production shape (this Core-package
/// test target cannot import the App target, so it is duplicated here).
private final class RecoveryCoordinatorBox: @unchecked Sendable {
  weak var coordinator: PlaybackSessionCoordinator?
}
