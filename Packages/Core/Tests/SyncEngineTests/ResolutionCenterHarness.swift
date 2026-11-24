import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Shared construction for `ResolutionCenterTests`: composes a `DownloadCoordinatorHarness`
/// (real `ABSClient` over `FakeHTTPClient`, one seeded account/library/book item, a real
/// `DownloadStore`/`DownloadCoordinator`) with the `OutboxStore`/`PlaybackSessionStore`/
/// `ObservedServerTimeStore` trio every progress-conflict/skew scenario needs, all over the same
/// in-memory database.
final class ResolutionCenterHarness: @unchecked Sendable {
  let downloads: DownloadCoordinatorHarness
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let observedServerTime: ObservedServerTimeStore
  let mediaProgressDAO: MediaProgressDAO
  let itemDAO: ItemDAO
  let resolutionCenter: ResolutionCenter
  let reauthenticationRequests = TestCounter()

  var database: AppDatabase { downloads.database }
  var http: FakeHTTPClient { downloads.http }
  var client: ABSClient { downloads.client }
  var accountId: Int64 { downloads.accountId }
  var itemRowId: Int64 { downloads.itemRowId }

  init() async throws {
    downloads = try await DownloadCoordinatorHarness()
    let localOutbox = try OutboxStore(database: downloads.database)
    outbox = localOutbox
    sessionStore = PlaybackSessionStore(database: downloads.database, outbox: localOutbox)
    observedServerTime = ObservedServerTimeStore(database: downloads.database)
    mediaProgressDAO = MediaProgressDAO(database: downloads.database)
    itemDAO = ItemDAO(database: downloads.database)

    let counter = reauthenticationRequests
    resolutionCenter = ResolutionCenter(
      database: downloads.database,
      outboxStore: localOutbox,
      downloadStore: downloads.downloadStore,
      downloadCoordinator: downloads.coordinator,
      client: downloads.client,
      diagnostics: downloads.diagnostics,
      requestReauthentication: { counter.increment() })
  }

  // MARK: - Progress-conflict seeding

  /// Seeds a substantial, already-acknowledged local progress row, then records a near-zero
  /// server observation as a conflict. Calls `MediaProgressDAO.recordConflict` directly rather
  /// than standing up a library-pull cycle through `SyncEngine`'s zero-position guard.
  @discardableResult
  func seedProgressConflict(
    localCurrentTime: Double = 600, serverCurrentTime: Double = 2, serverIsFinished: Bool = false,
    detectedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws -> Int64 {
    _ = try mediaProgressDAO.applyServerResolution(
      accountId: accountId, identity: .item(itemId: itemRowId), currentTime: localCurrentTime,
      isFinished: false,
      serverUpdatedAt: nil)
    // `applyServerResolution` stamps `origin: .server`, but the zero-position guard only inspects
    // `currentTime`/`duration`, never `origin`, so this is a faithful minimal seed for the
    // conflict record/resolve methods.
    let conflict = try mediaProgressDAO.recordConflict(
      accountId: accountId, identity: .item(itemId: itemRowId),
      serverCurrentTime: serverCurrentTime,
      serverIsFinished: serverIsFinished, serverUpdatedAt: nil, detectedAt: detectedAt)
    return try #require(conflict.id)
  }

  // MARK: - Skew-confirmation seeding

  /// Seeds one fully-closed offline session already held `needsResolution` for future skew,
  /// without depending on `LocalSessionUploadHarness`'s `OutboxDrainer`/scripted-HTTP setup.
  @discardableResult
  func seedHeldSkewSession(
    clientSessionId: String = UUID().uuidString,
    currentTime: Double = 120,
    startedAt: Date,
    updatedAt: Date
  ) throws -> (sessionId: Int64, operationId: Int64) {
    let started = try sessionStore.startSession(
      accountId: accountId, clientSessionId: clientSessionId, itemId: itemRowId, startedAt: startedAt,
      isOffline: true)
    let sessionId = try #require(started.id)
    _ = try sessionStore.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: currentTime, isFinished: false, deltaSecondsSinceLastTick: currentTime,
        localSequence: 1, originKey: "device-uuid", segmentKey: "seg-0", now: updatedAt))
    _ = try sessionStore.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: currentTime, deltaSecondsSinceLastSend: 0, localSequence: 1, now: updatedAt))

    let queued = try outbox.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 10)
    let operationId = try #require(queued.first { $0.playbackSessionId == sessionId }?.id)
    // Hold it `needsResolution` directly: this harness exercises `ResolutionCenter`'s actions,
    // not `OutboxDrainer`'s skew detection (`SkewClampTests`).
    _ = try outbox.transition(operationId: operationId, to: .needsResolution)
    return (sessionId, operationId)
  }

  // MARK: - Dead-letter seeding

  /// Seeds one dead-lettered ordinary `progress`-kind operation for the fixture item.
  @discardableResult
  func seedProgressDeadLetter(reason: String = "notFound") throws -> Int64 {
    let operation = try outbox.enqueueProgress(
      accountId: accountId, entityKey: DownloadCoordinatorHarness.itemID, podcastEpisodeId: nil,
      coalescingKey: "dead-letter-fixture",
      localSequence: 1, payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 0))
    let operationId = try #require(operation.id)
    _ = try outbox.transition(operationId: operationId, to: .sending)
    _ = try outbox.transition(operationId: operationId, to: .deadLetter, deadLetterReason: reason)
    return operationId
  }

  func fetchOperation(_ operationId: Int64) throws -> OutboxOperationRecord? {
    try database.read { db in try OutboxOperationRecord.fetchOne(db, key: operationId) }
  }

  /// A canned `GET /api/me` response carrying one `mediaProgresses[]` row, which is what
  /// `ResolutionCenter.takeServerSkew` reads for an item-progress refresh.
  static func mediaProgressResponse(
    libraryItemID: String, currentTime: Double, isFinished: Bool
  ) -> HTTPResponse {
    let object: [String: Any] = [
      "mediaProgresses": [
        ["libraryItemId": libraryItemID, "currentTime": currentTime, "isFinished": isFinished]
      ]
    ]
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }

  /// An empty `GET /api/me` response: no row for this item, so `takeServerSkew` must leave the
  /// resolution open.
  static func emptyMediaProgressResponse() -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: ["mediaProgresses": [[String: Any]]()]))
  }
}
