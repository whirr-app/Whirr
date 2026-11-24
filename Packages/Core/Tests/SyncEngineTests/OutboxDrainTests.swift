import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Outbox drain in SyncEngine (API-CONVENTIONS.md rule 14).
///
/// Two layers are tested separately, matching how `SyncEngine`'s drain is built:
/// - `OutboxAcknowledgementPolicy` is pure decision logic: every classification and
///   acknowledgement rule, including `local-all`-shaped batch matching, is checked directly
///   against synthetic outcomes.
/// - `SyncEngineOutboxDrainTests` exercises the real actor against a fake `ABSClient` built as
///   in `ABSApiTests` (`@testable import ABSApi`, `FakeHTTPClient` or a scripted per-path fake,
///   `InMemoryTokenStore`) for `progress` scenarios through real HTTP status codes: 2xx ack,
///   transport/429/5xx backoff, 401-after-refresh, permanent 4xx, cancellation, lost-response
///   replay.
@Suite("Outbox acknowledgement policy", .timeLimit(.minutes(1)))
struct OutboxAcknowledgementPolicyTests {
  @Test("an ordinary mutation's 2xx acknowledges unconditionally")
  func ordinarySuccessAcknowledges() {
    let policy = OutboxAcknowledgementPolicy()
    #expect(policy.decide(outcome: .ordinarySuccess, attempts: 1) == .acknowledge)
  }

  // MARK: - local-all-shaped batch matching

  @Test("exactly one matching success row acknowledges")
  func exactlyOneMatchingSuccessRowAcknowledges() {
    let policy = OutboxAcknowledgementPolicy()
    let decision = policy.decide(
      outcome: .batchResult(
        rows: [OutboxAcknowledgementPolicy.BatchResultRow(id: "op-1", success: true)],
        expectedID: "op-1"),
      attempts: 1)
    #expect(decision == .acknowledge)
  }

  @Test("a missing result row remains queued")
  func missingResultRowRemainsQueued() {
    let policy = OutboxAcknowledgementPolicy()
    let decision = policy.decide(
      outcome: .batchResult(rows: [], expectedID: "op-1"),
      attempts: 1, now: Date(), randomUnit: 1)
    guard case .retryWaiting = decision else {
      Issue.record("expected retryWaiting, got \(decision)")
      return
    }
  }

  @Test("duplicate success rows for the same id remain queued, not acknowledged")
  func duplicateSuccessRowsForTheSameIdRemainQueued() {
    // Mirrors ABSApi's `syncLocalSessions` one-matching-row rule at the outbox layer:
    // two `success: true` rows for one id is ambiguous, not an unambiguous acknowledgement.
    let policy = OutboxAcknowledgementPolicy()
    let decision = policy.decide(
      outcome: .batchResult(
        rows: [
          OutboxAcknowledgementPolicy.BatchResultRow(id: "op-1", success: true),
          OutboxAcknowledgementPolicy.BatchResultRow(id: "op-1", success: true),
        ],
        expectedID: "op-1"),
      attempts: 1, now: Date(), randomUnit: 1)
    guard case .retryWaiting = decision else {
      Issue.record("expected retryWaiting, got \(decision)")
      return
    }
  }

  @Test("an explicit failure row remains queued")
  func explicitFailureRowRemainsQueued() {
    let policy = OutboxAcknowledgementPolicy()
    let decision = policy.decide(
      outcome: .batchResult(
        rows: [OutboxAcknowledgementPolicy.BatchResultRow(id: "op-1", success: false)],
        expectedID: "op-1"),
      attempts: 1, now: Date(), randomUnit: 1)
    guard case .retryWaiting = decision else {
      Issue.record("expected retryWaiting, got \(decision)")
      return
    }
  }

  @Test("an unrelated id's result row leaves this operation unmatched and queued")
  func unmatchedIdRemainsQueued() {
    let policy = OutboxAcknowledgementPolicy()
    let decision = policy.decide(
      outcome: .batchResult(
        rows: [OutboxAcknowledgementPolicy.BatchResultRow(id: "some-other-op", success: true)],
        expectedID: "op-1"),
      attempts: 1, now: Date(), randomUnit: 1)
    guard case .retryWaiting = decision else {
      Issue.record("expected retryWaiting, got \(decision)")
      return
    }
  }

