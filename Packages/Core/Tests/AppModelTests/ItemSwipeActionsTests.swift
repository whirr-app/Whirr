import Persistence
import Testing

@testable import AppModel

/// The Saved for Later shelf's swipe vocabulary, and the promote rule it shares with
/// every podcast episode row rather than re-deriving.
@Suite("Item swipe actions")
struct ItemSwipeActionsTests {

  private static let book = ListeningIdentity.audiobook(itemID: "book-1")
  private static let episode = ListeningIdentity.podcastEpisode(
    itemID: "show-1", episodeID: "episode-1")

  // MARK: - The shared promote rule

  @Test("nothing playing offers Play; another identity offers Play Next; the playing row offers Pause")
  func promotionFollowsThePlayer() {
    #expect(MediaSwipePromotion.leading(identity: Self.book, nowPlaying: nil, isPlaybackIntended: false) == .play)
    #expect(
      MediaSwipePromotion.leading(identity: Self.book, nowPlaying: Self.episode, isPlaybackIntended: false) == .playNext
    )
    #expect(
      MediaSwipePromotion.leading(identity: Self.book, nowPlaying: Self.episode, isPlaybackIntended: true) == .playNext)
    #expect(MediaSwipePromotion.leading(identity: nil, nowPlaying: Self.episode, isPlaybackIntended: true) == nil)
  }

  @Test("the now-playing row is never left with an empty leading edge")
  func nowPlayingRowTogglesRatherThanGoingBlank() {
    #expect(MediaSwipePromotion.leading(identity: Self.book, nowPlaying: Self.book, isPlaybackIntended: true) == .pause)
    // Paused, or merely retained by the mini-player: the row resumes it.
    #expect(MediaSwipePromotion.leading(identity: Self.book, nowPlaying: Self.book, isPlaybackIntended: false) == .play)
  }

  @Test("a podcast episode row still resolves through the lifted rule unchanged")
  func podcastEpisodeSwipeStillFollowsTheSameRule() {
    let idle = PodcastEpisodeSwipeActions.actions(
      deviceAction: .download, isAvailableOnServer: true, playbackStatus: nil,
      identity: Self.episode, nowPlaying: nil, isPlaybackIntended: false)
    #expect(idle.leading == [.playPause])

    let other = PodcastEpisodeSwipeActions.actions(
      deviceAction: .download, isAvailableOnServer: true, playbackStatus: nil,
      identity: Self.episode, nowPlaying: Self.book, isPlaybackIntended: false)
    #expect(other.leading == [.playNext])

    let pausedItself = PodcastEpisodeSwipeActions.actions(
      deviceAction: .download, isAvailableOnServer: true, playbackStatus: nil,
      identity: Self.episode, nowPlaying: Self.episode, isPlaybackIntended: false)
    #expect(pausedItself.leading == [.playPause])
    #expect(pausedItself.pausesPlayback == false)

    let playingItself = PodcastEpisodeSwipeActions.actions(
      deviceAction: .download, isAvailableOnServer: true, playbackStatus: nil,
      identity: Self.episode, nowPlaying: Self.episode, isPlaybackIntended: true)
    #expect(playingItself.leading == [.playPause])
    #expect(playingItself.pausesPlayback)
  }

  @Test("a playing item row offers Pause on its leading edge")
  func playingItemRowPauses() {
    let playing = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: .inProgress), capability: .audio, deviceAction: .remove,
      identity: Self.book, nowPlaying: Self.book, isPlaybackIntended: true)
    #expect(playing.leading == [.pause])

    let saved = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .audio, deviceAction: .remove, identity: Self.book,
      nowPlaying: Self.book, isPlaybackIntended: true)
    #expect(saved.leading == [.pause])

    let paused = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: .inProgress), capability: .audio, deviceAction: .remove,
      identity: Self.book, nowPlaying: Self.book, isPlaybackIntended: false)
    #expect(paused.leading == [.play])
  }

  // MARK: - Per-row vocabulary

  @Test("an audiobook row promotes on leading and manages the device inside Remove on trailing")
  func audiobookRow() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .audio, deviceAction: .download, identity: Self.book, nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(actions.leading == [.play])
    #expect(actions.trailing == [.removeFromSaved, .download])
  }

  @Test("a downloaded row offers Remove Download inside Remove from Saved, never outside it")
  func downloadedRowKeepsRedInside() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .audio, deviceAction: .remove, identity: Self.book, nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(actions.trailing == [.removeFromSaved, .removeDownload])
    #expect(actions.trailing.first == .removeFromSaved)
  }

  @Test("an eBook row's start verb is Read")
  func ebookRowReads() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .ebook, deviceAction: .download, identity: nil, nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(actions.leading == [.read])
    #expect(actions.trailing == [.removeFromSaved, .download])
  }

  @Test("a mixed item keeps the audio promote verb and one coarse Download capsule")
  func mixedItemRow() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .audioAndEbook, deviceAction: .download, identity: Self.book, nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(actions.leading == [.play])
    #expect(actions.trailing == [.removeFromSaved, .download])
    #expect(ItemSwipeActions.downloadFormat(for: .audioAndEbook) == .both)
    #expect(ItemSwipeActions.downloadFormat(for: .audio) == .audio)
    #expect(ItemSwipeActions.downloadFormat(for: .ebook) == .ebook)
  }

  @Test("a podcast episode row answers the same vocabulary as an audiobook one")
  func podcastEpisodeRow() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .podcast, deviceAction: .remove, identity: Self.episode, nowPlaying: Self.book,
      isPlaybackIntended: false)

    #expect(actions.leading == [.playNext])
    #expect(actions.trailing == [.removeFromSaved, .removeDownload])
  }

  @Test("a document Whirr cannot open answers Remove from Saved alone")
  func unsupportedDocumentRow() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .unsupportedDocument, deviceAction: .download, identity: nil, nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(actions.leading.isEmpty)
    #expect(actions.trailing == [.removeFromSaved])
  }

  @Test("an unavailable placeholder answers Remove from Saved alone")
  func unavailableRow() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: nil, deviceAction: .download, identity: Self.book, nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(actions.leading.isEmpty)
    #expect(actions.trailing == [.removeFromSaved])
  }

  @Test("a purge in flight draws no device capsule, leaving Remove from Saved alone")
  func purgeInFlightRow() {
    let actions = ItemSwipeActions.actions(
      shelf: .savedForLater, capability: .audio, deviceAction: .unavailable, identity: Self.book, nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(actions.trailing == [.removeFromSaved])
  }

  // MARK: - Cross-surface parity

  /// Which actions a swipe offers is a property of the episode, not of the screen it was reached
  /// from (the principle behind `PodcastEpisodeSwipeActionsModifier`). The saved shelf adds a
  /// capsule and drops the progress one, but an episode's device action must not change edges
  /// just because the row is listed here.
  @Test("a podcast episode's device action stays on the trailing edge on this shelf too")
  func episodeDeviceActionKeepsItsEdge() {
    for deviceAction in [ItemContextMenuDownloadAction.download, .remove, .unavailable] {
      let elsewhere = PodcastEpisodeSwipeActions.actions(
        deviceAction: deviceAction, isAvailableOnServer: true, playbackStatus: nil,
        identity: Self.episode, nowPlaying: nil, isPlaybackIntended: false)
      let shelf = ItemSwipeActions.actions(
        shelf: .savedForLater, capability: .podcast, deviceAction: deviceAction, identity: Self.episode,
        nowPlaying: nil, isPlaybackIntended: false)

      let elsewhereHasDevice = elsewhere.trailing.contains { $0 == .download || $0 == .removeDownload }
      let shelfHasDevice = shelf.trailing.contains { $0 == .download || $0 == .removeDownload }
      #expect(elsewhereHasDevice == shelfHasDevice)

      #expect(elsewhere.leading.isEmpty == shelf.leading.isEmpty)
      #expect(shelf.leading.contains(.download) == false)
      #expect(shelf.leading.contains(.removeDownload) == false)
    }
  }

  @Test("no edge ever exceeds two capsules")
  func edgesStayAtTwoCapsules() {
    let capabilities: [ItemMediaCapability?] = [
      .audio, .ebook, .audioAndEbook, .unsupportedDocument, .podcast, nil,
    ]
    let deviceActions: [ItemContextMenuDownloadAction] = [.download, .remove, .unavailable]
    let players: [ListeningIdentity?] = [nil, Self.book, Self.episode]

    for capability in capabilities {
      for deviceAction in deviceActions {
        for nowPlaying in players {
          let actions = ItemSwipeActions.actions(
            shelf: .savedForLater, capability: capability, deviceAction: deviceAction, identity: Self.book,
            nowPlaying: nowPlaying, isPlaybackIntended: false)
          #expect(actions.leading.count <= 2)
          #expect(actions.trailing.count <= 2)
          #expect(actions.trailing.contains(.removeFromSaved))
          #expect(actions.trailing.first == .removeFromSaved)
        }
      }
    }
  }
}

