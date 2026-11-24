import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `OutboxDrainer`'s `sessionSync`/`sessionClose` send and acknowledgement paths. Session-gone-404
/// classification and recovery are in `SessionGoneRecoveryTests`; every scenario here uses
/// ordinary 2xx/4xx/5xx/401/cancellation outcomes that never trigger it, proving
/// `OutboxAcknowledgementPolicy` applies to session kinds unchanged.
@Suite(.timeLimit(.minutes(1))) struct SessionOutboxDrainTests {

  private static let syncPath = "/api/session/server-session-1/sync"
  private static let closePath = "/api/session/server-session-1/close"

  // MARK: - `/sync` body

  @Test func syncSendsCurrentTimeTimeListenedAndDurationFromTheFrozenRow() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession(duration: 3600)
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 120, isFinished: false, deltaSecondsSinceLastTick: 15, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let requests = await harness.http.requests(forPath: Self.syncPath)
    #expect(requests.count == 1)
    let object = try #require(JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: Any])
    #expect(object["currentTime"] as? Double == 120)
    #expect(object["timeListened"] as? Double == 15)
    #expect(object["duration"] as? Double == 3600)
  }

  // MARK: - Only 2xx acknowledges; delta resets only inside that transaction

  @Test func aNon2xxResponseLeavesSessionSyncQueuedAndDeltaIntact() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.listenedDeltaSeconds == 5, "a failed attempt never resets delta")
    let rows = try harness.sessionRows(sessionId)
    #expect(rows.count == 1)
    #expect(rows[0].state == .retryWaiting)
  }

  // MARK: - Delta resets only on ack; ticks accrued mid-request stay separately queued

  @Test func deltaResetsOnlyOnAckAndATickDuringTheRequestIsSentAsItsOwnSeparateRow() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    await harness.http.hang(path: Self.syncPath)

    let task = Task { await harness.drainer.drainOutbox(now: Date()) }
    await harness.http.waitUntilRequested(path: Self.syncPath)

    // A second tick lands while the first `/sync` request is still in flight. It is its own
    // segment, so it opens a fresh row rather than mutating the one already `sending`.
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 14, isFinished: false, deltaSecondsSinceLastTick: 4, localSequence: 2,
        originKey: "device-uuid", segmentKey: "seg-2", now: Date(timeIntervalSince1970: 1_700_000_014)))

    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.http.release(path: Self.syncPath, with: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    await task.value

    let requests = await harness.http.requests(forPath: Self.syncPath)
    #expect(requests.count == 2, "the second tick was sent as its own request, not folded into the first")
    let firstBody = try #require(JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: Any])
    let secondBody = try #require(JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any])
    #expect(firstBody["currentTime"] as? Double == 10)
    #expect(secondBody["currentTime"] as? Double == 14)

    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.listenedDeltaSeconds == 0, "both rows eventually acknowledged, in order")
    #expect(try harness.sessionRows(sessionId).isEmpty)
  }

  // MARK: - Per-session requests never overlap

  @Test func aSecondQueuedSyncRowIsNeverAttemptedWhileTheFirstIsStillInFlight() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 14, isFinished: false, deltaSecondsSinceLastTick: 4, localSequence: 2,
        originKey: "device-uuid", segmentKey: "seg-2", now: Date(timeIntervalSince1970: 1_700_000_014)))
    await harness.http.hang(path: Self.syncPath)

    let task = Task { await harness.drainer.drainOutbox(now: Date()) }
    await harness.http.waitUntilRequested(path: Self.syncPath)

    #expect(
      await harness.http.requestCount(forPath: Self.syncPath) == 1,
      "the second row must not be attempted while the first is still in flight")

    await harness.http.stub(
      path: Self.syncPath,
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.http.release(path: Self.syncPath, with: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    await task.value

    #expect(await harness.http.requestCount(forPath: Self.syncPath) == 2)
  }

  // MARK: - Close waits behind earlier sync rows and includes the final remainder

  @Test func closeWaitsBehindEarlierSyncRowsAndIncludesTheFinalRemainder() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 50, isFinished: false, deltaSecondsSinceLastTick: 10, localSequence: 5,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    // Mirrors `PlaybackSessionCoordinator.closeActiveSessionIfPresent`: an immediate close reuses
    // the session's `lastLocalSequence` rather than minting a new one, so this row's
    // `localSequence` ties the sync row's above.
    _ = try harness.sessionStore.close(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 53, deltaSecondsSinceLastSend: 3, localSequence: 5,
        now: Date(timeIntervalSince1970: 1_700_000_013)))

    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.http.stub(
      path: Self.closePath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let allRequests = await harness.http.requests
    #expect(allRequests.count == 2)
    #expect(allRequests[0].url.path == Self.syncPath, "sync precedes close despite the tied localSequence")
    #expect(allRequests[1].url.path == Self.closePath)

    let closeObject = try #require(JSONSerialization.jsonObject(with: allRequests[1].body ?? Data()) as? [String: Any])
    #expect(closeObject["currentTime"] as? Double == 53)
    #expect(
      closeObject["timeListened"] as? Double == 3, "the close row carries only its own remainder, not the running total"
    )

    #expect(try harness.sessionStore.fetchSession(id: sessionId) == nil, "fully closed and acknowledged")
  }

  // MARK: - Existing transport/429/5xx/401/cancellation classifications still apply

  @Test func transportFailureBacksOffSessionSyncExactlyLikeAnOrdinaryMutation() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 1, isFinished: false, deltaSecondsSinceLastTick: 1, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_001)))
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 503, headers: [:], body: Data())])

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    await harness.drainer.drainOutbox(now: now, randomUnit: { 1 })

    let rows = try harness.sessionRows(sessionId)
    #expect(rows.first?.state == .retryWaiting)
    #expect(rows.first?.nextAttemptAt == now.addingTimeInterval(BackoffPolicy.baseDelay))
  }

  @Test func cancellationMidSendReturnsSessionSyncToPendingWithoutAFurtherAttempt() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 1, isFinished: false, deltaSecondsSinceLastTick: 1, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_001)))
    await harness.http.hang(path: Self.syncPath)

    let task = Task { await harness.drainer.drainOutbox(now: Date()) }
    await harness.http.waitUntilRequested(path: Self.syncPath)
    task.cancel()
    await task.value

    let rows = try harness.sessionRows(sessionId)
    #expect(rows.first?.state == .pending, "cancellation recovers to pending, never stuck in sending")
    #expect(rows.first?.attempts == 1, "cancellation is not a further attempt")
  }

  @Test func authFailureSurvivingRefreshRetainsSessionSyncAndNeverTouchesTheSession() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 1, isFinished: false, deltaSecondsSinceLastTick: 1, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_001)))
    await harness.http.stub(
      path: Self.syncPath,
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ])
    await harness.http.stub(
      path: "/auth/refresh",
      responses: [makeSessionAuthRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")])

    await harness.drainer.drainOutbox(now: Date())

    let rows = try harness.sessionRows(sessionId)
    #expect(rows.first?.state == .pending, "a 401 waits for re-authentication, never dead-letters")
    #expect(rows.first?.deadLetterReason == nil)
    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.state == .active, "a 401 is a generic auth failure, never session-gone")
  }

  // MARK: - Transient ambiguity (no server session id yet) retains the row

  @Test func aRowWithNoServerSessionIdYetIsRetainedNeverSent() async throws {
    // Transient, and the case in `sendSessionOperation`'s guard that must stay retained:
    // `setServerSessionId` can still land and give this row an endpoint to address. Retention is
    // bounded if it never does, since `PlaybackSessionCoordinator.performRecovery` marks a
    // never-confirmed active session gone at next launch, which deletes its outbox rows.
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession(serverSessionId: nil)
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 1, isFinished: false, deltaSecondsSinceLastTick: 1, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_001)))

    await harness.drainer.drainOutbox(now: Date())

    #expect(await harness.http.requests.isEmpty)
    let rows = try harness.sessionRows(sessionId)
    #expect(rows.first?.state == .pending)
    #expect(rows.first?.deadLetterReason == nil, "an unconfirmed session is not a missing one")
  }

  // MARK: - Local references that are gone for good (escape from a permanent halt)

  @Test func deletingASessionTakesItsQueuedSyncRowsWithIt() async throws {
    // The dead-letters below are a safety valve, not a fix for a live bug.
    // `outboxOperation.playbackSessionId` is `ON DELETE CASCADE` (SchemaV1 v1) and
    // `markSessionGone` deletes a session's outbox rows in the same transaction, so a session-kind
    // row cannot outlive its session while foreign keys are enforced. This pins that: a migration
    // rebuilding either table without the cascade makes orphans possible and fails this first.
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    #expect(try harness.sessionRows(sessionId).isEmpty == false, "a queued row to orphan in the first place")

    try await harness.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM playbackSession WHERE id = ?", arguments: [sessionId])
    }

    #expect(try harness.sessionRows(sessionId).isEmpty, "the session's deletion takes its queued rows with it")
  }

  @Test func anOrphanedSessionRowDeadLettersRatherThanHaltingItsQueueForever() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    try await harness.orphanTheSessionRow(sessionId)

    await harness.drainer.drainOutbox(now: Date())

    #expect(await harness.http.requests.isEmpty, "no server session id was ever resolved to address")
    let rows = try harness.sessionRows(sessionId)
    #expect(rows.first?.state == .deadLetter, "a session that is gone for good has no attempt left to make")
    #expect(rows.first?.deadLetterReason == "sessionRowMissing")
  }

  @Test func aSessionKindRowPointingAtNoSessionAtAllDeadLetters() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    try await harness.detachTheSessionReference(sessionId)

    await harness.drainer.drainOutbox(now: Date())

    #expect(await harness.http.requests.isEmpty)
    let rows = try harness.database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.first?.state == .deadLetter, "no session id to resolve, and none can ever appear")
    #expect(rows.first?.deadLetterReason == "sessionReferenceMissing")
  }

  @Test func aSessionLookupTheStoreCannotAnswerRetainsTheRowAndHalts() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    try await harness.makeTheSessionLookupFail()

    await harness.drainer.drainOutbox(now: Date())

    #expect(await harness.http.requests.isEmpty)
    let rows = try harness.database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.first?.state == .pending, "ambiguity retains the row and halts the queue")
    #expect(rows.first?.deadLetterReason == nil, "a store that could not answer is not evidence the session is gone")
  }

  // MARK: - Repeated drains and process reopen preserve ordering, never double-acknowledge

  @Test func repeatedDrainsAfterFullAcknowledgementNeitherResendNorDoubleAcknowledge() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())
    await harness.drainer.drainOutbox(now: Date())

    #expect(await harness.http.requestCount(forPath: Self.syncPath) == 1)
    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.listenedDeltaSeconds == 0)
  }

  @Test func drainOrderAndAcknowledgementSurviveAFreshOutboxDrainerAgainstTheSameDatabase() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 503, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000), randomUnit: { 1 })
    #expect(try harness.sessionRows(sessionId).first?.state == .retryWaiting)

    // A new `OutboxDrainer` instance against the same store/database (simulating process reopen)
    // picks the row back up once it is due, without re-deriving any in-memory state.
    let reopenedDrainer = OutboxDrainer(
      outboxStore: harness.outbox, database: harness.database, absClient: harness.client,
      account: harness.account, accountId: harness.accountId)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await reopenedDrainer.drainOutbox(
      now: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(BackoffPolicy.baseDelay), randomUnit: { 1 })

    #expect(await harness.http.requestCount(forPath: Self.syncPath) == 2)
    #expect(try harness.sessionRows(sessionId).isEmpty)
    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.listenedDeltaSeconds == 0)
  }
  // MARK: - A lost `/sync` response is reconciled, never replayed blind

  private static let sessionPath = "/api/session/server-session-1"

  /// `/sync` is additive and answers with no body, so a request that landed while its response
  /// was lost is indistinguishable from one that never arrived, and a replay adds the same
  /// listening time to the user's history twice. The session's server-side total is the
  /// evidence that tells them apart.
  @Test func aSyncThatLandedWithoutItsResponseIsAcknowledgedRatherThanResent() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession(duration: 3600)
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 120, isFinished: false, deltaSecondsSinceLastTick: 15, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    // Additive with nothing stubbed: the server counts the delta, then the client sees a transport
    // failure instead of the answer, as a dropped connection produces.
    await harness.http.makeSyncAdditive(path: Self.syncPath)
    await harness.http.serveSessionLedger(path: Self.sessionPath, sessionID: "server-session-1")

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020))

    #expect(await harness.http.serverTimeListening == 15, "counted exactly once")
    #expect(await harness.http.requestCount(forPath: Self.syncPath) == 1, "never resent")
    #expect(try harness.sessionRows(sessionId).isEmpty, "the operation was acknowledged, not retained")
    let session = try #require(try harness.sessionStore.fetchSession(id: sessionId))
    #expect(session.listenedDeltaSeconds == 0)
    #expect(session.acknowledgedListenedSeconds == 15, "the ledger advanced with the acknowledgement")
  }

  /// Guards against reconciliation becoming "assume it landed": a sync that never reached the
  /// server must still be replayed, and must end up counted once.
  @Test func aSyncThatNeverLandedIsStillResentAndCountedExactlyOnce() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession(duration: 3600)
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 120, isFinished: false, deltaSecondsSinceLastTick: 15, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    // Not additive yet: the request never reaches the server on this pass.
    await harness.http.serveSessionLedger(path: Self.sessionPath, sessionID: "server-session-1")
    let firstPass = Date(timeIntervalSince1970: 1_700_000_020)

    await harness.drainer.drainOutbox(now: firstPass, randomUnit: { 1 })

    #expect(await harness.http.serverTimeListening == 0)
    #expect(try harness.sessionRows(sessionId).isEmpty == false, "retained for the replay")

    await harness.http.makeSyncAdditive(path: Self.syncPath)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.drainer.drainOutbox(
      now: firstPass.addingTimeInterval(BackoffPolicy.baseDelay), randomUnit: { 1 })

    #expect(await harness.http.serverTimeListening == 15, "the replay was correct - counted once")
    #expect(try harness.sessionRows(sessionId).isEmpty)
    let session = try #require(try harness.sessionStore.fetchSession(id: sessionId))
    #expect(session.acknowledgedListenedSeconds == 15)
  }

  /// When the reconciliation cannot read the ledger there is no evidence either way, and guessing
  /// in either direction has a real cost, so the row waits for a pass that can tell.
  @Test func aFailedReconciliationLeavesTheRowPendingRatherThanResendingBlind() async throws {
    let harness = try await SessionDrainHarness()
    let sessionId = try harness.seedActiveSession(duration: 3600)
    _ = try harness.sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 120, isFinished: false, deltaSecondsSinceLastTick: 15, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    // Additive, and the ledger fetch is left unstubbed so it fails too.
    await harness.http.makeSyncAdditive(path: Self.syncPath)

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_020), randomUnit: { 1 })

    #expect(await harness.http.requestCount(forPath: Self.syncPath) == 1, "never resent blind")
    let rows = try harness.sessionRows(sessionId)
    #expect(rows.count == 1)
    #expect(rows[0].state == .pending, "retained and retryable - never dead-lettered")
    let session = try #require(try harness.sessionStore.fetchSession(id: sessionId))
    #expect(session.listenedDeltaSeconds == 15, "nothing was acknowledged")
  }
}

