import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

extension ItemContextMenuContent {
  /// Read in the presented menu's body, like `queueAvailability`. The device list is warmed when
  /// the screen appears (`itemActionErrorAlert`), so it is normally already here.
  var deliveryEntry: EbookDeliveryMenuEntry? {
    EbookDeliveryMenuEntry.resolve(capability: capability, devices: actions.ereaderDevices)
  }

  /// The narrator link's label, or `nil` where the book offers none: only audio has a narrator.
  var bookNarratorLabel: String? {
    capability.supportsPlayback && showsNarratorLink ? narratorLabel : nil
  }

  var bookCreatorLabel: String? {
    ItemContextMenuPresentation.creatorLabel(category: category, creator: author)
  }

  /// A book's menu as data (`BookMenuPresentation`), narrowed by `bookSurface` the way an episode's
  /// is narrowed by its surface.
  var bookSections: [MediaItemActionSection] {
    BookMenuPresentation.actionSections(
      BookMenuPresentation.State(
        capability: capability,
        isSaved: savedMembership,
        queueAvailability: queueAvailability,
        playbackStatus: playbackStatus(),
        isCurrentlyPlaying: isCurrentlyPlaying,
        isHidden: actions.isHiddenFromContinueListening(itemID: itemID, episodeID: episodeID),
        downloadAction: actions.downloadAction(for: itemID),
        canOpenReader: onRead != nil,
        hasCreatorOrNarratorLink: bookCreatorLabel != nil || bookNarratorLabel != nil,
        canSendToEreader: deliveryEntry != nil,
        watchCopy: bookWatchCopy),
      surface: bookSurface)
  }

  /// The two `PlaybackModel` reads behind Play/Pause, here in the presented body and never in a
  /// row's (see `ItemContextMenuModifier`'s note).
  var bookRowContext: ItemContextMenuPresentation.RowContext {
    let delivery = deliveryEntry
    let devices: [EbookDeliveryDevice] =
      switch delivery {
      case .single(let device): [device]
      case .submenu(let devices): devices
      case nil: []
      }
    return ItemContextMenuPresentation.RowContext(
      isEpisode: false,
      playback: ItemContextMenuPresentation.playbackButton(
        isActiveItem: playback.activeItemID == itemID,
        isPlaybackIntended: playback.isPlaybackIntended),
      isDownloadInert: actions.downloadAction(for: itemID) == .unavailable,
      downloadFormats: capability.downloadFormats,
      delivery: delivery,
      sendingDeviceNames: Set(
        devices.map(\.name).filter { actions.isSendingEbook(itemID: itemID, deviceName: $0) }),
      creatorLabel: bookCreatorLabel,
      narratorLabel: bookNarratorLabel,
      usesEbookProgress: usesEbookProgress,
      bookWatchOversizedMessage: bookWatchOversizedMessage)
  }

  /// Play/Pause for either family, decided from the player now rather than when the row was drawn.
  func togglePlayback() {
    if let episodeID {
      let button = ItemContextMenuPresentation.podcastPlaybackButton(
        isActiveEpisode: playback.activeItemID == itemID && playback.activeEpisodeID == episodeID,
        isPlaybackIntended: playback.isPlaybackIntended)
      switch button.action {
      case .toggle: playback.togglePlayPause(itemID: itemID)
      case .start: Task { await playback.start(itemID: itemID, episodeID: episodeID) }
      }
    } else {
      let button = ItemContextMenuPresentation.playbackButton(
        isActiveItem: playback.activeItemID == itemID,
        isPlaybackIntended: playback.isPlaybackIntended)
      switch button.action {
      case .toggle:
        PlayerTransportIntents(playback: playback, itemID: itemID, episodeID: episodeID).toggle()
      case .start:
        // A menu row need not be the retained item, so it cannot take the player's saved-position
        // path (`play`); `start` resolves the position through the session instead.
        Task { await playback.start(itemID: itemID) }
      }
    }
  }
}
