import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `DownloadCoordinator.reconcileAfterLaunch`: the join between the DB-level
/// `.downloading` -> `.interrupted` bulk reconciliation (performed by `DownloadStore.init`, not
/// this coordinator) and the adapter's live-task snapshot.
@Suite struct DownloadReconciliationTests {

  @Test func reconcileAfterLaunchRemovesOrphanFiles() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let orphanURL = harness.downloadFileStore.rootURL.appendingPathComponent("orphan.m4b")
    try Data([0x01]).write(to: orphanURL)
    #expect(FileManager.default.fileExists(atPath: orphanURL.path))

    await harness.coordinator.reconcileAfterLaunch()

    #expect(FileManager.default.fileExists(atPath: orphanURL.path) == false)
  }

  @Test func downloadingRowsWithoutALiveTaskBecomeInterruptedThenRequeue() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)

    // Simulate a relaunch: constructing a fresh `DownloadStore` performs the
    // `.downloading` -> `.interrupted` bulk reconciliation.
    let freshStore = try DownloadStore(database: harness.database)
    #expect(try freshStore.fetch(downloadId: downloadId)?.state == .interrupted)

    // No live task reported for this download (the fake's default `currentTasks()` is empty).
    let freshCoordinator = harness.makeCoordinator(downloadStore: freshStore)
    await freshCoordinator.reconcileAfterLaunch()

    #expect(
      try freshStore.fetch(downloadId: downloadId)?.state == .downloading,
      "requeued to pending, then immediately restarted by the ordinary scheduler since a slot is free")
  }

  @Test func aLiveTaskWithoutARowIsCancelled() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.backgroundTransferring.setCurrentTasks([BackgroundTransferSnapshot(identity: .abs(rowID: 999_999))])

    await harness.coordinator.reconcileAfterLaunch()

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: 999_999))))
  }

  @Test func absAndRSSRowsWithTheSameNumericIdReattachByTaggedIdentity() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 4, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let absID = try #require(try harness.downloadStore.fetchAll().first?.id)
    #expect(absID == 1)

    let feedID = try await RSSFeedStore(database: harness.database).subscribe(
      feedURL: URL(string: "https://example.com/reconcile.xml")!, title: "RSS", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: harness.database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", enclosureURL: URL(string: "https://example.com/e.mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: 4)
      ])
    let episodeID = try #require(
      try await harness.database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode LIMIT 1")
      })
    let rssStore = try RSSDownloadStore(database: harness.database)
    let rssRow = try await rssStore.claimOrCreateAsync(episodeId: episodeID)
    #expect(rssRow.id == absID)
    _ = try await rssStore.transitionAsync(downloadId: rssRow.id!, to: .downloading)
    let relaunchedRSSStore = try RSSDownloadStore(database: harness.database)
    let rssFiles = try RSSFileStore(
      rootURL: harness.downloadFileStore.rootURL,
      fileAttributes: InertFileAttributes(), downloadStore: relaunchedRSSStore)

    harness.backgroundTransferring.setCurrentTasks([
      BackgroundTransferSnapshot(identity: .abs(rowID: absID)),
      BackgroundTransferSnapshot(identity: .rss(rowID: try #require(rssRow.id))),
    ])
    let freshABSStore = try DownloadStore(database: harness.database)
    let fresh = DownloadCoordinator.make(
      client: harness.client, database: harness.database, downloadStore: freshABSStore,
      downloadFileStore: harness.downloadFileStore,
      backgroundTransferring: harness.backgroundTransferring,
      downloadPreferences: harness.downloadPreferences, networkConditions: harness.networkConditions,
      diagnostics: harness.diagnostics, freeSpaceReporting: harness.freeSpaceReporting,
      rssDownloadStore: relaunchedRSSStore, rssFileStore: rssFiles)

    await fresh.reconcileAfterLaunch()

    #expect(try freshABSStore.fetch(downloadId: absID)?.state == .downloading)
    #expect(try relaunchedRSSStore.fetch(downloadId: absID)?.state == .downloading)
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: absID))) == false)
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .rss(rowID: absID))) == false)
  }

  @Test func orphanRSSTaskIsCancelledWithoutCancellingAnABSTaskWithTheSameId() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.backgroundTransferring.setCurrentTasks([
      BackgroundTransferSnapshot(identity: .rss(rowID: 1))
    ])
    let rssStore = try RSSDownloadStore(database: harness.database)
    let rssFiles = try RSSFileStore(
      rootURL: harness.downloadFileStore.rootURL,
      fileAttributes: InertFileAttributes(), downloadStore: rssStore)
    let fresh = DownloadCoordinator.make(
      client: harness.client, database: harness.database, downloadStore: harness.downloadStore,
      downloadFileStore: harness.downloadFileStore,
      backgroundTransferring: harness.backgroundTransferring,
      downloadPreferences: harness.downloadPreferences, networkConditions: harness.networkConditions,
      diagnostics: harness.diagnostics, freeSpaceReporting: harness.freeSpaceReporting,
      rssDownloadStore: rssStore, rssFileStore: rssFiles)

    await fresh.reconcileAfterLaunch()

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .rss(rowID: 1))))
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: 1))) == false)
  }

  @Test func aMatchingLiveTaskIsReattachedWithoutEnqueuingADuplicate() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    let freshStore = try DownloadStore(database: harness.database)
    harness.backgroundTransferring.setCurrentTasks([
      BackgroundTransferSnapshot(identity: .abs(rowID: downloadId))
    ])
    let callsBeforeReconciliation = harness.backgroundTransferring.calls
    let freshCoordinator = harness.makeCoordinator(downloadStore: freshStore)

    await freshCoordinator.reconcileAfterLaunch()

    #expect(try freshStore.fetch(downloadId: downloadId)?.state == .downloading)
    #expect(harness.backgroundTransferring.calls == callsBeforeReconciliation)
  }

  @Test func forceQuitShapedCancellationsReconcileInterruptedRowsAndOrphanTasksTheSameWay() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5),
      (index: 1, ino: 101, size: 50, mimeType: "audio/mp4", duration: 5),
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.allSatisfy { $0.state == .downloading }, "both files fit within the two-slot cap")

    let freshStore = try DownloadStore(database: harness.database)
    // Force-quit-shaped: the adapter reports no tasks for either row, plus one orphaned task with
    // no row at all. Everything reconciles through the same pass.
    harness.backgroundTransferring.setCurrentTasks([BackgroundTransferSnapshot(identity: .abs(rowID: 424_242))])
    let freshCoordinator = harness.makeCoordinator(downloadStore: freshStore)

    await freshCoordinator.reconcileAfterLaunch()

    for row in rows {
      let refreshed = try freshStore.fetch(downloadId: try #require(row.id))
      #expect(refreshed?.state == .downloading, "every interrupted row is requeued and restarted")
    }
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: 424_242))))
  }

  /// Device stall: a force-quit three files into a five-file book left the remaining two
  /// `.pending` for the life of the process, with an entirely open gate published on every pass.
  ///
  /// `DownloadStore.init` has demoted the killed rows to `.interrupted` by the time the background
  /// session redelivers their cancellations, and `reconcileAfterLaunch` requeues them to
  /// `.pending`. `.pending -> .failed` is not a legal edge, so the durable half of
  /// `handleTransferEvent(.failed:)` is rejected and swallowed by its `try?`, while the in-memory
  /// `eventFailedDownloadIds` marker is inserted regardless. The row stays `.pending` with a
  /// marker only `performResume` retires, and `performSchedule` subtracts it forever.
  ///
  /// The slot cap is load-bearing: with a free slot the requeued row restarts immediately and the
  /// redelivered `.failed` lands on a legal `.downloading -> .failed` edge, so a single-row
  /// reproduction ends `.failed`, not the `.pending` the device reported.
  @Test func requeuedRowsStillStartAfterTheirForceQuitCancellationsAreRedelivered() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: (0..<5).map {
        (index: $0, ino: 100 + $0, size: 4, mimeType: "audio/mp4", duration: 5)
      })
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let ids = try harness.fetchDownloads(itemId: harness.itemRowId).map { try #require($0.id) }
    #expect(ids.count == 5)

    // Relaunch: a fresh `DownloadStore` is what performs the `.downloading` -> `.interrupted` bulk
    // demotion of the two rows the force-quit killed mid-transfer.
    let freshStore = try DownloadStore(database: harness.database)
    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .interrupted)
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .interrupted)
    let fresh = harness.makeCoordinator(downloadStore: freshStore)

    // The device's ordering: the new process runs an ordinary schedule pass before the launch join,
    // so both slots go to rows that had never started and the requeued pair has nowhere to go.
    await fresh.schedule()
    await fresh.reconcileAfterLaunch()
    #expect(try freshStore.fetch(downloadId: ids[2])?.state == .downloading)
    #expect(try freshStore.fetch(downloadId: ids[3])?.state == .downloading)
    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .pending)
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .pending)

    // `WHIRRDL transfer id=31/32 event=finish result=failed`: a force-quit's cancellations reach
    // the next process as ordinary transport failures, after the rows have been requeued.
    await fresh.handleTransferEvent(.failed(identity: .abs(rowID: ids[0]), errorDomain: nil, errorCode: nil))
    await fresh.handleTransferEvent(.failed(identity: .abs(rowID: ids[1]), errorDomain: nil, errorCode: nil))
    #expect(
      try freshStore.fetch(downloadId: ids[0])?.state == .pending,
      "the device's own discrepancy - the redelivered failure never reaches the row")
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .pending)

    let records = ScheduleTraceRecorder()
    await fresh.setDeviceTraceSink { record in records.append(record) }

    // Free both slots. Nothing is left holding the queue back.
    for id in [ids[2], ids[3]] {
      await fresh.handleTransferEvent(
        .finished(
          identity: .abs(rowID: id), temporaryFileURL: try harness.makeTempFile(bytes: 4),
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 4)))
    }

    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .downloading)
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .downloading)
    #expect(
      records.skippedCounts.allSatisfy { $0 == 0 },
      "no pending row is subtracted by a stale marker")
  }

  /// The sibling ordering, where the failure lands early enough that the launch join's snapshot
  /// already reads `.failed`. The row is left `.failed`, visibly with the ordinary retry
  /// affordance, rather than silently requeued: a genuine transport failure arriving seconds
  /// before launch reconciliation must not become an invisible extra attempt. Either way a
  /// `.pending` row carrying a marker must not happen, which is what `skipped=` pins.
  @Test func aFailureLandingBeforeTheLaunchSnapshotLeavesTheRowFailedRatherThanSubtracted()
    async throws
  {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: (0..<5).map {
        (index: $0, ino: 100 + $0, size: 4, mimeType: "audio/mp4", duration: 5)
      })
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let ids = try harness.fetchDownloads(itemId: harness.itemRowId).map { try #require($0.id) }
    #expect(ids.count == 5)

    let freshStore = try DownloadStore(database: harness.database)
    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .interrupted)
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .interrupted)
    let fresh = harness.makeCoordinator(downloadStore: freshStore)
    let records = ScheduleTraceRecorder()
    await fresh.setDeviceTraceSink { record in records.append(record) }

    // The ordinary pass spends both slots before the launch join, matching the device ordering.
    await fresh.schedule()
    #expect(try freshStore.fetch(downloadId: ids[2])?.state == .downloading)
    #expect(try freshStore.fetch(downloadId: ids[3])?.state == .downloading)

    // This cancellation lands while the row is still `.interrupted`, so the durable failure and
    // its in-memory marker are both legitimate. The launch join's snapshot, taken afterwards,
    // sees the `.failed` state rather than a stale `.interrupted` one.
    await fresh.handleTransferEvent(.failed(identity: .abs(rowID: ids[0]), errorDomain: nil, errorCode: nil))
    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .failed)

    await fresh.reconcileAfterLaunch()
    #expect(
      try freshStore.fetch(downloadId: ids[0])?.state == .failed,
      "a row the launch join saw as already failed stays failed, not silently retried")

    // The second cancellation arrives after reconciliation, as in the already-covered ordering.
    await fresh.handleTransferEvent(.failed(identity: .abs(rowID: ids[1]), errorDomain: nil, errorCode: nil))
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .pending)

    for id in [ids[2], ids[3]] {
      await fresh.handleTransferEvent(
        .finished(
          identity: .abs(rowID: id), temporaryFileURL: try harness.makeTempFile(bytes: 4),
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 4)))
    }

    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .failed)
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .downloading)
    #expect(
      records.skippedCounts.allSatisfy { $0 == 0 },
      "the `.failed` row is not pending, so nothing is subtracted from any pass")
  }

  /// The device's ordering: `reconcileAfterLaunch` snapshots `.interrupted` rows, then the
  /// cancellation lands while it awaits the live-task snapshot, and the stale snapshot requeues
  /// the row after its durable state is already `.failed`.
  @Test func requeuedRowsStillStartWhenTheFailureLandsBetweenTheLaunchSnapshotAndItsRequeue() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: (0..<5).map {
        (index: $0, ino: 100 + $0, size: 4, mimeType: "audio/mp4", duration: 5)
      })
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let ids = try harness.fetchDownloads(itemId: harness.itemRowId).map { try #require($0.id) }
    #expect(ids.count == 5)

    let freshStore = try DownloadStore(database: harness.database)
    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .interrupted)
    #expect(try freshStore.fetch(downloadId: ids[1])?.state == .interrupted)
    let fresh = harness.makeCoordinator(downloadStore: freshStore)
    let records = ScheduleTraceRecorder()
    await fresh.setDeviceTraceSink { record in records.append(record) }

    // The ordinary pass spends both slots before the launch join, matching the device ordering.
    await fresh.schedule()
    #expect(try freshStore.fetch(downloadId: ids[2])?.state == .downloading)
    #expect(try freshStore.fetch(downloadId: ids[3])?.state == .downloading)

    // The device's failure lands after the launch snapshot but before its row reaches the
    // requeue loop: `currentTasks()` is the coordinator's suspension seam for that ordering.
    await harness.backgroundTransferring.setCurrentTasksHook {
      Task {
        await fresh.handleTransferEvent(
          .failed(identity: .abs(rowID: ids[0]), errorDomain: nil, errorCode: nil))
      }
      #expect(
        await TestSupport.waitUntil {
          (try? freshStore.fetch(downloadId: ids[0]))?.state == .failed
        })
    }

    await fresh.reconcileAfterLaunch()
    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .pending)

    for id in [ids[2], ids[3]] {
      await fresh.handleTransferEvent(
        .finished(
          identity: .abs(rowID: id), temporaryFileURL: try harness.makeTempFile(bytes: 4),
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 4)))
    }

    #expect(try freshStore.fetch(downloadId: ids[0])?.state == .downloading)
    #expect(records.skippedCounts.allSatisfy { $0 == 0 })
  }

  /// The RSS half of the ordering above: the stale launch snapshot requeues a row whose redelivered
  /// failure already marked it, and the marker must go with the `.failed` state it shadowed.
  @Test func requeuedRSSRowsStillStartWhenTheFailureLandsBetweenTheLaunchSnapshotAndItsRequeue()
    async throws
  {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let seed = try await harness.seedRSSDownload(feedID: 74, episodeKey: "requeued-rss")
    let id = try #require(seed.id)
    _ = try await harness.rssDownloadStore.transitionAsync(downloadId: id, to: .downloading)

    let freshRSSStore = try RSSDownloadStore(database: harness.database)
    #expect(try freshRSSStore.fetch(downloadId: id)?.state == .interrupted)
    let fresh = harness.makeUnsubscribedCoordinator(
      downloadStore: try DownloadStore(database: harness.database), rssDownloadStore: freshRSSStore)

    await harness.backgroundTransferring.setCurrentTasksHook {
      Task {
        await fresh.handleTransferEvent(.failed(identity: .rss(rowID: id), errorDomain: nil, errorCode: nil))
      }
      #expect(
        await TestSupport.waitUntil {
          (try? freshRSSStore.fetch(downloadId: id))?.state == .failed
        })
    }

    await fresh.reconcileAfterLaunch()
    await fresh.schedule()

    #expect(
      try freshRSSStore.fetch(downloadId: id)?.state == .downloading,
      "the requeued row is started, not subtracted by its stale failure marker")
  }

  @Test func aNewlyScheduledRSSTaskIsNotCancelledByAStaleLaunchSnapshot() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let seed = try await harness.seedRSSDownload(feedID: 73, episodeKey: "late-rss")
    let seedID = try #require(seed.id)
    let details = try #require(try harness.rssDownloadStore.transferDetails(downloadId: seedID))
    let feedID = try #require(details.feed.id)
    try await harness.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM rssDownload WHERE id = ?", arguments: [seedID])
    }

    await harness.backgroundTransferring.setCurrentTasksHook {
      Task {
        try? await harness.coordinator.requestEpisodeDownload(
          itemID: "rss:\(feedID)", episodeID: "late-rss")
      }
      await TestSupport.awaitQuiescence(
        "the request racing the launch task snapshot",
        of: { String(describing: harness.backgroundTransferring.calls) })
      let identities = harness.backgroundTransferring.calls.compactMap { call -> TransferIdentity? in
        guard case .enqueue(let identity, _, _, _) = call else { return nil }
        return identity
      }
      harness.backgroundTransferring.setCurrentTasks(
        identities.map(BackgroundTransferSnapshot.init(identity:)))
    }

    await harness.coordinator.reconcileAfterLaunch()
    #expect(
      await TestSupport.waitUntil {
        (try? harness.rssDownloadStore.fetchAll().first?.state) == .downloading
      })
    let row = try #require(try harness.rssDownloadStore.fetchAll().first)
    let rowID = try #require(row.id)
    #expect(
      harness.backgroundTransferring.calls.contains(.cancel(identity: .rss(rowID: rowID))) == false)
  }
}

/// `TestSupport.Locked` is not `public`, and `DownloadDeviceTraceTests`' file-private copy is not
/// reachable from here. Only the `skipped=` field off the schedule lines is needed.
private final class ScheduleTraceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int] = []

  func append(_ record: DownloadDeviceTrace.Record) {
    guard case .schedule(let schedule) = record else { return }
    lock.lock()
    defer { lock.unlock() }
    storage.append(schedule.skipped)
  }

  var skippedCounts: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
