import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `ResolutionCenter`'s enumeration of conflicts, dead letters, skew and paused auth, and every
/// per-kind action.
@Suite struct ResolutionCenterTests {

  @Test func invalidAccountServerURLProducesMissingHostConfigurationError() async throws {
    let harness = try await ResolutionCenterHarness()
    let operationId = try harness.seedProgressDeadLetter()
    try await harness.database.writeAsync { db in
      var record = try AccountRecord.fetchOne(db)!
      record.serverBaseURL = "http://[invalid"
      try record.update(db)
    }

    await #expect(throws: APIError.invalidServerConfiguration(.missingHost)) {
      try await harness.resolutionCenter.refreshMetadataDeadLetter(operationId: operationId)
    }
  }

  private static let fiveMinutes: TimeInterval = 5 * 60

  /// Inserts a second `ItemRecord` alongside the harness's own fixture item, so a bulk-resolution
  /// test can seed two distinct progress conflicts without colliding on `progressConflict`'s
  /// one-row-per-item unique index. Kept local to this file rather than the shared harness, since
  /// only these bulk tests need more than one item.
  private func seedSecondItemRow(_ h: ResolutionCenterHarness) async throws -> Int64 {
    var item = try #require(try await h.itemDAO.fetchOneAsync(id: h.itemRowId))
    item.id = nil
    item.serverItemId = "second-\(item.serverItemId)"
    let inserted = try await h.itemDAO.upsertAsync(item)
    return try #require(inserted.id)
  }

  @Test func aDeadLetteredBookmarkNamesItsItem() async throws {
    let h = try await ResolutionCenterHarness()
    let created = try await AudioBookmarkStore(database: h.database).create(
      accountId: h.accountId, serverItemId: DownloadCoordinatorHarness.itemID, time: 30,
      title: "Bookmark", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    guard case .created = created else {
      Issue.record("expected the bookmark to be created, got \(created)")
      return
    }
    let operationId = try #require(
      try h.outbox.fetchQueued(accountId: h.accountId, entityKey: DownloadCoordinatorHarness.itemID)
        .first?.id)
    _ = try h.outbox.transition(operationId: operationId, to: .sending)
    _ = try h.outbox.transition(operationId: operationId, to: .deadLetter, deadLetterReason: "forbidden")

    let items = try await h.resolutionCenter.fetchOpenItems()

    let item = try #require(items.first { $0.id == "deadLetter:\(operationId)" })
    #expect(item.itemTitle == "Title")
  }

  @Test func aDeadLetteredEbookRowNamesItsItem() async throws {
    let h = try await ResolutionCenterHarness()
    let itemRowId = try #require(
      try await ItemDAO(database: h.database).fetchOneAsync(
        accountId: h.accountId, serverItemId: DownloadCoordinatorHarness.itemID)?.id)
    let dao = MediaProgressDAO(database: h.database)
    try await dao.writeEbookPositionAndEnqueueAsync(
      accountId: h.accountId, identity: .item(itemId: itemRowId),
      entityKey: DownloadCoordinatorHarness.itemID, readingPositionJSON: "{}", ebookProgress: 0.3,
      ebookLocation: nil, originKey: "resolution-fixture")
    try await dao.markEbookAsFinishedAndEnqueueAsync(
      accountId: h.accountId, identity: .item(itemId: itemRowId),
      entityKey: DownloadCoordinatorHarness.itemID, originKey: "resolution-fixture")
    let operationIds = try h.outbox.fetchQueued(
      accountId: h.accountId, entityKey: DownloadCoordinatorHarness.itemID
    ).compactMap(\.id)
    #expect(operationIds.count == 2)
    for operationId in operationIds {
      _ = try h.outbox.transition(operationId: operationId, to: .sending)
      _ = try h.outbox.transition(operationId: operationId, to: .deadLetter, deadLetterReason: "forbidden")
    }

    let items = try await h.resolutionCenter.fetchOpenItems()

    for operationId in operationIds {
      let item = try #require(items.first { $0.id == "deadLetter:\(operationId)" })
      #expect(item.itemTitle == "Title")
    }
  }

  @Test func aDeadLetteredContinueListeningRowNamesItsItemAndRefreshesItsMetadata() async throws {
    let h = try await ResolutionCenterHarness()
    let operation = try h.outbox.enqueueContinueListeningVisibility(
      accountId: h.accountId, entityKey: DownloadCoordinatorHarness.itemID, podcastEpisodeId: nil,
      localSequence: 1, hideFromContinueListening: true)
    let operationId = try #require(operation.id)
    _ = try h.outbox.transition(operationId: operationId, to: .sending)
    _ = try h.outbox.transition(operationId: operationId, to: .deadLetter, deadLetterReason: "notFound")

    let items = try await h.resolutionCenter.fetchOpenItems()
    let item = try #require(items.first { $0.id == "deadLetter:\(operationId)" })
    #expect(item.itemTitle == "Title")

    h.downloads.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await h.resolutionCenter.refreshMetadataDeadLetter(operationId: operationId)
    #expect(try h.fetchOperation(operationId)?.state == .pending)
  }

  // MARK: - Enumeration

  @Test func enumeratesAllFourOpenKindsWithPrivacySafeDescriptors() async throws {
    let h = try await ResolutionCenterHarness()
    let conflictId = try h.seedProgressConflict()
    let skew = try h.seedHeldSkewSession(
      startedAt: Date(timeIntervalSince1970: 2_000_000_000), updatedAt: Date(timeIntervalSince1970: 2_000_000_000))
    let deadLetterId = try h.seedProgressDeadLetter()
    let downloads = try h.downloads.fetchDownloads(itemId: h.itemRowId)
    // Seed one `pausedAuth` download row directly. This exercises the enumeration, not the
    // transition path (`DownloadAuthRecoveryTests` covers how a row gets there).
    h.downloads.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 200, size: 10, mimeType: "audio/mp4", duration: 1)])
    try await h.downloads.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadRows = try h.downloads.fetchDownloads(itemId: h.itemRowId)
    let downloadId = try #require(downloadRows.first?.id)
    _ = try h.downloads.downloadStore.transition(downloadId: downloadId, to: .pausedAuth)
    _ = downloads

    let items = try await h.resolutionCenter.fetchOpenItems()

    #expect(items.count == 4)
    #expect(items.allSatisfy { $0.itemTitle == "Title" }, "every descriptor resolves the item title via a local join")
    let kinds = Set(items.map(\.id))
    #expect(kinds.contains("progressConflict:\(conflictId)"))
    #expect(kinds.contains("skewConfirmation:\(skew.operationId)"))
    #expect(kinds.contains("deadLetter:\(deadLetterId)"))
    #expect(kinds.contains("pausedAuthDownload:\(h.itemRowId)"))
    #expect(try await h.resolutionCenter.openCount() == 4)
  }

  @Test func openCountReflectsEnumerationExactly() async throws {
    let h = try await ResolutionCenterHarness()
    #expect(try await h.resolutionCenter.openCount() == 0)
    _ = try h.seedProgressConflict()
    #expect(try await h.resolutionCenter.openCount() == 1)
  }

  // MARK: - Progress conflicts: keep-local / take-server

  @Test func keepLocalReEnqueuesTheLocalValueAsAFreshProgressOperationAndClearsTheConflict() async throws {
    let h = try await ResolutionCenterHarness()
    let conflictId = try h.seedProgressConflict(localCurrentTime: 700, serverCurrentTime: 1)

    try await h.resolutionCenter.keepLocalProgress(conflictId: conflictId)

    #expect(try h.mediaProgressDAO.fetchConflict(id: conflictId) == nil, "the conflict is cleared")
    let queued = try h.outbox.fetchQueued(accountId: h.accountId, entityKey: DownloadCoordinatorHarness.itemID)
    let fresh = try #require(queued.first { $0.operationKind == OutboxOperationKind.progress.rawValue })
    #expect(fresh.payloadCurrentTime == 700, "the local value, not the rejected server value")
    #expect(fresh.state == .pending)
  }

  @Test func takeServerAppliesTheAlreadyRecordedServerValueThroughApplyServerResolutionAndClears() async throws {
    let h = try await ResolutionCenterHarness()
    let conflictId = try h.seedProgressConflict(localCurrentTime: 700, serverCurrentTime: 3, serverIsFinished: true)

    try await h.resolutionCenter.takeServerProgress(conflictId: conflictId)

    #expect(try h.mediaProgressDAO.fetchConflict(id: conflictId) == nil)
    let progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 3)
    #expect(progress.isFinished == true)
    #expect(progress.origin == .server)
  }

  @Test func bothProgressConflictActionsAreIdempotentAgainstAnAlreadyResolvedConflict() async throws {
    let h = try await ResolutionCenterHarness()
    let conflictId = try h.seedProgressConflict()
    try await h.resolutionCenter.takeServerProgress(conflictId: conflictId)

    // Repeating either action against the now-cleared id is a safe no-op, never a throw.
    try await h.resolutionCenter.takeServerProgress(conflictId: conflictId)
    try await h.resolutionCenter.keepLocalProgress(conflictId: conflictId)
  }

  // MARK: - Progress conflicts: bulk take-server-for-all

  @Test func takeServerForAllResolvesEveryOpenProgressConflict() async throws {
    let h = try await ResolutionCenterHarness()
    let firstConflictId = try h.seedProgressConflict(
      localCurrentTime: 700, serverCurrentTime: 3, serverIsFinished: true)
    let secondItemRowId = try await seedSecondItemRow(h)
    let secondConflict = try await h.mediaProgressDAO.recordConflictAsync(
      accountId: h.accountId, identity: .item(itemId: secondItemRowId),
      serverCurrentTime: 5, serverIsFinished: false, serverUpdatedAt: nil, detectedAt: Date())
    let secondConflictId = try #require(secondConflict.id)

    let result = try await h.resolutionCenter.takeServerForAllProgressConflicts()

    #expect(result.resolvedCount == 2)
    #expect(result.failedCount == 0)
    #expect(try h.mediaProgressDAO.fetchConflict(id: firstConflictId) == nil)
    #expect(try h.mediaProgressDAO.fetchConflict(id: secondConflictId) == nil)
    let progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 3)
    #expect(progress.isFinished == true)
    let secondProgress = try #require(
      try h.mediaProgressDAO.fetchCurrent(accountId: h.accountId, identity: .item(itemId: secondItemRowId)))
    #expect(secondProgress.currentTime == 5)
  }

  @Test func takeServerForAllLeavesDeadLetteredOutboxItemsUntouched() async throws {
    let h = try await ResolutionCenterHarness()
    let conflictId = try h.seedProgressConflict(serverCurrentTime: 3, serverIsFinished: true)
    let deadLetterId = try h.seedProgressDeadLetter(reason: "notFound")

    let result = try await h.resolutionCenter.takeServerForAllProgressConflicts()

    #expect(result.resolvedCount == 1)
    #expect(result.failedCount == 0)
    #expect(try h.mediaProgressDAO.fetchConflict(id: conflictId) == nil)
    #expect(try h.fetchOperation(deadLetterId)?.state == .deadLetter, "dead letters are a different resolution kind")
  }

  @Test func takeServerForAllContinuesPastOneFailureAndReportsBothCounts() async throws {
    let h = try await ResolutionCenterHarness()
    let goodConflictId = try h.seedProgressConflict(serverCurrentTime: 3, serverIsFinished: true)
    let secondItemRowId = try await seedSecondItemRow(h)
    // An ebook fraction that fails `validatedEbookProgress` (non-finite) forces this one conflict's
    // write transaction to roll back without touching the other.
    let badConflict = try await h.mediaProgressDAO.recordConflictAsync(
      accountId: h.accountId, identity: .item(itemId: secondItemRowId),
      serverCurrentTime: 1, serverIsFinished: false, serverUpdatedAt: nil, detectedAt: Date())
    let badConflictId = try #require(badConflict.id)
    try await h.database.writeAsync { db in
      var conflict = try #require(try ProgressConflictRecord.fetchOne(db, key: badConflictId))
      // SQLite stores a NaN REAL as NULL, so `.infinity` is the non-finite value that round-trips.
      // `validatedEbookProgress` rejects both alike (`isFinite`).
      conflict.serverEbookProgress = .infinity
      try conflict.update(db)
    }

    let result = try await h.resolutionCenter.takeServerForAllProgressConflicts()

    #expect(result.resolvedCount == 1)
    #expect(result.failedCount == 1)
    #expect(try h.mediaProgressDAO.fetchConflict(id: goodConflictId) == nil, "the good conflict still resolved")
    #expect(try h.mediaProgressDAO.fetchConflict(id: badConflictId) != nil, "the failing one is left open for retry")
  }

  @Test func takeServerForAllAppliesAServerEbookValueWhenTheConflictCarriesOne() async throws {
    let h = try await ResolutionCenterHarness()
    try await h.mediaProgressDAO.applyPulledCompositeProgressAsync(
      accountId: h.accountId,
      resolutions: [],
      conflicts: [
        MediaProgressDAO.PulledCompositeConflict(
          identity: .item(itemId: h.itemRowId), serverCurrentTime: 3, serverIsFinished: false,
          serverUpdatedAt: nil, detectedAt: Date(), serverEbookProgress: 0.42)
      ])
    let conflicts = try h.mediaProgressDAO.fetchOpenConflicts(accountId: h.accountId)
    let conflictId = try #require(conflicts.first?.id)

    let result = try await h.resolutionCenter.takeServerForAllProgressConflicts()

    #expect(result.resolvedCount == 1)
    #expect(result.failedCount == 0)
    #expect(try h.mediaProgressDAO.fetchConflict(id: conflictId) == nil)
    let progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.ebookProgress == 0.42)
    #expect(progress.currentTime == 3)
  }

  // MARK: - Skew confirmations: keep-local confirmation / take-server-discard

  @Test func keepLocalSkewConfirmationReleasesTheHeldUploadWithAFreshClamp() async throws {
    let h = try await ResolutionCenterHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try h.observedServerTime.recordObservation(accountId: h.accountId, offsetSeconds: 0, observedAt: now)
    let farFuture = now.addingTimeInterval(Self.fiveMinutes + 1000)
    let seed = try h.seedHeldSkewSession(startedAt: farFuture, updatedAt: farFuture)

    try await h.resolutionCenter.keepLocalSkew(operationId: seed.operationId, sessionId: seed.sessionId, now: now)

    let released = try #require(try h.fetchOperation(seed.operationId))
    #expect(released.state == .pending, "released back to pending for the next drain to send")
    let session = try #require(try h.sessionStore.fetchSession(id: seed.sessionId))
    let ceiling = now.addingTimeInterval(Self.fiveMinutes)
    #expect(session.updatedAt == ceiling, "the clamped ceiling, not the raw far-future value")
  }

  @Test func takeServerSkewRefreshesThenTransactionallyDiscardsAndAppliesTheServerValue() async throws {
    let h = try await ResolutionCenterHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let farFuture = now.addingTimeInterval(Self.fiveMinutes + 1000)
    let seed = try h.seedHeldSkewSession(startedAt: farFuture, updatedAt: farFuture)
    h.http.enqueue(
      ResolutionCenterHarness.mediaProgressResponse(
        libraryItemID: DownloadCoordinatorHarness.itemID, currentTime: 42, isFinished: true))

    try await h.resolutionCenter.takeServerSkew(operationId: seed.operationId, sessionId: seed.sessionId)

    #expect(try h.fetchOperation(seed.operationId) == nil, "the held operation is removed")
    let session = try #require(try h.sessionStore.fetchSession(id: seed.sessionId))
    #expect(session.state == .closedAwaitingUpload, "retained as local history, never marked uploaded")
    let progress = try #require(
      try h.mediaProgressDAO.fetchCurrent(
        accountId: h.accountId, identity: .item(itemId: h.itemRowId)))
    #expect(progress.currentTime == 42)
    #expect(progress.isFinished == true)
  }

  @Test func takeServerSkewLeavesTheResolutionUntouchedWhenTheRefreshFails() async throws {
    let h = try await ResolutionCenterHarness()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let farFuture = now.addingTimeInterval(Self.fiveMinutes + 1000)
    let seed = try h.seedHeldSkewSession(startedAt: farFuture, updatedAt: farFuture)
    h.http.enqueue(ResolutionCenterHarness.emptyMediaProgressResponse())

    try await h.resolutionCenter.takeServerSkew(operationId: seed.operationId, sessionId: seed.sessionId)

    let stillHeld = try #require(try h.fetchOperation(seed.operationId))
    #expect(stillHeld.state == .needsResolution, "left open - no matching row to apply")
    #expect(try h.sessionStore.fetchSession(id: seed.sessionId) != nil, "never discarded on failure")
  }

  // MARK: - Dead letters: discard / refresh-metadata / re-authenticate

  @Test func discardDeletesTheDeadLetteredRowWithOneDiagnostic() async throws {
    let h = try await ResolutionCenterHarness()
    let operationId = try h.seedProgressDeadLetter(reason: "notFound")

    try await h.resolutionCenter.discardDeadLetter(operationId: operationId)

    #expect(try h.fetchOperation(operationId) == nil)
    let diagnostics = h.downloads.diagnostics.recorded.filter { $0.category == .outboxTransition }
    #expect(diagnostics.count == 1)
  }

  @Test func discardIsIdempotentAgainstAnAlreadyDiscardedRow() async throws {
    let h = try await ResolutionCenterHarness()
    let operationId = try h.seedProgressDeadLetter()
    try await h.resolutionCenter.discardDeadLetter(operationId: operationId)

    try await h.resolutionCenter.discardDeadLetter(operationId: operationId)

    #expect(
      h.downloads.diagnostics.recorded.filter { $0.category == .outboxTransition }.count == 1, "never double-recorded")
  }

  @Test func aLocalSessionUploadDeadLetterWithNoSessionIsListedAndDiscardable() async throws {
    let h = try await ResolutionCenterHarness()
    let operationId = try await h.database.writeAsync { [accountId = h.accountId] db -> Int64 in
      var operation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "session:gone",
        podcastEpisodeId: nil, operationKind: OutboxOperationKind.localSessionUpload.rawValue,
        coalescingKey: "session:gone:local-upload", payloadVersion: 1, localSequence: 1,
        payloadCurrentTime: 10, payloadAccumulatedDeltaSeconds: 10, playbackSessionId: nil)
      try operation.insert(db)
      return try #require(operation.id)
    }
    _ = try h.outbox.transition(operationId: operationId, to: .sending)
    _ = try h.outbox.transition(operationId: operationId, to: .deadLetter, deadLetterReason: "missingSession")

    let items = try await h.resolutionCenter.fetchOpenItems()
    let item = try #require(items.first { $0.id == "deadLetter:\(operationId)" })
    #expect(item.kind == .deadLetter(operationId: operationId, reason: "missingSession"))
    #expect(item.itemTitle == "Unknown item")

    try await h.resolutionCenter.discardDeadLetter(operationId: operationId)

    #expect(try h.fetchOperation(operationId) == nil)
  }

  @Test func refreshMetadataRequeuesOnlyWhenTheItemRefreshSucceeds() async throws {
    let h = try await ResolutionCenterHarness()
    let operationId = try h.seedProgressDeadLetter(reason: "notFound")
    h.downloads.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])

    try await h.resolutionCenter.refreshMetadataDeadLetter(operationId: operationId)

    #expect(try h.fetchOperation(operationId)?.state == .pending)
    #expect(h.http.requests.first?.url.host == "downloads.example.test")
  }

  @Test func refreshMetadataLeavesTheRowDeadLetteredWhenTheRefreshFails() async throws {
    let h = try await ResolutionCenterHarness()
    let operationId = try h.seedProgressDeadLetter(reason: "notFound")
    h.http.enqueue(HTTPResponse(statusCode: 404, headers: [:], body: Data()))

    try await h.resolutionCenter.refreshMetadataDeadLetter(operationId: operationId)

    #expect(try h.fetchOperation(operationId)?.state == .deadLetter)
  }

  @Test func reAuthenticateRoutesToTheAppsAuthFlow() async throws {
    let h = try await ResolutionCenterHarness()
    #expect(h.reauthenticationRequests.value == 0)

    await h.resolutionCenter.requestReAuthentication()

    #expect(h.reauthenticationRequests.value == 1)
  }

  // MARK: - Auth recovery: successful re-auth transitions pausedAuth + requeues auth dead letters

  @Test func successfulReauthenticationTransitionsPausedAuthDownloadsAndRequeuesAuthDeadLetteredRows() async throws {
    let h = try await ResolutionCenterHarness()
    h.downloads.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await h.downloads.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try h.downloads.fetchDownloads(itemId: h.itemRowId).first?.id)
    _ = try h.downloads.downloadStore.transition(downloadId: downloadId, to: .pausedAuth)

    let authDeadLetterId = try h.seedProgressDeadLetter(reason: "unauthorized")
    let otherDeadLetterId = try h.seedProgressDeadLetter(reason: "notFound")

    try await h.resolutionCenter.handleSuccessfulReauthentication()
    #expect(
      await TestSupport.waitUntil {
        (try? h.downloads.downloadStore.fetch(downloadId: downloadId)?.state) != .pausedAuth
      })

    #expect(try h.downloads.downloadStore.fetch(downloadId: downloadId)?.state != .pausedAuth)
    #expect(try h.fetchOperation(authDeadLetterId)?.state == .pending, "auth dead letter requeued")
    #expect(try h.fetchOperation(otherDeadLetterId)?.state == .deadLetter, "non-auth dead letter left alone")
  }

  @Test func handleSuccessfulReauthenticationIsIdempotentAcrossRepeatedCalls() async throws {
    let h = try await ResolutionCenterHarness()
    let authDeadLetterId = try h.seedProgressDeadLetter(reason: "unauthorized")

    try await h.resolutionCenter.handleSuccessfulReauthentication()
    try await h.resolutionCenter.handleSuccessfulReauthentication()

    #expect(try h.fetchOperation(authDeadLetterId)?.state == .pending)
  }
}
