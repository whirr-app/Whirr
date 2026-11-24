import AppModel
import DesignSystem
import Persistence

nonisolated extension PodcastShowViewPresentation {
  struct Episode: Equatable {
    let id: String
    let title: String
    let synopsis: String?
    let dateText: String
    let durationText: String
    let progressText: String
    let playbackProgressFraction: Double?
    let playbackStatus: PodcastEpisodePlaybackStatus
    let playbackStatusText: String
    let serverAvailability: PodcastServerAudioAvailability
    let serverAvailabilityText: String
    let deviceStatus: PodcastEpisodeDeviceDownloadStatus
    /// The trailing download control's tap, or `nil` for states with none. One of `actions` except
    /// in `.failed`, where it is `PodcastDownloadFailurePresentation.control` (its alert retries).
    let downloadAction: MediaContextAction?
    /// The canonical menu groups after surface suppression and data-dependent omissions. The
    /// boundaries are kept (not flattened for `PodcastEpisodeRowView`) so the show row renders the
    /// same separators as episode cards on Home and Podcasts.
    let actionSections: [[MediaContextAction]]
    /// Every choosable row in menu order, a submenu's choices in its place.
    var actions: [MediaContextAction] {
      actionSections.joined().flatMap { $0.isSubmenu ? $0.children : [$0] }
    }
  }

  /// `queueAvailability` is resolved once per list, as this runs at row-body time on the scroll
  /// path (see `contextAction`'s `.playPause` note). `progressSeconds` comes from
  /// `PlaybackModel.displayedPositionSeconds`; default is the persisted position.
  /// `offersTranscript` is whether the app can open transcripts at all; the menu also needs the
  /// download.
  static func episode(
    _ episode: PodcastEpisodeSummary,
    progressSeconds: Double? = nil,
    creator: String? = nil,
    isSaved: Bool? = nil,
    queueAvailability: ListeningQueueActionAvailability,
    isCurrentlyPlaying: Bool = false,
    isHidden: Bool = false,
    serverSave: NativeEpisodeServerSaveAvailability = .hidden,
    serverRemove: NativeEpisodeServerSaveAvailability = .hidden,
    offersTranscript: Bool = false,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) -> Episode {
    let policy = PodcastShowPresentation.episode(
      episode, surface: PodcastMenuBearingSurface.podcastShowEpisodeRow.menuSurface, isSaved: isSaved,
      serverSave: serverSave, serverRemove: serverRemove, watchCopy: watchCopy)
    // The same derivation the cross-show card rows read, so the two rows cannot disagree.
    let listening = PodcastEpisodeListeningState(
      progressSeconds: progressSeconds ?? episode.progressSeconds,
      durationSeconds: episode.durationSeconds, isFinished: episode.isFinished)
    let playbackStatus = Self.playbackStatus(for: listening.playbackStatus)
    let playbackStatusText =
      switch playbackStatus {
      case .played: PodcastCopy.played
      case .inProgress: "In progress"
      case .unplayed: PodcastCopy.notPlayed
      }
    let serverAvailability: PodcastServerAudioAvailability =
      policy.serverAvailability == .available ? .available : .unavailable
    let actionSections = PodcastShowPresentation.episodeActionSections(
      status: episode.downloadStatus,
      isAvailableOnServer: episode.isAvailableOnServer,
      surface: PodcastMenuBearingSurface.podcastShowEpisodeRow.menuSurface,
      isSaved: isSaved,
      playbackStatus: listening.playbackStatus,
      isCurrentlyPlaying: isCurrentlyPlaying,
      isHidden: isHidden,
      serverSave: serverSave,
      serverRemove: serverRemove,
      offersTranscript: offersTranscript,
      watchCopy: watchCopy
    ).compactMap { section in
      let actions = ItemContextMenuPresentation.foldedRows(
        ListeningQueueActionPolicy
          .apply(queueAvailability, to: section.actions)
          .compactMap { action in
            let availability: NativeEpisodeServerSaveAvailability? =
              switch action {
              case .saveToServer: serverSave
              case .removeFromServer: serverRemove
              default: nil
              }
            return contextAction(action, creator: creator, availability: availability)
              .map { (action, $0) }
          })
      return actions.isEmpty ? nil : actions
    }

    return Episode(
      id: episode.id,
      title: episode.title.isEmpty ? PodcastCopy.untitledEpisode : episode.title,
      synopsis: policy.synopsis,
      dateText: policy.episode.dateText,
      durationText: policy.episode.durationText,
      progressText: listening.progressText,
      playbackProgressFraction: listening.progressFraction,
      playbackStatus: playbackStatus,
      playbackStatusText: playbackStatusText,
      serverAvailability: serverAvailability,
      serverAvailabilityText: policy.serverAvailabilityText,
      deviceStatus: deviceStatus(
        for: episode.downloadStatus, isDownloadSizeKnown: episode.isDownloadSizeKnown),
      downloadAction: PodcastDownloadFailurePresentation.control(for: episode.downloadStatus)
        ?? policy.primaryDeviceAction.flatMap { contextAction($0, creator: creator) },
      actionSections: actionSections)
  }

  /// The row tap presents the episode card rather than playing it. Quick play stays in the
  /// long-press menu and ellipsis (`.playPause` is in `episode(_:creator:).actions`) and the
  /// card's own button. A pure ref-builder so `episodeRowSelectPresentsCard` can pin the tap's
  /// target without rendering anything.
  static func episodeRowSelection(itemID: String, episodeID: String)
    -> NavigationModel
    .PodcastEpisodeRef
  {
    NavigationModel.PodcastEpisodeRef(itemID: itemID, episodeID: episodeID)
  }

  /// DesignSystem cannot see AppModel's status, so the one mapping from it to the row's own enum
  /// lives here.
  static func playbackStatus(for status: ItemPlaybackStatus?) -> PodcastEpisodePlaybackStatus {
    switch status {
    case .finished: .played
    case .inProgress: .inProgress
    case nil: .unplayed
    }
  }

  /// Not `private`: `PodcastEpisodeCardView` reuses this mapping for its trailing download
  /// control, so the card and the show row always draw the same glyph for a device-transfer state.
  static func deviceStatus(
    for status: ItemDownloadStatus,
    isDownloadSizeKnown: Bool = true
  ) -> PodcastEpisodeDeviceDownloadStatus {
    let values: (DownloadControlKind, String, Double?, Bool) =
      switch status {
      case .notDownloaded: (.notDownloaded, "arrow.down.circle", nil, false)
      case .waitingForWiFi: (.waitingForWiFi, "wifi.exclamationmark", nil, false)
      case .queued: (.queued, "clock", nil, false)
      case .downloading(let fraction):
        (.downloading, "arrow.down.circle.fill", isDownloadSizeKnown ? fraction : nil, !isDownloadSizeKnown)
      case .paused: (.paused, "pause.circle", nil, false)
      case .pausedAuth: (.pausedAuth, "person.crop.circle.badge.exclamationmark", nil, false)
      case .interrupted: (.interrupted, "arrow.clockwise.circle", nil, false)
      case .deleting: (.deleting, "trash.circle", nil, false)
      case .failed: (.failed, "exclamationmark.circle", nil, false)
      // No fraction: a finished transfer is not in motion, and a `1` would pin a full-width bar
      // under every downloaded episode.
      case .completed: (.completed, "arrow.down.circle.fill", nil, false)
      }
    // Rows get the dense form: the detail screen's held-download sentence is 100 characters, which
    // truncates itself and its two neighbour labels in a row this narrow.
    return PodcastEpisodeDeviceDownloadStatus(
      kind: values.0,
      text: ItemDownloadCopy.shortText(
        for: status, isDownloadSizeKnown: isDownloadSizeKnown),
      systemImage: values.1, progressFraction: values.2, isIndeterminate: values.3)
  }
}
