import AppModel
import DesignSystem
import Testing

@testable import Whirr

/// The episode rows' menus and swipes (`PodcastShowViewPresentation.contextAction`), the shared
/// item menu's entries and the detail bubble are separate renderers of one action vocabulary.
/// Each must read the same title and glyph from `MediaActionCopy`.
@Suite("Every renderer words an item action the same way")
struct ItemMenuCopyConsistencyTests {
  /// Every episode action with a fixed table label. Open Show has no row, More from names the
  /// creator, and Pause/Resume Download are transfer controls rather than item actions.
  private static let episodeLabels: [(MediaItemAction, MediaActionLabel)] = [
    (.playPause, MediaActionCopy.play),
    (.playNext, MediaActionCopy.playNext),
    (.addToUpNext, MediaActionCopy.addToUpNext),
    (.saveForLater, MediaActionCopy.saveForLater),
    (.removeFromSaved, MediaActionCopy.removeFromSaved),
    (.download, MediaActionCopy.download),
    (.removeDownload, MediaActionCopy.removeDownload),
    (.markAsFinished, MediaActionCopy.markAsFinished),
    (.resetProgress, MediaActionCopy.resetProgress),
    (.removeFromContinueListening, MediaActionCopy.removeFromContinueListening),
    (.saveToServer, MediaActionCopy.saveToServer),
    (.removeFromServer, MediaActionCopy.removeFromServer),
    (.transcript, MediaActionCopy.transcript),
    (.sendToWatch, MediaActionCopy.sendToWatch),
    (.removeFromWatch, MediaActionCopy.removeFromWatch),
  ]

  @Test func episodeRowActionsReadTheTable() throws {
    for (action, label) in Self.episodeLabels {
      let row = try #require(PodcastShowViewPresentation.contextAction(action, creator: nil))
      #expect(row.label == label.title, "\(action)")
      #expect(row.systemImage == label.systemImage, "\(action)")
    }
  }

  @Test func itemMenuEntriesReadTheTable() {
    let entries: [(ItemContextMenuPresentation.MenuEntry, MediaActionLabel)] = [
      (ItemContextMenuPresentation.downloadEntry, MediaActionCopy.download),
      (ItemContextMenuPresentation.removeDownloadEntry, MediaActionCopy.removeDownload),
      (ItemContextMenuPresentation.removingDownloadEntry, MediaActionCopy.removingDownload),
      (ItemContextMenuPresentation.viewDetailsEntry, MediaActionCopy.viewDetails),
      (ItemContextMenuPresentation.viewEpisodesEntry, MediaActionCopy.viewEpisodes),
      (ItemContextMenuPresentation.savedEntry(isSaved: false), MediaActionCopy.saveForLater),
      (ItemContextMenuPresentation.savedEntry(isSaved: true), MediaActionCopy.removeFromSaved),
      (ItemContextMenuPresentation.progressEntry(.markAsFinished), MediaActionCopy.markAsFinished),
      (ItemContextMenuPresentation.progressEntry(.resetProgress), MediaActionCopy.resetProgress),
    ]
    for (entry, label) in entries {
      #expect(entry.title == label.title, "\(label.title)")
      #expect(entry.systemImage == label.systemImage, "\(label.title)")
    }
  }

  /// A book and an episode say the same word, so the scroll-path rows (which cannot read the
  /// player) and a presented menu never disagree.
  @Test func playbackSaysPlayOrPauseForEveryFamily() {
    for isActive in [false, true] {
      let book = ItemContextMenuPresentation.playbackButton(
        isActiveItem: isActive, isPlaybackIntended: true)
      let episode = ItemContextMenuPresentation.podcastPlaybackButton(
        isActiveEpisode: isActive, isPlaybackIntended: true)
      let expected = isActive ? MediaActionCopy.pause.title : MediaActionCopy.play.title
      #expect(book.title == expected)
      #expect(episode.title == expected)
    }
  }

  @Test func detailBubbleMatchesTheMenu() {
    #expect(
      ItemDetailDownloadBubblePresentation.primaryActionLabel(for: .notDownloaded)
        == MediaActionCopy.download.title)
    #expect(
      ItemDetailDownloadBubblePresentation.primaryActionLabel(for: .completed)
        == MediaActionCopy.removeDownload.title)
  }

  @Test func downloadsTabClosesWithTheSameRemoval() {
    #expect(DownloadsViewPresentation.deleteActionTitle == MediaActionCopy.removeSwipeTitle)
    #expect(
      DownloadsViewPresentation.deleteActionSystemImage == MediaActionCopy.removeDownload.systemImage)
    #expect(StorageCopy.confirmRemove == MediaActionCopy.removeSwipeTitle)
  }
}
