import CoreSupport
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

extension PlaybackModel {

  // MARK: - Progress events (display synchronously; forwarded to sync once, in order)

  internal func ingest(progressEvent event: PlaybackProgressEvent) -> PlaybackEventBridge.Envelope? {
    guard isLoadedTarget(of: event) else { return nil }

    apply(displayEvent: event)
    if event.listenedDelta > 0 { lastListen = (itemID: event.itemId, episodeID: event.episodeID, at: Date()) }
    noteSkip(in: event)
    noteTrimmed(in: event)
    noteTimeSaved(in: event)
    return PlaybackEventBridge.Envelope(event: event, modelGeneration: playbackGeneration)
  }

  internal func isCurrent(_ envelope: PlaybackEventBridge.Envelope) -> Bool {
    envelope.modelGeneration == playbackGeneration && isLoadedTarget(of: envelope.event)
  }

  /// The model is live, the item it loaded is still the active one, and the event names it.
  private func isLoadedTarget(of event: PlaybackProgressEvent) -> Bool {
    isQuiescedForLogout == false
      && loadedPlaybackGeneration == playbackGeneration
      && activeItemID != nil
      && loadedItemID != nil
      && event.itemId == loadedItemID
      && event.episodeID == loadedEpisodeID
      && activeItemID == loadedItemID
      && activeEpisodeID == loadedEpisodeID
  }

  private func apply(displayEvent event: PlaybackProgressEvent) {
    let rate = player.state.rate
    setPlaybackRate(rate)
    let nextPhase = Self.mapPhase(event.phase)
    if phase != nextPhase {
      setPhase(nextPhase)
      if nextPhase == .stalled, Self.shouldProbeABSReachability(for: event.itemId) {
        requestReachabilityProbe()
      }
    }
    setCurrentTime(event.currentTime)
    #if DEBUG
      // Diagnostic timeline for playback bug hunts: an exact, ordered phase/position trace of what
      // the display state machine did, streamed via
      // `log stream --predicate 'eventMessage CONTAINS "WHIRRPERF"'`. DEBUG-only; never in release.
      DeviceTraceLog.emit(
        "WHIRRPERF seq=\(event.sequence) phase=\(String(describing: event.phase)) "
          + "t=\(String(format: "%.2f", event.currentTime)) "
          + "intended=\(player.state.isPlaybackIntended ? 1 : 0) "
          + "delta=\(String(format: "%.3f", event.listenedDelta))")
    #endif
  }

  internal func handleLocalTimerExpiry(_ envelope: PlaybackEventBridge.Envelope) {
    guard isCurrent(envelope) else { return }
    if envelope.event.episodeID == nil { onBookSleepTimerPause?() }
    guard isStreamingSource == false else { return }
    freshLocalSessionOnNextPlay = (
      itemID: envelope.event.itemId, episodeID: envelope.event.episodeID
    )
  }

  internal func handleBufferingProbeElapsed(_ token: PlaybackEventBridge.BufferingProbeToken) {
    guard isQuiescedForLogout == false,
      playbackGeneration == token.modelGeneration,
      phase == .buffering,
      isStreamingSource,
      loadedItemID == token.itemID,
      loadedEpisodeID == token.episodeID,
      Self.shouldProbeABSReachability(for: token.itemID)
    else { return }
    requestReachabilityProbe()
  }

  private static func shouldProbeABSReachability(for itemID: String?) -> Bool {
    guard let itemID else { return false }
    switch PodcastSourceIdentity(itemId: itemID)?.source {
    case .rss:
      return false
    case .abs:
      return true
    case nil:
      return false
    }
  }
}