  // MARK: - Retry classification (API-CONVENTIONS.md rule 14)

  @Test("transport, rate-limited, and server failures back off exponentially using injected clock/RNG")
  func transientFailuresRetryWaitingWithBackoff() {
    let policy = OutboxAcknowledgementPolicy()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    for error in [APIError.transport, .rateLimited, .serverFailure(statusCode: 503)] {
      let decision = policy.decide(outcome: .apiFailure(error), attempts: 1, now: now, randomUnit: 1)
      guard case .retryWaiting(let delay) = decision else {
        Issue.record("expected retryWaiting for \(error), got \(decision)")
        continue
      }
      #expect(delay == BackoffPolicy.baseDelay)
    }
  }

  @Test("backoff delay grows with the operation's own persisted attempt count")
  func backoffGrowsWithPersistedAttempts() {
    let policy = OutboxAcknowledgementPolicy()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let firstDecision = policy.decide(outcome: .apiFailure(.transport), attempts: 1, now: now, randomUnit: 1)
    let secondDecision = policy.decide(outcome: .apiFailure(.transport), attempts: 2, now: now, randomUnit: 1)
    let thirdDecision = policy.decide(outcome: .apiFailure(.transport), attempts: 3, now: now, randomUnit: 1)

    guard case .retryWaiting(let firstDelay) = firstDecision,
      case .retryWaiting(let secondDelay) = secondDecision,
      case .retryWaiting(let thirdDelay) = thirdDecision
    else {
      Issue.record("expected retryWaiting for every attempt count")
      return
    }
    #expect(firstDelay == 1)
    #expect(secondDelay == 2)
    #expect(thirdDelay == 4)
  }

  @Test("permanent validation/permission/not-found errors dead-letter with a privacy-safe reason")
  func permanentErrorsDeadLetter() {
    let policy = OutboxAcknowledgementPolicy()
    let cases: [(APIError, String)] = [
      (.notFound, "notFound"),
      (.forbidden, "forbidden"),
      (.payloadTooLarge, "payloadTooLarge"),
      (.decoding, "decoding"),
    ]
    for (error, expectedReason) in cases {
      let decision = policy.decide(outcome: .apiFailure(error), attempts: 1)
      #expect(decision == .deadLetter(reason: expectedReason))
    }
  }

  @Test("an auth failure surviving the client's single refresh waits for re-authentication, never dead-letters")
  func unauthorizedAfterRefreshAwaitsReauthentication() {
    let policy = OutboxAcknowledgementPolicy()
    let decision = policy.decide(outcome: .apiFailure(.unauthorized), attempts: 1)
    #expect(decision == .awaitReauthentication)
  }

  @Test("cancellation - via Task cancellation or APIError.cancelled - requeues without backoff")
  func cancellationRequeuesWithoutBackoff() {
    let policy = OutboxAcknowledgementPolicy()
    #expect(policy.decide(outcome: .cancelled, attempts: 1) == .cancelledRequeue)
    #expect(policy.decide(outcome: .apiFailure(.cancelled), attempts: 1) == .cancelledRequeue)
  }

  @Test("decode/protocol ambiguity retains the row and halts the queue, never dead-letters")
  func decodeAmbiguityRetainsAndHalts() {
    let policy = OutboxAcknowledgementPolicy()
    #expect(policy.decide(outcome: .decodeAmbiguous, attempts: 1) == .retainAndHaltQueue)
  }
}

@Suite("SyncEngine outbox drain", .timeLimit(.minutes(1)))
struct SyncEngineOutboxDrainTests {

