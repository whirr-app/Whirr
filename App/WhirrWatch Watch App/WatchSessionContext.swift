import Foundation
import WatchPlayback
import WatchProtocol

/// One account identity and service graph, shared by every controller until teardown completes.
@MainActor
struct WatchSessionContext {
  let account: WatchAccountRecord
  let authenticatedStamp: WatchAccountStamp
  let epoch: Int
  let libraryClient: WatchLibraryClient
  let service: ABSWatchLibraryService
  let coordinator: WatchPlaybackSessionCoordinator
  let downloadStore: WatchDownloadStore
  let progressStore: WatchOfflineProgressStore
  let downloadManager: WatchDownloadManager
  /// The one 2 GB ceiling the Audiobookshelf and received-episode stores both claim against.
  var storageBudget: WatchStorageBudget?
  /// Native-RSS copies and their progress. Both are absent when their storage cannot open, which
  /// leaves the feature out for this session and the Audiobookshelf stores unchanged.
  var receivedEpisodes: WatchReceivedEpisodeStore?
  var nativeJournal: WatchNativeProgressJournal?
}

/// Cancellation supplements the session epoch; an already delivered reply still needs fencing.
@MainActor
final class WatchSessionLifecycle {
  var initialization: Task<Void, Never>?
  var restore: Task<Void, Never>?
  var install: Task<Void, Never>?
  var offlineTimer: Task<Void, Never>?
  var reconciliation: Task<Void, Never>?
  /// The last fire-and-forget pause ask the phone, owned here so logout cancels it.
  var peerHandoff: Task<Void, Never>?

  isolated deinit { cancelAll() }

  func cancelAll() {
    initialization?.cancel()
    restore?.cancel()
    install?.cancel()
    offlineTimer?.cancel()
    reconciliation?.cancel()
    peerHandoff?.cancel()
    initialization = nil
    restore = nil
    install = nil
    offlineTimer = nil
    reconciliation = nil
    peerHandoff = nil
  }
}
