import Persistence

/// The actions selected for an episode's leading and trailing swipe edges. Presentation details
/// remain in the App target. There is no surface parameter because swipe never emits `.openShow`,
/// the only action suppressed on one podcast menu surface. Swipe presents only the
/// first eligible progress action so its compact two-capsule design stays stable; eligibility and
/// ordering still come from the same policy as every long-press and player menu.
public enum PodcastEpisodeSwipeActions {
  public struct Actions: Sendable, Equatable {
    public let leading: [MediaItemAction]
    public let trailing: [MediaItemAction]
    /// Whether a leading `.playPause` pauses this row rather than starting it. The action is one
    /// toggle in the menu vocabulary, but a swipe capsule names what the tap will do.
    public let pausesPlayback: Bool
  }

  public static func actions(
    deviceAction: ItemContextMenuDownloadAction,
    isAvailableOnServer: Bool,
    playbackStatus: ItemPlaybackStatus?,
    identity: ListeningIdentity?,
    nowPlaying: ListeningIdentity?,
    isPlaybackIntended: Bool
  ) -> Actions {
    // The rule itself lives in `MediaSwipePromotion` so the Saved for Later shelf inherits it
    // rather than re-deriving it; only the mapping to this surface's action vocabulary is here.
    let promotion = MediaSwipePromotion.leading(
      identity: identity, nowPlaying: nowPlaying, isPlaybackIntended: isPlaybackIntended)
    let leading: [MediaItemAction] =
      switch promotion {
      case .play, .pause: [.playPause]
      case .playNext: [.playNext]
      case nil: []
      }

    // Coarse: swipe removes any present download, unlike the fine-grained inline
    // control represented by PodcastShowPresentation.primaryDeviceAction.
    let device: [MediaItemAction]
    switch deviceAction {
    case .download:
      device = isAvailableOnServer ? [.download] : []
    case .remove:
      device = [.removeDownload]
    case .unavailable:
      device = []
    }

    let progress = MediaProgressActionPolicy.actions(for: playbackStatus).prefix(1).map { action in
      switch action {
      case .markAsFinished: MediaItemAction.markAsFinished
      case .resetProgress: MediaItemAction.resetProgress
      case .removeFromContinueListening: MediaItemAction.removeFromContinueListening
      }
    }
    return Actions(
      leading: leading, trailing: device + progress, pausesPlayback: promotion == .pause)
  }
}
