import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The downloads/removal crash matrix: deterministic evidence for the downloads, offline and
/// removal boundaries, alongside `SessionRecoveryJourneyTests`. Every genuine crash cut discards an
/// on-disk `AppDatabase` (and, for download cuts, keeps the same downloads-root directory) and
/// opens a fresh one over the same file, the idiom of `DownloadCrashRecoveryTests`,
/// `AccountRemovalCrashRecoveryTests` and `SessionRecoveryJourneyTests`. Cuts an existing suite
/// already covers get a thin named test here.
@Suite struct DownloadCrashMatrixTests {

  // MARK: - 1. Temp-move vs completion transaction (download finish)

  @Test
  func fileMoveCommitsButTheCompletionTransactionNeverDoesLeavesAResumableRowAndTheStaleFileIsOverwrittenOnRetry()
    async throws
  {
    let env = try await DownloadMatrixEnvironment()
    let downloadId: Int64
    let relativePath: String
    do {
      let inc = try env.openIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, serverFileIno: "ino-move-1", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: nil, orderIndex: 0,
          serverFileIno: "ino-move-1", mimeType: "audio/mp4"),
        expectedBytes: 1000, expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      downloadId = try #require(record.id)
      relativePath = record.destinationRelativePath
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)

      // Replicates `DownloadFileStore.completeTransfer`'s two steps by hand so the "crash" lands
      // between them: the temp file is moved into its final destination...
      let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data(repeating: 0x9, count: 1000).write(to: temp)
      let destination = inc.downloadFileStore.absoluteURL(forRelativePath: relativePath)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: temp, to: destination)
      // ...but the process dies here. `DownloadStore.complete` (the separate DB transaction that
      // would mark the row `completed`) never runs.
    }

    let reopened = try env.openIncarnation()
    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadId))
    #expect(recovered.state == .interrupted, "launch reconciliation infers the crash, never trusts `downloading`")
    let destinationURL = reopened.downloadFileStore.absoluteURL(forRelativePath: relativePath)
    #expect(
      FileManager.default.fileExists(atPath: destinationURL.path),
      "the moved-but-uncommitted file survives the crash on disk")

    // Retryable: a fresh temp file completes the transfer, overwriting the orphan the crashed
    // attempt left at the same destination (`completeTransfer`'s stale-file guard).
    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadId, to: .pending)
    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
    let retryTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x1, count: 1000).write(to: retryTemp)
    let completed = try reopened.downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: retryTemp,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 1000))
    #expect(completed.state == .completed)
    #expect(
      try Data(contentsOf: destinationURL) == Data(repeating: 0x1, count: 1000),
      "the stale orphan is fully overwritten, never left alongside or mixed with the retry's bytes")
  }

  @Test
  func ebookFileMoveBeforeCompletionCommitRelaunchesAndRetriesWithAnEpubDestination() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadID: Int64
    let relativePath: String
    do {
      let inc = try env.openIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, serverFileIno: "ebook-crash-ino", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: nil, orderIndex: 0,
          serverFileIno: "ebook-crash-ino", mimeType: "application/epub+zip"),
        expectedBytes: 1000, expectedMimeType: "application/epub+zip", fileDurationSeconds: 0,
        mediaKind: .ebook)
      downloadID = try #require(record.id)
      relativePath = record.destinationRelativePath
      #expect(relativePath.hasSuffix(".epub"))
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadID, to: .downloading)

      let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data(repeating: 0x9, count: 1000).write(to: temp)
      let destination = inc.downloadFileStore.absoluteURL(forRelativePath: relativePath)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: temp, to: destination)
      // Crash after the adapter's temp move, before the completion transaction commits.
    }

    let reopened = try env.openIncarnation()
    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadID))
    #expect(recovered.state == .interrupted)
    #expect(recovered.mediaKind == .ebook)
    #expect(recovered.destinationRelativePath.hasSuffix(".epub"))
    #expect(
      FileManager.default.fileExists(
        atPath: reopened.downloadFileStore.absoluteURL(forRelativePath: relativePath).path))

    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadID, to: .pending)
    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadID, to: .downloading)
    let retryTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x1, count: 1000).write(to: retryTemp)
    let completed = try reopened.downloadFileStore.completeTransfer(
      downloadId: downloadID, temporaryFileURL: retryTemp,
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "application/epub+zip", contentLength: 1000))
    #expect(completed.state == .completed)
    #expect(completed.mediaKind == .ebook)
    #expect(completed.destinationRelativePath.hasSuffix(".epub"))
  }

  @Test
  func episodeFileMoveWithoutCompletionTransactionRelaunchesWithItsIdentityAndNestedPathIntact() async throws {
    let env = try await DownloadMatrixEnvironment()
    let episodeRowId = try await env.seedPodcastEpisode(episodeID: "episode-move")
    let downloadId: Int64
    let relativePath: String
    do {
      let inc = try env.openIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.podcastItemRowId, podcastEpisodeId: episodeRowId,
        serverFileIno: "ino-episode-move", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.podcastItemRowId,
          podcastEpisodeId: episodeRowId, orderIndex: 0,
          serverFileIno: "ino-episode-move", mimeType: "audio/mpeg"),
        expectedBytes: 100, expectedMimeType: "audio/mpeg", fileDurationSeconds: 60)
      downloadId = try #require(record.id)
      relativePath = record.destinationRelativePath
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
      let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data(repeating: 0x9, count: 100).write(to: temp)
      let destination = inc.downloadFileStore.absoluteURL(forRelativePath: relativePath)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: temp, to: destination)
    }

    let reopened = try env.openIncarnation()
    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadId))
    #expect(recovered.state == .interrupted)
    #expect(recovered.podcastEpisodeId == episodeRowId)
    #expect(recovered.destinationRelativePath == relativePath)
    #expect(relativePath.contains("/ep-\(episodeRowId)/"))

    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadId, to: .pending)
    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
    let retryTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x1, count: 100).write(to: retryTemp)
    let completed = try reopened.downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: retryTemp,
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 100))
    #expect(completed.state == .completed)
    #expect(completed.podcastEpisodeId == episodeRowId)
    #expect(
      try Data(
        contentsOf: reopened.downloadFileStore.absoluteURL(
          forRelativePath: relativePath)) == Data(repeating: 0x1, count: 100))
  }

  /// The other ordering of the same two-step protocol: a crash with only the DB transaction side
  /// run (the file move never started) reconciles through the same `.downloading -> .interrupted`
  /// path that `DownloadCrashRecoveryTests.aRowCrashedMidDownloadingIsResumableAfterReconciliation`
  /// covers. Both orderings converge to the same safe, resumable state.
  @Test
  func aCrashBeforeTheFileMoveEverStartedConvergesToTheIdenticalInterruptedStateAsAfterIt() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadId: Int64
    do {
      let inc = try env.openIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, serverFileIno: "ino-move-2", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: nil, orderIndex: 0,
          serverFileIno: "ino-move-2", mimeType: "audio/mp4"),
        expectedBytes: 1000, expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      downloadId = try #require(record.id)
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
      // Crash: neither the file move nor the completion transaction has run yet.
    }

    let reopened = try env.openIncarnation()
    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadId))
    #expect(recovered.state == .interrupted)
    let destinationURL = reopened.downloadFileStore.absoluteURL(
      forRelativePath: try #require(try reopened.downloadStore.fetch(downloadId: downloadId)).destinationRelativePath)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false, "no file exists at all yet")
  }

  // MARK: - 2. Every `deleting` mark / file-delete / row-delete boundary, one item and purge-all

  @Test
  func oneItemCrashAfterMarkedDeletingBeforeTheFileIsEverRemovedFinishesDeletionOnRelaunch() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadId: Int64
    let destinationURL: URL
    do {
      let inc = try env.openIncarnation()
      downloadId = try await env.seedCompletedDownload(inc, ino: "ino-del-1")
      destinationURL = inc.downloadFileStore.absoluteURL(
        forRelativePath: try #require(try inc.downloadStore.fetch(downloadId: downloadId)).destinationRelativePath)
      #expect(FileManager.default.fileExists(atPath: destinationURL.path))
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .deleting)
      // Crash: neither the file nor the row is removed.
    }

    let reopened = try env.openIncarnation()
    #expect(try reopened.downloadStore.fetch(downloadId: downloadId)?.state == .deleting, "durable across the crash")

    let sweep = DownloadIntegritySweep(rootURL: env.downloadsRoot, downloadStore: reopened.downloadStore)
    let result = try sweep.run()
    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(try reopened.downloadStore.fetch(downloadId: downloadId) == nil)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)

    // A second pass is idempotent: nothing left to finish twice.
    let again = try DownloadIntegritySweep(rootURL: env.downloadsRoot, downloadStore: reopened.downloadStore).run()
    #expect(again.finishedDeletionDownloadIds.isEmpty)
  }

  @Test
  func oneItemCrashAfterTheFileIsRemovedButBeforeTheRowIsFinalizesTheRowOnRelaunch() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadId: Int64
    do {
      let inc = try env.openIncarnation()
      downloadId = try await env.seedCompletedDownload(inc, ino: "ino-del-2")
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .deleting)
      let destinationURL = inc.downloadFileStore.absoluteURL(
        forRelativePath: try #require(try inc.downloadStore.fetch(downloadId: downloadId)).destinationRelativePath)
      try FileManager.default.removeItem(at: destinationURL)
      // Crash: `DownloadStore.finalizeDeletion` (the row-removal half) never runs.
    }

    let reopened = try env.openIncarnation()
    #expect(try reopened.downloadStore.fetch(downloadId: downloadId)?.state == .deleting)

    let result = try DownloadIntegritySweep(rootURL: env.downloadsRoot, downloadStore: reopened.downloadStore).run()
    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(
      try reopened.downloadStore.fetch(downloadId: downloadId) == nil,
      "idempotent - the already-gone file is simply not there to remove twice")
  }

  @Test
  func episodeDeletionCrashCutsFinishOnlyTheTargetAndPreserveItsSibling() async throws {
    for removeTargetFileBeforeCrash in [false, true] {
      let env = try await DownloadMatrixEnvironment()
      let episodeA = try await env.seedPodcastEpisode(episodeID: "episode-a")
      let episodeB = try await env.seedPodcastEpisode(episodeID: "episode-b")
      let targetId: Int64
      let siblingId: Int64
      let siblingURL: URL
      do {
        let inc = try env.openIncarnation()
        targetId = try await env.seedCompletedDownload(
          inc, ino: "ino-episode-a", podcastEpisodeId: episodeA)
        siblingId = try await env.seedCompletedDownload(
          inc, ino: "ino-episode-b", podcastEpisodeId: episodeB)
        _ = try await inc.downloadStore.transitionAsync(downloadId: targetId, to: .deleting)
        let target = try #require(try inc.downloadStore.fetch(downloadId: targetId))
        siblingURL = inc.downloadFileStore.absoluteURL(
          forRelativePath: try #require(
            try inc.downloadStore.fetch(downloadId: siblingId)
          ).destinationRelativePath)
        if removeTargetFileBeforeCrash {
          try FileManager.default.removeItem(
            at: inc.downloadFileStore.absoluteURL(
              forRelativePath: target.destinationRelativePath))
        }
      }

      let reopened = try env.openIncarnation()
      let result = try DownloadIntegritySweep(
        rootURL: env.downloadsRoot, downloadStore: reopened.downloadStore
      ).run()
      #expect(result.finishedDeletionDownloadIds == [targetId])
      #expect(try reopened.downloadStore.fetch(downloadId: targetId) == nil)
      #expect(try reopened.downloadStore.fetch(downloadId: siblingId)?.state == .completed)
      #expect(FileManager.default.fileExists(atPath: siblingURL.path))
    }
  }

  @Test
  func purgeAllCrashMidwayFinishesEveryStillMarkedRowExactlyOnceOnRelaunch() async throws {
    let env = try await DownloadMatrixEnvironment()
    let firstId: Int64
    let secondId: Int64
    let secondDestination: URL
    do {
      let inc = try env.openIncarnation()
      firstId = try await env.seedCompletedDownload(inc, ino: "ino-purge-1")
      secondId = try await env.seedCompletedDownload(inc, ino: "ino-purge-2")
      secondDestination = inc.downloadFileStore.absoluteURL(
        forRelativePath: try #require(try inc.downloadStore.fetch(downloadId: secondId)).destinationRelativePath)

      let marked = try inc.downloadStore.markAllDeleting()
      #expect(Set(marked.compactMap(\.id)) == Set([firstId, secondId]))
      // The first row's file+row protocol fully finishes before the crash...
      try inc.downloadFileStore.delete(downloadId: firstId)
      // ...the second is only marked `.deleting`. The crash lands here, mid purge-all.
    }

    let reopened = try env.openIncarnation()
    #expect(
      try reopened.downloadStore.fetch(downloadId: firstId) == nil,
      "already finished before the crash - untouched by recovery")
    #expect(try reopened.downloadStore.fetch(downloadId: secondId)?.state == .deleting, "durable across the crash")

    let result = try DownloadIntegritySweep(rootURL: env.downloadsRoot, downloadStore: reopened.downloadStore).run()
    #expect(
      result.finishedDeletionDownloadIds == [secondId],
      "only the still-pending row is finished - the already-finished first row is never revisited")
    #expect(try reopened.downloadStore.fetch(downloadId: secondId) == nil)
    #expect(FileManager.default.fileExists(atPath: secondDestination.path) == false)

    // Every row counted exactly once: a second sweep finds nothing left.
    let again = try DownloadIntegritySweep(rootURL: env.downloadsRoot, downloadStore: reopened.downloadStore).run()
    #expect(again.finishedDeletionDownloadIds.isEmpty)
  }

  // MARK: - 3. Force-quit mid-transfer

  /// The DB-only half is covered by `DownloadCrashRecoveryTests`
  /// (`aRowCrashedMidDownloadingIsResumableAfterReconciliation`,
  /// `crashDuringDownloadingWithConcurrentUnrelatedRowsRecoversOnlyTheStrandedRow`), and the
  /// adapter-join half by `DownloadReconciliationTests
  /// .forceQuitShapedCancellationsReconcileInterruptedRowsAndOrphanTasksTheSameWay`. This proves it
  /// across an on-disk relaunch: a fresh `AppDatabase` over the same file plus a new
  /// `DownloadCoordinator`/adapter graph.
  @Test
  func forceQuitMidTransferReconcilesToPendingAndRestartsAcrossARealOnDiskRelaunch() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadId: Int64
    do {
      let inc = try env.openIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, serverFileIno: "ino-fq", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: nil, orderIndex: 0,
          serverFileIno: "ino-fq", mimeType: "audio/mp4"),
        expectedBytes: 500, expectedMimeType: "audio/mp4", fileDurationSeconds: 30)
      downloadId = try #require(record.id)
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
      // Force-quit here: no background task survives, and the process runs nothing else.
    }

    let coordinatorIncarnation = try env.openCoordinatorIncarnation()
    // `DownloadStore.init` already reconciled `.downloading -> .interrupted` before this
    // coordinator was constructed. The adapter reports no live tasks, its force-quit default.
    #expect(try coordinatorIncarnation.downloadStore.fetch(downloadId: downloadId)?.state == .interrupted)

    await coordinatorIncarnation.coordinator.reconcileAfterLaunch()
    var fetchError: (any Error)?
    await TestSupport.waitUntil {
      do {
        return try coordinatorIncarnation.downloadStore.fetch(downloadId: downloadId)?.state
          == .downloading
      } catch {
        fetchError = error
        return true
      }
    }
    if let fetchError { throw fetchError }

    let recovered = try #require(try coordinatorIncarnation.downloadStore.fetch(downloadId: downloadId))
    #expect(recovered.state == .downloading, "requeued to pending, then immediately restarted since a slot is free")
    #expect(
      coordinatorIncarnation.backgroundTransferring.calls.contains(
        .enqueue(
          identity: .abs(rowID: downloadId), itemID: DownloadMatrixEnvironment.itemID, fileID: "ino-fq",
          destinationURL: coordinatorIncarnation.downloadFileStore.absoluteURL(
            forRelativePath: recovered.destinationRelativePath))))
  }

  @Test
  func liveEpisodeTaskReattachesAcrossRelaunchWithoutLosingIdentityOrEnqueuingADuplicate() async throws {
    let env = try await DownloadMatrixEnvironment()
    let episodeRowId = try await env.seedPodcastEpisode(episodeID: "episode-live")
    let downloadId: Int64
    let relativePath: String
    do {
      let inc = try env.openIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.podcastItemRowId, podcastEpisodeId: episodeRowId,
        serverFileIno: "ino-episode-live", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.podcastItemRowId,
          podcastEpisodeId: episodeRowId, orderIndex: 0,
          serverFileIno: "ino-episode-live", mimeType: "audio/mpeg"),
        expectedBytes: 500, expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
      downloadId = try #require(record.id)
      relativePath = record.destinationRelativePath
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
    }

    let reopened = try env.openCoordinatorIncarnation(
      currentTasks: [BackgroundTransferSnapshot(identity: .abs(rowID: downloadId))])
    #expect(try reopened.downloadStore.fetch(downloadId: downloadId)?.state == .interrupted)

    await reopened.coordinator.reconcileAfterLaunch()

    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadId))
    #expect(recovered.state == .downloading)
    #expect(recovered.podcastEpisodeId == episodeRowId)
    #expect(recovered.destinationRelativePath == relativePath)
    #expect(reopened.backgroundTransferring.calls.isEmpty)
  }

  @Test
  func liveEbookTaskReattachesAcrossRelaunchWithoutMintingOrEnqueuingADuplicate() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadID: Int64
    let relativePath: String
    do {
      let inc = try env.openIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, serverFileIno: "ebook-live-ino", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: nil, orderIndex: 0,
          serverFileIno: "ebook-live-ino", mimeType: "application/epub+zip"),
        expectedBytes: 500, expectedMimeType: "application/epub+zip", fileDurationSeconds: 0,
        mediaKind: .ebook)
      downloadID = try #require(record.id)
      relativePath = record.destinationRelativePath
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadID, to: .downloading)
    }

    let reopened = try env.openCoordinatorIncarnation(
      currentTasks: [BackgroundTransferSnapshot(identity: .abs(rowID: downloadID))])
    #expect(try reopened.downloadStore.fetch(downloadId: downloadID)?.state == .interrupted)

    await reopened.coordinator.reconcileAfterLaunch()

    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadID))
    #expect(recovered.state == .downloading)
    #expect(recovered.mediaKind == .ebook)
    #expect(recovered.destinationRelativePath == relativePath)
    #expect(reopened.backgroundTransferring.calls.isEmpty)
  }

  // MARK: - 4. Failed-transfer restart

  /// There is no byte-level resume: the system's `NSURLSessionDownloadTaskResumeData` is discarded
  /// at the adapter, nothing is persisted, and an interrupted transfer starts again. The per-file
  /// endpoint supports Range/resume server-side, but the client does not use it. What must survive
  /// a crash is the row: its `.failed` state and transport category, so the user still sees why it
  /// stopped and a resume re-enqueues an ordinary fresh transfer.
  @Test
  func aFailedTransferSurvivesACrashAndResumesAsAnOrdinaryFreshTransfer() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadId: Int64
    do {
      let inc = try env.openCoordinatorIncarnation()
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, serverFileIno: "ino-resume", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: nil, orderIndex: 0,
          serverFileIno: "ino-resume", mimeType: "audio/mp4"),
        expectedBytes: 500, expectedMimeType: "audio/mp4", fileDurationSeconds: 30)
      downloadId = try #require(record.id)
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)

      inc.backgroundTransferring.pushEvent(
        .failed(identity: .abs(rowID: downloadId), errorDomain: nil, errorCode: nil))
      var fetchError: (any Error)?
      await TestSupport.waitUntil {
        do {
          return try inc.downloadStore.fetch(downloadId: downloadId)?.state == .failed
        } catch {
          fetchError = error
          return true
        }
      }
      if let fetchError { throw fetchError }

      let failed = try #require(try inc.downloadStore.fetch(downloadId: downloadId))
      #expect(failed.state == .failed)
      #expect(failed.errorCategory == .transport)
      // Crash right here.
    }

    let reopened = try env.openCoordinatorIncarnation()
    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadId))
    #expect(
      recovered.state == .failed, "a plain `.failed` row is never itself reconciled by launch - only `.downloading` is")
    #expect(recovered.errorCategory == .transport, "why it stopped survives the crash durably")

    try await reopened.coordinator.resumeDownload(downloadId: downloadId)
    var fetchError: (any Error)?
    await TestSupport.waitUntil {
      do {
        return try reopened.downloadStore.fetch(downloadId: downloadId)?.state == .downloading
      } catch {
        fetchError = error
        return true
      }
    }
    if let fetchError { throw fetchError }

    let resumed = try #require(try reopened.downloadStore.fetch(downloadId: downloadId))
    #expect(
      resumed.state == .downloading,
      "resume always re-enters through `.pending`, then restarts through the ordinary scheduler")
    #expect(
      resumed.errorCategory == nil,
      "the ordinary transition path clears the failure category once the row leaves `.failed`")
    // The row flips `.downloading` and the fake records `enqueue` from concurrent coordinator
    // work. Under parallel-suite load the test can wake between the two, so wait rather than
    // assert the call immediately.
    await TestSupport.waitUntil {
      reopened.backgroundTransferring.calls.contains {
        if case .enqueue(let identity, _, _, _) = $0,
          case .abs(let id) = identity
        {
          return id == downloadId
        }
        return false
      }
    }
  }

  // MARK: - 5. Offline tick vs close freeze

  @Test
  func offlineTickCommitsButTheSessionIsNeverClosedSurvivesACrashAndContinuesRecordingOnRelaunch() async throws {
    let env = try await PlaybackMatrixEnvironment()
    let sessionId: Int64
    do {
      let inc = try env.openIncarnation()
      let started = try inc.sessionStore.startSession(
        accountId: env.accountId, clientSessionId: UUID().uuidString, itemId: env.itemRowId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
      sessionId = try #require(started.id)
      _ = try inc.sessionStore.recordLocalTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 42, isFinished: false, deltaSecondsSinceLastTick: 7, localSequence: 1,
          originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      // Crash: never closed. Offline ticks never touch the network (rule 10), so nothing else is
      // in flight to lose.
    }

    let reopened = try env.openIncarnation()
    let recovered = try #require(try reopened.sessionStore.fetchSession(id: sessionId))
    #expect(recovered.state == .active, "still recording - a tick alone never freezes/closes anything")
    #expect(recovered.globalPosition == 42)
    #expect(recovered.listenedDeltaSeconds == 7, "the accrued delta survives, since nothing has drained yet")
    #expect(try reopened.outbox.fetchQueuedLocalSessionUploads(accountId: env.accountId, limit: 10).isEmpty)

    // Resumable: another tick continues accumulating on the same row, never a second session.
    let continued = try reopened.sessionStore.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 50, isFinished: false, deltaSecondsSinceLastTick: 8, localSequence: 2,
        originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_020)))
    #expect(continued.globalPosition == 50)
    #expect(continued.listenedDeltaSeconds == 15)
  }

  @Test
  func offlineCloseFreezeCommitsButIsNeverDrainedSurvivesACrashAndDrainsExactlyOnceOnRelaunch() async throws {
    let env = try await PlaybackMatrixEnvironment()
    let sessionId: Int64
    var clientSessionId = ""
    do {
      let inc = try env.openIncarnation()
      let started = try inc.sessionStore.startSession(
        accountId: env.accountId, clientSessionId: UUID().uuidString, itemId: env.itemRowId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
      sessionId = try #require(started.id)
      clientSessionId = started.clientSessionId
      _ = try inc.sessionStore.recordLocalTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 55, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
          originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      _ = try inc.sessionStore.closeLocalSession(
        sessionId: sessionId,
        tick: PlaybackSessionClose(
          globalPosition: 60, deltaSecondsSinceLastSend: 5, localSequence: 2,
          now: Date(timeIntervalSince1970: 1_700_000_012)))
      // Crash: the freeze transaction committed (`.closedAwaitingUpload` + one queued
      // `localSessionUpload` row), but nothing has been sent.
    }

    let midway = try env.openIncarnation()
    let frozen = try #require(try midway.sessionStore.fetchSession(id: sessionId))
    #expect(frozen.state == .closedAwaitingUpload)
    let uploadRows = try await midway.database.readAsync { db in
      try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionId).fetchAll(db)
    }
    #expect(uploadRows.count == 1, "exactly one upload row - durable, never lost or duplicated by the crash")

    let http = FakeHTTPClient()
    let client = try env.makeClient(http: http)
    let drainer = OutboxDrainer(
      outboxStore: midway.outbox, database: midway.database, absClient: client, account: env.account,
      accountId: env.accountId)
    http.enqueue(makeLocalAllResponse([(id: clientSessionId, success: true)]))
    await drainer.drainLocalSessionUploads()

    #expect(try midway.sessionStore.fetchSession(id: sessionId) == nil, "acknowledged and fully removed")
    #expect(http.requests.count == 1)

    // A second drain in the same incarnation is idempotent: never a repeat send.
    await drainer.drainLocalSessionUploads()
    #expect(http.requests.count == 1, "no repeat send - each session counted exactly once")
  }

  // MARK: - 6. `local-all` response landed but the acknowledgement transaction never committed

  @Test
  func localAllResponseLandsButTheAcknowledgementTransactionNeverCommitsStillCountsExactlyOnceOnRelaunch()
    async throws
  {
    let env = try await PlaybackMatrixEnvironment()
    let sessionId: Int64
    var material: PlaybackSessionStore.LocalSessionUploadMaterial!
    do {
      let inc = try env.openIncarnation()
      let started = try inc.sessionStore.startSession(
        accountId: env.accountId, clientSessionId: UUID().uuidString, itemId: env.itemRowId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
      sessionId = try #require(started.id)
      _ = try inc.sessionStore.recordLocalTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: 70, isFinished: false, deltaSecondsSinceLastTick: 9, localSequence: 1,
          originKey: "device-uuid", segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
      _ = try inc.sessionStore.closeLocalSession(
        sessionId: sessionId,
        tick: PlaybackSessionClose(
          globalPosition: 70, deltaSecondsSinceLastSend: 0, localSequence: 2,
          now: Date(timeIntervalSince1970: 1_700_000_012)))
      let queued = try #require(
        try inc.outbox.fetchQueuedLocalSessionUploads(accountId: env.accountId, limit: 10).first)
      _ = try await inc.outbox.transitionAsync(operationId: try #require(queued.id), to: .sending)
      material = try inc.sessionStore.fetchLocalSessionUploadMaterial(sessionId: sessionId)

      let http = FakeHTTPClient()
      let client = try env.makeClient(http: http)
      http.enqueue(makeLocalAllResponse([(id: material.clientSessionId, success: true)]))
      // The response arrives...
      let outcome = try await client.syncLocalSessions(
        account: env.account,
        sessions: [
          LocalPlaybackSession(
            id: material.clientSessionId, libraryItemID: material.itemServerId, episodeID: material.episodeServerId,
            currentTime: 70, timeListening: 9, startedAt: material.startedAt, updatedAt: material.updatedAt)
        ])
      #expect(outcome.acknowledged.contains(material.clientSessionId))
      // ...but the process dies before `PlaybackSessionStore.acknowledgeLocalUpload` (the ack
      // transaction that would delete both rows) runs.
    }

    let second = try env.openIncarnation()
    #expect(
      try second.sessionStore.fetchSession(id: sessionId) != nil,
      "durable and unacknowledged - a lost ack is safe to replay")

    let http = FakeHTTPClient()
    let client = try env.makeClient(http: http)
    let drainer = OutboxDrainer(
      outboxStore: second.outbox, database: second.database, absClient: client, account: env.account,
      accountId: env.accountId)
    http.enqueue(makeLocalAllResponse([(id: material.clientSessionId, success: true)]))
    await drainer.drainLocalSessionUploads()

    #expect(
      try second.sessionStore.fetchSession(id: sessionId) == nil, "the eventual real ack still lands, exactly once")
    #expect(http.requests.count == 1)

    await drainer.drainLocalSessionUploads()
    #expect(http.requests.count == 1, "a second drain finds nothing left - never double-counted")
  }

  // MARK: - 7. Duplicate offline UUID, pre- and post-send

  /// The spec says a duplicate session UUID merges only before either copy is sent, else
  /// quarantines as a data-integrity error. `PlaybackSessionStore.startSession`
  /// (`PlaybackSessionStoreTests.duplicateClientSessionIdQuarantinesTheExistingRowAndThrows`)
  /// always quarantines the existing row on any `clientSessionId` collision; production has no
  /// merge path. This locks that in for the pre-send case (both copies unsent).
  @Test
  func duplicateOfflineUUIDDiscoveredBeforeEitherCopyIsSentQuarantinesTheOlderRowRatherThanMerging() async throws {
    let env = try await PlaybackMatrixEnvironment()
    let inc = try env.openIncarnation()
    let sharedClientSessionId = UUID().uuidString
    let first = try inc.sessionStore.startSession(
      accountId: env.accountId, clientSessionId: sharedClientSessionId, itemId: env.itemRowId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let firstId = try #require(first.id)
    _ = try inc.sessionStore.closeLocalSession(
      sessionId: firstId,
      tick: PlaybackSessionClose(
        globalPosition: 10, deltaSecondsSinceLastSend: 10, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_010)))
    // Still `.closedAwaitingUpload`, its upload row still queued, never sent (offline recording
    // and close never touch the network, rule 10).

    #expect(throws: PlaybackSessionStoreError.duplicateClientSessionId(sharedClientSessionId)) {
      try inc.sessionStore.startSession(
        accountId: env.accountId, clientSessionId: sharedClientSessionId, itemId: env.itemRowId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_020), isOffline: true)
    }

    let quarantined = try #require(try inc.sessionStore.fetchSession(id: firstId))
    #expect(quarantined.state == .quarantined)

    // Quarantined rows are dead-lettered on drain, never sent (as in
    // `LocalSessionReconciliationTests`).
    let http = FakeHTTPClient()
    let client = try env.makeClient(http: http)
    let drainer = OutboxDrainer(
      outboxStore: inc.outbox, database: inc.database, absClient: client, account: env.account,
      accountId: env.accountId)
    await drainer.drainLocalSessionUploads()
    #expect(http.requests.isEmpty, "a quarantined session is never sent")
  }

  @Test
  func duplicateOfflineUUIDDiscoveredWhileTheOlderCopyIsAlreadyInFlightQuarantinesItTooAcrossARelaunch()
    async throws
  {
    let env = try await PlaybackMatrixEnvironment()
    let inc = try env.openIncarnation()
    let sharedClientSessionId = UUID().uuidString
    let first = try inc.sessionStore.startSession(
      accountId: env.accountId, clientSessionId: sharedClientSessionId, itemId: env.itemRowId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let firstId = try #require(first.id)
    _ = try inc.sessionStore.closeLocalSession(
      sessionId: firstId,
      tick: PlaybackSessionClose(
        globalPosition: 20, deltaSecondsSinceLastSend: 20, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_010)))
    let queued = try #require(try inc.outbox.fetchQueuedLocalSessionUploads(accountId: env.accountId, limit: 10).first)
    // In flight at the moment of collision.
    _ = try await inc.outbox.transitionAsync(operationId: try #require(queued.id), to: .sending)

    #expect(throws: PlaybackSessionStoreError.duplicateClientSessionId(sharedClientSessionId)) {
      try inc.sessionStore.startSession(
        accountId: env.accountId, clientSessionId: sharedClientSessionId, itemId: env.itemRowId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_030), isOffline: true)
    }
    #expect(
      try inc.sessionStore.fetchSession(id: firstId)?.state == .quarantined,
      "quarantined even mid-flight - the drain's own per-row re-check never trusts a stale in-flight snapshot")

    // Crash right after this. The stranded `.sending` row (a crash limbo that `OutboxStore`'s
    // launch reconciliation reverts to `.pending`) is dead-lettered on the next drain, never
    // resent, across an on-disk relaunch.
    let reopened = try env.openIncarnation()
    let http = FakeHTTPClient()
    let client = try env.makeClient(http: http)
    let drainer = OutboxDrainer(
      outboxStore: reopened.outbox, database: reopened.database, absClient: client, account: env.account,
      accountId: env.accountId)
    await drainer.drainLocalSessionUploads()
    #expect(
      http.requests.isEmpty, "the quarantined row is never sent, not even after reverting from stranded `.sending`")
  }

  // MARK: - 8. Removal after journal creation and every later stage boundary

  /// Every account-removal stage boundary, including "after journal creation" and "after the
  /// account row itself is gone", is already parameterised across `AccountRemovalCoordinator.Step`
  /// by `AccountRemovalCrashRecoveryTests
  /// .aCrashAtEveryStageBoundaryRelaunchesIntoRemovalPendingAndResumeConverges` and
  /// `.crashAfterTheAccountRowIsAlreadyGoneStillResumesAndClearsTheJournal`. This thin test reuses
  /// that harness.
  @Test
  func removalCrashImmediatelyAfterJournalCreationConvergesOnRelaunchIncludingDownloadPurge() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)

    let launchA = harness.makeCoordinator(database: database)
    await launchA.setCrashAfterStepForTesting(.journalWritten)
    await #expect(throws: AccountRemovalCoordinator.SimulatedCrashForTesting.self) {
      try await launchA.confirmRemoval()
    }

    let reopenedDatabase = try harness.openDatabase()
    let launchB = harness.makeCoordinator(database: reopenedDatabase)
    #expect(try await launchB.isRemovalPending())

    try await launchB.resumeIfNeeded()

    #expect(try await launchB.isRemovalPending() == false)
    #expect(try harness.fetchAccountRow(database: reopenedDatabase) == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path) == false,
      "downloads purged as part of the same converged sequence")
  }

  // MARK: - 9. Low disk mid-write

  @Test
  func lowDiskMidWriteFailsTheRowLeavesNoOrphanAndIsRetryableAfterACrashOnceSpaceReturns() async throws {
    let env = try await DownloadMatrixEnvironment()
    let downloadId: Int64
    do {
      let inc = try env.openIncarnation(
        fileMover: FakeDownloadFileMoving(error: FakeDownloadFileMoving.outOfSpace))
      let record = try inc.downloadStore.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, serverFileIno: "ino-lowdisk", orderIndex: 0,
        destinationRelativePath: DownloadFileStore.destinationRelativePath(
          accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: nil, orderIndex: 0,
          serverFileIno: "ino-lowdisk", mimeType: "audio/mp4"),
        expectedBytes: 100, expectedMimeType: "audio/mp4", fileDurationSeconds: 10)
      downloadId = try #require(record.id)
      _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
      let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data(repeating: 0x1, count: 100).write(to: temp)

      #expect(throws: DownloadCompletionFailure.self) {
        _ = try inc.downloadFileStore.completeTransfer(
          downloadId: downloadId, temporaryFileURL: temp,
          response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 100))
      }
      // `quarantineAndFail` passes no temp-file URL for a low-disk failure, so the temp file is
      // left for the background adapter/OS to reclaim, as in `DownloadFileStoreTests
      // .aDiskFullFailureDuringMoveIntoPlaceClassifiesLowDiskDistinctlyFromTransportOrValidation`.
      // This cut asserts the destination below: no orphan or partial file lands there.
      let failed = try #require(try inc.downloadStore.fetch(downloadId: downloadId))
      #expect(failed.state == .failed)
      #expect(failed.errorCategory == .lowDisk)
      // Crash right after this: nothing further runs.
    }

    // Space has "returned": the next incarnation uses an ordinary mover.
    let reopened = try env.openIncarnation()
    let recovered = try #require(try reopened.downloadStore.fetch(downloadId: downloadId))
    #expect(recovered.state == .failed, "durable across the crash - never silently reconciled away")
    #expect(recovered.errorCategory == .lowDisk)
    let destinationURL = reopened.downloadFileStore.absoluteURL(forRelativePath: recovered.destinationRelativePath)
    #expect(
      FileManager.default.fileExists(atPath: destinationURL.path) == false,
      "no orphan/partial file left at the destination")

    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadId, to: .pending)
    _ = try await reopened.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
    let retryTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x2, count: 100).write(to: retryTemp)
    let completed = try reopened.downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: retryTemp,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 100))
    #expect(completed.state == .completed, "fully retryable once space is available again")
  }
}