  @Test("an ordinary progress mutation acknowledges only on its documented 2xx and deletes the row")
  func ordinaryProgressAcknowledgesOn2xxAndDeletesTheRow() async throws {
    let harness = try await makeHarness()
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 42, isFinished: false, accumulatedDeltaSeconds: 5))

    await harness.engine.drainOutbox(now: Date())

    let remaining = try harness.store.fetchQueued(accountId: harness.accountId, entityKey: "item-1")
    #expect(remaining.isEmpty)
    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record == nil, "an acknowledged row is deleted, not merely transitioned")
  }

  @Test("a progress operation queued before item quarantine is retained but never sent")
  func quarantinedItemProgressIsWithheldAtDrainSelection() async throws {
    let harness = try await makeHarness()
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: nil,
      coalescingKey: "quarantined-item", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 42, isFinished: false, accumulatedDeltaSeconds: 5))

    try await harness.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [harness.itemRowId])
      try db.execute(
        sql: """
          INSERT INTO itemQuarantine (
            itemId, accountId, serverItemId, reason, quarantinedAt, terminalizedOperationCount
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          harness.itemRowId, harness.accountId, DrainHarness.itemServerID,
          "reservedPodcastSourceIdentity", Date(timeIntervalSince1970: 1_700_000_000), 0,
        ])
    }

    await harness.engine.drainOutbox(now: Date())

    #expect(await harness.http.requestCount(forPath: "/api/me/progress/\(DrainHarness.itemServerID)") == 0)
    let operationID = try #require(operation.id)
    let retained = try #require(try harness.store.fetchOperation(id: operationID))
    #expect(retained.state == .pending)
  }

  @Test("a non-2xx response leaves the ordinary mutation queued, not acknowledged")
  func non2xxLeavesOrdinaryMutationQueued() async throws {
    let harness = try await makeHarness()
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 503, headers: [:], body: Data())])
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    await harness.engine.drainOutbox(now: Date())

    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record?.state == .retryWaiting)
  }

  @Test("permanent 4xx dead-letters with a privacy-safe reason")
  func permanentNotFoundDeadLetters() async throws {
    let harness = try await makeHarness()
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    await harness.engine.drainOutbox(now: Date())

    let remaining = try harness.store.fetchQueued(accountId: harness.accountId, entityKey: "item-1")
    #expect(remaining.isEmpty, "a dead-lettered row is no longer part of the queue")
    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record?.state == .deadLetter)
    #expect(record?.deadLetterReason == "notFound")
  }

  @Test("transport/5xx enters retryWaiting with exponential backoff and does not resend before it is due")
  func transientFailureBacksOffAndDoesNotResendBeforeDue() async throws {
    let harness = try await makeHarness()
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 503, headers: [:], body: Data())])
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    await harness.engine.drainOutbox(now: now, randomUnit: { 1 })

    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record?.state == .retryWaiting)
    #expect(record?.nextAttemptAt == now.addingTimeInterval(BackoffPolicy.baseDelay))

    // Not due yet: a second drain pass before nextAttemptAt must not resend.
    await harness.engine.drainOutbox(now: now.addingTimeInterval(0.5), randomUnit: { 1 })
    #expect(await harness.http.requestCount(forPath: "/api/me/progress/item-1") == 1)

    // Due now: the next pass resends and, given a success response, acknowledges.
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.engine.drainOutbox(now: now.addingTimeInterval(BackoffPolicy.baseDelay), randomUnit: { 1 })
    #expect(await harness.http.requestCount(forPath: "/api/me/progress/item-1") == 2)
    let finalRemaining = try harness.store.fetchQueued(accountId: harness.accountId, entityKey: "item-1")
    #expect(finalRemaining.isEmpty)
  }

  @Test("a 401 that still fails after the client's single refresh retains the row without looping")
  func stillFailingAuthAfterSingleRefreshRetainsWithoutLooping() async throws {
    let harness = try await makeHarness()
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ])
    await harness.http.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")])
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    await harness.engine.drainOutbox(now: Date())

    #expect(await harness.http.requestCount(forPath: "/api/me/progress/item-1") == 2)
    #expect(await harness.http.requestCount(forPath: "/auth/refresh") == 1, "exactly one refresh - never a loop")
    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record?.state == .pending)
    #expect(record?.deadLetterReason == nil)

    // The client is now latched: a further drain is refused locally, sends nothing, and still
    // keeps the row for the drain that follows re-authentication.
    await harness.engine.drainOutbox(now: Date())
    #expect(await harness.http.requestCount(forPath: "/api/me/progress/item-1") == 2)
    let afterLatch = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(afterLatch?.state == .pending)
  }

  @Test("cancellation mid-send returns sending to pending without a further attempt, and is not lost or duplicated")
  func cancellationMidSendRecovers() async throws {
    let harness = try await makeHarness()
    await harness.http.hang(path: "/api/me/progress/item-1")
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    let task = Task { await harness.engine.drainOutbox(now: Date()) }
    await harness.http.waitUntilRequested(path: "/api/me/progress/item-1")
    task.cancel()
    await task.value

    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record?.state == .pending, "cancellation recovers to pending, never stuck in sending")
    #expect(record?.attempts == 1, "cancellation is not a further attempt beyond the one already recorded")
    #expect(await harness.http.requestCount(forPath: "/api/me/progress/item-1") == 1, "not duplicated")
  }

  @Test("a lost response replays as a byte-identical request - the absolute-value PATCH is idempotent")
  func lostResponseReplayIsIdempotent() async throws {
    let harness = try await makeHarness()
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 503, headers: [:], body: Data())])
    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 99.5, isFinished: false, accumulatedDeltaSeconds: 3))

    let firstAttempt = Date(timeIntervalSince1970: 1_700_000_000)
    await harness.engine.drainOutbox(now: firstAttempt, randomUnit: { 1 })

    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.engine.drainOutbox(now: firstAttempt.addingTimeInterval(10), randomUnit: { 1 })

    let requests = await harness.http.requests(forPath: "/api/me/progress/item-1")
    #expect(requests.count == 2)
    // Compare decoded JSON values, not raw bytes: `JSONEncoder` (no `.sortedKeys`) does not
    // guarantee the same key order across separate encoder instances, so byte-for-byte equality
    // would be flaky on an incidental detail. Idempotency means the replay carries the same field
    // values, which a real server would apply identically either time.
    let firstObject = try #require(
      JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: Any])
    let secondObject = try #require(
      JSONSerialization.jsonObject(with: requests[1].body ?? Data()) as? [String: Any])
    #expect(NSDictionary(dictionary: firstObject) == NSDictionary(dictionary: secondObject))
    #expect(requests[0].method == requests[1].method)
    #expect(requests[0].url == requests[1].url)
  }

  @Test("operations for one entity drain in strict local-sequence order")
  func operationsForOneEntityDrainInStrictLocalSequenceOrder() async throws {
    let harness = try await makeHarness()
    await harness.http.stub(
      path: "/api/me/progress/item-1",
      responses: Array(repeating: HTTPResponse(statusCode: 200, headers: [:], body: Data()), count: 3))

    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-3",
      localSequence: 3,
      payload: OutboxProgressPayload(currentTime: 30, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-2",
      localSequence: 2,
      payload: OutboxProgressPayload(currentTime: 20, isFinished: false, accumulatedDeltaSeconds: 1))

    await harness.engine.drainOutbox(now: Date())

    let requests = await harness.http.requests(forPath: "/api/me/progress/item-1")
    let currentTimes = try requests.map { try currentTime(fromBody: $0.body) }
    #expect(currentTimes == [10, 20, 30])
  }

  // MARK: - Episode-scoped progress routing (API-CONVENTIONS.md rule 11)

  @Test("an episode-scoped progress row PATCHes the episode route while an item-level row keeps the item route")
  func episodeScopedProgressUsesTheEpisodeRouteAndItemLevelProgressIsUnchanged() async throws {
    let harness = try await makeHarness()
    let itemPath = "/api/me/progress/\(DrainHarness.itemServerID)"
    let episodePath = "\(itemPath)/\(DrainHarness.episodeServerID)"
    await harness.http.stub(path: episodePath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.http.stub(path: itemPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: harness.episodeRowId,
      coalescingKey: "episode-scoped", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 120.5, isFinished: false, accumulatedDeltaSeconds: 0))
    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: nil,
      coalescingKey: "item-level", localSequence: 2,
      payload: OutboxProgressPayload(currentTime: 7, isFinished: true, accumulatedDeltaSeconds: 0))

    await harness.engine.drainOutbox(now: Date())

    let episodeRequests = await harness.http.requests(forPath: episodePath)
    #expect(episodeRequests.count == 1, "the episode's position is written to the episode, never to the show")
    let episodeRequest = try #require(episodeRequests.first)
    #expect(episodeRequest.method == .patch)
    #expect(episodeRequest.routeTemplate == "/api/me/progress/:id/:episodeId")
    let episodeBody = try #require(
      JSONSerialization.jsonObject(with: episodeRequest.body ?? Data()) as? [String: Any])
    #expect(episodeBody["currentTime"] as? Double == 120.5)
    #expect(episodeBody["progress"] as? Double == 120.5 / 800)
    #expect(episodeBody["isFinished"] as? Bool == false)
    #expect(episodeBody["id"] == nil, "rule 11: never an `id` field in a progress payload")

    let itemRequests = await harness.http.requests(forPath: itemPath)
    #expect(itemRequests.count == 1, "an item-level row still goes to the item-level route, unchanged")
    let itemRequest = try #require(itemRequests.first)
    #expect(itemRequest.routeTemplate == "/api/me/progress/:id")
    let itemBody = try #require(JSONSerialization.jsonObject(with: itemRequest.body ?? Data()) as? [String: Any])
    #expect(itemBody["currentTime"] as? Double == 7)
    // `7.0`, not `7`: two integer literals divide as integers and fold to `0`, so the expectation
    // could never pass. The sibling assertions escape this only because `120.5`/`640.25` already
    // force the operands to `Double`.
    #expect(itemBody["progress"] as? Double == 7.0 / 1_000)
    #expect(itemBody["isFinished"] as? Bool == true)

    let remaining = try harness.store.fetchQueued(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID)
    #expect(remaining.isEmpty, "both rows acknowledged on their own documented 2xx")
  }

  @Test("visibility PATCHes preserve item and episode scope and contain only the visibility field")
  func continueListeningVisibilityUsesTheCorrectRouteAndExactBody() async throws {
    let harness = try await makeHarness()
    let itemPath = "/api/me/progress/\(DrainHarness.itemServerID)"
    let episodePath = "\(itemPath)/\(DrainHarness.episodeServerID)"
    await harness.http.stub(
      path: itemPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await harness.http.stub(
      path: episodePath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    _ = try harness.store.enqueueContinueListeningVisibility(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID,
      podcastEpisodeId: harness.episodeRowId, localSequence: 1,
      hideFromContinueListening: true)
    _ = try harness.store.enqueueContinueListeningVisibility(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID,
      podcastEpisodeId: nil, localSequence: 2,
      hideFromContinueListening: false)

    await harness.engine.drainOutbox(now: Date())

    let episodeRequest = try #require(await harness.http.requests(forPath: episodePath).first)
    #expect(episodeRequest.method == .patch)
    #expect(episodeRequest.routeTemplate == "/api/me/progress/:id/:episodeId")
    let episodeBody = try #require(
      JSONSerialization.jsonObject(with: episodeRequest.body ?? Data()) as? [String: Any])
    #expect(NSDictionary(dictionary: episodeBody) == ["hideFromContinueListening": true])

    let itemRequest = try #require(await harness.http.requests(forPath: itemPath).first)
    #expect(itemRequest.method == .patch)
    #expect(itemRequest.routeTemplate == "/api/me/progress/:id")
    let itemBody = try #require(
      JSONSerialization.jsonObject(with: itemRequest.body ?? Data()) as? [String: Any])
    #expect(NSDictionary(dictionary: itemBody) == ["hideFromContinueListening": false])
  }

  @Test("a position-only progress row omits isFinished entirely, so it can never un-finish a server row")
  func positionOnlyProgressOmitsTheFinishedFlag() async throws {
    let harness = try await makeHarness()
    let episodePath = "/api/me/progress/\(DrainHarness.itemServerID)/\(DrainHarness.episodeServerID)"
    await harness.http.stub(path: episodePath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: harness.episodeRowId,
      coalescingKey: OutboxStore.localSessionProgressCoalescingKey, localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 640.25, isFinished: nil, accumulatedDeltaSeconds: 0))

    await harness.engine.drainOutbox(now: Date())

    let request = try #require(await harness.http.requests(forPath: episodePath).first)
    let body = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    #expect(body["currentTime"] as? Double == 640.25)
    #expect(body["progress"] as? Double == 640.25 / 800)
    #expect(
      body["isFinished"] == nil,
      "rule 11a: a position mirror restates position only - an explicit false would reopen a finished episode")
    #expect(body["id"] == nil, "rule 11: never an `id` field in a progress payload")
  }

  @Test("deleting a podcast show takes its episodes' queued progress rows with it, leaving nothing orphaned")
  func deletingAShowCascadesThroughItsEpisodesIntoTheirQueuedProgressRows() async throws {
    // The escape below is a safety valve, not a fix for a live bug. Every production route that
    // removes an episode row cascades: an item purge deletes `podcastEpisode`, which deletes
    // `outboxOperation` (`podcastEpisodeId ... ON DELETE CASCADE`), and account removal deletes
    // the account row above both. With `PRAGMA foreign_keys = ON` on every connection
    // (AppDatabase.configuration) an episode-scoped row cannot outlive its episode. This pins
    // that: a migration rebuilding either table without the cascade makes orphans real and fails.
    let harness = try await makeHarness()
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: harness.episodeRowId,
      coalescingKey: "episode-scoped", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 120.5, isFinished: false, accumulatedDeltaSeconds: 0))

    try await harness.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [harness.itemRowId])
    }

    let episode = try harness.database.read { db in
      try PodcastEpisodeRecord.fetchOne(db, key: harness.episodeRowId)
    }
    #expect(episode == nil, "the show's deletion cascades into its episodes")
    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record == nil, "and on into the episode's queued progress rows - never leaving one orphaned")
  }

  @Test("an episode-scoped row whose episode row is gone dead-letters instead of halting the show's queue forever")
  func orphanedEpisodeRowDeadLettersRatherThanHaltingTheQueueForever() async throws {
    let harness = try await makeHarness()
    let itemPath = "/api/me/progress/\(DrainHarness.itemServerID)"
    let episodePath = "\(itemPath)/\(DrainHarness.episodeServerID)"
    await harness.http.stub(path: itemPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let orphaned = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: harness.episodeRowId,
      coalescingKey: "episode-scoped", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 120.5, isFinished: false, accumulatedDeltaSeconds: 0))
    // Queued behind it on the same entity key: what a permanent halt on the head row would strand.
    let behind = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: nil,
      coalescingKey: "item-level", localSequence: 2,
      payload: OutboxProgressPayload(currentTime: 7, isFinished: true, accumulatedDeltaSeconds: 0))
    try await harness.orphanTheEpisodeRow()
    let survivingRows = try harness.database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(survivingRows.count == 2, "the outbox rows survive the orphaning - otherwise this proves nothing")

    await harness.engine.drainOutbox(now: Date())

    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: orphaned.id) }
    #expect(record?.state == .deadLetter, "an episode that is gone for good has no attempt left to make")
    #expect(record?.deadLetterReason == "episodeRowMissing")
    #expect(await harness.http.requests(forPath: episodePath).isEmpty, "no episode identity was ever resolved")

    let itemRequests = await harness.http.requests(forPath: itemPath)
    #expect(itemRequests.count == 1, "never the show's own progress row on the orphan's behalf")
    #expect(try itemRequests.map { try currentTime(fromBody: $0.body) } == [7], "only the genuine item-level row")
    let behindRecord = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: behind.id) }
    #expect(behindRecord == nil, "the row behind the orphan drained rather than being stuck behind it forever")
  }

  @Test("an episode lookup the store cannot answer retains the row and halts, never dead-letters")
  func unreadableEpisodeLookupRetainsTheRowRatherThanDeadLettering() async throws {
    let harness = try await makeHarness()
    let itemPath = "/api/me/progress/\(DrainHarness.itemServerID)"
    let episodePath = "\(itemPath)/\(DrainHarness.episodeServerID)"
    await harness.http.stub(path: itemPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let operation = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: DrainHarness.itemServerID, podcastEpisodeId: harness.episodeRowId,
      coalescingKey: "episode-scoped", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 120.5, isFinished: false, accumulatedDeltaSeconds: 0))
    try await harness.makeTheEpisodeLookupFail()

    await harness.engine.drainOutbox(now: Date())

    #expect(await harness.http.requests(forPath: itemPath).isEmpty, "never the show's own progress row")
    #expect(await harness.http.requests(forPath: episodePath).isEmpty)
    let record = try harness.database.read { db in try OutboxOperationRecord.fetchOne(db, key: operation.id) }
    #expect(record?.state == .pending, "ambiguity retains the row and halts the queue")
    #expect(record?.deadLetterReason == nil, "a store that could not answer is not evidence the episode is gone")
  }

  @Test("different entities drain concurrently while each entity's own order is preserved")
  func differentEntitiesDrainConcurrentlyPreservingPerEntityOrder() async throws {
    let harness = try await makeHarness()
    await harness.http.hang(path: "/api/me/progress/item-1")
    await harness.http.stub(
      path: "/api/me/progress/item-2",
      responses: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ])

    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-1", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-2", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try harness.store.enqueueProgress(
      accountId: harness.accountId, entityKey: "item-2", podcastEpisodeId: nil, coalescingKey: "session-2",
      localSequence: 2,
      payload: OutboxProgressPayload(currentTime: 20, isFinished: false, accumulatedDeltaSeconds: 1))

    let task = Task { await harness.engine.drainOutbox(now: Date()) }

    // item-1's request is held open; item-2's queue must still fully drain without waiting for
    // it, which shows the two entities' queues interleave.
    await harness.http.waitUntilRequested(path: "/api/me/progress/item-1")
    await harness.http.waitUntilRequestCount(path: "/api/me/progress/item-2", atLeast: 2)

    await harness.http.release(
      path: "/api/me/progress/item-1", with: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    await task.value

    let item2Requests = await harness.http.requests(forPath: "/api/me/progress/item-2")
    let currentTimes = try item2Requests.map { try currentTime(fromBody: $0.body) }
    #expect(currentTimes == [10, 20])
    let remainingItem1 = try harness.store.fetchQueued(accountId: harness.accountId, entityKey: "item-1")
    #expect(remainingItem1.isEmpty)
  }
}

// MARK: - Test harness

private struct DrainHarness {
  /// The seeded podcast show/episode the episode-scoped routing tests enqueue against. The show's
  /// server id doubles as the `entityKey` every other test in this file already uses, so those
  /// tests keep their existing `/api/me/progress/item-1` paths unchanged.
  static let itemServerID = "item-1"
  static let episodeServerID = "episode-1"

  let engine: OutboxDrainer
  let http: ScriptedHTTPClient
  let store: OutboxStore
  let database: AppDatabase
  let accountId: Int64
  let itemRowId: Int64
  let episodeRowId: Int64

  /// Deletes the episode row but leaves its outbox row, so `podcastEpisodeId` resolves to nothing.
  /// `outboxOperation.podcastEpisodeId` is `ON DELETE CASCADE`, so an ordinary delete cannot reach
  /// this state. The populated table is renamed out of the DAO's path and replaced with an empty
  /// one of the same shape, keeping all writes on the async database path. The branch under test
  /// is send-time resolution, not SQLite's integrity enforcement.
  func orphanTheEpisodeRow() async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "ALTER TABLE podcastEpisode RENAME TO podcastEpisode_missing")
      try db.execute(
        sql: """
          CREATE TABLE podcastEpisode (
            id INTEGER PRIMARY KEY,
            accountId INTEGER NOT NULL,
            itemId INTEGER NOT NULL,
            serverEpisodeId TEXT NOT NULL,
            title TEXT NOT NULL,
            episodeNumber TEXT,
            lastSeenGeneration INTEGER NOT NULL,
            softDeleted BOOLEAN NOT NULL DEFAULT 0
          )
          """)
      db.clearSchemaCache()
    }
  }

  /// Removes the episode table, so the lookup throws rather than returning `nil`. The store
  /// could not answer at all, as with a transient read failure (`SQLITE_BUSY`, a damaged page).
  /// That differs from "the episode is gone" and the two must not share an outcome: only the
  /// latter is evidence about the episode. The table is renamed without replacement so the DAO
  /// receives a read error.
  func makeTheEpisodeLookupFail() async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "ALTER TABLE podcastEpisode RENAME TO podcastEpisode_missing")
      db.clearSchemaCache()
    }
  }
}

private func makeHarness() async throws -> DrainHarness {
  let database = try AppDatabase.inMemory()
  let clientUUID = UUID().uuidString
  let accountId = try await database.writeAsync { db in
    var account = AccountRecord(
      clientUUID: clientUUID, serverBaseURL: "https://books.example.test",
      serverUserId: "user-1", serverVersion: "2.35.1")
    try account.insert(db)
    return account.id!
  }
  let itemRowId = try await database.writeAsync { db -> Int64 in
    var library = LibraryRecord(
      accountId: accountId, serverLibraryId: "lib-1", mediaType: "podcast", name: "Podcasts")
    try library.insert(db)
    var item = ItemRecord(
      accountId: accountId, libraryId: library.id!, serverItemId: DrainHarness.itemServerID,
      mediaKind: "podcast", title: "Show", sortTitle: "show", durationSeconds: 1_000)
    try item.insert(db)
    return item.id!
  }
  let episodeRowId = try #require(
    try PodcastEpisodeDAO(database: database).upsert(
      PodcastEpisodeRecord(
        accountId: accountId, itemId: itemRowId, serverEpisodeId: DrainHarness.episodeServerID,
        title: "Episode", durationSeconds: 800, lastSeenGeneration: 1)
    ).id)
  let store = try OutboxStore(database: database)

  let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
  let account = try TokenAccount(
    credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
  let tokenStore = InMemoryTokenStore()
  try tokenStore.save(TokenPair(accessToken: "access-token", refreshToken: "refresh-token"), for: account)
  let http = ScriptedHTTPClient()
  let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

  let engine = OutboxDrainer(
    outboxStore: store, database: database, absClient: client, account: account, accountId: accountId)
  return DrainHarness(
    engine: engine, http: http, store: store, database: database, accountId: accountId, itemRowId: itemRowId,
    episodeRowId: episodeRowId)
}

private func makeRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

private func currentTime(fromBody body: Data?) throws -> Double {
  let object = try #require(JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
  return try #require(object["currentTime"] as? Double)
}

/// Per-path FIFO canned responses (mirrors ABSApiTests' `ScriptedHTTPClient`), plus an optional
/// "hang" mode per path that holds a request open until released or the caller is cancelled, so
/// concurrent per-entity draining and mid-send cancellation recovery are deterministic with no
/// wall-clock sleep. Waiters are continuation-based, not a poll loop: a real request crosses
/// several actor hops (`ABSClient` → `AuthenticatedHTTPClient` → `ServerRequestGate` →
/// `RedactingHTTPLogger` → here), so a fixed number of `Task.yield()`s does not prove arrival.
// Stays: needs per-path FIFO queues and a cancellable per-path hang so concurrent per-entity
// drains are deterministic; FakeHTTPClient has only one global queue.
private actor ScriptedHTTPClient: HTTPClienting {
  private var queues: [String: [HTTPResponse]] = [:]
  private var hangingPaths: Set<String> = []
  private var pendingContinuations: [String: [CheckedContinuation<HTTPResponse, Error>]] = [:]
  private nonisolated let arrivals = CallRecorder<String>(
    label: "ScriptedHTTPClient requested paths")
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

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    let path = request.url.path
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

  /// Waits until at least `count` requests have been recorded for `path`.
  func waitUntilRequestCount(path: String, atLeast count: Int) async {
    await arrivals.waitUntil { $0.filter { $0 == path }.count >= count }
  }
}
