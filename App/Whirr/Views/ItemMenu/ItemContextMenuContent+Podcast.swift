import AppModel
import DesignSystem
import SwiftUI

extension ItemContextMenuContent {
  var episodeSections: [MediaItemActionSection] {
    let downloadAction = actions.downloadAction(for: itemID, episodeID: episodeID)
    return ItemContextMenuPresentation.podcastEpisodeSections(
      downloadAction: downloadAction, surface: placement.menuSurface,
      isSaved: savedMembership,
      queueAvailability: queueAvailability,
      playbackStatus: playbackStatus(),
      isCurrentlyPlaying: isCurrentlyPlaying,
      isHidden: actions.isHiddenFromContinueListening(itemID: itemID, episodeID: episodeID),
      offersTranscript: transcriptOpener != nil
        && actions.isDownloadComplete(itemID: itemID, episodeID: episodeID),
      watchCopy: episodeID.flatMap {
        watchCopies?.watchCopy(itemID: itemID, episodeID: $0)
      })
  }

  /// Play/Pause read from the player in the presented body, never in a row's.
  var episodeRowContext: ItemContextMenuPresentation.RowContext {
    ItemContextMenuPresentation.RowContext(
      isEpisode: true,
      playback: ItemContextMenuPresentation.podcastPlaybackButton(
        isActiveEpisode: playback.activeItemID == itemID && playback.activeEpisodeID == episodeID,
        isPlaybackIntended: playback.isPlaybackIntended),
      isDownloadInert: ItemContextMenuPresentation.isDownloadEntryInert(
        actions.downloadAction(for: itemID, episodeID: episodeID)),
      creatorLabel: ItemContextMenuPresentation.creatorLabel(category: category, creator: author))
  }
}