// MARK: - Test harness

final class SessionDrainHarness: @unchecked Sendable {
  static let itemID = "item_fixture"

  let http: SessionScriptedHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let client: ABSClient
  let account: TokenAccount
  let accountId: Int64
  let itemRowId: Int64
  let diagnostics: FakeDiagnosticsRecording
  let recovery: SessionGoneRecoveryRecorder
  let drainer: OutboxDrainer

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://drain.example.test")))
    // Tokens live under the account row's credential namespace, which is what
    // `OutboxDrainRequester` resolves from the record; a URL-keyed item would never be found.
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

    let libraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(accountId: accountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let itemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: Self.itemID, mediaKind: "book", title: "Title",
          sortTitle: "title")
      ).id)

    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let diagnostics = FakeDiagnosticsRecording()
    let recovery = SessionGoneRecoveryRecorder()

    self.http = http
    self.database = database
    self.outbox = outbox
    self.sessionStore = sessionStore
    self.client = client
    self.account = account
    self.accountId = accountId
    self.itemRowId = itemRowId
    self.diagnostics = diagnostics
    self.recovery = recovery
    drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId,
      diagnostics: diagnostics,
      notifySessionGoneRecovery: { itemID, episodeID in await recovery.record(itemID: itemID, episodeID: episodeID) }
    )
  }

  @discardableResult
  func seedActiveSession(
    clientSessionId: String = UUID().uuidString,
    serverSessionId: String? = "server-session-1",
    duration: Double? = 3600,
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws -> Int64 {
    let started = try sessionStore.startSession(
      accountId: accountId, clientSessionId: clientSessionId, itemId: itemRowId, duration: duration,
      startedAt: startedAt)
    let sessionId = try #require(started.id)
    if let serverSessionId {
      _ = try sessionStore.setServerSessionId(sessionId: sessionId, serverSessionId: serverSessionId)
    }
    return sessionId
  }

  func sessionRows(_ sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionId).fetchAll(db)
    }
  }

  /// Deletes the session row while leaving its outbox rows behind. `outboxOperation`'s
  /// `playbackSessionId` is `ON DELETE CASCADE` (SchemaV1 v1), so this state is unreachable
  /// through an ordinary delete. The populated table is renamed out of the DAO's path and
  /// replaced with an empty table of the same shape, preserving the outbox row while keeping
  /// all writes on the async database path.
  func orphanTheSessionRow(_ sessionId: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "ALTER TABLE playbackSession RENAME TO playbackSession_missing")
      try db.execute(
        sql: """
          CREATE TABLE playbackSession (
            id INTEGER PRIMARY KEY,
            accountId INTEGER NOT NULL,
            clientSessionId TEXT NOT NULL,
            serverSessionId TEXT,
            itemId INTEGER NOT NULL,
            podcastEpisodeId INTEGER,
            startedAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            listenedDeltaSeconds DOUBLE NOT NULL DEFAULT 0,
            closePending BOOLEAN NOT NULL DEFAULT 0,
            isOffline BOOLEAN NOT NULL DEFAULT 0,
            globalPosition DOUBLE NOT NULL DEFAULT 0,
            duration DOUBLE,
            state TEXT NOT NULL DEFAULT 'active',
            lastLocalSequence INTEGER NOT NULL DEFAULT 0
          )
          """)
      db.clearSchemaCache()
    }
  }

  /// Clears the session-kind rows' own `playbackSessionId`. Every enqueue path requires a session
  /// id (`OutboxStore.enqueueSessionSync`/`enqueueSessionClose` both take a non-optional `Int64`),
  /// so only a direct write can produce a session-kind row that points at nothing.
  func detachTheSessionReference(_ sessionId: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE outboxOperation SET playbackSessionId = NULL WHERE playbackSessionId = ?",
        arguments: [sessionId])
    }
  }

  /// Removes the session table, so the lookup throws rather than returning `nil`. The store
  /// cannot answer at all, which is what a transient read failure (`SQLITE_BUSY`, a damaged
  /// page) looks like from the sender's side. That differs from "the session is gone", and only
  /// the latter is evidence about the session.
  func makeTheSessionLookupFail() async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "ALTER TABLE playbackSession RENAME TO playbackSession_missing")
      db.clearSchemaCache()
    }
  }
}

