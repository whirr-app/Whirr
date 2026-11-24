import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// A failed automatic download is retried a bounded number of times, by the ordinary `schedule()`
/// pass, once its deadline passes. Every case drives the harness clock instead of sleeping, and
/// delivers transfer events itself.
@Suite struct AutomaticDownloadRetryTests {
  private static let timedOut = NSURLErrorTimedOut

  // MARK: - ABS

  @Test func aTimedOutAutomaticDownloadIsRequeuedOnceItsDeadlinePassesAndNotBefore() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()
    let failedAt = harness.clock.value
    await fail(harness, .abs(rowID: id))

    let failed = try #require(try harness.downloadStore.fetch(downloadId: id))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .transport, "the failure copy is unchanged")
    #expect(failed.autoRetryNotBefore == failedAt.addingTimeInterval(600))

    advance(harness, by: 599)
    await harness.coordinator.schedule()
    #expect(try harness.downloadStore.fetch(downloadId: id)?.state == .failed)

    advance(harness, by: 1)
    await harness.coordinator.schedule()
    let retried = try #require(try harness.downloadStore.fetch(downloadId: id))
    // `.downloading`, not `.pending`: the requeue clears the failure marker, so the row starts
    // rather than sitting skipped.
    #expect(retried.state == .downloading)
    #expect(retried.autoRetryCount == 1)
    #expect(enqueuedIdentities(harness) == [.abs(rowID: id), .abs(rowID: id)])
  }

  @Test func manualRowsAndPermanentFailuresAreNeverRequeued() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let manual = try await insertABS(harness, origin: .manual, ino: "100")
    let redirected = try await insertABS(harness, origin: .automatic, ino: "200")
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: manual))
    await fail(harness, .abs(rowID: redirected), domain: "whirr.adapter.redirectDenied", code: NSURLErrorCancelled)

    advance(harness, by: 24 * 60 * 60)
    await harness.coordinator.schedule()

    for id in [manual, redirected] {
      let row = try #require(try harness.downloadStore.fetch(downloadId: id))
      #expect(row.state == .failed)
      #expect(row.autoRetryNotBefore == nil)
      #expect(row.autoRetryCount == 0)
    }
  }

  @Test func aDueRetryWaitsOutCellularAndLowPowerWithoutSpendingAnAttempt() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: id))
    let deadline = try #require(try harness.downloadStore.fetch(downloadId: id)?.autoRetryNotBefore)
    advance(harness, by: 600)

    harness.networkConditions.isConstrainedOrCellular = true
    await harness.coordinator.schedule()
    try expectStillWaiting(harness, id, deadline: deadline)
    harness.networkConditions.isConstrainedOrCellular = false

    harness.networkConditions.isLowPowerMode = true
    await harness.coordinator.schedule()
    try expectStillWaiting(harness, id, deadline: deadline)
    harness.networkConditions.isLowPowerMode = false

    await harness.coordinator.schedule()
    #expect(try harness.downloadStore.fetch(downloadId: id)?.autoRetryCount == 1)
  }

  @Test func aDueRetryWaitsOutTheLowDiskPause() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: id))
    let deadline = try #require(try harness.downloadStore.fetch(downloadId: id)?.autoRetryNotBefore)

    // A pending row that cannot fit pauses the queue before the retry is due.
    harness.freeSpaceReporting.availableCapacityBytesValue = 0
    _ = try await insertABS(harness, origin: .manual, ino: "200")
    await harness.coordinator.schedule()
    #expect(await harness.coordinator.isQueuePausedForLowDisk())

    advance(harness, by: 600)
    await harness.coordinator.schedule()
    try expectStillWaiting(harness, id, deadline: deadline)

    harness.freeSpaceReporting.availableCapacityBytesValue = .max
    await harness.coordinator.schedule()  // starts the manual row, which clears the pause
    await harness.coordinator.schedule()
    #expect(try harness.downloadStore.fetch(downloadId: id)?.autoRetryCount == 1)
  }

  @Test func aRowPromotedToManualWhileFailedIsNotRequeued() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: id))
    _ = try await harness.downloadStore.promoteToManualAsync(downloadId: id)

    advance(harness, by: 600)
    await harness.coordinator.schedule()

    #expect(try harness.downloadStore.fetch(downloadId: id)?.state == .failed)
  }

  @Test func aFailedRenewalSchedulesARetry() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()
    harness.http.enqueueFailure(URLError(.notConnectedToInternet))

    await harness.coordinator.handleTransferEvent(.authChallenge(identity: .abs(rowID: id)))

    let row = try #require(try harness.downloadStore.fetch(downloadId: id))
    #expect(row.state == .failed)
    #expect(row.autoRetryNotBefore == harness.clock.value.addingTimeInterval(600))
  }

  @Test(arguments: [(503, true), (429, true), (408, true), (404, false), (403, false)])
  func anHTTPAnswerIsRetriedOnlyWhenTheServerWasUnavailable(status: Int, retried: Bool) async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: id), temporaryFileURL: try harness.makeTempFile(bytes: 10),
        response: BackgroundTransferResponse(httpStatusCode: status, mimeType: "audio/mp4", contentLength: 10)))

    let row = try #require(try harness.downloadStore.fetch(downloadId: id))
    #expect(row.state == .failed)
    #expect(row.errorCategory == .validation)
    #expect((row.autoRetryNotBefore != nil) == retried)
  }

  @Test func atMostTwoRowsAreRequeuedPerPass() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let ids = [
      try await insertABS(harness, origin: .automatic, ino: "100"),
      try await insertABS(harness, origin: .automatic, ino: "200"),
      try await insertABS(harness, origin: .automatic, ino: "300"),
    ]
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: ids[0]))  // its trailing pass starts the third row
    await fail(harness, .abs(rowID: ids[1]))
    await fail(harness, .abs(rowID: ids[2]))
    #expect(try harness.downloadStore.fetchAll().allSatisfy { $0.state == .failed })

    advance(harness, by: 600)
    await harness.coordinator.schedule()

    let rows = try harness.downloadStore.fetchAll()
    #expect(rows.filter { $0.state == .downloading }.count == 2)
    let waiting = try #require(rows.first { $0.state == .failed })
    #expect(waiting.autoRetryNotBefore != nil, "the third keeps its deadline for a later pass")
    #expect(waiting.autoRetryCount == 0)
  }

  // MARK: - The multi-pass bound

  @Test func fourFailuresSpendExactlyThreeRetriesThenTryAgainStartsOver() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let retries = Locked<[Int]>([])
    await harness.coordinator.setDeviceTraceSink { record in
      if case .transfer(let transfer) = record, case .retry(let attempt) = transfer.event {
        retries.withValue { $0.append(attempt) }
      }
    }
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()

    for (pass, wait) in [600.0, 1_800, 7_200].enumerated() {
      let failedAt = harness.clock.value
      await fail(harness, .abs(rowID: id))
      let row = try #require(try harness.downloadStore.fetch(downloadId: id))
      #expect(row.autoRetryNotBefore == failedAt.addingTimeInterval(wait), "failure \(pass + 1)")
      advance(harness, by: wait)
      await harness.coordinator.schedule()
      #expect(try harness.downloadStore.fetch(downloadId: id)?.state == .downloading)
    }

    await fail(harness, .abs(rowID: id))
    let exhausted = try #require(try harness.downloadStore.fetch(downloadId: id))
    #expect(exhausted.autoRetryCount == 3)
    #expect(exhausted.autoRetryNotBefore == nil)
    advance(harness, by: 24 * 60 * 60)
    await harness.coordinator.schedule()
    #expect(try harness.downloadStore.fetch(downloadId: id)?.state == .failed)
    #expect(retries.value == [1, 2, 3])
    #expect(enqueuedIdentities(harness).count == 4)

    try await harness.coordinator.resumeDownload(downloadId: id)
    let restarted = try #require(try harness.downloadStore.fetch(downloadId: id))
    #expect(restarted.state == .downloading)
    #expect(restarted.autoRetryCount == 0)
    let failedAt = harness.clock.value
    await fail(harness, .abs(rowID: id))
    #expect(try harness.downloadStore.fetch(downloadId: id)?.autoRetryNotBefore == failedAt.addingTimeInterval(600))
  }

  @Test func aRetryThatSucceedsResetsTheCountForTheNextDownload() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: id))
    advance(harness, by: 600)
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: id))
    advance(harness, by: 1_800)
    await harness.coordinator.schedule()

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: id), temporaryFileURL: try harness.makeTempFile(bytes: 10),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 10)))
    let completed = try #require(try harness.downloadStore.fetch(downloadId: id))
    #expect(completed.state == .completed)
    #expect(completed.autoRetryCount == 0)

    // The integrity sweep's demotion is the one way a completed row fails again.
    _ = try await harness.downloadStore.transitionAsync(downloadId: id, to: .failed, errorCategory: .storage)
    _ = try await harness.downloadStore.transitionAsync(downloadId: id, to: .pending)
    await harness.coordinator.schedule()
    let failedAt = harness.clock.value
    await fail(harness, .abs(rowID: id))
    #expect(try harness.downloadStore.fetch(downloadId: id)?.autoRetryNotBefore == failedAt.addingTimeInterval(600))
  }

  @Test func aFreshCoordinatorHonoursThePersistedCountAndDeadline() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await insertABS(harness, origin: .automatic, ino: "100")
    await harness.coordinator.schedule()
    await fail(harness, .abs(rowID: id))
    advance(harness, by: 600)
    await harness.coordinator.schedule()
    let secondFailure = harness.clock.value
    await fail(harness, .abs(rowID: id))

    // An overnight wake: new stores and a new coordinator over the same database.
    let freshStore = try DownloadStore(database: harness.database)
    let fresh = harness.makeUnsubscribedCoordinator(
      downloadStore: freshStore, rssDownloadStore: try RSSDownloadStore(database: harness.database))
    advance(harness, by: 1_799)
    await fresh.reconcileAfterLaunch()
    #expect(try freshStore.fetch(downloadId: id)?.state == .failed)
    #expect(try freshStore.fetch(downloadId: id)?.autoRetryNotBefore == secondFailure.addingTimeInterval(1_800))

    advance(harness, by: 1)
    await fresh.reconcileAfterLaunch()
    let row = try #require(try freshStore.fetch(downloadId: id))
    #expect(row.state == .downloading)
    #expect(row.autoRetryCount == 2, "the cap does not reset across coordinator incarnations")
  }

  // MARK: - RSS

  @Test func aTimedOutAutomaticRSSDownloadIsRequeuedAndStarts() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await seedRSS(harness, origin: .automatic, feedID: 201)
    await harness.coordinator.schedule()
    let failedAt = harness.clock.value
    await fail(harness, .rss(rowID: id))
    #expect(try harness.rssDownloadStore.fetch(downloadId: id)?.autoRetryNotBefore == failedAt.addingTimeInterval(600))

    advance(harness, by: 599)
    await harness.coordinator.schedule()
    #expect(try harness.rssDownloadStore.fetch(downloadId: id)?.state == .failed)

    advance(harness, by: 1)
    await harness.coordinator.schedule()
    let row = try #require(try harness.rssDownloadStore.fetch(downloadId: id))
    #expect(row.state == .downloading, "the RSS failure marker went with the requeue")
    #expect(row.autoRetryCount == 1)
  }

  @Test func manualAndPromotedRSSRowsAreNotRequeued() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let manual = try await seedRSS(harness, origin: .manual, feedID: 202)
    let promoted = try await seedRSS(harness, origin: .automatic, feedID: 203)
    await harness.coordinator.schedule()
    await fail(harness, .rss(rowID: manual))
    await fail(harness, .rss(rowID: promoted))
    _ = try await harness.rssDownloadStore.promoteToManualAsync(downloadId: promoted)

    advance(harness, by: 600)
    await harness.coordinator.schedule()

    #expect(try harness.rssDownloadStore.fetch(downloadId: manual)?.state == .failed)
    #expect(try harness.rssDownloadStore.fetch(downloadId: promoted)?.state == .failed)
  }

  @Test func rssTryAgainResetsTheCount() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let id = try await seedRSS(harness, origin: .automatic, feedID: 204)
    await harness.coordinator.schedule()
    await fail(harness, .rss(rowID: id))
    advance(harness, by: 600)
    await harness.coordinator.schedule()
    await fail(harness, .rss(rowID: id))
    #expect(try harness.rssDownloadStore.fetch(downloadId: id)?.autoRetryCount == 1)

    let details = try #require(try harness.rssDownloadStore.transferDetails(downloadId: id))
    try await harness.coordinator.resumeEpisodeDownload(
      itemID: "rss:\(try #require(details.feed.id))", episodeID: details.episode.identityKey)

    let row = try #require(try harness.rssDownloadStore.fetch(downloadId: id))
    #expect(row.autoRetryCount == 0)
    #expect(row.autoRetryNotBefore == nil)
  }

  // MARK: - Helpers

  private func insertABS(
    _ harness: DownloadCoordinatorHarness, origin: DownloadOrigin, ino: String
  ) async throws -> Int64 {
    try await harness.database.writeAsync { db in
      var row = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: ino,
        orderIndex: Int(ino) ?? 0, destinationRelativePath: "retry-\(ino).m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1, origin: origin)
      try row.insert(db)
      return try #require(row.id)
    }
  }

  private func seedRSS(
    _ harness: DownloadCoordinatorHarness, origin: DownloadOrigin, feedID: Int64
  ) async throws -> Int64 {
    let row = try await harness.seedRSSDownload(feedID: feedID, episodeKey: "retry-\(feedID)", bytes: 10)
    let id = try #require(row.id)
    try await harness.database.writeAsync { db in
      try db.execute(sql: "UPDATE rssDownload SET origin = ? WHERE id = ?", arguments: [origin.rawValue, id])
    }
    return id
  }

  private func fail(
    _ harness: DownloadCoordinatorHarness, _ identity: TransferIdentity,
    domain: String = NSURLErrorDomain, code: Int = AutomaticDownloadRetryTests.timedOut
  ) async {
    await harness.coordinator.handleTransferEvent(.failed(identity: identity, errorDomain: domain, errorCode: code))
  }

  private func advance(_ harness: DownloadCoordinatorHarness, by seconds: TimeInterval) {
    harness.clock.withValue { $0 = $0.addingTimeInterval(seconds) }
  }

  private func expectStillWaiting(
    _ harness: DownloadCoordinatorHarness, _ id: Int64, deadline: Date,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let row = try #require(try harness.downloadStore.fetch(downloadId: id), sourceLocation: sourceLocation)
    #expect(row.state == .failed, sourceLocation: sourceLocation)
    #expect(row.autoRetryCount == 0, sourceLocation: sourceLocation)
    #expect(row.autoRetryNotBefore == deadline, sourceLocation: sourceLocation)
  }

  private func enqueuedIdentities(_ harness: DownloadCoordinatorHarness) -> [TransferIdentity] {
    harness.backgroundTransferring.calls.compactMap { call -> TransferIdentity? in
      guard case .enqueue(let identity, _, _, _) = call else { return nil }
      return identity
    }
  }
}