// MARK: - On-disk download environment

/// Shared on-disk plumbing for this file's download-side crash cuts: one seeded account/library/
/// item persisted to a real temp-file database plus a real downloads-root directory, both of
/// which survive across `openIncarnation()` calls like a real process relaunch. Generalises
/// `DownloadCrashRecoveryTests`'s per-test temp-file helper, since these tests reopen more than
/// once per scenario.
private final class DownloadMatrixEnvironment: @unchecked Sendable {
  static let itemID = "item-crash-matrix"
  static let podcastItemID = "item-crash-matrix-podcast"

  let downloadsRoot: URL
  let accountId: Int64
  /// The audiobook fixture every item-level cut runs against. A separate row from
  /// `podcastItemRowId`: sharing one item and flipping it to `mediaKind: "podcast"` for the episode
  /// cuts would re-point every audiobook case at a podcast-kind item.
  let itemRowId: Int64
  /// The podcast show every episode-scoped cut runs against.
  let podcastItemRowId: Int64

  private let fixture: SuiteOnDiskDatabases
  private let scope: OnDiskDatabaseScope
  private let databaseURL: URL
  private var currentDatabase: AppDatabase?
  private let server: ABSServerConfig
  private let account: TokenAccount

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "DownloadMatrixEnvironment")
    self.fixture = fixture
    scope = fixture.scope
    databaseURL = scope.url()
    downloadsRoot = scope.directoryURL.appendingPathComponent("Downloads", isDirectory: true)

    server = try ABSServerConfig(url: try #require(URL(string: "https://download-matrix.example.test")))
    let clientUUID = UUID().uuidString
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")

    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    let serverBaseURL = server.baseURL.absoluteString
    let saved = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: serverBaseURL, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let localAccountId = try #require(saved.id)
    accountId = localAccountId
    let libraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    itemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title", sortTitle: "title")
      ).id)
    podcastItemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryId, serverItemId: Self.podcastItemID,
          mediaKind: "podcast", title: "Show", sortTitle: "show")
      ).id)
    scope.close(database)
  }

  deinit {}

  struct Incarnation {
    let database: AppDatabase
    let downloadStore: DownloadStore
    let downloadFileStore: DownloadFileStore
  }

  /// One "process lifetime": a fresh `AppDatabase` connection (which performs the bulk
  /// `.downloading -> .interrupted` reconciliation) plus a fresh `DownloadFileStore` over the same
  /// real downloads-root directory. This is the relaunch boundary every test above cuts across.
  func openIncarnation(fileMover: DownloadFileMoving = POSIXDownloadFileMover()) throws -> Incarnation {
    if let currentDatabase {
      scope.close(currentDatabase)
      self.currentDatabase = nil
    }
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    currentDatabase = database
    let downloadStore = try DownloadStore(database: database)
    let downloadFileStore = try DownloadFileStore(
      rootURL: downloadsRoot, fileAttributes: POSIXFileAttributeApplier(), downloadStore: downloadStore,
      fileMover: fileMover)
    return Incarnation(database: database, downloadStore: downloadStore, downloadFileStore: downloadFileStore)
  }

  struct CoordinatorIncarnation {
    let database: AppDatabase
    let downloadStore: DownloadStore
    let downloadFileStore: DownloadFileStore
    let coordinator: DownloadCoordinator
    let backgroundTransferring: FakeBackgroundTransferring
  }

  /// The full `DownloadCoordinator` graph over the same on-disk state, with fresh adapter fakes
  /// (a real relaunch's adapter remembers nothing held in memory either).
  func openCoordinatorIncarnation(
    currentTasks: [BackgroundTransferSnapshot] = []
  ) throws -> CoordinatorIncarnation {
    let inc = try openIncarnation()
    let http = FakeHTTPClient()
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let backgroundTransferring = FakeBackgroundTransferring()
    backgroundTransferring.setCurrentTasks(currentTasks)
    let coordinator = DownloadCoordinator.make(
      client: client, database: inc.database, downloadStore: inc.downloadStore,
      downloadFileStore: inc.downloadFileStore, backgroundTransferring: backgroundTransferring,
      downloadPreferences: FakeDownloadPreferences(), networkConditions: FakeNetworkConditions())
    return CoordinatorIncarnation(
      database: inc.database, downloadStore: inc.downloadStore, downloadFileStore: inc.downloadFileStore,
      coordinator: coordinator, backgroundTransferring: backgroundTransferring)
  }

  /// Enqueues, transitions through `downloading`, and completes one download row with a real file
  /// on disk, for tests whose subject is deletion rather than completion. An episode-scoped row
  /// belongs to the podcast show fixture and an item-level one to the audiobook fixture, so
  /// neither kind's cuts borrow the other's item.
  @discardableResult
  func seedCompletedDownload(
    _ inc: Incarnation, ino: String, bytes: Int64 = 100,
    podcastEpisodeId: Int64? = nil
  ) async throws -> Int64 {
    let itemRowId = podcastEpisodeId == nil ? self.itemRowId : podcastItemRowId
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: podcastEpisodeId,
      orderIndex: 0, serverFileIno: ino, mimeType: "audio/mpeg")
    let record = try inc.downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: podcastEpisodeId,
      serverFileIno: ino, orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: bytes, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try await inc.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x1, count: Int(bytes)).write(to: temp)
    _ = try inc.downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: temp,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: bytes))
    return downloadId
  }

  func seedPodcastEpisode(episodeID: String) async throws -> Int64 {
    if let currentDatabase {
      scope.close(currentDatabase)
      self.currentDatabase = nil
    }
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    defer {
      scope.close(database)
      currentDatabase = nil
    }
    let episode = try await PodcastEpisodeDAO(database: database).upsertAsync(
      PodcastEpisodeRecord(
        accountId: accountId, itemId: podcastItemRowId, serverEpisodeId: episodeID,
        title: episodeID, lastSeenGeneration: 1))
    return try #require(episode.id)
  }
}

