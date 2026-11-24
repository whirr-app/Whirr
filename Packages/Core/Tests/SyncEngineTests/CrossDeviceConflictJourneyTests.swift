import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// PRODUCT journey 6: a second device's progress, or this device's own offline listening,
/// reconciles against the server without silently clobbering a substantial position. Covers every
/// `ProgressMergePolicy` outcome plus the `ResolutionCenter` actions for the two cases the policy
/// cannot resolve itself. Drives a real `SyncEngine.refresh()` (real library-pull and
/// `applyProgress`, not a seeded conflict row) and a real `ResolutionCenter`/`OutboxDrainer` over
/// `ResolutionCenterHarness`'s real `AppDatabase`/`DownloadCoordinator`. Fakes only the HTTP
/// boundary.
@Suite("Cross-device conflict journey (PRODUCT journey 6)")
struct CrossDeviceConflictJourneyTests {

  // MARK: - Foreground pulls: newer applies, older is kept, a safe zero position applies

  @Test("a newer server position applies, an older one is kept local, and a safe zero position applies")
  func newerOlderAndSafeZeroPositionResolvePerPolicy() async throws {
    let h = try await ResolutionCenterHarness()
    let engine = try Self.makeSyncEngine(h)

    // Newer: substantial local progress, then a pull with a strictly newer timestamp and position.
    _ = try h.mediaProgressDAO.applyServerResolution(
      accountId: h.accountId, identity: .item(itemId: h.itemRowId), currentTime: 500,
      isFinished: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    Self.enqueuePullCycle(on: h.http, itemRowId: h.itemRowId, currentTime: 900, lastUpdateEpochMillis: 2_000_000)
    await engine.refresh()
    var progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 900, "a legitimately newer server position applies")

    // Older: a pull with an older timestamp than the persisted one must not move it backward.
    Self.enqueuePullCycle(on: h.http, itemRowId: h.itemRowId, currentTime: 50, lastUpdateEpochMillis: 1_000_000)
    await engine.refresh()
    progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 900, "an older server position is kept local, never applied backward")

