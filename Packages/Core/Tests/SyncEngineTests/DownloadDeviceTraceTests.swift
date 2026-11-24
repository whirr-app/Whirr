import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The download half of the device trace (`WHIRRDL`). The runbook asks for verdicts the app cannot
/// otherwise produce: "reattaches to the transfer" and "interrupted, requeued, no phantom rows"
/// are `reconcileAfterLaunch`'s internal join, a reattach and a restart-from-zero look the same on
/// screen, and a Wi-Fi hold and a never-started row both render as "waiting". These tests own the
/// record shapes and pin the wiring. The `NSLog` is DEBUG-only and untestable, as with
/// `DrainCadenceTrace`/`ReaderTrace`/`SearchTrace`.
@Suite struct DownloadDeviceTraceTests {

  // MARK: - Record shapes

  @Test func theReconcileLineNamesEveryOutcomeOfTheLaunchJoin() {
    let line = DownloadDeviceTrace.line(
      .reconcile(
        DownloadDeviceTrace.Reconcile(
          rows: 4, liveTasks: 1, reattached: 1, requeued: 3, orphansCancelled: 2, heldAdopted: 0)))

    #expect(line == "WHIRRDL reconcile rows=4 live=1 reattached=1 requeued=3 orphans=2 held=0")
  }

