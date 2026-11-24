import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// A transfer that finished while the app was terminated. The background session relaunches the
/// process, the fresh stores rewrite the row `.downloading -> .interrupted`, and the buffered
/// `.finished` reaches the new coordinator before or after its launch reconcile. Both orders must
/// complete the row from the delivered file without a second transfer.
@Suite struct DownloadUndeliveredFinishTests {

  private static let absResponse = BackgroundTransferResponse(
    httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)
  private static let rssResponse = BackgroundTransferResponse(
    httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 50)

  // MARK: - Finish handled before reconcile

  @Test func anABSFinishHandledBeforeReconcileCompletesTheInterruptedRow() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let downloadId = try await startABSDownload(harness)
    let relaunched = try relaunch(harness)
    #expect(try relaunched.abs.fetch(downloadId: downloadId)?.state == .interrupted)
    let enqueuesBefore = enqueueCount(harness)

    await relaunched.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: Self.absResponse))
    await relaunched.coordinator.reconcileAfterLaunch()

    #expect(try relaunched.abs.fetch(downloadId: downloadId)?.state == .completed)
    #expect(enqueueCount(harness) == enqueuesBefore, "the delivered file is used, never fetched again")
    #expect(harness.backgroundTransferring.acknowledgedFinishes == [.abs(rowID: downloadId)])
  }

  @Test func anRSSFinishHandledBeforeReconcileCompletesTheInterruptedRow() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let downloadId = try await startRSSDownload(harness)
    let relaunched = try relaunch(harness)
    #expect(try relaunched.rss.fetch(downloadId: downloadId)?.state == .interrupted)
    let enqueuesBefore = enqueueCount(harness)

    await relaunched.coordinator.handleTransferEvent(
      .finished(
        identity: .rss(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: Self.rssResponse))
    await relaunched.coordinator.reconcileAfterLaunch()

    // `.interrupted -> .completed` must be a legal edge: otherwise it escapes as a storage failure
    // and leaves the episode `.failed` with its file in place.
    #expect(try relaunched.rss.fetch(downloadId: downloadId)?.state == .completed)
    #expect(enqueueCount(harness) == enqueuesBefore)
    #expect(harness.backgroundTransferring.acknowledgedFinishes == [.rss(rowID: downloadId)])
  }

  // MARK: - Reconcile before the finish is handled

  @Test func reconcileReattachesAnUndeliveredABSFinishInsteadOfRequeuingIt() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let downloadId = try await startABSDownload(harness)
    let relaunched = try relaunch(harness)
    harness.backgroundTransferring.setUndeliveredFinishes([.abs(rowID: downloadId)])
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await relaunched.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }
    let enqueuesBefore = enqueueCount(harness)

    await relaunched.coordinator.reconcileAfterLaunch()

    #expect(try relaunched.abs.fetch(downloadId: downloadId)?.state == .downloading)
    #expect(enqueueCount(harness) == enqueuesBefore, "no second transfer for a finished one")
    let summary = try #require(reconcileSummaries(records.value).last)
    #expect(summary.reattached == 1)
    #expect(summary.requeued == 0)

    await relaunched.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: Self.absResponse))

    #expect(try relaunched.abs.fetch(downloadId: downloadId)?.state == .completed)
    #expect(await harness.backgroundTransferring.undeliveredFinishes().isEmpty)
  }

  @Test func reconcileReattachesAnUndeliveredRSSFinishInsteadOfRequeuingIt() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let downloadId = try await startRSSDownload(harness)
    let relaunched = try relaunch(harness)
    harness.backgroundTransferring.setUndeliveredFinishes([.rss(rowID: downloadId)])
    let enqueuesBefore = enqueueCount(harness)

    await relaunched.coordinator.reconcileAfterLaunch()

    #expect(try relaunched.rss.fetch(downloadId: downloadId)?.state == .downloading)
    #expect(enqueueCount(harness) == enqueuesBefore)

    await relaunched.coordinator.handleTransferEvent(
      .finished(
        identity: .rss(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: Self.rssResponse))

    #expect(try relaunched.rss.fetch(downloadId: downloadId)?.state == .completed)
  }

  // MARK: - Edges

  @Test func aFinishForADeletedRowCompletesNothingAndIsAcknowledged() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let relaunched = try relaunch(harness)

    await relaunched.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: 987_654), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: Self.absResponse))

    #expect(try relaunched.abs.fetchAll().isEmpty)
    #expect(harness.backgroundTransferring.acknowledgedFinishes == [.abs(rowID: 987_654)])
  }

  @Test func anUndeliveredFinishNeverMarksAWiFiHeldRowAsOwningALiveTask() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    harness.networkConditions.isConstrainedOrCellular = true
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let row = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    let downloadId = try #require(row.id)
    #expect(row.state == .pending)
    #expect(row.holdReason == .waitingForWiFi)
    let relaunched = try relaunch(harness)
    harness.backgroundTransferring.setUndeliveredFinishes([.abs(rowID: downloadId)])

    await relaunched.coordinator.reconcileAfterLaunch()

    #expect(await relaunched.coordinator.liveTaskOwnedDownloadIds.contains(downloadId) == false)
  }

  /// The overnight analysis task awaits a reconcile of its own, which is a second one when
  /// the process already composed the coordinator.
  @Test func aSecondReconcileInOneProcessLeavesALiveTransferAlone() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    _ = try await startABSDownload(harness)
    let callsBefore = harness.backgroundTransferring.calls.count

    await harness.coordinator.reconcileAfterLaunch()
    await harness.coordinator.reconcileAfterLaunch()

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).first?.state == .downloading)
    #expect(
      harness.backgroundTransferring.calls.dropFirst(callsBefore).contains {
        switch $0 {
        case .enqueue, .cancel: return true
        default: return false
        }
      } == false, "no second transfer and no cancel for the live one")
  }

  // MARK: - Helpers

  private struct Relaunched {
    let abs: DownloadStore
    let rss: RSSDownloadStore
    let coordinator: DownloadCoordinator
  }

  /// Fresh stores over the same database are what perform the launch rewrite.
  private func relaunch(_ harness: DownloadCoordinatorHarness) throws -> Relaunched {
    let abs = try DownloadStore(database: harness.database)
    let rss = try RSSDownloadStore(database: harness.database)
    return Relaunched(
      abs: abs, rss: rss,
      coordinator: harness.makeUnsubscribedCoordinator(downloadStore: abs, rssDownloadStore: rss))
  }

  private func startABSDownload(_ harness: DownloadCoordinatorHarness) async throws -> Int64 {
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let row = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    #expect(row.state == .downloading)
    return try #require(row.id)
  }

  private func startRSSDownload(_ harness: DownloadCoordinatorHarness) async throws -> Int64 {
    let row = try await harness.seedRSSDownload(bytes: 50)
    let downloadId = try #require(row.id)
    await harness.coordinator.schedule()
    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadId)?.state == .downloading)
    return downloadId
  }

  private func enqueueCount(_ harness: DownloadCoordinatorHarness) -> Int {
    harness.backgroundTransferring.calls.filter {
      if case .enqueue = $0 { return true }
      return false
    }.count
  }

  private func reconcileSummaries(_ records: [DownloadDeviceTrace.Record]) -> [DownloadDeviceTrace.Reconcile] {
    records.compactMap {
      guard case .reconcile(let summary) = $0 else { return nil }
      return summary
    }
  }
}
