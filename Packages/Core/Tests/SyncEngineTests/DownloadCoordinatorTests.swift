import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct DownloadCoordinatorTests {

  @Test("reports only transfers that are currently downloading")
  func reportsActiveTransfers() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let record = try await harness.downloadStore.enqueueAsync(
      accountId: harness.accountId,
      itemId: harness.itemRowId,
      serverFileIno: "active-file",
      orderIndex: 0,
      destinationRelativePath: "active-file",
      expectedBytes: 100,
      expectedMimeType: "audio/mp4",
      fileDurationSeconds: 10)
    let downloadID = try #require(record.id)

    #expect(await harness.coordinator.hasActiveTransfers() == false)
    _ = try await harness.downloadStore.transitionAsync(downloadId: downloadID, to: .downloading)
    #expect(await harness.coordinator.hasActiveTransfers())
    _ = try await harness.downloadStore.transitionAsync(downloadId: downloadID, to: .failed)
    #expect(await harness.coordinator.hasActiveTransfers() == false)

    let rssRecord = try await harness.seedRSSDownload()
    let rssDownloadID = try #require(rssRecord.id)
    _ = try await harness.rssDownloadStore.transitionAsync(downloadId: rssDownloadID, to: .downloading)
    #expect(await harness.coordinator.hasActiveTransfers())
    _ = try await harness.rssDownloadStore.transitionAsync(downloadId: rssDownloadID, to: .failed)
    #expect(await harness.coordinator.hasActiveTransfers() == false)
  }

  @Test("teardown cancels subscriptions and drops later transfer events")
  func teardownCancelsSubscriptionsAndDropsLaterTransferEvents() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let eventSource = FakeBackgroundTransferring()
    let coordinator = DownloadCoordinator.make(
      client: harness.client,
      database: harness.database,
      downloadStore: harness.downloadStore,
      downloadFileStore: harness.downloadFileStore,
      backgroundTransferring: eventSource,
      downloadPreferences: harness.downloadPreferences,
      networkConditions: harness.networkConditions,
      diagnostics: harness.diagnostics,
      freeSpaceReporting: harness.freeSpaceReporting)

    let record = try await harness.downloadStore.enqueueAsync(
      accountId: harness.accountId,
      itemId: harness.itemRowId,
      serverFileIno: "event-file",
      orderIndex: 0,
      destinationRelativePath: "event-file",
      expectedBytes: 100,
      expectedMimeType: "audio/mp4",
      fileDurationSeconds: 10)
    let downloadId = try #require(record.id)
    _ = try await harness.downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)

    #expect(
      eventSource.pushEvent(
        .progress(identity: .abs(rowID: downloadId), receivedBytes: 42, expectedBytes: 100)))
    #expect(
      await TestSupport.waitUntil {
        do {
          return try await harness.downloadStore.fetchAsync(downloadId: downloadId)?.receivedBytes == 42
        } catch {
          return false
        }
      })

    await coordinator.teardown()
    await coordinator.teardown()
    #expect(await TestSupport.waitUntil { eventSource.eventsTerminated })

    #expect(
      eventSource.pushEvent(
        .progress(identity: .abs(rowID: downloadId), receivedBytes: 84, expectedBytes: 100)) == false)
    let rowAfterTeardown = try await harness.downloadStore.fetchAsync(downloadId: downloadId)
    #expect(rowAfterTeardown?.receivedBytes == 42)
  }
}
