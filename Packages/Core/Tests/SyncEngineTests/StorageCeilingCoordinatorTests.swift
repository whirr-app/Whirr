import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite struct StorageCeilingCoordinatorTests {

  @Test func unlimitedDoesNothingAtAll() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: nil)
    let reading = FakeStorageReading(completedDownloadBytes: 500)
    let claiming = FakeStorageEvictionClaiming(rows: [Self.row(id: 1, bytes: 500)])
    let purging = FakeStorageCeilingPurging()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: reading, evictionClaiming: claiming,
      purging: purging)

    let result = await coordinator.enforce()

    #expect(result == .unlimited)
    #expect(await claiming.callCount == 0)
    #expect(await purging.events.isEmpty)
    #expect(reading.completedObservationCount == 0)
  }

  @Test func atOrUnderCapDoesNothing() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: 500)
    let reading = FakeStorageReading(completedDownloadBytes: 500)
    let claiming = FakeStorageEvictionClaiming(rows: [Self.row(id: 1, bytes: 500)])
    let purging = FakeStorageCeilingPurging()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: reading, evictionClaiming: claiming,
      purging: purging)

    let result = await coordinator.enforce()

    #expect(result.capBytes == 500)
    #expect(result.completedBytes == 500)
    #expect(result.targetBytes == 0)
    #expect(result.removed.isEmpty)
    #expect(await claiming.callCount == 0)
    #expect(await purging.events.isEmpty)
    #expect(reading.completedObservationCount == 1)
  }

  @Test func onePassUsesClaimResultsAndSchedulesOnceAfterWholeBatch() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: 100)
    let claiming = FakeStorageEvictionClaiming(rows: [
      Self.row(id: 1, bytes: 120, itemID: 11),
      Self.row(id: 2, bytes: 30, itemID: 12, state: .pending, holdReason: .waitingForWiFi),
    ])
    let purging = FakeStorageCeilingPurging()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: FakeStorageReading(), evictionClaiming: claiming,
      purging: purging)

    let result = await coordinator.enforce(completedBytes: 200)

    #expect(await claiming.targets == [100])
    #expect(result.removedRows == 2)
    #expect(result.removedBytes == 150)
    #expect(result.unmetBytes == 0)
    #expect(await purging.events == [.cancel(2), .delete(1), .delete(2), .schedule])
  }

  @Test func networkHeldClaimIsCancelledBeforeDelete() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: 0)
    let claiming = FakeStorageEvictionClaiming(rows: [
      Self.row(id: 77, bytes: 40, state: .pending, holdReason: .waitingForWiFi)
    ])
    let purging = FakeStorageCeilingPurging()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: FakeStorageReading(), evictionClaiming: claiming,
      purging: purging)

    _ = await coordinator.enforce(completedBytes: 40)

    #expect(await purging.events == [.cancel(77), .delete(77), .schedule])
  }

  @Test func exhaustedCandidatesReportUnmetTargetWithoutReentry() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: 100)
    let claiming = FakeStorageEvictionClaiming(rows: [Self.row(id: 1, bytes: 50)])
    let purging = FakeStorageCeilingPurging()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: FakeStorageReading(), evictionClaiming: claiming,
      purging: purging)

    let result = await coordinator.enforce(completedBytes: 300)

    #expect(await claiming.targets == [200])
    #expect(await claiming.callCount == 1)
    #expect(result.removedBytes == 50)
    #expect(result.unmetBytes == 150)
    #expect(await purging.events == [.delete(1), .schedule])
  }

  @Test func summaryUsesOnlyRowsActuallyDeleted() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: 100)
    let claiming = FakeStorageEvictionClaiming(rows: [Self.row(id: 1, bytes: 120)])
    let purging = FakeStorageCeilingPurging()
    let summary = FakeStorageCeilingSummaryStore()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: FakeStorageReading(), evictionClaiming: claiming,
      purging: purging, summaryStoring: summary)

    let result = await coordinator.enforce(completedBytes: 120)

    #expect(result.removedBytes == 120)
    #expect(
      summary.lastStorageCeilingSummary
        == StorageCeilingEvictionSummary(
          capBytes: 100, removedBytes: 120, removedRows: 1, unmetBytes: 0))
  }

  /// The claim the pass reads is source-qualified. An RSS row routed through an ABS-only fake
  /// would lose its source and delete the wrong table, so this pins the identity the purging
  /// boundary receives.
  @Test func rssClaimKeepsItsSourceThroughCancelAndDelete() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: 100)
    let claiming = FakeStorageEvictionClaiming(rows: [
      Self.row(id: 9, bytes: 120, itemID: 7, episodeID: 11, source: .rss)
    ])
    let purging = FakeStorageCeilingPurging()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: FakeStorageReading(), evictionClaiming: claiming,
      purging: purging)

    let result = await coordinator.enforce(completedBytes: 220)

    #expect(
      result.removed == [
        StorageCeilingRemovedDownload(
          id: 9, itemId: 7, podcastEpisodeId: 11, bytes: 120, source: .rss)
      ])
    #expect(await purging.events == [.deleteRSS(9), .schedule])
  }

  @Test func concurrentPassesCoalesceOntoOneFlight() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: 100)
    let claiming = GatedStorageEvictionClaiming(rows: [Self.row(id: 1, bytes: 100)])
    let purging = FakeStorageCeilingPurging()
    let coordinator = StorageCeilingCoordinator(
      preferences: preferences, storageReading: FakeStorageReading(), evictionClaiming: claiming,
      purging: purging)

    let first = Task { await coordinator.enforce(completedBytes: 200) }
    _ = await TestSupport.awaitCondition(
      "the claiming call to arrive",
      observing: { "callCount \(await claiming.callCount)" },
      until: { await claiming.callCount > 0 })
    let second = Task { await coordinator.enforce(completedBytes: 200) }
    await claiming.release()

    let firstResult = await first.value
    let secondResult = await second.value
    #expect(await claiming.callCount == 1)
    #expect(await purging.events.filter { $0 == .schedule }.count == 1)
    #expect(firstResult == secondResult, "a joiner receives the flight's result, not its own")
    #expect(await coordinator.lastResult == secondResult)
  }

  private static func row(
    id: Int64, bytes: Int64, itemID: Int64 = 1, episodeID: Int64? = nil,
    state: DownloadState = .completed, holdReason: DownloadHoldReason? = nil,
    source: StorageEvictionSource = .abs
  ) -> StorageEvictionClaimedRow {
    StorageEvictionClaimedRow(
      identity: StorageEvictionIdentity(
        source: source, itemId: itemID, episodeId: episodeID, downloadId: id),
      downloadId: id, podcastEpisodeId: episodeID, bytes: bytes, state: state,
      holdReason: holdReason?.rawValue)
  }
}

