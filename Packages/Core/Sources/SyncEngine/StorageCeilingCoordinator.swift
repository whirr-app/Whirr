import Foundation
import Persistence

/// The deletion boundary the storage-ceiling pass needs from `DownloadCoordinator`. The pass
/// does not depend on `DownloadIntents`: the claim has already made every row
/// `.deleting`, and scheduling must happen only once after the whole batch.
public protocol StorageCeilingPurging: Sendable {
  func cancelStorageCeilingDownload(downloadId: Int64) async
  func deleteStorageCeilingDownload(downloadId: Int64) async throws
  func cancelStorageCeilingDownload(identity: StorageEvictionIdentity) async
  func deleteStorageCeilingDownload(identity: StorageEvictionIdentity) async throws
  func scheduleAfterStorageCeiling() async
}

extension StorageCeilingPurging {
  public func cancelStorageCeilingDownload(identity: StorageEvictionIdentity) async {
    guard identity.source == .abs else { return }
    await cancelStorageCeilingDownload(downloadId: identity.downloadId ?? identity.itemId)
  }

  public func deleteStorageCeilingDownload(identity: StorageEvictionIdentity) async throws {
    guard identity.source == .abs else { return }
    try await deleteStorageCeilingDownload(downloadId: identity.downloadId ?? identity.itemId)
  }
}

extension DownloadCoordinator: StorageCeilingPurging {}

/// Default seam for compositions that have not wired the real download coordinator yet.
public struct NoOpStorageCeilingPurging: StorageCeilingPurging, Sendable {
  public init() {}
  public func cancelStorageCeilingDownload(downloadId: Int64) async {}
  public func deleteStorageCeilingDownload(downloadId: Int64) async throws {}
  public func scheduleAfterStorageCeiling() async {}
}

/// One pre-mark row returned by the atomic eviction claim. These are the bytes the pass reports;
/// candidate projections are not carried into the result.
public struct StorageCeilingRemovedDownload: Identifiable, Sendable, Equatable {
  public let id: Int64
  public let source: StorageEvictionSource
  public let itemId: Int64
  public let podcastEpisodeId: Int64?
  public let bytes: Int64

  public init(
    id: Int64, itemId: Int64, podcastEpisodeId: Int64?, bytes: Int64,
    source: StorageEvictionSource = .abs
  ) {
    self.id = id
    self.source = source
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.bytes = bytes
  }
}

/// The bounded outcome of one ceiling pass. `removed` is derived only from rows returned by the
/// atomic claim, so a caller never reports bytes from a candidate estimate that was invalidated
/// before marking.
public struct StorageCeilingPassResult: Sendable, Equatable {
  public let capBytes: Int64?
  public let completedBytes: Int64?
  public let targetBytes: Int64
  public let removed: [StorageCeilingRemovedDownload]
  public let unmetBytes: Int64

  public init(
    capBytes: Int64?, completedBytes: Int64?, targetBytes: Int64,
    removed: [StorageCeilingRemovedDownload], unmetBytes: Int64
  ) {
    self.capBytes = capBytes
    self.completedBytes = completedBytes
    self.targetBytes = targetBytes
    self.removed = removed
    self.unmetBytes = unmetBytes
  }

  public static let unlimited = StorageCeilingPassResult(
    capBytes: nil, completedBytes: nil, targetBytes: 0, removed: [], unmetBytes: 0)

  public var removedRows: Int { removed.count }
  public var removedBytes: Int64 { removed.reduce(into: 0) { $0 += $1.bytes } }
  public var reachedTarget: Bool { unmetBytes == 0 }
}

/// The durable, user-visible result of an automatic ceiling pass. Every byte in this projection
/// comes from a row the coordinator actually finished deleting, never from the candidate query's
/// projected total.
public struct StorageCeilingEvictionSummary: Codable, Sendable, Equatable {
  public let capBytes: Int64
  public let removedBytes: Int64
  public let removedRows: Int
  public let unmetBytes: Int64

  public init(
    capBytes: Int64, removedBytes: Int64, removedRows: Int, unmetBytes: Int64
  ) {
    self.capBytes = capBytes
    self.removedBytes = removedBytes
    self.removedRows = removedRows
    self.unmetBytes = unmetBytes
  }

  public var reachedTarget: Bool { unmetBytes == 0 }
}

/// Read side of the last automatic ceiling result. The synchronous value is read at model
/// construction; the stream carries later passes in the same process.
public protocol StorageCeilingSummaryReading: Sendable {
  var lastStorageCeilingSummary: StorageCeilingEvictionSummary? { get }
  var storageCeilingSummaryChanges: AsyncStream<StorageCeilingEvictionSummary?> { get }
}

/// Persistence side of the ceiling result. This is separate from `StorageReading`:
/// the summary is a policy result, not a projection of candidate or download-row accounting.
public protocol StorageCeilingSummaryStoring: StorageCeilingSummaryReading {
  func storeStorageCeilingSummary(_ summary: StorageCeilingEvictionSummary) async
}

public struct NoOpStorageCeilingSummaryStore: StorageCeilingSummaryStoring, Sendable {
  public init() {}

  public var lastStorageCeilingSummary: StorageCeilingEvictionSummary? { nil }

  public var storageCeilingSummaryChanges: AsyncStream<StorageCeilingEvictionSummary?> {
    AsyncStream { $0.finish() }
  }

  public func storeStorageCeilingSummary(_ summary: StorageCeilingEvictionSummary) async {}
}

