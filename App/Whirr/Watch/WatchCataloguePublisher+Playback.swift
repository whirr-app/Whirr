import AppModel
import Foundation
import Observation
import Persistence
import PlayerCore
import WatchProtocol

/// Playback observation and the values a publication reads from it: the state, the playhead's
/// retention rule, and whether an observed change was only the playhead ticking.
extension WatchCataloguePublisher {
  /// A change in anything but the playhead publishes at once. A tick leaves a pending publication
  /// alone (it captures the position when it runs) and otherwise waits out the position-only
  /// interval, so it can never delay or replace a state change's publication.
  func playbackDidChange() {
    guard started, identity != nil, let playback else { return }
    let fingerprint = PlaybackFingerprint(
      phase: playback.phase, activeItemID: playback.activeItemID, activeEpisodeID: playback.activeEpisodeID,
      loadedItemID: playback.loadedItemID, loadedEpisodeID: playback.loadedEpisodeID,
      displayedItemID: playback.displayedItem?.serverItemId, displayedEpisodeID: playback.displayedItem?.episodeID,
      displayedTitle: playback.displayedItem?.title, rate: playback.playbackRate,
      chapterStart: playback.companionPlaybackProgress?.chapter?.start)
    guard fingerprint == lastPlaybackFingerprint else {
      lastPlaybackFingerprint = fingerprint
      refresh()
      return
    }
    if let publishedPlayhead, let position = playback.companionPlaybackProgress?.position,
      publishedPlayhead.isDeparted(by: position, at: now())
    {
      refresh()
      return
    }
    guard publicationTask == nil, assemblyTask == nil else { return }
    schedulePublication(publicationEpoch: publicationEpoch, interval: Self.positionOnlyPublicationInterval)
  }

  func observePlayback(publicationEpoch: UInt64) {
    guard started, self.publicationEpoch == publicationEpoch, let playback else { return }
    withObservationTracking {
      _ = playback.phase
      _ = playback.activeItemID
      _ = playback.activeEpisodeID
      _ = playback.loadedItemID
      _ = playback.loadedEpisodeID
      _ = playback.displayedItem
      _ = playback.displayedItemPositionSeconds
      _ = playback.playbackRate
      _ = playback.companionPlaybackProgress
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.started, self.publicationEpoch == publicationEpoch else { return }
        self.playbackDidChange()
        self.observePlayback(publicationEpoch: publicationEpoch)
      }
    }
  }

  func currentPlaybackState() -> WatchPlaybackState {
    guard let playback else { return .idle }
    if audioActivationWasRefused() { return .unresolved }
    switch playback.phase {
    case .idle, .ended: return .idle
    case .preparing, .buffering, .seeking: return .preparing
    case .paused: return .paused
    case .playing: return .playing
    case .stalled, .recoverableError, .unrecoverableError: return .failed
    }
  }

  /// `displayedItem` with the retained position as of the latest save: the bookmark alone is
  /// republished only when something besides its position changes.
  static func retainedBookmark(of playback: PlaybackModel) -> PlaybackBookmark? {
    guard let item = playback.displayedItem else { return nil }
    return PlaybackBookmark(
      serverItemId: item.serverItemId, episodeID: item.episodeID,
      episodeTitle: item.episodeTitle, showTitle: item.showTitle, title: item.title,
      author: item.author, durationSeconds: item.durationSeconds,
      positionSeconds: playback.displayedItemPositionSeconds, isFinished: item.isFinished)
  }

  func effectiveBookmark() -> PlaybackBookmark? {
    guard let bookmark = playback.flatMap(Self.retainedBookmark(of:)) ?? bookmark else { return nil }
    if let playback, let activeItemID = playback.activeItemID {
      guard bookmark.serverItemId == activeItemID, bookmark.episodeID == playback.activeEpisodeID else {
        // The persisted bookmark may still describe the previous item during preparation.
        return nil
      }
    }
    if !nativeEnabled {
      guard let source = PodcastSourceIdentity(itemId: bookmark.serverItemId) else {
        return nil
      }
      if case .rss = source.source { return nil }
    }
    return bookmark
  }
}
