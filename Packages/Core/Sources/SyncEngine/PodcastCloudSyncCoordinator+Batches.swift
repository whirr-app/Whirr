import Foundation
import Persistence

/// The batch supplier: ordered, byte-aware, and closed whenever sending is not allowed.
extension PodcastCloudSyncCoordinator {
  /// Answers `nil` while the barrier is closed, signed out, after zone loss and while paused for
  /// quota. The store also refuses a closed barrier or stale namespace (two locks on one door).
  ///
  /// Order comes from the outbox read: global settings, subscriptions, feed settings, identity
  /// records, then episode state and saves, so a receiving device sees parents before children.
  /// Ceilings are the smaller of the engine's limits and the adaptive record ceiling
  /// `limitExceeded` lowers. A record that cannot be sent (undecodable, or over the per-record
  /// ceiling by estimate) is held at its generation rather than failing every batch.
  public func nextBatch(within limits: PodcastCloudBatchLimits) async -> PodcastCloudRecordBatch? {
    guard phase == .running, quotaPaused == false, let namespace else { return nil }
    let recordLimit = min(limits.maximumRecords, recordCeiling)
    guard recordLimit > 0, limits.maximumBytes > 0 else { return nil }
    guard
      let sends = try? await transport.pendingSends(
        namespace: namespace, maximumRecords: PodcastCloudBatchLimits.standard.maximumRecords,
        maximumBytes: PodcastCloudBatchLimits.standard.maximumBytes)
    else { return nil }

    var saves: [PodcastCloudRecordFields] = []
    var deletions: [String] = []
    var archives: [String: Data] = [:]
    var claimed: [PodcastCloudPendingSend] = []
    var bytes = 0
    for send in sends {
      // Already handed to the engine and not yet reported on. Offering it again would send the
      // same generation twice in one pass.
      if let flying = inFlight[send.recordName], flying.generation == send.generation { continue }
      guard claimed.count < recordLimit else { break }
      if send.isPhysicalDeletion {
        deletions.append(send.recordName)
        claimed.append(send)
        continue
      }
      guard let fields = try? PodcastCloudRecordPayload.decode(send.payload),
        fields.recordName == send.recordName
      else {
        try? await hold(send.recordName, send: send, category: .malformed)
        continue
      }
      let size = PodcastCloudRecordMerge.estimatedBytes(of: fields)
      guard size <= limits.maximumRecordBytes else {
        try? await hold(send.recordName, send: send, category: .recordTooLarge)
        continue
      }
      guard bytes + size <= limits.maximumBytes else { break }
      bytes += size
      saves.append(fields)
      if let archive = send.systemFields { archives[send.recordName] = archive }
      claimed.append(send)
    }

    let batch = PodcastCloudRecordBatch(saves: saves, deletions: deletions, systemFields: archives)
    guard batch.isEmpty == false else { return nil }
    for send in claimed { inFlight[send.recordName] = send }
    return batch
  }

  /// Names only, for seeding a newly constructed engine . Gated like `nextBatch`: a
  /// bootstrap engine is told of nothing, because it may send nothing.
  public func outstandingWork() async -> PodcastCloudPendingWork {
    guard phase == .running, let namespace else { return .none }
    return (try? await transport.pendingWork(namespace: namespace)) ?? .none
  }
}