/// The same policy for an ordinary list row: Home's drill-downs, Search, Library.
/// Such a list is not a bookmark shelf, so it has no Remove from Saved, and it carries the first
/// progress action the way an episode row does.
@Suite("Item swipe actions on a list row")
struct ItemListSwipeActionsTests {
  private static let book = ListeningIdentity.audiobook(itemID: "book-1")
  private static let episode = ListeningIdentity.podcastEpisode(
    itemID: "show-1", episodeID: "episode-1")

  @Test("an unstarted audiobook promotes on leading; trailing is device, then Mark as Finished")
  func unstartedAudiobook() {
    let actions = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: nil), capability: .audio, deviceAction: .download,
      identity: Self.book, nowPlaying: nil, isPlaybackIntended: false)

    #expect(actions.leading == [.play])
    #expect(actions.trailing == [.download, .markAsFinished])
  }

  @Test("a finished, downloaded book offers Remove Download and Reset Progress")
  func finishedDownloadedBook() {
    let actions = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: .finished), capability: .audio, deviceAction: .remove,
      identity: Self.book, nowPlaying: Self.episode, isPlaybackIntended: false)

    #expect(actions.leading == [.playNext])
    #expect(actions.trailing == [.removeDownload, .resetProgress])
  }

  @Test("an in-progress row offers only the first progress action")
  func inProgressTakesFirstAction() {
    let actions = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: .inProgress), capability: .audio, deviceAction: .unavailable,
      identity: Self.book, nowPlaying: nil, isPlaybackIntended: false)

    #expect(actions.trailing == [.markAsFinished])
  }

  @Test("an eBook reads, and a mixed item reads when the list is about reading")
  func readingRows() {
    let ebook = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: nil), capability: .ebook, deviceAction: .download,
      identity: nil, nowPlaying: nil, isPlaybackIntended: false)
    #expect(ebook.leading == [.read])

    let mixedListening = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: nil), capability: .audioAndEbook, deviceAction: .download,
      identity: Self.book, nowPlaying: nil, isPlaybackIntended: false)
    #expect(mixedListening.leading == [.play])

    let mixedReading = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: nil, prefersReading: true), capability: .audioAndEbook,
      deviceAction: .download, identity: Self.book, nowPlaying: nil, isPlaybackIntended: false)
    #expect(mixedReading.leading == [.read])
  }

  @Test("a list row never offers Remove from Saved")
  func noSavedRemovalOutsideTheShelf() {
    let capabilities: [ItemMediaCapability?] = [
      .audio, .ebook, .audioAndEbook, .unsupportedDocument, .podcast, nil,
    ]
    let statuses: [ItemPlaybackStatus?] = [nil, .inProgress, .finished]
    for capability in capabilities {
      for status in statuses {
        let actions = ItemSwipeActions.actions(
          shelf: .list(playbackStatus: status), capability: capability, deviceAction: .remove,
          identity: Self.book, nowPlaying: nil, isPlaybackIntended: false)
        #expect((actions.leading + actions.trailing).contains(.removeFromSaved) == false)
        #expect(actions.leading.count <= 2)
        #expect(actions.trailing.count <= 2)
      }
    }
  }

  @Test("an unavailable identity offers nothing on a list")
  func unavailableRowOffersNothing() {
    let actions = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: .inProgress), capability: nil, deviceAction: .download,
      identity: Self.book, nowPlaying: nil, isPlaybackIntended: false)

    #expect(actions.leading.isEmpty)
    #expect(actions.trailing.isEmpty)
  }

  /// Matches `PodcastEpisodeSwipeActions`: trailing is device action first, progress second, so a
  /// book and an episode listed side by side put the same kind of capsule in the same place.
  @Test("the trailing order matches an episode row's")
  func trailingOrderMatchesEpisodes() {
    let episode = PodcastEpisodeSwipeActions.actions(
      deviceAction: .remove, isAvailableOnServer: true, playbackStatus: .finished,
      identity: Self.episode, nowPlaying: nil, isPlaybackIntended: false)
    let item = ItemSwipeActions.actions(
      shelf: .list(playbackStatus: .finished), capability: .podcast, deviceAction: .remove,
      identity: Self.episode, nowPlaying: nil, isPlaybackIntended: false)

    #expect(episode.trailing == [.removeDownload, .resetProgress])
    #expect(item.trailing == [.removeDownload, .resetProgress])
  }
}