private actor FakeStorageEvictionClaiming: StorageEvictionClaiming {
  private let rows: [StorageEvictionClaimedRow]
  private(set) var targets: [Int64] = []

  init(rows: [StorageEvictionClaimedRow]) {
    self.rows = rows
  }

  var callCount: Int { targets.count }

  func claimUnion(targetBytes: Int64) async throws -> [StorageEvictionClaimedRow] {
    targets.append(targetBytes)
    return rows
  }
}

private actor GatedStorageEvictionClaiming: StorageEvictionClaiming {
  private let rows: [StorageEvictionClaimedRow]
  private(set) var callCount = 0
  // A parked claim stays parked through task cancellation until `release()`.
  private nonisolated let gate = TestGate<Void>(
    label: "GatedStorageEvictionClaiming claim", ignoresCancellation: true)

  init(rows: [StorageEvictionClaimedRow]) {
    self.rows = rows
    gate.hold()
  }

  func claimUnion(targetBytes: Int64) async throws -> [StorageEvictionClaimedRow] {
    callCount += 1
    await gate.pass()
    return rows
  }

  func release() {
    gate.release()
  }
}

private actor FakeStorageCeilingPurging: StorageCeilingPurging {
  enum Event: Equatable, Sendable {
    case cancel(Int64)
    case delete(Int64)
    case cancelRSS(Int64)
    case deleteRSS(Int64)
    case schedule
  }

  private(set) var events: [Event] = []

  func cancelStorageCeilingDownload(downloadId: Int64) async {
    events.append(.cancel(downloadId))
  }

  func deleteStorageCeilingDownload(downloadId: Int64) async throws {
    events.append(.delete(downloadId))
  }

  func cancelStorageCeilingDownload(identity: StorageEvictionIdentity) async {
    switch identity.source {
    case .abs: events.append(.cancel(identity.downloadId ?? identity.itemId))
    case .rss: events.append(.cancelRSS(identity.downloadId ?? identity.itemId))
    }
  }

  func deleteStorageCeilingDownload(identity: StorageEvictionIdentity) async throws {
    switch identity.source {
    case .abs: events.append(.delete(identity.downloadId ?? identity.itemId))
    case .rss: events.append(.deleteRSS(identity.downloadId ?? identity.itemId))
    }
  }

  func scheduleAfterStorageCeiling() async {
    events.append(.schedule)
  }
}

private final class FakeStorageCeilingSummaryStore: StorageCeilingSummaryStoring, @unchecked Sendable {
  private nonisolated(unsafe) var summary: StorageCeilingEvictionSummary?

  var lastStorageCeilingSummary: StorageCeilingEvictionSummary? {
    return summary
  }

  var storageCeilingSummaryChanges: AsyncStream<StorageCeilingEvictionSummary?> {
    AsyncStream { $0.finish() }
  }

  func storeStorageCeilingSummary(_ summary: StorageCeilingEvictionSummary) async {
    self.summary = summary
  }
}
