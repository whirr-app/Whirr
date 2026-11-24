import Foundation
import WatchProtocol

/// The Audiobookshelf half of one inventory, for `WatchEpisodeInventoryPlan.make`. The account is
/// the Watch's own when it wrote the entries: the phone applies them only when it matches its
/// authenticated account.
public struct WatchABSInventoryHalf: Sendable, Equatable {
  public let accountStamp: WatchAccountStamp
  public let acknowledgedGeneration: UInt64
  public let entries: [WatchABSInventoryEntry]

  public init(accountStamp: WatchAccountStamp, acknowledgedGeneration: UInt64, entries: [WatchABSInventoryEntry]) {
    self.accountStamp = accountStamp
    self.acknowledgedGeneration = acknowledgedGeneration
    self.entries = entries
  }
}

/// Maps a download group onto the wire's Audiobookshelf inventory entry, whose state, decline and
/// failure vocabularies are the RSS entry's, so the phone has one mapping to its statuses.
public enum WatchABSInventoryProjection {
  /// `nil` for a native selection, which the Audiobookshelf store never holds.
  public static func entry(for group: WatchDownloadGroup) throws -> WatchABSInventoryEntry? {
    guard case .audiobookshelf(let itemID, let episodeID) = group.selection else { return nil }
    let selection = try WatchABSSelection(itemID: itemID, episodeID: episodeID)
    let revision = group.origin == .phone ? group.phoneRevision.flatMap { $0 > 0 ? $0 : nil } : nil
    let origin: WatchABSOrigin = revision == nil ? .watch : .phone
    let trackCount = min(max(0, group.expectedTrackCount), WatchABSSendLimits.maxTrackCount)
    let completed = min(max(0, group.completedTrackCount), trackCount)
    func entry(
      _ state: WatchABSInventoryEntry.State, completedTracks: Int? = nil,
      declineReason: WatchABSInventoryEntry.DeclineReason? = nil,
      failureReason: WatchABSInventoryEntry.FailureReason? = nil, progress: Double? = nil,
      committedBytes: Int64? = nil
    ) throws -> WatchABSInventoryEntry {
      try WatchABSInventoryEntry(
        selection: selection, revision: revision, origin: origin, state: state, trackCount: trackCount,
        completedTracks: completedTracks ?? completed, declineReason: declineReason, failureReason: failureReason,
        progress: progress, committedBytes: committedBytes)
    }
    switch group.state {
    case .ready:
      return try entry(.ready, completedTracks: trackCount, committedBytes: committedBytes(of: group))
    case .enqueuing, .waiting:
      return try entry(.receiving)
    case .downloading:
      return try entry(.downloading, progress: group.progress)
    case .waitingForNetwork:
      return try entry(.waitingForNetwork)
    case .failed:
      return try entry(.failed, failureReason: failureReason(group.failureReason))
    case .declined:
      return try entry(.declined, declineReason: .storageFull)
    }
  }

  /// The ABS manifest's own failure vocabulary on the phone's. A transfer that was cut off is a
  /// network failure; a refused sign-in is the server's answer, as an HTTP status is for RSS.
  public static func failureReason(
    _ reason: WatchDownloadFailureReason?
  ) -> WatchABSInventoryEntry.FailureReason {
    switch reason {
    case .transport, .interrupted, .cancelled, .waitingForWiFi: return .network
    case .unauthorized: return .httpStatus
    case .validation, .storage, .quota, nil: return .invalidResponse
    }
  }

  /// What the completed files measured, or what the plan declared when a file recorded nothing.
  private static func committedBytes(of group: WatchDownloadGroup) -> Int64 {
    let measured = group.receivedBytes > 0 ? group.receivedBytes : (group.expectedBytes ?? 1)
    return min(max(1, measured), WatchABSSendLimits.maxItemBytes)
  }
}
