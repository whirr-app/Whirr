import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `OutboxDrainer.drainLocalSessionUploads`: the bounded `local-all` reconciliation drain
/// (API-CONVENTIONS.md rule 10).
@Suite struct LocalSessionReconciliationTests {

  @Test func aSingleBatchEmitsOneBatchRecordAndACompleteSummary() async throws {
    let h = try await LocalSessionUploadHarness()
    for index in 0..<7 { _ = try await h.seedClosedLocalSession(clientSessionId: "session-\(index)") }
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [makeLocalAllResponse((0..<7).map { (id: "session-\($0)", success: true) })])
    let records = LocalAllTraceRecorder()
    await h.drainer.setLocalAllDeviceTraceSink { record in records.append(record) }

    await h.drainer.drainLocalSessionUploads()

    #expect(
      records.lines == [
        "WHIRRSYNC localall drain=start coalesced=0",
        "WHIRRSYNC localall batch=1 sessions=7 result=ok accepted=7 rejected=0",
        "WHIRRSYNC localall drain=end batches=1 sessions=7",
      ])
  }

  @Test func twoBatchesAreIndexedAndSummarizedThroughTheDrainer() async throws {
    let h = try await LocalSessionUploadHarness()
    for index in 0..<51 { _ = try await h.seedClosedLocalSession(clientSessionId: "session-\(index)") }
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [
        makeLocalAllResponse((0..<50).map { (id: "session-\($0)", success: true) }),
        makeLocalAllResponse([(id: "session-50", success: true)]),
      ])
    let records = LocalAllTraceRecorder()
    await h.drainer.setLocalAllDeviceTraceSink { record in records.append(record) }

    await h.drainer.drainLocalSessionUploads()

    let lines = records.lines
    #expect(lines.contains("WHIRRSYNC localall batch=1 sessions=50 result=ok accepted=50 rejected=0"))
    #expect(lines.contains("WHIRRSYNC localall batch=2 sessions=1 result=ok accepted=1 rejected=0"))
    #expect(lines.last == "WHIRRSYNC localall drain=end batches=2 sessions=51")
  }

  @Test func aCoalescedTriggerIsTracedWithoutAnExtraBatch() async throws {
    let h = try await LocalSessionUploadHarness()
    _ = try await h.seedClosedLocalSession(clientSessionId: "solo-session")
    await h.http.hang(path: LocalSessionUploadHarness.localAllPath)
    let records = LocalAllTraceRecorder()
    await h.drainer.setLocalAllDeviceTraceSink { record in records.append(record) }

    let first = Task { await h.drainer.drainLocalSessionUploads() }
    await h.http.waitUntilRequested(path: LocalSessionUploadHarness.localAllPath)
    await h.drainer.drainLocalSessionUploads()
    #expect(records.lines.contains("WHIRRSYNC localall drain=start coalesced=1"))

    await h.http.release(
      path: LocalSessionUploadHarness.localAllPath,
      with: makeLocalAllResponse([(id: "solo-session", success: true)]))
    await first.value
    #expect(records.lines.filter { $0.contains(" batch=") }.count == 1)
  }

  @Test func anHTTPFailureEmitsItsOutcomeAndStillEndsThePass() async throws {
    let h = try await LocalSessionUploadHarness()
    _ = try await h.seedClosedLocalSession(clientSessionId: "failed-session")
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [HTTPResponse(statusCode: 503, headers: [:], body: Data())])
    let records = LocalAllTraceRecorder()
    await h.drainer.setLocalAllDeviceTraceSink { record in records.append(record) }

    await h.drainer.drainLocalSessionUploads(randomUnit: { 1 })

    let lines = records.lines
    #expect(lines.contains("WHIRRSYNC localall batch=1 sessions=1 result=httpError accepted=0 rejected=0"))
    #expect(lines.last == "WHIRRSYNC localall drain=end batches=1 sessions=1")
  }

  /// A response we cannot read says nothing about which sessions the server accepted, so nothing
  /// in the batch may be dead-lettered. The drain must also stop rather than send the next batch
  /// into the same unreadable answer. Seeded past one batch so the halt is observable: with 51
  /// rows a continuing drain would issue a second request.
  @Test func anAmbiguousTopLevelResponseRetainsEveryBatchRowAndHaltsTheDrain() async throws {
    let h = try await LocalSessionUploadHarness()
    var seeded: [(sessionId: Int64, operationId: Int64)] = []
    for index in 0..<51 {
      let seed = try await h.seedClosedLocalSession(clientSessionId: "ambiguous-session-\(index)")
      seeded.append((seed.sessionId, seed.operationId))
    }
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data("not-json".utf8))])

    await h.drainer.drainLocalSessionUploads()

    #expect(
      await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 1,
      "the second batch is never sent - the drain halted on the first unreadable answer")
    for seed in seeded {
      let operation = try #require(try h.fetchOperation(seed.operationId))
      #expect(operation.state == .pending, "retained for a later pass, never dead-lettered")
    }
  }

  @Test func anOversizedTopLevelResponseRetainsEveryBatchRowAndHaltsTheDrain() async throws {
    let h = try await LocalSessionUploadHarness()
    var seeded: [(sessionId: Int64, operationId: Int64)] = []
    for index in 0..<3 {
      let seed = try await h.seedClosedLocalSession(clientSessionId: "oversized-session-\(index)")
      seeded.append((seed.sessionId, seed.operationId))
    }
    let oversizedBody = Data(repeating: 0x20, count: EndpointDecodeLimits.standard.maximumBodyBytes + 1)
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: oversizedBody)])

    await h.drainer.drainLocalSessionUploads()

    #expect(await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 1)
    for seed in seeded {
      let operation = try #require(try h.fetchOperation(seed.operationId))
      #expect(operation.state == .pending)
    }
  }

  // MARK: - Bounded sequential batching

  @Test func oneHundredTwentyPendingSessionsDrainAsThreeSequentialBatches() async throws {
    let h = try await LocalSessionUploadHarness()
    var seeded: [(sessionId: Int64, clientSessionId: String)] = []
    for index in 0..<120 {
      let clientSessionId = "session-\(index)"
      let seed = try await h.seedClosedLocalSession(clientSessionId: clientSessionId)
      seeded.append((seed.sessionId, clientSessionId))
    }
    let http = makeBodyAwareLocalAllClient()
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    await drainer.drainLocalSessionUploads()

    let requests = http.localAllRequests()
    #expect(requests.count == 3, "120 sessions bounded at 50 per batch is three requests")
    let sizes = try requests.map { request -> Int in
      let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
      let sessions = try #require(object["sessions"] as? [[String: Any]])
      return sessions.count
    }
    #expect(sizes == [50, 50, 20])
    #expect(
      try http.decodedBatchIDs() == [
        (0..<50).map { "session-\($0)" },
        (50..<100).map { "session-\($0)" },
        (100..<120).map { "session-\($0)" },
      ])

    for seed in seeded {
      #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil, "every acknowledged session is removed")
    }
    #expect(try h.outbox.fetchQueuedLocalSessionUploads(accountId: h.accountId, limit: 200).isEmpty)
  }

  @Test func anUploadedLocalSessionCarriesTheDurationItWasClosedWith() async throws {
    let h = try await LocalSessionUploadHarness()
    _ = try await h.seedClosedLocalSession(clientSessionId: "session-0", durationSeconds: 2_512.5)
    let http = makeBodyAwareLocalAllClient()
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    await drainer.drainLocalSessionUploads()

    let request = try #require(http.localAllRequests().first)
    let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    let session = try #require((object["sessions"] as? [[String: Any]])?.first)
    #expect(
      session["duration"] as? Double == 2_512.5,
      "the audio length we measured travels with the session, so the server never has to guess it from a feed")
  }

  @Test func aLocalSessionClosedWithoutAKnownDurationOmitsTheFieldRatherThanSendingZero() async throws {
    let h = try await LocalSessionUploadHarness()
    _ = try await h.seedClosedLocalSession(clientSessionId: "session-0")
    let http = makeBodyAwareLocalAllClient()
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    await drainer.drainLocalSessionUploads()

    let request = try #require(http.localAllRequests().first)
    let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    let session = try #require((object["sessions"] as? [[String: Any]])?.first)
    #expect(session["duration"] == nil, "an unknown length is absent, never a zero the server could believe")
  }

  @Test func anUploadedLocalSessionCarriesThePositionItStartedFrom() async throws {
    let h = try await LocalSessionUploadHarness()
    _ = try await h.seedClosedLocalSession(
      clientSessionId: "session-0", currentTime: 19_580, startPosition: 19_520.5)
    let http = makeBodyAwareLocalAllClient()
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    await drainer.drainLocalSessionUploads()

    let request = try #require(http.localAllRequests().first)
    let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    let session = try #require((object["sessions"] as? [[String: Any]])?.first)
    #expect(
      session["startTime"] as? Double == 19_520.5,
      "the server derives no start of its own for a local session, so history shows whatever this carries")
  }

  @Test func aLocalSessionWithNoRecordedStartOmitsStartTimeRatherThanSendingZero() async throws {
    let h = try await LocalSessionUploadHarness()
    _ = try await h.seedClosedLocalSession(clientSessionId: "session-0")
    let http = makeBodyAwareLocalAllClient()
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    await drainer.drainLocalSessionUploads()

    let request = try #require(http.localAllRequests().first)
    let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    let session = try #require((object["sessions"] as? [[String: Any]])?.first)
    #expect(
      session["startTime"] == nil,
      "a zero would claim the session began at the start of the book - the very bug this fixes")
  }

  @Test func batchesNeverSendConcurrentlyEvenAcrossMultipleBatchesInOnePass() async throws {
    let h = try await LocalSessionUploadHarness()
    for index in 0..<60 {
      _ = try await h.seedClosedLocalSession(clientSessionId: "session-\(index)")
    }
    let gate = TestGate<Void>(label: "local-all response")
    gate.hold()
    let http = makeBodyAwareLocalAllClient(gate: gate)
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    let task = Task { await drainer.drainLocalSessionUploads() }
    let firstRequestArrived = await TestSupport.waitUntil {
      let requestCount = http.localAllRequests().count
      let pendingCount = gate.parkedCount
      return requestCount == 1 && pendingCount == 1
    }
    #expect(firstRequestArrived)
    #expect(http.localAllRequests().count == 1)
    #expect(
      gate.parkedCount == 1,
      "exactly one request may be in flight at a time")

    gate.releaseNext()
    let secondRequestArrived = await TestSupport.waitUntil {
      let requestCount = http.localAllRequests().count
      let pendingCount = gate.parkedCount
      return requestCount == 2 && pendingCount == 1
    }
    #expect(secondRequestArrived)
    #expect(
      gate.parkedCount == 1,
      "the second batch's request arrived only after the first fully finished processing")
    gate.releaseNext()

    await task.value

    #expect(http.localAllRequests().count == 2)
    #expect(
      try http.decodedBatchIDs() == [
        (0..<50).map { "session-\($0)" },
        (50..<60).map { "session-\($0)" },
      ])
  }

  @Test func aBatchDeletesOnlySessionsExplicitlyAcknowledgedByTheResponse() async throws {
    let h = try await LocalSessionUploadHarness()
    var seeded: [(sessionId: Int64, clientSessionId: String)] = []
    for index in 0..<4 {
      let clientSessionId = "session-\(index)"
      let seed = try await h.seedClosedLocalSession(clientSessionId: clientSessionId)
      seeded.append((seed.sessionId, clientSessionId))
    }
    let http = makeBodyAwareLocalAllClient(acknowledgingOnly: ["session-0", "session-2"])
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    await drainer.drainLocalSessionUploads()

    #expect(try http.decodedBatchIDs() == [(0..<4).map { "session-\($0)" }])
    #expect(try h.sessionStore.fetchSession(id: seeded[0].sessionId) == nil)
    #expect(try h.sessionStore.fetchSession(id: seeded[1].sessionId) != nil)
    #expect(try h.sessionStore.fetchSession(id: seeded[2].sessionId) == nil)
    #expect(try h.sessionStore.fetchSession(id: seeded[3].sessionId) != nil)
    #expect(
      try h.outbox.fetchQueuedLocalSessionUploads(accountId: h.accountId, limit: 200).count == 2,
      "only unacknowledged sessions remain queued")
  }

  @Test func anAcknowledgeWhoseLocalWriteFailsRequeuesTheRowRatherThanStrandingItInSending() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "session-0")
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [
        makeLocalAllResponse([(id: "session-0", success: true)]),
        makeLocalAllResponse([(id: "session-0", success: true)]),
      ])
    await h.drainer.setAcknowledgeLocalUploadOverride { _, _ in
      throw CocoaError(.fileWriteUnknown)
    }

    await h.drainer.drainLocalSessionUploads()

    let queued = try h.outbox.fetchQueuedLocalSessionUploads(accountId: h.accountId, limit: 10)
    #expect(queued.count == 1, "the row returns to the queue instead of stranding in `sending`")
    #expect(queued.first?.state == .pending)
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) != nil, "nothing was deleted without an acknowledge")

    // Once the local write can succeed again, the next drain replays the idempotent upload and
    // completes the acknowledge, with no cold launch required.
    await h.drainer.setAcknowledgeLocalUploadOverride(nil)
    await h.drainer.drainLocalSessionUploads()
    #expect(try h.outbox.fetchQueuedLocalSessionUploads(accountId: h.accountId, limit: 10).isEmpty)
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil)
  }

  // MARK: - Coalesced overlapping drain requests

  @Test func anOverlappingDrainRequestCoalescesRatherThanFiringASecondNetworkCall() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "solo-session")
    await h.http.hang(path: LocalSessionUploadHarness.localAllPath)

    let first = Task { await h.drainer.drainLocalSessionUploads() }
    await h.http.waitUntilRequested(path: LocalSessionUploadHarness.localAllPath)
    // Arrives while the first call is still in flight, so must coalesce, not fire its own request.
    let submissions = TestCountRecorder(label: "local-session drain submissions")
    let second = Task {
      submissions.record()
      await h.drainer.drainLocalSessionUploads()
    }
    await submissions.waitUntil(count: 1)
    #expect(await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 1)

    await h.http.release(
      path: LocalSessionUploadHarness.localAllPath,
      with: makeLocalAllResponse([(id: "solo-session", success: true)]))
    _ = await (first.value, second.value)

    #expect(
      await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 1,
      "the coalesced follow-up pass finds nothing left to send and makes no extra request")
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil)
  }

  // MARK: - Per-result acknowledgement

  @Test func onlyExplicitSuccessTrueRowsAreAcknowledgedPartialDuplicateFailureAndMissingStayQueued() async throws {
    let h = try await LocalSessionUploadHarness()
    let acknowledged = try await h.seedClosedLocalSession(clientSessionId: "acked")
    let explicitFailure = try await h.seedClosedLocalSession(clientSessionId: "failed")
    let duplicateResult = try await h.seedClosedLocalSession(clientSessionId: "duped")
    let missingResult = try await h.seedClosedLocalSession(clientSessionId: "missing")

    let body = try! JSONSerialization.data(
      withJSONObject: [
        "results": [
          ["id": "acked", "success": true],
          ["id": "failed", "success": false],
          ["id": "duped", "success": true],
          ["id": "duped", "success": true],
          // "missing" has no row at all.
        ]
      ])
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: body)])

    await h.drainer.drainLocalSessionUploads(randomUnit: { 1 })

    #expect(try h.sessionStore.fetchSession(id: acknowledged.sessionId) == nil, "success:true clears the row")
    for held in [explicitFailure, duplicateResult, missingResult] {
      #expect(try h.sessionStore.fetchSession(id: held.sessionId) != nil, "unacknowledged sessions are retained")
      let operation = try #require(try h.fetchOperation(held.operationId))
      #expect(operation.state == .retryWaiting, "not yet permanently failed - just not yet acknowledged")
    }
  }

  // MARK: - Same-session serialization across overlapping drains

  @Test func aSecondOverlappingDrainNeverSendsTheSameSessionTwiceWhileTheFirstIsInFlight() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "in-flight-session")
    await h.http.hang(path: LocalSessionUploadHarness.localAllPath)

    let first = Task { await h.drainer.drainLocalSessionUploads() }
    await h.http.waitUntilRequested(path: LocalSessionUploadHarness.localAllPath)

    // A second overlapping call must not re-attempt the session already mid-flight.
    await h.drainer.drainLocalSessionUploads()
    #expect(await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 1)

    await h.http.release(
      path: LocalSessionUploadHarness.localAllPath,
      with: makeLocalAllResponse([(id: "in-flight-session", success: true)]))
    await first.value

    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil)
    #expect(await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 1)
  }

  // MARK: - Transport / 429 / 5xx / auth / cancellation classifications preserved

  @Test func aTransportFailureRetriesTheWholeBatchWithBackoff() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession()
    await h.http.stub(path: LocalSessionUploadHarness.localAllPath, throwing: [FakeHTTPClientError(message: "offline")])

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    await h.drainer.drainLocalSessionUploads(now: now, randomUnit: { 1 })

    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .retryWaiting)
    #expect(operation.nextAttemptAt == now.addingTimeInterval(BackoffPolicy.baseDelay))
  }

  @Test func aRateLimited429RetriesWithBackoff() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession()
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [HTTPResponse(statusCode: 429, headers: [:], body: Data())])

    await h.drainer.drainLocalSessionUploads(randomUnit: { 1 })

    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .retryWaiting)
  }

  @Test func aServer5xxRetriesWithBackoff() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession()
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [HTTPResponse(statusCode: 503, headers: [:], body: Data())])

    await h.drainer.drainLocalSessionUploads(randomUnit: { 1 })

    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .retryWaiting)
  }

  @Test func anAuthFailureSurvivingRefreshRetainsTheWholeBatchWithoutLooping() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession()
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ])
    await h.http.stub(
      path: "/auth/refresh",
      responses: [makeLocalUploadAuthRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")])

    await h.drainer.drainLocalSessionUploads()

    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .pending, "a 401 waits for re-authentication, never dead-letters")
    #expect(operation.deadLetterReason == nil)
    // The original send and its single post-refresh retry; a retained, immediately-due batch must
    // halt the pass rather than refetch it.
    #expect(await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 2)

    // Latched: a further drain is refused locally and sends nothing.
    await h.drainer.drainLocalSessionUploads()
    #expect(await h.http.requestCount(forPath: LocalSessionUploadHarness.localAllPath) == 2)
    #expect(try h.fetchOperation(seed.operationId)?.state == .pending)
  }

  @Test func cancellationMidSendReturnsEveryRowToPendingWithoutAFurtherAttemptAndHaltsThePass() async throws {
    let h = try await LocalSessionUploadHarness()
    let first = try await h.seedClosedLocalSession(clientSessionId: "session-a")
    _ = try await h.seedClosedLocalSession(clientSessionId: "session-b")
    await h.http.hang(path: LocalSessionUploadHarness.localAllPath)

    let task = Task { await h.drainer.drainLocalSessionUploads() }
    await h.http.waitUntilRequested(path: LocalSessionUploadHarness.localAllPath)
    task.cancel()
    await task.value

    let operation = try #require(try h.fetchOperation(first.operationId))
    #expect(operation.state == .pending, "cancellation recovers to pending, never stuck in sending")
    #expect(operation.attempts == 1, "cancellation is not a further attempt")
  }

  // MARK: - Lost response replay is idempotent

  @Test func aLostResponseRetainsRowsAndTheSerialReplayIsIdempotent() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "replay-session")
    let (replayClient, sawIdenticalReplay) = makeIdempotentReplayClient()
    let client = ABSClient(
      server: try makeReplayServer(), httpClient: replayClient, tokenStore: h.makeMatchingTokenStore())
    let drainer = OutboxDrainer(
      outboxStore: h.outbox, database: h.database, absClient: client, account: h.account, accountId: h.accountId)

    // First attempt: the response is "lost" (a transport error at the client, even though a real
    // server might have recorded it). The row must survive, unacknowledged.
    let firstAttemptNow = Date(timeIntervalSince1970: 1_700_000_000)
    await drainer.drainLocalSessionUploads(now: firstAttemptNow, randomUnit: { 1 })
    let afterFirst = try #require(try h.fetchOperation(seed.operationId))
    #expect(afterFirst.state == .retryWaiting)
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) != nil)

    // Replay: the same stable UUID and timestamps are resent. The fake asserts the second
    // request body is identical to the first before acknowledging it. `now` must be past the
    // backoff delay the first attempt scheduled, or the row is not due yet.
    await drainer.drainLocalSessionUploads(now: firstAttemptNow.addingTimeInterval(BackoffPolicy.baseDelay + 1))

    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil, "the idempotent replay is acknowledged")
    #expect(sawIdenticalReplay.value)
  }

  // MARK: - Backed-off and malformed rows never occupy the batch window

  @Test func aDueRowBehindMoreThanABatchOfBackedOffRowsIsStillSentAcrossRepeatedPasses() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_001_000)
    var backedOff: [Int64] = []
    for index in 0..<55 {
      let seed = try await h.seedClosedLocalSession(clientSessionId: "backed-off-\(index)")
      backedOff.append(seed.operationId)
    }
    try await h.database.writeAsync { [backedOff] db in
      for operationId in backedOff {
        guard var operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else { continue }
        operation.state = .retryWaiting
        operation.attempts = 3
        operation.nextAttemptAt = now.addingTimeInterval(600)
        try operation.update(db)
      }
    }
    let due = try await h.seedClosedLocalSession(clientSessionId: "due-newest")
    let http = makeBodyAwareLocalAllClient()
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    for _ in 0..<3 { await drainer.drainLocalSessionUploads(now: now, randomUnit: { 1 }) }

    #expect(try http.decodedBatchIDs() == [["due-newest"]])
    #expect(try h.fetchOperation(due.operationId) == nil, "the due row is acknowledged and removed")
    for operationId in backedOff {
      let operation = try #require(try h.fetchOperation(operationId))
      #expect(operation.state == .retryWaiting, "a backed-off row is never sent before it is due")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aDueRowMissingItsPayloadIsDeadLetteredAsMalformedRatherThanSpinning() async throws {
    let h = try await LocalSessionUploadHarness()
    let malformed = try await h.seedClosedLocalSession(clientSessionId: "malformed")
    try await h.database.writeAsync { db in
      guard var operation = try OutboxOperationRecord.fetchOne(db, key: malformed.operationId) else { return }
      operation.payloadCurrentTime = nil
      try operation.update(db)
    }
    let records = LocalAllTraceRecorder()
    await h.drainer.setLocalAllDeviceTraceSink { record in records.append(record) }

    await h.drainer.drainLocalSessionUploads()

    #expect(await h.http.requests.isEmpty, "a row with no payload is never sent")
    let operation = try #require(try h.fetchOperation(malformed.operationId))
    #expect(operation.state == .deadLetter)
    #expect(operation.deadLetterReason == "malformedPayload")
    #expect(records.lines.last == "WHIRRSYNC localall drain=end batches=0 sessions=0")
  }

  @Test(.timeLimit(.minutes(1)))
  func rowsWhoseSessionIsGoneAreDeadLetteredAndADueRowBehindMoreThanABatchOfThemIsStillSent() async throws {
    let h = try await LocalSessionUploadHarness()
    var orphaned: [Int64] = []
    for index in 0..<55 {
      let seed = try await h.seedClosedLocalSession(clientSessionId: "orphan-\(index)")
      orphaned.append(seed.operationId)
    }
    try await h.database.writeAsync { [orphaned] db in
      for operationId in orphaned {
        guard var operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else { continue }
        operation.playbackSessionId = nil
        try operation.update(db)
      }
    }
    let due = try await h.seedClosedLocalSession(clientSessionId: "due-behind-orphans")
    let http = makeBodyAwareLocalAllClient()
    let drainer = try makeBodyAwareDrainer(for: h, http: http)

    await drainer.drainLocalSessionUploads()

    #expect(try http.decodedBatchIDs() == [["due-behind-orphans"]])
    #expect(try h.fetchOperation(due.operationId) == nil, "the due row is acknowledged and removed")
    for operationId in orphaned {
      let operation = try #require(try h.fetchOperation(operationId))
      #expect(operation.state == .deadLetter)
      #expect(operation.deadLetterReason == "missingSession")
    }
  }

  @Test func aRowWhoseSessionMaterialReadsAsAbsentIsDeadLetteredAsMissingSession() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "absent-material")
    await h.drainer.setFetchLocalUploadMaterialOverride { _ in nil }

    await h.drainer.drainLocalSessionUploads()

    #expect(await h.http.requests.isEmpty)
    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .deadLetter)
    #expect(operation.deadLetterReason == "missingSession")
  }

  @Test(.timeLimit(.minutes(1)))
  func aDeadLetterWriteThatFailsHaltsThePassRatherThanRefetchingTheRow() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "unwritable")
    try await h.database.writeAsync { db in
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER rejectOutboxStateChange BEFORE UPDATE OF state ON outboxOperation
          BEGIN SELECT RAISE(ABORT, 'write rejected'); END
          """)
    }
    // Reads after the first throw, so a regression ends in a failed count rather than a hang.
    let reads = TestCounter()
    await h.drainer.setFetchLocalUploadMaterialOverride { _ in
      reads.increment()
      if reads.value > 1 { throw CocoaError(.fileReadUnknown) }
      return nil
    }
    let records = LocalAllTraceRecorder()
    await h.drainer.setLocalAllDeviceTraceSink { record in records.append(record) }

    await h.drainer.drainLocalSessionUploads()

    #expect(reads.value == 1, "the pass halts instead of refetching the row it could not dead-letter")
    #expect(try h.fetchOperation(seed.operationId)?.state == .pending)
    #expect(records.lines.last == "WHIRRSYNC localall drain=end batches=0 sessions=0 halted=1")
  }

  @Test(.timeLimit(.minutes(1)))
  func aSessionMaterialReadThatThrowsRetainsTheRowAndHaltsThePass() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "unreadable")
    await h.drainer.setFetchLocalUploadMaterialOverride { _ in throw CocoaError(.fileReadUnknown) }
    let records = LocalAllTraceRecorder()
    await h.drainer.setLocalAllDeviceTraceSink { record in records.append(record) }

    await h.drainer.drainLocalSessionUploads()

    #expect(await h.http.requests.isEmpty, "an unreadable row is never sent")
    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .pending, "a read failure is not evidence the session is gone")
    #expect(operation.deadLetterReason == nil)
    #expect(records.lines.last == "WHIRRSYNC localall drain=end batches=0 sessions=0 halted=1")
  }

  // MARK: - Quarantine on a post-send duplicate UUID

  @Test func aSessionQuarantinedAfterItsUploadRowWasQueuedIsDeadLetteredNeverSentOrMerged() async throws {
    let h = try await LocalSessionUploadHarness()
    let seed = try await h.seedClosedLocalSession(clientSessionId: "quarantine-me")
    // Simulates `PlaybackSessionStore.startSession`'s duplicate-`clientSessionId` collision
    // handling having already quarantined this row under its still-queued upload.
    try await h.database.writeAsync { db in
      guard var session = try PlaybackSessionRecord.fetchOne(db, key: seed.sessionId) else { return }
      session.state = .quarantined
      try session.update(db)
    }

    await h.drainer.drainLocalSessionUploads()

    #expect(await h.http.requests.isEmpty, "a quarantined session is never sent")
    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .deadLetter)
    #expect(operation.deadLetterReason == "quarantined")
  }

  // MARK: - Trigger matrix (launch/foreground/close/refresh; no timer path)

  @Test func launchForegroundAndExplicitRefreshEachFireExactlyOneDrainCall() async throws {
    let harness = try await makeTriggerHarness()

    // Launch: `SyncEngine.make` fires one drain, spawned in a detached `Task`. Wait for it.
    await waitUntilRecorderCount(harness.localRecorder, atLeast: 1)
    await harness.playback.waitForCalls { ordinaryDrainCallCount($0) >= 1 }

    harness.appLifecycle.simulateForeground()
    await waitUntilRecorderCount(harness.localRecorder, atLeast: 2)
    await harness.playback.waitForCalls { ordinaryDrainCallCount($0) >= 2 }

    await harness.engine.refresh()
    await waitUntilRecorderCount(harness.localRecorder, atLeast: 3)
    await harness.playback.waitForCalls { ordinaryDrainCallCount($0) >= 3 }

    #expect(await harness.localRecorder.count == 3)
    #expect(ordinaryDrainCallCount(harness.playback.calls) == 3)
  }

  @Test func backgroundDoesNotRequestAnOrdinaryOrLocalSessionUploadDrain() async throws {
    let harness = try await makeTriggerHarness()

    await waitUntilRecorderCount(harness.localRecorder, atLeast: 1)
    await harness.playback.waitForCalls { ordinaryDrainCallCount($0) >= 1 }
    let ordinaryCallsBeforeBackground = ordinaryDrainCallCount(harness.playback.calls)

    harness.appLifecycle.simulateBackground()
    await harness.playback.waitForCalls { calls in
      calls.contains { call in
        if case .handleAppBackgrounded = call { return true }
        return false
      }
    }

    #expect(ordinaryDrainCallCount(harness.playback.calls) == ordinaryCallsBeforeBackground)
    #expect(await harness.localRecorder.count == 1)
  }

  /// The fourth trigger: an offline-session close while conditions are non-offline. With no
  /// reachability boundary (`NetworkConditions` tracks only power/cellular), the concrete stand-in
  /// in `PlaybackSessionCoordinator` is switching from a local offline session to a streaming
  /// item: the scenario of
  /// `OfflineSessionRecordingTests.switchingFromALocalItemToAStreamingItemClosesTheLocalSessionBeforePlayingTheNewOne`,
  /// with a drain-request spy added.
  @Test func anOfflineSessionCloseWhileSwitchingToStreamingFiresExactlyOneDrainRequest() async throws {
    let h = try await OfflinePlaybackHarness()
    let recorder = DrainCallRecorder()
    let localItemRowId = try await h.makeItem(serverItemId: "item-local-side")
    try h.completeDownload(itemRowId: localItemRowId, orderIndex: 0, fileDurationSeconds: 600)
    _ = try await h.makeItem(serverItemId: "item-streaming-side")
    h.enqueuePlayResponse(itemID: "item-streaming-side")
    let coordinator = try h.makeCoordinator(requestLocalSessionUploadDrain: { await recorder.record() })

    _ = try await coordinator.startSession(itemID: "item-local-side", episodeID: nil)
    #expect(await recorder.count == 0, "no drain yet - nothing has closed")

    _ = try await coordinator.startSession(itemID: "item-streaming-side", episodeID: nil)

    #expect(await recorder.count == 1, "closing the local session while switching to streaming fires exactly one drain")
  }

  @Test func startingADifferentLocalItemNeverFiresTheUploadDrainTrigger() async throws {
    let h = try await OfflinePlaybackHarness()
    let recorder = DrainCallRecorder()
    let firstLocalItemRowId = try await h.makeItem(serverItemId: "item-local-first")
    try h.completeDownload(itemRowId: firstLocalItemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let secondLocalItemRowId = try await h.makeItem(serverItemId: "item-local-second")
    try h.completeDownload(itemRowId: secondLocalItemRowId, orderIndex: 0, fileDurationSeconds: 600)
    let coordinator = try h.makeCoordinator(requestLocalSessionUploadDrain: { await recorder.record() })

    _ = try await coordinator.startSession(itemID: "item-local-first", episodeID: nil)
    _ = try await coordinator.startSession(itemID: "item-local-second", episodeID: nil)

    #expect(
      await recorder.count == 0,
      "switching between two local items is never a non-offline situation - the trigger never fires")
  }

  @Test func noTimerPathEverFiresTheLocalSessionUploadDrain() async throws {
    let recorder = DrainCallRecorder()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://trigger.example.test")))
    let tokenStore = InMemoryTokenStore()
    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let database = try AppDatabase.inMemory()
    let appLifecycle = FakeAppLifecycle()
    let diagnostics = FakeDiagnosticsRecording()

    // Held for the duration of the test: `SyncEngine.make`'s internal trigger `Task`s capture the
    // engine only weakly, so a discarded return value would let ARC deallocate it before either
    // task runs.
    let engine = SyncEngine.make(
      client: client, database: database, diagnostics: diagnostics, appLifecycle: appLifecycle,
      localSessionUploadDrain: { await recorder.record() })

    // The one launch-time call is expected. The test introduces no later event, so a timer path
    // would have to fire synchronously to affect this construction check.
    await waitUntilRecorderCount(recorder, atLeast: 1)
    #expect(await recorder.count == 1)
    withExtendedLifetime(engine) {}
  }
}

private func waitUntilRecorderCount(
  _ recorder: DrainCallRecorder, atLeast target: Int,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  await TestSupport.waitUntil(sourceLocation: sourceLocation) { await recorder.count >= target }
}

private struct TriggerHarness: Sendable {
  let engine: SyncEngine
  let appLifecycle: FakeAppLifecycle
  let playback: FakePlaybackSyncing
  let localRecorder: DrainCallRecorder
}

private func makeTriggerHarness() async throws -> TriggerHarness {
  let localRecorder = DrainCallRecorder()
  let server = try ABSServerConfig(url: try #require(URL(string: "https://trigger.example.test")))
  let clientUUID = UUID().uuidString
  let account = try TokenAccount(
    credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
  let tokenStore = InMemoryTokenStore()
  try tokenStore.save(TokenPair(accessToken: "a", refreshToken: "r"), for: account)
  let http = FakeHTTPClient()
  let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
  let database = try AppDatabase.inMemory()
  try await database.writeAsync { db in
    var record = AccountRecord(
      clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
      serverVersion: "2.35.1")
    try record.save(db)
  }
  let appLifecycle = FakeAppLifecycle()
  let playback = FakePlaybackSyncing()
  let engine = SyncEngine.make(
    client: client, database: database, diagnostics: FakeDiagnosticsRecording(), appLifecycle: appLifecycle,
    playback: playback,
    localSessionUploadDrain: { await localRecorder.record() })
  return TriggerHarness(
    engine: engine, appLifecycle: appLifecycle, playback: playback, localRecorder: localRecorder)
}

private func ordinaryDrainCallCount(_ calls: [FakePlaybackSyncing.RecordedCall]) -> Int {
  calls.reduce(into: 0) { count, call in
    if case .notifyImmediateSyncTrigger(_) = call { count += 1 }
  }
}

/// `TestSupport.Locked` is not public, so this file keeps its own small lock-backed trace sink
/// recorder, as the other SyncEngine trace tests do.
private final class LocalAllTraceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ record: LocalAllDeviceTrace.Record) {
    lock.lock()
    storage.append(LocalAllDeviceTrace.line(record))
    lock.unlock()
  }

  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private actor DrainCallRecorder {
  private(set) var count = 0
  func record() { count += 1 }
}

private func makeLocalUploadAuthRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

private func makeReplayServer() throws -> ABSServerConfig {
  try ABSServerConfig(url: URL(string: "https://drain.example.test")!)
}

extension LocalSessionUploadHarness {
  /// A token store pre-loaded with this harness's own account/tokens, for a test that needs to
  /// stand up a second `ABSClient` over a different fake transport against the same account.
  func makeMatchingTokenStore() -> InMemoryTokenStore {
    let store = InMemoryTokenStore()
    try? store.save(TokenPair(accessToken: "access-token", refreshToken: "refresh-token"), for: account)
    return store
  }
}

private func makeBodyAwareDrainer(
  for harness: LocalSessionUploadHarness, http: FakeHTTPClient
) throws -> OutboxDrainer {
  let server = harness.server
  let client = ABSClient(
    server: server, httpClient: http, tokenStore: harness.makeMatchingTokenStore())
  return OutboxDrainer(
    outboxStore: harness.outbox,
    database: harness.database,
    absClient: client,
    account: harness.account,
    accountId: harness.accountId,
    diagnostics: harness.diagnostics)
}

/// A local-all transport fake that derives its acknowledgement rows from the submitted batch.
/// The wire body is the documented `{sessions: [...]}` request shape, so a wrong batch cannot be
/// hidden by acknowledging a superset of ids. Hold `gate` to park each response until released.
private func makeBodyAwareLocalAllClient(
  acknowledgingOnly allowedIDs: Set<String>? = nil,
  gate: TestGate<Void> = TestGate(label: "local-all response")
) -> FakeHTTPClient {
  FakeHTTPClient(handler: { request in
    guard request.url.path == LocalSessionUploadHarness.localAllPath else {
      throw FakeHTTPClientError(message: "unexpected path \(request.url.path)")
    }
    guard let body = request.body,
      let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let rawSessions = object["sessions"] as? [[String: Any]]
    else {
      throw FakeHTTPClientError(message: "local-all request did not contain sessions")
    }
    let batchIDs = rawSessions.compactMap { $0["id"] as? String }
    guard batchIDs.count == rawSessions.count else {
      throw FakeHTTPClientError(message: "local-all request contained a session without an id")
    }
    let acknowledgedIDs = allowedIDs.map { allowed in batchIDs.filter { allowed.contains($0) } }
    let response = makeLocalAllResponse(
      (acknowledgedIDs ?? batchIDs).map { (id: $0, success: true) })
    await gate.pass(otherwise: {})
    return response
  })
}

extension FakeHTTPClient {
  fileprivate func localAllRequests() -> [HTTPRequest] {
    requests.filter { $0.url.path == LocalSessionUploadHarness.localAllPath }
  }

  /// The session ids of every local-all batch, decoded from the wire bodies in send order.
  fileprivate func decodedBatchIDs() throws -> [[String]] {
    try localAllRequests().map { request in
      let object = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
      let sessions = (object?["sessions"] as? [[String: Any]]) ?? []
      return sessions.compactMap { $0["id"] as? String }
    }
  }
}

/// Models "a lost response is safe to replay serially" (issue advplyr#2662). The first call to
/// `/api/session/local-all` throws (the response never reached the client, though a real server
/// might have recorded it). The replay is acknowledged only once this fake confirms its body is
/// semantically identical to the first attempt's (same session ids, timestamps and positions),
/// comparing parsed values as `JSONEncoder`'s keyed-container field order is not stable across
/// encode calls. This models the server's `updatedAt` guard: nothing sent changes between attempts.
/// `sawIdenticalReplay` reports whether the replay matched.
private func makeIdempotentReplayClient() -> (
  client: FakeHTTPClient, sawIdenticalReplay: Locked<Bool>
) {
  let firstSessions = Locked<[[String: AnyHashable]]?>(nil)
  let sawIdenticalReplay = Locked(false)
  let client = FakeHTTPClient(handler: { request in
    guard request.url.path == "/api/session/local-all" else {
      throw FakeHTTPClientError(message: "unexpected path \(request.url.path)")
    }
    let object = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
    let rawSessions = (object?["sessions"] as? [[String: Any]]) ?? []
    let comparableSessions = rawSessions.map { session -> [String: AnyHashable] in
      var result: [String: AnyHashable] = [:]
      for (key, value) in session {
        if let hashable = value as? AnyHashable { result[key] = hashable }
      }
      return result
    }

    let isFirstAttempt = firstSessions.withValue { stored -> Bool in
      guard stored == nil else { return false }
      stored = comparableSessions
      return true
    }
    if isFirstAttempt {
      throw FakeHTTPClientError(message: "response lost")
    }
    sawIdenticalReplay.value = comparableSessions == firstSessions.value

    let results = rawSessions.compactMap { $0["id"] as? String }.map {
      ["id": $0, "success": true] as [String: Any]
    }
    let body = try JSONSerialization.data(withJSONObject: ["results": results])
    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
  })
  return (client, sawIdenticalReplay)
}
