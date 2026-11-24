import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine

/// Starts a list's episode through playback and records the run, so a row or Play on a list's
/// screen begins that list's run only once the start succeeded.
@MainActor
final class SmartListPlaybackAdapter: SmartListPlaybackStarting {
  private let playback: PlaybackModel

  init(playback: PlaybackModel) {
    self.playback = playback
  }

  func startFromList(listID: Int64, itemID: String, episodeID: String) async -> Bool {
    await playback.startReportingSuccess(
      itemID: itemID, episodeID: episodeID, run: .begin(listID: listID))
  }
}

extension AppEnvironment {
  /// The models the Smart Lists surfaces use, bound to this environment's playback. Nil on the
  /// setup and removal graphs, which compose no smart-list services.
  func makeSmartListsAccess(playback: PlaybackModel) -> SmartListsAccess? {
    smartListServices.map {
      SmartListsAccess(services: $0, playback: SmartListPlaybackAdapter(playback: playback))
    }
  }

  /// The persistence and source services behind Smart Lists. The native preference is the same
  /// device-owned instance that gates the rest of Podcasts. `expand` fills a list's named
  /// Audiobookshelf shows in the foreground right after a save, through the same coordinator the
  /// background pass uses. The active run comes from the run row, and a delete goes through the
  /// download reconciler so the list's claimed downloads are released before its rows cascade.
  static func makeSmartListServices(
    database: AppDatabase,
    nativeSubscriptions: any NativePodcastSubscriptionsReading,
    client: ABSClient,
    showRefresh: PodcastRefreshCoordinator,
    downloads: SmartListDownloadReconciler
  ) -> SmartListServices {
    let runs = SmartListRunStore(database: database)
    let expansion = SmartListShowExpansion(
      database: database, client: client, showRefresh: showRefresh)
    return SmartListServices(
      database: database,
      subscriptions: nativeSubscriptions,
      accountIdentity: DefaultAccountIdentityReading(database: database),
      showCatalog: DefaultSmartListShowCatalogReading(database: database),
      expand: { listID in _ = await expansion.expand(listID: listID) },
      observeActiveRunListID: {
        let records = runs.observeCurrent()
        return AsyncStream { continuation in
          let task = Task {
            for await record in records { continuation.yield(record?.listId) }
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      },
      deleteList: { listID in try await downloads.deleteList(listID) })
  }
}