// MARK: - On-disk offline-playback environment

/// Shared on-disk plumbing for this file's offline-session/`local-all` crash cuts. Follows
/// `SessionRecoveryJourneyTests`'s `RecoveryJourneyEnvironment`/`openIncarnation()` shape, but
/// seeds an offline item and wires no full `PlaybackSessionCoordinator`. These tests drive
/// `PlaybackSessionStore`/`OutboxDrainer` directly, the layer `LocalSessionReconciliationTests`
/// tests at, over a real on-disk file instead of `AppDatabase.inMemory()`.
private final class PlaybackMatrixEnvironment: @unchecked Sendable {
  static let itemID = "item-offline-crash-matrix"

  let account: TokenAccount
  let accountId: Int64
  let itemRowId: Int64

  private let fixture: SuiteOnDiskDatabases
  private let scope: OnDiskDatabaseScope
  private let databaseURL: URL
  private let server: ABSServerConfig
  private var currentDatabase: AppDatabase?

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "PlaybackMatrixEnvironment")
    self.fixture = fixture
    scope = fixture.scope
    databaseURL = scope.url()

    server = try ABSServerConfig(url: try #require(URL(string: "https://offline-matrix.example.test")))
    let clientUUID = UUID().uuidString
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")

    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    let serverBaseURL = server.baseURL.absoluteString
    let saved = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: serverBaseURL, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let localAccountId = try #require(saved.id)
    accountId = localAccountId
    let libraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    itemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title", sortTitle: "title")
      ).id)
    scope.close(database)
  }

  deinit {}

  struct Incarnation {
    let database: AppDatabase
    let outbox: OutboxStore
    let sessionStore: PlaybackSessionStore
  }

  func openIncarnation() throws -> Incarnation {
    if let currentDatabase {
      scope.close(currentDatabase)
      self.currentDatabase = nil
    }
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    currentDatabase = database
    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    return Incarnation(database: database, outbox: outbox, sessionStore: sessionStore)
  }

  /// A fresh `ABSClient` over the given fake transport, pre-loaded with this environment's account
  /// identity. Needed by every test that drains/sends against `/api/session/local-all`.
  func makeClient(http: any HTTPClienting) throws -> ABSClient {
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)
    return ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
  }
}
