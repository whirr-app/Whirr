import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The offline-session upload clamp: `min(localTimestamp, estimatedServerNow + 5 minutes)`,
/// where `estimatedServerNow = localNow + persistedOffset`.
@Suite struct SkewClampTests {

  private static let fiveMinutes: TimeInterval = 5 * 60

  @Test func sharedTimestampClampPreservesToleranceBoundaryReportsExcessAndSkipsWithoutOffset() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let tolerance: TimeInterval = 5 * 60
    let atTolerance = now.addingTimeInterval(tolerance)

    let withinTolerance = clampSyncTimestamps(
      startedAt: atTolerance, updatedAt: atTolerance, now: now, observedServerOffset: 0)
    #expect(withinTolerance.startedAt == atTolerance)
    #expect(withinTolerance.updatedAt == atTolerance)
    #expect(withinTolerance.exceedsFutureTolerance == false)

    let beyondTolerance = now.addingTimeInterval(tolerance + 1)
    let clamped = clampSyncTimestamps(
      startedAt: beyondTolerance, updatedAt: beyondTolerance, now: now, observedServerOffset: 0)
    #expect(clamped.startedAt == atTolerance)
    #expect(clamped.updatedAt == atTolerance)
    #expect(clamped.exceedsFutureTolerance)

    let noObservation = clampSyncTimestamps(
      startedAt: beyondTolerance, updatedAt: beyondTolerance, now: now, observedServerOffset: nil)
    #expect(noObservation.startedAt == beyondTolerance)
    #expect(noObservation.updatedAt == beyondTolerance)
    #expect(noObservation.exceedsFutureTolerance == false)
  }

  // MARK: - Estimated server now advances from the persisted offset

  @Test func estimatedServerNowAdvancesFromThePersistedOffsetAsLocalNowAdvances() async throws {
    let h = try await LocalSessionUploadHarness()
    // Offset +100s: at drain time 1, estimatedServerNow = now1+100. The session's `updatedAt` is
    // chosen just inside that instant's tolerance ceiling, so the clamp ceiling must shift as
    // `now` advances between two separate (single-session) drains. This proves
    // `estimatedServerNow` tracks `now` rather than a fixed value.
    try h.observedServerTime.recordObservation(
      accountId: h.accountId, offsetSeconds: 100, observedAt: Date(timeIntervalSince1970: 500))

    let now1 = Date(timeIntervalSince1970: 1_000)
    let now2 = Date(timeIntervalSince1970: 10_000)
    let updatedAt = Date(timeIntervalSince1970: 1_000 + 100 + Self.fiveMinutes - 1)  // just inside now1's ceiling

    let seed1 = try await h.seedClosedLocalSession(clientSessionId: "s1", startedAt: updatedAt, updatedAt: updatedAt)
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath, responses: [makeLocalAllResponse([(id: "s1", success: true)])])
    await h.drainer.drainLocalSessionUploads(now: now1)
    let request1 = try #require(await h.http.requests(forPath: LocalSessionUploadHarness.localAllPath).first)
    let sentUpdatedAt1 = try Self.updatedAtMillis(request1)
    // now1's ceiling (now1 + 100 + 300 = 1400s) is past updatedAt (1399s), so it is sent as-is.
    #expect(sentUpdatedAt1 == updatedAt.timeIntervalSince1970 * 1000)

    // The same `updatedAt`, drained much later: `now2`'s ceiling (now2+100+300=10400s) is far
    // past `updatedAt` (1399s) too, so it is sent as-is. Both prove `estimatedServerNow` is
    // computed fresh from the `now` each drain call uses, not cached from the first.
    let seed2 = try await h.seedClosedLocalSession(clientSessionId: "s2", startedAt: updatedAt, updatedAt: updatedAt)
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath, responses: [makeLocalAllResponse([(id: "s2", success: true)])])
    await h.drainer.drainLocalSessionUploads(now: now2)
    let request2 = try #require(await h.http.requests(forPath: LocalSessionUploadHarness.localAllPath).last)
    let sentUpdatedAt2 = try Self.updatedAtMillis(request2)
    #expect(sentUpdatedAt2 == updatedAt.timeIntervalSince1970 * 1000)
    _ = (seed1, seed2)
  }

  // MARK: - Clamp applied per timestamp when an observation exists

  @Test func aFutureTimestampWithinToleranceIsClampedDownToTheCeiling() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    // 4 minutes in the future: inside the 5-minute tolerance, so not held, but ahead of
    // `estimatedServerNow` (== `now` here). `min(x, ceiling)` with x < ceiling leaves x
    // unchanged, so the value passes through as-is. A value past the ceiling would flag skew
    // rather than clamp; `aSessionExceedingToleranceIsHeldForResolution` below covers that.
    let future = now.addingTimeInterval(4 * 60)
    let seed = try await h.seedClosedLocalSession(clientSessionId: "future-ok", startedAt: future, updatedAt: future)
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [makeLocalAllResponse([(id: "future-ok", success: true)])])

    await h.drainer.drainLocalSessionUploads(now: now)

    let request = try #require(await h.http.requests(forPath: LocalSessionUploadHarness.localAllPath).first)
    #expect(try Self.updatedAtMillis(request) == future.timeIntervalSince1970 * 1000)
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil, "acknowledged, never held")
  }

  @Test func aBehindServerTimestampIsNeverClampedUpward() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    // Two hours behind: the clamp ceiling (`now` + 5 min) is far above this, so `min` must leave
    // it untouched, never raised toward the ceiling.
    let behind = now.addingTimeInterval(-2 * 60 * 60)
    let seed = try await h.seedClosedLocalSession(clientSessionId: "behind", startedAt: behind, updatedAt: behind)
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath, responses: [makeLocalAllResponse([(id: "behind", success: true)])])

    await h.drainer.drainLocalSessionUploads(now: now)

    let request = try #require(await h.http.requests(forPath: LocalSessionUploadHarness.localAllPath).first)
    #expect(try Self.updatedAtMillis(request) == behind.timeIntervalSince1970 * 1000)
    #expect(try Self.startedAtMillis(request) == behind.timeIntervalSince1970 * 1000)
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil)
  }

  // MARK: - No observation: upload unclamped, even far in the future

  @Test func noObservationUploadsUnclampedEvenWhenFarInTheFuture() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // No `observedServerTime.recordObservation` call: this account has not observed a server
    // `Date` header yet.
    let farFuture = now.addingTimeInterval(60 * 60 * 24)  // one day in the future
    let seed = try await h.seedClosedLocalSession(
      clientSessionId: "no-observation", startedAt: farFuture, updatedAt: farFuture)
    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [makeLocalAllResponse([(id: "no-observation", success: true)])])

    await h.drainer.drainLocalSessionUploads(now: now)

    let request = try #require(await h.http.requests(forPath: LocalSessionUploadHarness.localAllPath).first)
    #expect(try Self.updatedAtMillis(request) == farFuture.timeIntervalSince1970 * 1000, "sent unclamped")
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil, "uploaded and acknowledged, never held")
  }

  // MARK: - Future skew beyond 5 minutes: one diagnostic, needsResolution, no upload

  @Test func futureSkewBeyondFiveMinutesHoldsForResolutionWithExactlyOneDiagnosticAndNoUpload() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    let farFuture = now.addingTimeInterval(Self.fiveMinutes + 1)
    let seed = try await h.seedClosedLocalSession(
      clientSessionId: "skewed", startedAt: farFuture, updatedAt: farFuture)

    await h.drainer.drainLocalSessionUploads(now: now)

    #expect(await h.http.requests.isEmpty, "no upload occurs before resolution")
    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .needsResolution)
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) != nil, "retained, not lost")
    let skewDiagnostics = h.diagnostics.recorded.filter { $0.category == .clockSkew }
    #expect(skewDiagnostics.count == 1)
  }

  @Test func noUploadEverOccursForAHeldSessionAcrossRepeatedDrains() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    let farFuture = now.addingTimeInterval(Self.fiveMinutes + 1)
    let seed = try await h.seedClosedLocalSession(
      clientSessionId: "skewed-repeat", startedAt: farFuture, updatedAt: farFuture)

    await h.drainer.drainLocalSessionUploads(now: now)
    await h.drainer.drainLocalSessionUploads(now: now.addingTimeInterval(3600))
    await h.drainer.drainLocalSessionUploads(now: now.addingTimeInterval(7200))

    #expect(await h.http.requests.isEmpty)
    let operation = try #require(try h.fetchOperation(seed.operationId))
    #expect(operation.state == .needsResolution, "stays held across every later drain, never spontaneously retried")
  }

  // MARK: - Keep-local confirmation releases the clamped value and wins last-write-wins

  @Test func keepLocalConfirmationReleasesTheClampedValueAndUploadsIt() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    let farFuture = now.addingTimeInterval(Self.fiveMinutes + 1)
    let seed = try await h.seedClosedLocalSession(
      clientSessionId: "keep-local", startedAt: farFuture, updatedAt: farFuture)

    await h.drainer.drainLocalSessionUploads(now: now)
    let held = try #require(try h.fetchOperation(seed.operationId))
    #expect(held.state == .needsResolution)

    // Keep-local: releases the row with the clamped value it will upload (the ceiling this
    // `now`/offset produces), authorizing that possibly newer-than-server timestamp to win under
    // the server's last-write-wins behaviour.
    let ceiling = now.addingTimeInterval(Self.fiveMinutes)
    try h.sessionStore.releaseHeldLocalUpload(
      operationId: seed.operationId, sessionId: seed.sessionId, clampedStartedAt: ceiling, clampedUpdatedAt: ceiling)
    #expect(try h.fetchOperation(seed.operationId)?.state == .pending)

    await h.http.stub(
      path: LocalSessionUploadHarness.localAllPath,
      responses: [makeLocalAllResponse([(id: "keep-local", success: true)])])
    await h.drainer.drainLocalSessionUploads(now: now)

    let request = try #require(await h.http.requests(forPath: LocalSessionUploadHarness.localAllPath).first)
    #expect(try Self.updatedAtMillis(request) == ceiling.timeIntervalSince1970 * 1000)
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) == nil, "uploaded and acknowledged after release")
  }

  // MARK: - Take-server / discard leaves newer server progress untouched

  @Test func takeServerDiscardRemovesTheHeldOperationWithoutEverUploadingOrTouchingServerProgress() async throws {
    let h = try await LocalSessionUploadHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    let farFuture = now.addingTimeInterval(Self.fiveMinutes + 1)
    let seed = try await h.seedClosedLocalSession(
      clientSessionId: "discard-me", startedAt: farFuture, updatedAt: farFuture)
    await h.drainer.drainLocalSessionUploads(now: now)
    #expect(try h.fetchOperation(seed.operationId)?.state == .needsResolution)

    try h.sessionStore.discardHeldLocalUpload(operationId: seed.operationId)

    #expect(await h.http.requests.isEmpty, "server progress is never touched by this drain path")
    #expect(try h.fetchOperation(seed.operationId) == nil, "the held operation is removed")
    let survivingSession = try #require(try h.sessionStore.fetchSession(id: seed.sessionId))
    #expect(
      survivingSession.state == .closedAwaitingUpload,
      "the session itself is retained as local history, never marked uploaded")

    // A later drain must never resurrect the discarded upload.
    await h.drainer.drainLocalSessionUploads(now: now.addingTimeInterval(3600))
    #expect(await h.http.requests.isEmpty)
  }

  // MARK: - Helpers

  private static func updatedAtMillis(_ request: HTTPRequest) throws -> Double {
    let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    let sessions = try #require(object["sessions"] as? [[String: Any]])
    return try #require(sessions.first?["updatedAt"] as? Double)
  }

  private static func startedAtMillis(_ request: HTTPRequest) throws -> Double {
    let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    let sessions = try #require(object["sessions"] as? [[String: Any]])
    return try #require(sessions.first?["startedAt"] as? Double)
  }
}
