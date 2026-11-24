import Foundation
import Persistence

/// Bridges the outbox's stored shape to the sync boundary's value.
///
/// Separate from either type because it is the one place that sees both, like
/// `PodcastCloudInstallationMapping` for the clock: `Persistence` cannot import `SyncEngine`, and
/// `PodcastCloudSyncing.swift` does not import `Persistence`, so the translation sits above both.
extension PodcastCloudPendingWork {
  public init(_ outstanding: PodcastCloudOutstandingWork) {
    self.init(saves: outstanding.saves, deletions: outstanding.deletions)
  }
}

extension PodcastCloudTransportStore {
  /// The outbox's outstanding work as the boundary's value, so a handler can answer
  /// `outstandingWork()` without restating the mapping.
  public func pendingWork(namespace: Data) async throws -> PodcastCloudPendingWork {
    PodcastCloudPendingWork(try await outstandingWork(namespace: namespace))
  }
}
