import ABSApi
import Foundation
import PlayerCore
import SyncEngine

/// Setup needs only `AccountLifecycle`; these inert boundaries keep launch from constructing the
/// authenticated sync, playback-session, network-monitor, and download graphs before login.
nonisolated struct SetupSyncCoordinator: SyncCoordinating {
  func refresh() async {}
  func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
    SearchFanOutResult(matches: [])
  }
}

nonisolated struct SetupPlaybackSync: PlaybackSyncing {
  private struct Unavailable: Error {}

  func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    throw Unavailable()
  }
  func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback? { nil }
  func stopSession() async throws {}
  /// No session exists before setup completes, so there is nothing to renew.
  func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? { nil }
  func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {}
  func willStartPlayback(itemID: String) {}
  func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {}
  func handleAppBackgrounded() async {}
  func recoverOpenSessions() async {}
  func quiesceForLogout() async {}
  func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool = false
  ) async {}
}

nonisolated struct SetupNetworkConditions: NetworkConditions {
  let isLowPowerMode = false
  let isConstrainedOrCellular = false
  let changes = AsyncStream<NetworkConditionsSnapshot> { $0.finish() }
}