/// One-shot storage-ceiling pass. A caller may supply the completed-byte value that triggered it;
/// a foreground or manual call with no value reads the first value from the completed-byte
/// observation. The cap is read before that observation so an unlimited cap does nothing at all.
public actor StorageCeilingCoordinator: CoalescedPassHost {
  private let preferences: any DownloadPreferences
  private let storageReading: any StorageReading
  private let evictionClaiming: any StorageEvictionClaiming
  private let purging: any StorageCeilingPurging
  private let summaryStoring: any StorageCeilingSummaryStoring

  var passSlot = CoalescedPassSlot<StorageCeilingPassResult>()
  public private(set) var lastResult: StorageCeilingPassResult?

  public init(
    preferences: any DownloadPreferences,
    storageReading: any StorageReading,
    evictionClaiming: any StorageEvictionClaiming,
    purging: any StorageCeilingPurging = NoOpStorageCeilingPurging(),
    summaryStoring: any StorageCeilingSummaryStoring = NoOpStorageCeilingSummaryStore()
  ) {
    self.preferences = preferences
    self.storageReading = storageReading
    self.evictionClaiming = evictionClaiming
    self.purging = purging
    self.summaryStoring = summaryStoring
  }

  /// Runs at most one bounded pass. Concurrent callers await the same in-flight pass.
  @discardableResult
  public func enforce(completedBytes: Int64? = nil) async -> StorageCeilingPassResult {
    let outcome = await runCoalescedPass(policy: .shareInFlight) {
      await self.perform(completedBytes: completedBytes)
    }
    if outcome.startedFlight {
      lastResult = outcome.value
    }
    return outcome.value
  }

  private func perform(completedBytes suppliedCompletedBytes: Int64?) async
    -> StorageCeilingPassResult
  {
    guard let capBytes = preferences.storageCeilingBytes else {
      return .unlimited
    }

    let completedBytes: Int64
    if let suppliedCompletedBytes {
      completedBytes = suppliedCompletedBytes
    } else {
      completedBytes = await readCompletedBytes()
    }
    guard completedBytes > capBytes else {
      return StorageCeilingPassResult(
        capBytes: capBytes, completedBytes: completedBytes, targetBytes: 0,
        removed: [], unmetBytes: 0)
    }

    let targetBytes = completedBytes - capBytes
    let claimed: [StorageEvictionClaimedRow]
    do {
      // One claim only. If the candidate list is exhausted, the result below reports the
      // remaining target; this pass never calls back into claim to chase a moving total.
      claimed = try await evictionClaiming.claimUnion(targetBytes: targetBytes)
    } catch {
      // A failed claim still gets the one trailing scheduling opportunity. The durable database
      // transaction is the source of truth, so no bytes are reported when no claim was returned.
      await purging.scheduleAfterStorageCeiling()
      return StorageCeilingPassResult(
        capBytes: capBytes, completedBytes: completedBytes, targetBytes: targetBytes,
        removed: [], unmetBytes: targetBytes)
    }

    // These snapshots are pre-mark state. Cancellation therefore happens before any file delete,
    // including pending Wi-Fi-held rows whose adapter task is not represented by `.downloading`.
    for row in claimed {
      let isNetworkHeld = row.state == .pending && row.holdReason == DownloadHoldReason.waitingForWiFi.rawValue
      guard row.state == .downloading || isNetworkHeld else { continue }
      let identity = StorageEvictionIdentity(
        source: row.identity.source, itemId: row.identity.itemId,
        episodeId: row.podcastEpisodeId, downloadId: row.downloadId)
      await purging.cancelStorageCeilingDownload(identity: identity)
    }

    var removed: [StorageCeilingRemovedDownload] = []
    for row in claimed {
      // A claim has already made this row `.deleting`; the narrow boundary's implementation owns
      // the idempotent file removal followed by `finalizeDeletion`, without scheduling per row.
      do {
        let identity = StorageEvictionIdentity(
          source: row.identity.source, itemId: row.identity.itemId,
          episodeId: row.podcastEpisodeId, downloadId: row.downloadId)
        try await purging.deleteStorageCeilingDownload(identity: identity)
        removed.append(
          StorageCeilingRemovedDownload(
            id: row.downloadId, itemId: row.identity.itemId, podcastEpisodeId: row.podcastEpisodeId,
            bytes: row.bytes, source: row.identity.source))
      } catch {
        // The row remains `.deleting` for DownloadIntegritySweep. It is not reported as removed
        // until the file/row boundary has completed, so unmet bytes stay visible.
      }
    }
    let removedBytes = removed.reduce(into: Int64(0)) { $0 += $1.bytes }
    let unmetBytes = max(0, targetBytes - removedBytes)

    // Exactly one trailing schedule for the entire claimed batch, including an exhausted batch.
    await purging.scheduleAfterStorageCeiling()
    let result = StorageCeilingPassResult(
      capBytes: capBytes, completedBytes: completedBytes, targetBytes: targetBytes,
      removed: removed, unmetBytes: unmetBytes)
    if result.removed.isEmpty == false {
      await summaryStoring.storeStorageCeilingSummary(
        StorageCeilingEvictionSummary(
          capBytes: capBytes,
          removedBytes: result.removedBytes,
          removedRows: result.removedRows,
          unmetBytes: result.unmetBytes))
    }
    return result
  }

  private func readCompletedBytes() async -> Int64 {
    var iterator = storageReading.observeCompletedDownloadTotals().makeAsyncIterator()
    return await iterator.next() ?? 0
  }
}