  /// The schedule gate states every input to the start/hold decision, because on device the reader
  /// needs to know why nothing started. No slot, cellular policy and low disk are three different
  /// findings, and the UI shows one stalled row for all three.
  @Test func theScheduleLineStatesEveryInputToTheGate() {
    let line = DownloadDeviceTrace.line(
      .schedule(
        DownloadDeviceTrace.Schedule(
          active: 1, pending: 3, slots: 1, isConstrainedOrCellular: true, allowsCellular: false,
          isQueuePausedForLowDisk: false, skipped: 0)))

    #expect(
      line
        == "WHIRRDL schedule active=1 pending=3 slots=1 cellular=1 allowCellular=0 lowDisk=0 skipped=0"
    )
  }

  /// Device stall shape: two rows pending, two free slots, cellular allowed, disk fine, and nothing
  /// started, pass after pass. The scheduler also drops any pending row carrying a failed-event
  /// marker, so the line states that input too, or the trace shows the stall without naming it.
  @Test func theScheduleLineStatesHowManyPendingRowsItSkipped() {
    let line = DownloadDeviceTrace.line(
      .schedule(
        DownloadDeviceTrace.Schedule(
          active: 0, pending: 2, slots: 2, isConstrainedOrCellular: true, allowsCellular: true,
          isQueuePausedForLowDisk: false, skipped: 2)))

    #expect(
      line
        == "WHIRRDL schedule active=0 pending=2 slots=2 cellular=1 allowCellular=1 lowDisk=0 skipped=2"
    )
  }

  /// An RSS row id is a different sequence from an ABS row id, so the RSS line carries its own
  /// tag. Its rejection names the RSS store's own guard, since `.validation` alone does not say
  /// why the row failed.
  @Test func anRSSTransferLineIsTaggedAndNamesTheRSSGuardThatRejectedIt() {
    #expect(
      DownloadDeviceTrace.line(
        .rssTransfer(.init(downloadId: 7, event: .finish(.rssRejected(.validation, .responseSizeMismatch)))))
        == "WHIRRDL rssTransfer id=7 event=finish result=rejected category=validation reason=responseSizeMismatch"
    )
    #expect(
      DownloadDeviceTrace.line(.rssTransfer(.init(downloadId: 7, event: .finish(.stored))))
        == "WHIRRDL rssTransfer id=7 event=finish result=stored")
    #expect(
      DownloadDeviceTrace.line(.rssTransfer(.init(downloadId: 7, event: .start(expectedBytes: 0))))
        == "WHIRRDL rssTransfer id=7 event=start bytes=0")
  }

  @Test func aStartedTransferReportsTheByteCountItIsAbout() {
    let line = DownloadDeviceTrace.line(
      .transfer(DownloadDeviceTrace.Transfer(downloadId: 7, event: .start(expectedBytes: 52_428_800))))

    #expect(line == "WHIRRDL transfer id=7 event=start bytes=52428800")
  }

  /// The two holds are not the same event. `origin=active` is a live transfer suspended by a
  /// network transition (the only place the in-memory `networkHeldActiveDownloadIds` residual can
  /// bite); `origin=pending` is a row that never started. Both durably land on
  /// `.pending(.waitingForWiFi)`, so the durable row cannot tell them apart afterwards.
  @Test func aHoldSaysWhetherItSuspendedLiveWorkOrGatedAnUnstartedRow() {
    #expect(
      DownloadDeviceTrace.line(.transfer(.init(downloadId: 7, event: .hold(origin: .active))))
        == "WHIRRDL transfer id=7 event=hold origin=active")
    #expect(
      DownloadDeviceTrace.line(.transfer(.init(downloadId: 7, event: .hold(origin: .pending))))
        == "WHIRRDL transfer id=7 event=hold origin=pending")
  }

  /// A `release` is emitted only where an adapter task was believed to still exist (the in-memory
  /// `networkHeldActiveDownloadIds` set a relaunch empties). A hold this process has no memory of
  /// is restarted from zero instead and traces `start`. So `release` followed by no `progress`
  /// line shows the accepted residual: a resume sent to a task that was already gone.
  @Test func aReleasedHoldIsDistinguishableFromAFreshStart() {
    #expect(
      DownloadDeviceTrace.line(.transfer(.init(downloadId: 7, event: .release)))
        == "WHIRRDL transfer id=7 event=release")
  }

  /// The device check reads one scheduled retry and the requeue that follows it.
  @Test func anAutomaticRetrySaysWhenItIsDueAndWhichAttemptItIs() {
    #expect(
      DownloadDeviceTrace.line(.transfer(.init(downloadId: 7, event: .retryScheduled(afterSeconds: 600))))
        == "WHIRRDL transfer id=7 event=retryScheduled after=600s")
    #expect(
      DownloadDeviceTrace.line(.rssTransfer(.init(downloadId: 8, event: .retry(attempt: 2))))
        == "WHIRRDL rssTransfer id=8 event=retry attempt=2")
  }

  @Test func everyTerminalOutcomeIsDistinguishable() {
    let outcomes: [(DownloadDeviceTrace.Outcome, String)] = [
      (.stored, "stored"), (.lowDisk, "lowDisk"),
      (.rejected(.transport), "rejected category=transport"),
      (.rejected(.auth), "rejected category=auth"),
      (.rejected(.validation), "rejected category=validation"),
      (.rejected(.storage), "rejected category=storage"),
      (.rejected(.lowDisk), "rejected category=lowDisk"),
      (.rejected(.unknown), "rejected category=unknown"),
      (
        .failed(errorDomain: "NSURLErrorDomain", errorCode: NSURLErrorNetworkConnectionLost),
        "failed domain=NSURLErrorDomain code=-1005"
      ),
      (.failed(errorDomain: nil, errorCode: nil), "failed"),
      (.authPaused, "authPaused"),
    ]
    for (outcome, rendered) in outcomes {
      #expect(
        DownloadDeviceTrace.line(.transfer(.init(downloadId: 7, event: .finish(outcome))))
          == "WHIRRDL transfer id=7 event=finish result=\(rendered)")
    }
  }

  /// `category=validation` alone covers four unrelated guards, and which one fired decides where
  /// the fault is: a length mismatch means the server's recorded size disagrees with the bytes it
  /// served, while a MIME mismatch means the response was not the file at all.
  @Test func aValidationRejectionNamesTheGuardThatFired() {
    let reasons: [DownloadValidationReason] = [
      .httpStatus, .mimeType, .contentLength, .contentRangeTotal, .onDiskSize,
    ]
    for reason in reasons {
      #expect(
        DownloadDeviceTrace.line(
          .transfer(.init(downloadId: 7, event: .finish(.rejected(.validation, reason)))))
          == "WHIRRDL transfer id=7 event=finish result=rejected category=validation "
          + "reason=\(reason.rawValue)")
    }
  }

  @Test func aPurgeLineNamesItsScopeSourceAndSelectedRows() {
    let line = DownloadDeviceTrace.line(
      .purge(
        DownloadDeviceTrace.Purge(scope: .item, source: .itemDetail, rows: 2)))

    #expect(line == "WHIRRDL purge scope=item source=itemDetail rows=2")
  }

  /// A smart list's release is the app letting go of a download its own request made, so it steps
  /// aside for a transfer in flight and is never taken for the listener removing it by hand.
  @Test func aSmartListReleaseIsAnAutomaticPurgeAndNotAHandRemoval() {
    #expect(DownloadPurgeSource.smartListRelease.isAutomatic)
    #expect(DownloadPurgeSource.smartListRelease.isHandRemoval == false)
    #expect(DownloadPurgeSource.smartListRelease.rawValue == "smartListRelease")
    #expect(
      DownloadDeviceTrace.line(
        .purge(DownloadDeviceTrace.Purge(scope: .episode, source: .smartListRelease, rows: 1)))
        == "WHIRRDL purge scope=episode source=smartListRelease rows=1")
  }

  /// The only record emitted from above the coordinator. A purge confirmed on the Downloads screen
  /// that never reaches `DownloadCoordinator` leaves the whole trace silent, and silence cannot say
  /// whether the intent was never sent, threw, or arrived and did nothing. `forwarded` with no
  /// `purge` line after it means something quite different from `unstaged`.
  @Test func aPurgeIntentLineSaysWhetherTheIntentEverLeftTheModel() {
    #expect(
      DownloadDeviceTrace.line(
        .purgeIntent(
          DownloadDeviceTrace.PurgeIntent(scope: .all, source: .storage, outcome: .forwarded)))
        == "WHIRRDL purgeIntent scope=all source=storage outcome=forwarded")
    #expect(
      DownloadDeviceTrace.line(
        .purgeIntent(
          DownloadDeviceTrace.PurgeIntent(scope: .item, source: .storage, outcome: .failed)))
        == "WHIRRDL purgeIntent scope=item source=storage outcome=failed")
  }

  /// A confirmation with nothing staged has no scope to name, and is rendered as such rather than
  /// guessed.
  @Test func anUnstagedConfirmationNamesNoScopeRatherThanInventingOne() {
    #expect(
      DownloadDeviceTrace.line(
        .purgeIntent(
          DownloadDeviceTrace.PurgeIntent(scope: nil, source: .storage, outcome: .unstaged)))
        == "WHIRRDL purgeIntent scope=none source=storage outcome=unstaged")
  }

  @Test func aCancelLineNamesItsLocalDownloadRow() {
    #expect(DownloadDeviceTrace.line(.cancel(downloadId: 7)) == "WHIRRDL cancel id=7")
  }

  @Test func aProgressLineCarriesThePercentageAndTheByteCount() {
    #expect(
      DownloadDeviceTrace.line(.progress(.init(downloadId: 7, receivedBytes: 22_020_096, percent: 40)))
        == "WHIRRDL progress id=7 pct=40 bytes=22020096")
  }

  /// A transfer whose total the adapter never learned still has to show movement, so the unknown
  /// percentage is stated rather than invented.
  @Test func anUnknownTotalRendersAsAnUnknownPercentageRatherThanAGuess() {
    #expect(
      DownloadDeviceTrace.line(.progress(.init(downloadId: 7, receivedBytes: 1_024, percent: nil)))
        == "WHIRRDL progress id=7 pct=? bytes=1024")
  }

  // MARK: - The progress throttle

  /// A byte-level progress callback fires far too often to log one line each; deciles keep ten
  /// lines per file, which is enough to see movement, a stall, and a resume, and few enough that a
  /// two-slot device day stays readable.
  @Test func progressIsTracedOncePerDecile() {
    var throttle = DownloadProgressTraceThrottle()
    let total: Int64 = 1_000

    #expect(throttle.decision(downloadId: 1, receivedBytes: 10, expectedBytes: total) == .trace(percent: 1))
    #expect(throttle.decision(downloadId: 1, receivedBytes: 50, expectedBytes: total) == .skip)
    #expect(throttle.decision(downloadId: 1, receivedBytes: 99, expectedBytes: total) == .skip)
    #expect(throttle.decision(downloadId: 1, receivedBytes: 100, expectedBytes: total) == .trace(percent: 10))
    #expect(throttle.decision(downloadId: 1, receivedBytes: 199, expectedBytes: total) == .skip)
    #expect(throttle.decision(downloadId: 1, receivedBytes: 1_000, expectedBytes: total) == .trace(percent: 100))
  }

  @Test func twoConcurrentTransfersAreThrottledIndependently() {
    var throttle = DownloadProgressTraceThrottle()
    #expect(throttle.decision(downloadId: 1, receivedBytes: 500, expectedBytes: 1_000) == .trace(percent: 50))
    #expect(throttle.decision(downloadId: 2, receivedBytes: 10, expectedBytes: 1_000) == .trace(percent: 1))
    #expect(throttle.decision(downloadId: 1, receivedBytes: 510, expectedBytes: 1_000) == .skip)
  }

  /// Without forgetting, the throttle would keep one entry per download for the life of the
  /// process, and a requeued row that restarts from zero would trace nothing until it passed its
  /// old high-water decile.
  @Test func aFinishedTransferIsForgottenSoARestartTracesFromZeroAgain() {
    var throttle = DownloadProgressTraceThrottle()
    #expect(throttle.decision(downloadId: 1, receivedBytes: 900, expectedBytes: 1_000) == .trace(percent: 90))
    throttle.forget(downloadId: 1)
    #expect(throttle.decision(downloadId: 1, receivedBytes: 10, expectedBytes: 1_000) == .trace(percent: 1))
  }

  @Test func anUnknownTotalFallsBackToFixedByteChunks() {
    var throttle = DownloadProgressTraceThrottle()
    let chunk = DownloadProgressTraceThrottle.unknownTotalChunkBytes

    #expect(throttle.decision(downloadId: 1, receivedBytes: 1, expectedBytes: nil) == .trace(percent: nil))
    #expect(throttle.decision(downloadId: 1, receivedBytes: 2, expectedBytes: nil) == .skip)
    #expect(throttle.decision(downloadId: 1, receivedBytes: chunk, expectedBytes: nil) == .trace(percent: nil))
  }

  // MARK: - Wiring (the trace is worthless if it is not connected)

  @Test func startingATransferIsTraced() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    #expect(
      records.value.contains(
        .transfer(.init(downloadId: downloadId, event: .start(expectedBytes: 50)))))
  }

  /// The same pass that reattaches a live task requeues the rows with none and cancels the tasks
  /// with no row, and the durable table afterwards looks identical either way.
  @Test func theLaunchReconciliationEmitsOneSummaryOfTheJoin() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5),
      (index: 1, ino: 101, size: 50, mimeType: "audio/mp4", duration: 5),
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    let reattachedId = try #require(rows.first?.id)

    let freshStore = try DownloadStore(database: harness.database)
    harness.backgroundTransferring.setCurrentTasks([
      BackgroundTransferSnapshot(identity: .abs(rowID: reattachedId)),
      BackgroundTransferSnapshot(identity: .abs(rowID: 424_242)),
    ])
    let freshCoordinator = harness.makeCoordinator(downloadStore: freshStore)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await freshCoordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    await freshCoordinator.reconcileAfterLaunch()

    let reconciles = records.value.compactMap { record -> DownloadDeviceTrace.Reconcile? in
      guard case .reconcile(let summary) = record else { return nil }
      return summary
    }
    #expect(reconciles.count == 1)
    let summary = try #require(reconciles.first)
    #expect(summary.rows == 2)
    #expect(summary.liveTasks == 2)
    #expect(summary.reattached == 1)
    #expect(summary.requeued == 1)
    #expect(summary.orphansCancelled == 1)
    #expect(summary.heldAdopted == 0)
  }

  /// The cellular hold. A row that never started is gated before it begins, and the schedule line
  /// names the policy that gated it.
  @Test func aCellularHoldOnAnUnstartedRowIsTracedWithItsGate() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.networkConditions.isConstrainedOrCellular = true
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    #expect(records.value.contains(.transfer(.init(downloadId: downloadId, event: .hold(origin: .pending)))))
    let schedules = records.value.compactMap { record -> DownloadDeviceTrace.Schedule? in
      guard case .schedule(let gate) = record else { return nil }
      return gate
    }
    #expect(schedules.contains { $0.isConstrainedOrCellular && $0.allowsCellular == false })
  }

  /// Both halves: leaving Wi-Fi suspends live work (`origin=active`), and returning releases it,
  /// the release stating whether an adapter task was believed to exist at all.
  @Test func leavingAndRejoiningWiFiTracesTheHoldAndItsRelease() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    harness.networkConditions.isConstrainedOrCellular = true
    await harness.coordinator.schedule()
    #expect(records.value.contains(.transfer(.init(downloadId: downloadId, event: .hold(origin: .active)))))

    harness.networkConditions.isConstrainedOrCellular = false
    await harness.coordinator.schedule()
    #expect(records.value.contains(.transfer(.init(downloadId: downloadId, event: .release))))
  }

  @Test func aFinishedTransferTracesItsStoredOutcome() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 4, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 4),
        response: BackgroundTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 4)))

    #expect(records.value.contains(.transfer(.init(downloadId: downloadId, event: .finish(.stored)))))
  }

  /// The guard that fired travels with the category all the way from `DownloadFileStore`, since a
  /// category alone leaves the four validation causes unattributable from a device capture.
  @Test func aCompletionRejectionTracesItsCategoryAndTheGuardThatFired() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 4, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 4),
        response: BackgroundTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4)))

    #expect(
      records.value.contains(
        .transfer(
          .init(downloadId: downloadId, event: .finish(.rejected(.validation, .mimeType))))))
  }

  @Test func aFailedTransferTracesItsFailure() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    await harness.coordinator.handleTransferEvent(
      .failed(
        identity: .abs(rowID: downloadId), errorDomain: NSURLErrorDomain,
        errorCode: NSURLErrorNetworkConnectionLost))

    #expect(
      records.value.contains(
        .transfer(
          .init(
            downloadId: downloadId,
            event: .finish(
              .failed(
                errorDomain: NSURLErrorDomain, errorCode: NSURLErrorNetworkConnectionLost))))))
  }

  @Test func aPurgeTracesItsScopeSourceAndSelectedRowsIncludingZero() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5),
      (index: 1, ino: 101, size: 50, mimeType: "audio/mp4", duration: 5),
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    try await harness.coordinator.purgeItemDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .itemDetail)
    try await harness.coordinator.purgeItemDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .itemDetail)

    let purges = records.value.compactMap { record -> DownloadDeviceTrace.Purge? in
      guard case .purge(let purge) = record else { return nil }
      return purge
    }
    #expect(purges.map(\.scope) == [.item, .item])
    #expect(purges.map(\.source) == [.itemDetail, .itemDetail])
    #expect(purges.map(\.rows) == [2, 0])
  }

  @Test func progressEventsAreTracedThroughTheThrottle() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 1_000, mimeType: "audio/mp4", duration: 5)
    ])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }

    for received: Int64 in [100, 150, 200] {
      await harness.coordinator.handleTransferEvent(
        .progress(identity: .abs(rowID: downloadId), receivedBytes: received, expectedBytes: 1_000))
    }

    let progress = records.value.compactMap { record -> DownloadDeviceTrace.Progress? in
      guard case .progress(let progress) = record else { return nil }
      return progress
    }
    #expect(progress.map(\.percent) == [10, 20] as [Int?], "one line per decile, not one per callback")
  }
}