    // Safe zero position: local progress is trivial (well under the substantial floor), so the
    // zero-position guard does not fire and the newer-timestamped zero position applies.
    _ = try h.mediaProgressDAO.applyServerResolution(
      accountId: h.accountId, identity: .item(itemId: h.itemRowId), currentTime: 2,
      isFinished: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 3_000))
    Self.enqueuePullCycle(on: h.http, itemRowId: h.itemRowId, currentTime: 0, lastUpdateEpochMillis: 4_000_000)
    await engine.refresh()
    progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 0, "a zero position over trivial local progress applies per policy")
  }

  // MARK: - Unsafe zero position: needsResolution, then both resolution actions

  @Test(
    "an unsafe zero position over substantial local progress surfaces needsResolution, and both resolution actions land correctly"
  )
  func unsafeZeroPositionSurfacesResolutionAndBothActionsLandCorrectly() async throws {
    let h = try await ResolutionCenterHarness()
    let engine = try Self.makeSyncEngine(h)

    // Take-server runs before keep-local: `keepLocalProgress` re-enqueues an outbox row for this
    // item's entity key, and while that row is unacknowledged it outranks a later pull per
    // policy, so the zero-position guard would never be reached.
    _ = try h.mediaProgressDAO.applyServerResolution(
      accountId: h.accountId, identity: .item(itemId: h.itemRowId), currentTime: 700,
      isFinished: false, serverUpdatedAt: nil)
    Self.enqueuePullCycle(on: h.http, itemRowId: h.itemRowId, currentTime: 2, lastUpdateEpochMillis: nil)
    await engine.refresh()

    var progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 700, "the local value stays visible pending resolution - never clobbered")
    let firstOpen = try await h.resolutionCenter.fetchOpenItems()
    let firstConflictId = try #require(Self.progressConflictId(in: firstOpen))

    try await h.resolutionCenter.takeServerProgress(conflictId: firstConflictId)
    progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 2, "take-server applies the recorded server value")
    #expect(progress.origin == .server)
    #expect(try h.mediaProgressDAO.fetchConflict(id: firstConflictId) == nil, "resolved")

    // Keep-local branch: a fresh conflict against the same item, resolved the other way.
    _ = try h.mediaProgressDAO.applyServerResolution(
      accountId: h.accountId, identity: .item(itemId: h.itemRowId), currentTime: 600,
      isFinished: false, serverUpdatedAt: nil)
    Self.enqueuePullCycle(on: h.http, itemRowId: h.itemRowId, currentTime: 1, lastUpdateEpochMillis: nil)
    await engine.refresh()
    let secondOpen = try await h.resolutionCenter.fetchOpenItems()
    let secondConflictId = try #require(Self.progressConflictId(in: secondOpen))

    try await h.resolutionCenter.keepLocalProgress(conflictId: secondConflictId)
    #expect(try h.mediaProgressDAO.fetchConflict(id: secondConflictId) == nil, "resolved")
    let queued = try h.outbox.fetchQueued(accountId: h.accountId, entityKey: DownloadCoordinatorHarness.itemID)
    #expect(queued.contains { $0.payloadCurrentTime == 600 }, "keep-local re-enqueues the local value")
    let finalOpen = try await h.resolutionCenter.fetchOpenItems()
    #expect(Self.progressConflictId(in: finalOpen) == nil, "no open conflict left behind")
  }

  // MARK: - Offline-upload skew: held, keep-local clamps, take-server/discard keeps server

  @Test("a future-skewed offline upload is held, and keep-local explicitly wins with clamped time")
  func futureSkewedUploadIsHeldAndKeepLocalWinsWithClampedTime() async throws {
    let h = try await ResolutionCenterHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    let farFuture = now.addingTimeInterval(6 * 60)  // beyond the 5-minute tolerance

    let drainer = Self.makeDrainer(h)
    let sessionId = try Self.seedClosedOfflineSession(
      h, clientSessionId: "skew-keep-local", startedAt: farFuture, updatedAt: farFuture)
    await drainer.drainLocalSessionUploads(now: now)

    let open = try await h.resolutionCenter.fetchOpenItems()
    let (operationId, openSessionId) = try #require(Self.skewConfirmation(in: open))
    #expect(openSessionId == sessionId, "a future-skewed offline upload is held for resolution")
    #expect(try h.outbox.fetchOperation(id: operationId)?.state == .needsResolution)

    try await h.resolutionCenter.keepLocalSkew(operationId: operationId, sessionId: sessionId, now: now)
    #expect(try h.outbox.fetchOperation(id: operationId)?.state == .pending, "released for the ordinary drain")

    let ceiling = now.addingTimeInterval(5 * 60)
    h.http.enqueue(Self.localAllResponse(id: "skew-keep-local"))
    await drainer.drainLocalSessionUploads(now: now)

    let request = try #require(h.http.requests.first { $0.url.path == Self.localAllPath })
    #expect(
      try Self.updatedAtMillis(request) == ceiling.timeIntervalSince1970 * 1000,
      "keep-local's clamped ceiling - not the original far-future value - is what actually uploads")
    #expect(try h.sessionStore.fetchSession(id: sessionId) == nil, "uploaded and acknowledged after release")
  }

  @Test("take-server/discard on a held offline upload preserves newer server progress, never touching it")
  func takeServerDiscardPreservesNewerServerProgress() async throws {
    let h = try await ResolutionCenterHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    let farFuture = now.addingTimeInterval(6 * 60)

    let drainer = Self.makeDrainer(h)
    let sessionId = try Self.seedClosedOfflineSession(
      h, clientSessionId: "skew-take-server", startedAt: farFuture, updatedAt: farFuture)
    await drainer.drainLocalSessionUploads(now: now)

    let open = try await h.resolutionCenter.fetchOpenItems()
    let (operationId, openSessionId) = try #require(Self.skewConfirmation(in: open))
    #expect(openSessionId == sessionId)

    // The server's progress is newer than anything this held session recorded, so take-server/
    // discard must preserve it rather than let the held upload overwrite it.
    h.http.enqueue(
      ResolutionCenterHarness.mediaProgressResponse(
        libraryItemID: DownloadCoordinatorHarness.itemID, currentTime: 950, isFinished: false))

    try await h.resolutionCenter.takeServerSkew(operationId: operationId, sessionId: sessionId)

    #expect(try h.outbox.fetchOperation(id: operationId) == nil, "the held operation is removed")
    #expect(h.http.requests.filter { $0.url.path == Self.localAllPath }.isEmpty, "never uploaded")
    let survivingSession = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(survivingSession.state == .closedAwaitingUpload, "retained as local history, never marked uploaded")
    let progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 950, "the newer server progress this device never sent is what wins")

    // A later drain must never resurrect the discarded upload.
    await drainer.drainLocalSessionUploads(now: now.addingTimeInterval(3600))
    #expect(h.http.requests.filter { $0.url.path == Self.localAllPath }.isEmpty)
  }

  // MARK: - Helpers

  private static let localAllPath = "/api/session/local-all"

  private static func makeSyncEngine(_ h: ResolutionCenterHarness) throws -> SyncEngine {
    SyncEngine.make(
      client: h.client, database: h.database, diagnostics: h.downloads.diagnostics,
      appLifecycle: FakeAppLifecycle(), clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)))
  }

  private static func makeDrainer(_ h: ResolutionCenterHarness) -> OutboxDrainer {
    OutboxDrainer(
      outboxStore: h.outbox, database: h.database, absClient: h.downloads.client, account: h.downloads.account,
      accountId: h.accountId, diagnostics: h.downloads.diagnostics)
  }

  /// Seeds one fully-closed offline session. Duplicates `LocalSessionUploadHarness
  /// .seedClosedLocalSession`, whose database/outbox are not this harness's.
  @discardableResult
  private static func seedClosedOfflineSession(
    _ h: ResolutionCenterHarness, clientSessionId: String, startedAt: Date, updatedAt: Date, currentTime: Double = 120
  ) throws -> Int64 {
    let started = try h.sessionStore.startSession(
      accountId: h.accountId, clientSessionId: clientSessionId, itemId: h.itemRowId, startedAt: startedAt,
      isOffline: true)
    let sessionId = try #require(started.id)
    _ = try h.sessionStore.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: currentTime, isFinished: false, deltaSecondsSinceLastTick: currentTime, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-0", now: updatedAt))
    _ = try h.sessionStore.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: currentTime, deltaSecondsSinceLastSend: 0, localSequence: 1, now: updatedAt)
    )
    return sessionId
  }

  private static func localAllResponse(id: String) -> HTTPResponse {
    let body = try! JSONSerialization.data(withJSONObject: ["results": [["id": id, "success": true]]])
    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
  }

  private static func updatedAtMillis(_ request: HTTPRequest) throws -> Double {
    let object = try #require(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    let sessions = try #require(object["sessions"] as? [[String: Any]])
    return try #require(sessions.first?["updatedAt"] as? Double)
  }

  private static func progressConflictId(in items: [ResolutionOpenItem]) -> Int64? {
    for item in items {
      if case .progressConflict(let conflictId) = item.kind { return conflictId }
    }
    return nil
  }

  private static func skewConfirmation(in items: [ResolutionOpenItem]) -> (operationId: Int64, sessionId: Int64)? {
    for item in items {
      if case .skewConfirmation(let operationId, let sessionId) = item.kind { return (operationId, sessionId) }
    }
    return nil
  }

  /// One full `SyncEngine.refresh()` cycle's worth of responses for the harness's one fixture item
  /// (same shape as `OfflinePlaybackHarness.enqueuePullCycle`, but over this harness's `http` and
  /// item identity): an empty-then-one-library list, an `/api/me` progress snapshot, then one page
  /// containing the fixture item, in the order `SyncEngine.performRefresh` requests them.
  private static func enqueuePullCycle(
    on http: FakeHTTPClient, itemRowId: Int64, currentTime: Double, lastUpdateEpochMillis: Double?
  ) {
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: [
          "libraries": [["id": "lib-1", "name": "Library", "mediaType": "book"]]
        ])))
    var progressObject: [String: Any] = [
      "libraryItemId": DownloadCoordinatorHarness.itemID, "currentTime": currentTime, "isFinished": false,
    ]
    if let lastUpdateEpochMillis {
      progressObject["lastUpdate"] = lastUpdateEpochMillis
    }
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: ["mediaProgresses": [progressObject]])))
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(
          withJSONObject: [
            "results": [
              [
                "id": DownloadCoordinatorHarness.itemID, "libraryId": "lib-1", "mediaType": "book",
                "media": ["metadata": ["title": "Title", "authorName": NSNull()]],
              ]
            ],
            "total": 1,
            "limit": 100,
            "page": 0,
          ])))
  }
}
