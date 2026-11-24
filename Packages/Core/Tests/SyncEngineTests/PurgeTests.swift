import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `DownloadCoordinator`'s purge intents and low-disk queue pause. Planning, scheduling, auth
/// recovery and launch reconciliation are covered by `DownloadPlanningTests`,
/// `DownloadSchedulingTests`, `DownloadAuthRecoveryTests` and `DownloadReconciliationTests`.
@Suite struct PurgeTests {

  // MARK: - Ordering: mark deleting first, then cancel, then finish the file/row protocol

  @Test func purgeItemMarksEveryRowDeletingCancelsTheLiveTransferThenRemovesFilesAndRows() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [
        (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5),
        (index: 1, ino: 101, size: 50, mimeType: "audio/mp4", duration: 5),
      ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.allSatisfy { $0.state == .downloading }, "the cap is two - both files started")
    let firstId = try #require(rows.first?.id)
    let secondId = try #require(rows.last?.id)

    try await harness.coordinator.purgeItemDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .itemDetail)

    // Both were downloading, so both must have had a matching cancel issued.
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: firstId))))
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: secondId))))
    // The file/row removal protocol finished: no surviving rows for this item.
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  @Test func purgeItemRemovesAudioAndEbookRowsAndFilesTogether() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let audio = try harness.downloadStore.enqueue(
      accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "mixed-audio",
      orderIndex: 0, destinationRelativePath: "mixed-audio.m4b", expectedBytes: 3,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
    let ebook = try harness.downloadStore.enqueue(
      accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "mixed-ebook",
      orderIndex: 0, destinationRelativePath: "mixed-ebook.epub", expectedBytes: 4,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
    for row in [audio, ebook] {
      let downloadID = try #require(row.id)
      _ = try harness.downloadStore.transition(downloadId: downloadID, to: .downloading)
      _ = try harness.downloadStore.complete(
        downloadId: downloadID, finalSizeBytes: row.expectedBytes)
      let url = harness.downloadFileStore.absoluteURL(
        forRelativePath: row.destinationRelativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 0x42, count: Int(row.expectedBytes)).write(to: url)
    }

    let audioURL = harness.downloadFileStore.absoluteURL(
      forRelativePath: audio.destinationRelativePath)
    let ebookURL = harness.downloadFileStore.absoluteURL(
      forRelativePath: ebook.destinationRelativePath)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).map(\.mediaKind) == [.audio, .ebook])

    try await harness.coordinator.purgeItemDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .itemDetail)

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
    #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: ebookURL.path) == false)
  }

  @Test func audioOnlyPurgeLeavesTheEbookAndItsFile() async throws {
    let harness = try await DownloadCoordinatorHarness()
    var rows: [DownloadRecord] = []
    for (ino, kind) in [("pin-audio", DownloadMediaKind.audio), ("pin-ebook", .ebook)] {
      let row = try harness.downloadStore.enqueue(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: ino,
        orderIndex: 0, destinationRelativePath: "\(ino).bin", expectedBytes: 3,
        expectedMimeType: "application/octet-stream", fileDurationSeconds: 0, mediaKind: kind)
      let downloadID = try #require(row.id)
      _ = try harness.downloadStore.transition(downloadId: downloadID, to: .downloading)
      _ = try harness.downloadStore.complete(downloadId: downloadID, finalSizeBytes: 3)
      let url = harness.downloadFileStore.absoluteURL(forRelativePath: row.destinationRelativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 0x42, count: 3).write(to: url)
      rows.append(row)
    }

    try await harness.coordinator.purgeItemAudioDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .pinnedListRelease)

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).map(\.mediaKind) == [.ebook])
    let ebookURL = harness.downloadFileStore.absoluteURL(forRelativePath: rows[1].destinationRelativePath)
    #expect(FileManager.default.fileExists(atPath: ebookURL.path))
  }

  @Test func aPinnedListReleaseStepsAsideWhileTheItemIsTransferring() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).first?.state == .downloading)

    try await harness.coordinator.purgeItemAudioDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .pinnedListRelease)

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).count == 1)
  }

  @Test func purgeNeverCancelsATransferThatWasNotActuallyDownloading() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.networkConditions.isConstrainedOrCellular = true
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    // Held for Wi-Fi, so never actually downloading.
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .pending)

    try await harness.coordinator.purgeItem(itemId: harness.itemRowId, source: .itemDetail)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))) == false)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func accountRemovalPurgeCancelsAUserPausedTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    try await harness.coordinator.pauseDownload(downloadId: downloadId)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)

    try await harness.coordinator.purgeAllDownloads(source: .accountRemoval)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))))
  }

  @Test func accountRemovalPurgeCancelsAWiFiHeldTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.networkConditions.isConstrainedOrCellular = true
    await harness.coordinator.schedule()
    let held = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    #expect(held.state == .pending)
    #expect(held.holdReason == .waitingForWiFi)

    try await harness.coordinator.purgeAllDownloads(source: .accountRemoval)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))))
  }

  @Test func itemPurgeCancelsTheSuspendedTaskOfAUserPausedTransferAndClearsBookkeeping() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    try await harness.coordinator.pauseDownload(downloadId: downloadId)
    #expect(await harness.coordinator.suspendedTaskDownloadIds.contains(downloadId))

    try await harness.coordinator.purgeItem(itemId: harness.itemRowId, source: .itemDetail)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))))
    #expect(await harness.coordinator.suspendedTaskDownloadIds.contains(downloadId) == false)
  }

  @Test func itemPurgeCancelsTheSuspendedTaskOfAWiFiHeldTransferAndClearsBookkeeping() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    harness.networkConditions.simulateChange(isConstrainedOrCellular: true)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.holdReason == .waitingForWiFi
    }
    // The durable hold lands before the in-memory ownership record, so wait for the latter too.
    await TestSupport.waitUntil {
      await harness.coordinator.liveTaskOwnedDownloadIds.contains(downloadId)
    }
    #expect(await harness.coordinator.liveTaskOwnedDownloadIds.contains(downloadId))

    try await harness.coordinator.purgeItem(itemId: harness.itemRowId, source: .itemDetail)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))))
    #expect(await harness.coordinator.liveTaskOwnedDownloadIds.contains(downloadId) == false)
  }

  /// Download, pause, Remove Download on the show page. The suspended URLSession task must be
  /// cancelled with its row: a leaked one keeps holding a per-host connection, and later downloads
  /// from the same host never start.
  @Test func episodeRemovalCancelsTheSuspendedTaskOfAPausedRSSRow() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)
    let feedID = try #require(
      try harness.rssDownloadStore.transferDetails(downloadId: downloadID)?.feed.id)
    await harness.coordinator.schedule()
    try await harness.coordinator.pauseEpisodeDownload(
      itemID: "rss:\(feedID)", episodeID: "rss-episode")
    #expect(await harness.coordinator.rssSuspendedTaskDownloadIds.contains(downloadID))

    try await harness.coordinator.purgeEpisodeDownload(
      itemID: "rss:\(feedID)", episodeID: "rss-episode", source: .podcastEpisodeRemoval)

    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID) == nil)
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .rss(rowID: downloadID))))
    #expect(await harness.coordinator.rssSuspendedTaskDownloadIds.contains(downloadID) == false)
  }

  @Test func deleteDownloadCancelsTheSuspendedTaskOfAUserPausedTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    try await harness.coordinator.pauseDownload(downloadId: downloadId)
    #expect(await harness.coordinator.suspendedTaskDownloadIds.contains(downloadId))

    try await harness.coordinator.deleteDownload(downloadId: downloadId)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))))
    #expect(await harness.coordinator.suspendedTaskDownloadIds.contains(downloadId) == false)
  }

  @Test func storagePurgeCancelsTheSuspendedTaskOfAPausedRSSRow() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)
    let feedID = try #require(
      try harness.rssDownloadStore.transferDetails(downloadId: downloadID)?.feed.id)
    await harness.coordinator.schedule()
    try await harness.coordinator.pauseEpisodeDownload(
      itemID: "rss:\(feedID)", episodeID: "rss-episode")
    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .paused)
    #expect(await harness.coordinator.rssSuspendedTaskDownloadIds.contains(downloadID))

    try await harness.coordinator.purgeAllDownloads(source: .storage)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .rss(rowID: downloadID))))
    #expect(await harness.coordinator.rssSuspendedTaskDownloadIds.contains(downloadID) == false)
  }

  @Test func accountRemovalPurgeCancelsAPausedAuthTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    _ = try harness.downloadStore.transition(downloadId: downloadId, to: .pausedAuth)

    try await harness.coordinator.purgeAllDownloads(source: .accountRemoval)

    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))))
  }

  @Test func purgingAnItemWithNoDownloadRowsIsANoOp() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await harness.coordinator.purgeItem(itemId: harness.itemRowId, source: .itemDetail)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  // MARK: - The automatic finished-download delete never destroys work in flight
  /// A purge marks every row `.deleting` with no state filter, so one arriving from the
  /// finished-download auto-delete mid-transfer would cancel the live transfer and delete its
  /// file. A user-initiated purge must still do that; an automatic one must not, because a
  /// download in flight is the user asking for the file right now.
  @Test func finishedAutoDeleteNeverPurgesAnItemWithWorkStillInFlight() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)

    try await harness.coordinator.purgeItem(
      itemId: harness.itemRowId, source: .finishedDownloadAutoDelete)

    #expect(
      harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))) == false,
      "an automatic purge must not cancel a transfer the user just started")
    #expect(
      try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading,
      "the row survives untouched - not deleted, not left stranded in .deleting")
  }

  /// The other half of the same rule: once nothing is in flight, the automatic delete still does
  /// its job. Without this, "skip when busy" could be implemented as "never delete".
  @Test func finishedAutoDeleteStillPurgesAnItemWhoseTransfersHaveAllCompleted() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    try harness.downloadStore.complete(downloadId: downloadId, finalSizeBytes: 50)

    try await harness.coordinator.purgeItem(
      itemId: harness.itemRowId, source: .finishedDownloadAutoDelete)

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  /// A partially-downloaded multi-file book is one unit of user intent: the completed file must
  /// not be swept out from under a sibling that is still transferring.
  @Test func finishedAutoDeleteSkipsTheWholeItemWhenOnlyOneFileIsStillTransferring() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [
        (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5),
        (index: 1, ino: 101, size: 50, mimeType: "audio/mp4", duration: 5),
      ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    let completedId = try #require(rows.first?.id)
    try harness.downloadStore.complete(downloadId: completedId, finalSizeBytes: 50)

    try await harness.coordinator.purgeItem(
      itemId: harness.itemRowId, source: .finishedDownloadAutoDelete)

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).count == rows.count)
  }

  // MARK: - Progress/session data remains intact

  @Test func purgeNeverTouchesProgressOrSessionRows() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)

    let progressId = try await harness.database.writeAsync { db -> Int64 in
      var progress = MediaProgressRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, currentTime: 42, isFinished: false,
        localSequence: 1, origin: .local, originKey: "client-uuid")
      try progress.insert(db)
      return progress.id!
    }

    try await harness.coordinator.purgeItem(itemId: harness.itemRowId, source: .itemDetail)

    let survivingProgress = try harness.database.read { db in
      try MediaProgressRecord.fetchOne(db, key: progressId)
    }
    #expect(survivingProgress?.currentTime == 42, "purge only ever touches `download` rows")
  }

  // MARK: - Re-downloadable only once the deleting rows are actually gone

  @Test func itemIsNotRedownloadableWhileDeletingRowsStillSurviveButIsOnceTheyAreGone() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    // Simulate a crash frozen right after the mark: the row is durably `.deleting` but the
    // file-delete/row-delete protocol has not run yet.
    _ = try harness.downloadStore.markDeleting(itemId: harness.itemRowId)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .deleting)

    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    #expect(
      try harness.fetchDownloads(itemId: harness.itemRowId).count == 1,
      "still exactly the one surviving `.deleting` row - no new plan while it exists")

    // The deleting row goes away (the removal protocol, or the integrity sweep resuming it).
    try harness.downloadFileStore.delete(downloadId: downloadId)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)

    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 200, size: 60, mimeType: "audio/mp4", duration: 6)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    #expect(
      try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty == false,
      "re-downloadable now that no deleting row survives")
  }

  // MARK: - Purge-all leaves no orphan in either direction

  @Test func purgeAllRemovesEveryRowAndEveryFileAcrossEveryItem() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let itemAId = try await harness.seedItem(serverItemId: "purge-all-a")
    let itemBId = try await harness.seedItem(serverItemId: "purge-all-b")
    harness.enqueueBookItemDetail(
      itemID: "purge-all-a", audioFiles: [(index: 0, ino: 400, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: "purge-all-a")
    harness.enqueueBookItemDetail(
      itemID: "purge-all-b", audioFiles: [(index: 0, ino: 401, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: "purge-all-b")

    let firstId = try #require(try harness.fetchDownloads(itemId: itemAId).first?.id)
    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: firstId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)))
    #expect(
      await TestSupport.waitUntil {
        (try? harness.downloadStore.fetch(downloadId: firstId)?.state) == .completed
      })
    let completedURL = harness.downloadFileStore.absoluteURL(
      forRelativePath: try #require(try harness.downloadStore.fetch(downloadId: firstId)?.destinationRelativePath))
    #expect(FileManager.default.fileExists(atPath: completedURL.path))

    try await harness.coordinator.purgeAllDownloads(source: .storage)

    #expect(try harness.fetchDownloads(itemId: itemAId).isEmpty)
    #expect(try harness.fetchDownloads(itemId: itemBId).isEmpty)
    #expect(try harness.downloadStore.fetchAll().isEmpty, "no orphan row survives")
    #expect(FileManager.default.fileExists(atPath: completedURL.path) == false, "no orphan file survives")
  }

  @Test func accountRemovalPurgeLeavesDeviceOwnedRSSRowAndFileUntouched() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try await harness.seedRSSDownload(bytes: 50)
    let id = try #require(row.id)
    _ = try harness.rssDownloadStore.transition(downloadId: id, to: .downloading)
    _ = try harness.rssDownloadStore.complete(downloadId: id, actualBytes: 50)
    let url = harness.rssFileStore.absoluteURL(forRelativePath: row.relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 50).write(to: url)

    try await harness.coordinator.purgeAllDownloads(source: .accountRemoval)

    #expect(try harness.rssDownloadStore.fetch(downloadId: id)?.state == .completed)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test func storagePurgeAllRemovesABSAndRSSRowsAndFiles() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 501, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let absID = try #require(try harness.downloadStore.fetchAll().first?.id)
    try harness.downloadStore.complete(downloadId: absID, finalSizeBytes: 50)
    let absRow = try #require(try harness.downloadStore.fetch(downloadId: absID))
    let absURL = harness.downloadFileStore.absoluteURL(forRelativePath: absRow.destinationRelativePath)
    try FileManager.default.createDirectory(at: absURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 50).write(to: absURL)

    let rssRow = try await harness.seedRSSDownload(feedID: 42, episodeKey: "rss-storage", bytes: 50)
    let rssID = try #require(rssRow.id)
    _ = try harness.rssDownloadStore.transition(downloadId: rssID, to: .downloading)
    _ = try harness.rssDownloadStore.complete(downloadId: rssID, actualBytes: 50)
    let rssURL = harness.rssFileStore.absoluteURL(forRelativePath: rssRow.relativePath)
    try FileManager.default.createDirectory(at: rssURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 50).write(to: rssURL)

    try await harness.coordinator.purgeAllDownloads(source: .storage)

    #expect(try harness.downloadStore.fetch(downloadId: absID) == nil)
    #expect(try harness.rssDownloadStore.fetch(downloadId: rssID) == nil)
    #expect(FileManager.default.fileExists(atPath: absURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: rssURL.path) == false)
  }

  @Test func storagePurgeAllMarksPendingRSSBeforeScheduling() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try await harness.seedRSSDownload(bytes: 50)

    try await harness.coordinator.purgeAllDownloads(source: .storage)

    #expect(try harness.rssDownloadStore.fetch(downloadId: try #require(row.id)) == nil)
    #expect(
      harness.backgroundTransferring.calls.contains {
        if case .enqueue(let identity, _, _, _) = $0 { return identity == .rss(rowID: row.id!) }
        return false
      } == false,
      "Delete All must not briefly enqueue an RSS row before its source table is marked")
  }

  @Test func reclaimTombstonedDownloadsRemovesRSSRowsAndFiles() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try await harness.seedRSSDownload(bytes: 50)
    let id = try #require(row.id)
    _ = try harness.rssDownloadStore.transition(downloadId: id, to: .downloading)
    _ = try harness.rssDownloadStore.complete(downloadId: id, actualBytes: 50)
    let url = harness.rssFileStore.absoluteURL(forRelativePath: row.relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 50).write(to: url)
    try await harness.database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET refreshGeneration = 2")
      try db.execute(
        sql: "UPDATE rssEpisode SET retained = 1, lastSeenGeneration = 1 WHERE id = ?",
        arguments: [row.episodeId])
    }

    try await harness.coordinator.purgeTombstonedEpisodeDownloads(source: .storage)

    #expect(try harness.rssDownloadStore.fetch(downloadId: id) == nil)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  // MARK: - Crash recovery: any boundary after the mark resumes via the durable `.deleting` state

  @Test func aCrashRightAfterTheMarkWithTheFileStillPresentResumesViaTheIntegritySweep() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)))
    #expect(
      await TestSupport.waitUntil {
        (try? harness.downloadStore.fetch(downloadId: downloadId)?.state) == .completed
      })
    let destinationURL = harness.downloadFileStore.absoluteURL(
      forRelativePath: try #require(
        try harness.downloadStore.fetch(downloadId: downloadId)?.destinationRelativePath))
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))

    // Crash frozen immediately after the transactional mark, before cancellation or any file I/O.
    _ = try harness.downloadStore.markDeleting(itemId: harness.itemRowId)

    let sweep = DownloadIntegritySweep(rootURL: harness.downloadFileStore.rootURL, downloadStore: harness.downloadStore)
    let result = try sweep.run()

    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func aCrashAfterTheFileIsAlreadyRemovedButBeforeTheRowIsResumesViaTheIntegritySweep() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)))
    #expect(
      await TestSupport.waitUntil {
        (try? harness.downloadStore.fetch(downloadId: downloadId)?.state) == .completed
      })
    let destinationURL = harness.downloadFileStore.absoluteURL(
      forRelativePath: try #require(
        try harness.downloadStore.fetch(downloadId: downloadId)?.destinationRelativePath))

    _ = try harness.downloadStore.markDeleting(itemId: harness.itemRowId)
    // Crash frozen after the file itself was removed but before the row-delete boundary.
    try FileManager.default.removeItem(at: destinationURL)

    let sweep = DownloadIntegritySweep(rootURL: harness.downloadFileStore.rootURL, downloadStore: harness.downloadStore)
    let result = try sweep.run()

    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(try harness.downloadStore.fetch(downloadId: downloadId) == nil)
  }

  // MARK: - Low-disk failure pauses the queue rather than dead-lettering (injected seam)

  @Test func insufficientFreeSpaceHoldsThePendingRowAndPausesTheQueueRatherThanFailingIt() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.freeSpaceReporting.availableCapacityBytesValue = 10
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 500, mimeType: "audio/mp4", duration: 5)])

    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)

    let row = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    #expect(row.state == .pending, "never attempted, and never dead-lettered as a failure")
    #expect(row.errorCategory == nil)
    #expect(await harness.coordinator.isQueuePausedForLowDisk())
    #expect(harness.backgroundTransferring.calls.isEmpty)
  }

  @Test func aSecondItemNeverStartsEitherWhileTheQueueIsPausedForLowDisk() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.freeSpaceReporting.availableCapacityBytesValue = 10
    let itemBId = try await harness.seedItem(serverItemId: "low-disk-b")
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 500, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)

    harness.enqueueBookItemDetail(
      itemID: "low-disk-b", audioFiles: [(index: 0, ino: 200, size: 500, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: "low-disk-b")

    #expect(try harness.fetchDownloads(itemId: itemBId).first?.state == .pending)
    #expect(harness.backgroundTransferring.calls.isEmpty)
  }

  // MARK: - Low-disk admission for RSS rows uses the same gate as ABS rows

  @Test func anRSSRowIsNotAdmittedWhenCapacityIsBelowItsDeclaredSizeReserve() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let declaredBytes: Int64 = 100 * 1024 * 1024
    let row = try await harness.seedRSSDownload(bytes: declaredBytes)
    let downloadID = try #require(row.id)
    let admission = RSSFileStore.admissionBytes(expectedBytes: declaredBytes)
    harness.freeSpaceReporting.availableCapacityBytesValue = admission - 1

    await harness.coordinator.schedule()

    let held = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(held.state == .pending, "never attempted, and never dead-lettered as a failure")
    #expect(held.errorCode == nil)
    #expect(await harness.coordinator.isQueuePausedForLowDisk())
    #expect(harness.backgroundTransferring.calls.isEmpty)
  }

  /// An enclosure with no declared length reserves the whole transfer cap plus the unknown-size
  /// safety margin, not just whatever the feed happened to say.
  @Test func anRSSRowWithUnknownSizeIsNotAdmittedBelowTheFullUnknownSizeReserve() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload(bytes: nil)
    let downloadID = try #require(row.id)
    let admission = RSSFileStore.admissionBytes(expectedBytes: nil)
    #expect(admission == RSSFileStore.sizeCapBytes + RSSFileStore.unknownSizeReserveBytes)
    harness.freeSpaceReporting.availableCapacityBytesValue = admission - 1

    await harness.coordinator.schedule()

    let held = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(held.state == .pending, "never attempted, and never dead-lettered as a failure")
    #expect(held.errorCode == nil)
    #expect(await harness.coordinator.isQueuePausedForLowDisk())
    #expect(harness.backgroundTransferring.calls.isEmpty)
  }

  @Test func recoveringFreeSpaceResumesTheHeldTransferAndClearsThePause() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.freeSpaceReporting.availableCapacityBytesValue = 10
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 500, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    #expect(await harness.coordinator.isQueuePausedForLowDisk())

    harness.freeSpaceReporting.availableCapacityBytesValue = .max
    await harness.coordinator.schedule()

    let row = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    #expect(row.state == .downloading)
    #expect(await harness.coordinator.isQueuePausedForLowDisk() == false)
  }

  @Test func aRealDiskFullWriteFailurePausesTheQueueAndLeavesTheRowOrdinarilyRetryableNeverDeadLettered()
    async throws
  {
    let outOfSpaceMover = FakeDownloadFileMoving(error: FakeDownloadFileMoving.outOfSpace)
    let harness = try await DownloadCoordinatorHarness(fileMover: outOfSpaceMover)
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)))
    #expect(
      await TestSupport.waitUntil {
        (try? harness.downloadStore.fetch(downloadId: downloadId)?.state) == .failed
      })

    let failed = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed, "ordinarily retryable - never stuck")
    #expect(failed.errorCategory == .lowDisk)
    #expect(await harness.coordinator.isQueuePausedForLowDisk())

    // Retrying is still possible: the row itself was never dead-lettered.
    try await harness.coordinator.resumeDownload(downloadId: downloadId)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)
  }
}