/// Captures every `notifySessionGoneRecovery` call an `OutboxDrainer` makes, for tests that only
/// need to prove whether, and with what arguments, it fired. The full coordinator-integration
/// scenarios (a real replacement `/play` call) live in `SessionGoneRecoveryTests`.
actor SessionGoneRecoveryRecorder {
  private(set) var calls: [(itemID: String, episodeID: String?)] = []
  func record(itemID: String, episodeID: String?) { calls.append((itemID: itemID, episodeID: episodeID)) }
}

func makeSessionAuthRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

/// Per-path FIFO canned responses, plus an optional "hang" mode per path so a test can hold a
/// request open until it is manually released or the caller is cancelled, proving concurrent
/// per-entity draining and mid-send cancellation recovery deterministically, with no wall-clock
/// sleep. Mirrors `OutboxDrainTests.swift`'s file-private `ScriptedHTTPClient` under a different
/// name so both test files can keep their own copy without colliding.
// Stays: per-path queues, cancellable hang and an additive-sync ledger shared by several drain
// test files; FakeHTTPClient has only one global queue.
actor SessionScriptedHTTPClient: HTTPClienting {
  private var queues: [String: [HTTPResponse]] = [:]
  private var hangingPaths: Set<String> = []
  private var pendingContinuations: [String: [CheckedContinuation<HTTPResponse, Error>]] = [:]
  private nonisolated let arrivals = CallRecorder<String>(
    label: "SessionScriptedHTTPClient requested paths")
  private(set) var requests: [HTTPRequest] = []

  func stub(path: String, responses: [HTTPResponse]) {
    queues[path, default: []].append(contentsOf: responses)
  }

  func hang(path: String) {
    hangingPaths.insert(path)
  }

  func release(path: String, with response: HTTPResponse) {
    hangingPaths.remove(path)
    let waiters = pendingContinuations[path] ?? []
    pendingContinuations[path] = []
    for waiter in waiters { waiter.resume(returning: response) }
  }

  func requestCount(forPath path: String) -> Int {
    requests.filter { $0.url.path == path }.count
  }

  func requests(forPath path: String) -> [HTTPRequest] {
    requests.filter { $0.url.path == path }
  }

  /// Models the server behaviour that makes a lost `/sync` response reconcilable: the endpoint
  /// is additive, so a request that arrives has already changed the session's total whether or
  /// not its response comes back. With this armed, "landed but the answer was lost" is a state
  /// the fake can be in, rather than something a test asserts about a server that never moved.
  private var additiveSyncPath: String?
  private var ledgerPath: String?
  private var ledgerSessionID: String?
  private(set) var serverTimeListening: Double = 0

  func makeSyncAdditive(path: String) { additiveSyncPath = path }

  /// Serves `GET /api/session/{id}` from the live ledger above, so the reconciliation reads what
  /// the fake server accumulated rather than a value the test hard-coded.
  func serveSessionLedger(path: String, sessionID: String) {
    ledgerPath = path
    ledgerSessionID = sessionID
  }

  private func ledgerResponse(sessionID: String) -> HTTPResponse {
    let object: [String: Any] = [
      "id": sessionID,
      "libraryItemId": SessionDrainHarness.itemID,
      "mediaType": "book",
      "playMethod": 0,
      "timeListening": serverTimeListening,
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
          "contentUrl": "/api/items/\(SessionDrainHarness.itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    let path = request.url.path
    if path == additiveSyncPath,
      let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let listened = object["timeListened"] as? Double
    {
      serverTimeListening += listened
    }
    if path == ledgerPath, let sessionID = ledgerSessionID {
      return ledgerResponse(sessionID: sessionID)
    }
    arrivals.record(path)

    if hangingPaths.contains(path) {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          pendingContinuations[path, default: []].append(continuation)
        }
      } onCancel: {
        Task { await self.cancelPending(path: path) }
      }
    }

    guard var queue = queues[path], queue.isEmpty == false else {
      struct NoStubbedResponse: Error {}
      throw NoStubbedResponse()
    }
    let response = queue.removeFirst()
    queues[path] = queue
    return response
  }

  private func cancelPending(path: String) {
    let waiters = pendingContinuations[path] ?? []
    pendingContinuations[path] = []
    for waiter in waiters { waiter.resume(throwing: CancellationError()) }
  }

  func waitUntilRequested(path: String) async {
    await arrivals.waitUntil { $0.contains(path) }
  }
}
