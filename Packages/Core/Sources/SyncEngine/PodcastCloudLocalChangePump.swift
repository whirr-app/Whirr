import Foundation
import Persistence

/// Feeds the outbox from the v70 dirty log while its task lives. Each log change is followed,
/// after a debounce that collapses a burst of edits onto one drain, by `publishLocalChanges()`.
/// The coordinator ignores it until its session is running; the log waits, and `enable` drains
/// what accumulated. Stateless, so safe to cancel at any point.
public enum PodcastCloudLocalChangePump {
  public static let defaultDebounce: Duration = .seconds(2)

  public static func run(
    database: AppDatabase,
    coordinator: PodcastCloudSyncCoordinator,
    debounce: Duration = defaultDebounce,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async {
    for await pending in PodcastCloudDirtyLog.observePending(in: database) where pending {
      do {
        try await sleep(debounce)
      } catch {
        return
      }
      await coordinator.publishLocalChanges()
    }
  }
}

/// The refresh path's view of cloud sync: told once a feed refresh has committed its episodes, so
/// held remote state can find the episodes it names. Defined here because `AppModel`, which owns
/// the refresh path, sits above `SyncEngine`.
public protocol PodcastRefreshCommitObserving: Sendable {
  func feedRefreshCommitted(feedId: Int64) async
}

extension PodcastCloudSyncCoordinator: PodcastRefreshCommitObserving {
  /// A failure is not the refresh's failure: held state stays held, and the next refresh or
  /// admission of the same feed retries it.
  public func feedRefreshCommitted(feedId: Int64) async {
    _ = try? await resolveEpisodeStates(afterRefreshOf: feedId)
  }
}
