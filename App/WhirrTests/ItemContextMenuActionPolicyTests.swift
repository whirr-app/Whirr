import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import Testing

@testable import Whirr

struct ItemContextMenuActionPolicyTests {
  @Test("only the exact active podcast episode toggles playback")
  func exactActivePodcastEpisodeTogglesPlayback() {
    let active = ItemContextMenuPresentation.podcastPlaybackButton(
      isActiveEpisode: true, isPlaybackIntended: true)
    let inactive = ItemContextMenuPresentation.podcastPlaybackButton(
      isActiveEpisode: false, isPlaybackIntended: true)

    #expect(active.title == "Pause")
    #expect(active.action == .toggle)
    #expect(inactive.title == "Play")
    #expect(inactive.action == .start)
  }

  /// The episode menu carries the same download and progress intents as the row's own menu,
  /// so a long press offers the same work.
  @Test("a podcast episode's menu carries download and progress entries, episode-scoped")
  func podcastEpisodeMenuCarriesDownloadAndProgressEntries() {
    #expect(
      ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: .download, surface: .episodeList, queueAvailability: .both,
        playbackStatus: .inProgress) == [
          .playPause, .playNext, .addToUpNext, .openShow, .download,
          .markAsFinished, .resetProgress, .removeFromContinueListening,
        ])
    #expect(
      ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: .remove, surface: .episodeList, queueAvailability: .both,
        playbackStatus: .inProgress) == [
          .playPause, .playNext, .addToUpNext, .openShow,
          .markAsFinished, .resetProgress, .removeFromContinueListening, .removeDownload,
        ])
    // Mid-purge the entry stays put and goes inert rather than vanishing without explanation.
    #expect(
      ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: .unavailable, surface: .episodeList, queueAvailability: .both,
        playbackStatus: .inProgress) == [
          .playPause, .playNext, .addToUpNext, .openShow,
          .markAsFinished, .resetProgress, .removeFromContinueListening, .removeDownload,
        ])
  }

  @Test("podcast episode sections mirror the book menu")
  func podcastEpisodeSectionsMirrorBookMenu() {
    let sections = ItemContextMenuPresentation.podcastEpisodeSections(
      downloadAction: .download, surface: .episodeList, isSaved: nil, queueAvailability: .both,
      playbackStatus: .inProgress)

    // Unresolved membership hides the saved section so the menu never flashes the wrong state.
    #expect(sections.map(\.kind) == [.primary, .navigation, .download, .progress])
    #expect(
      sections.map(\.actions) == [
        [.playPause, .playNext, .addToUpNext],
        [.openShow],
        [.download],
        [.markAsFinished, .resetProgress, .removeFromContinueListening],
      ])
  }

  @Test("podcast episode sections place exactly one saved action second")
  func podcastEpisodeSectionsResolveSavedEntry() {
    let cases: [(Bool, MediaItemAction)] = [
      (false, .saveForLater), (true, .removeFromSaved),
    ]
    for (isSaved, expectedAction) in cases {
      let sections = ItemContextMenuPresentation.podcastEpisodeSections(
        downloadAction: .download, surface: .episodeList, isSaved: isSaved, queueAvailability: .both,
        playbackStatus: .inProgress)

      #expect(sections.map(\.kind) == [.primary, .saved, .navigation, .download, .progress])
      #expect(sections[1].actions == [expectedAction])
    }
  }

  @Test("show row saved actions round-trip through the Core action adapter")
  func savedActionIDsRoundTripThroughAppModel() {
    #expect(
      MediaItemAction(actionID: PodcastEpisodeViewAction.saveForLater.rawValue)
        == .saveForLater)
    #expect(
      MediaItemAction(actionID: PodcastEpisodeViewAction.removeFromSaved.rawValue)
        == .removeFromSaved)
  }

  @Test("the shared menu forwards the Watch projection and its IDs round-trip")
  func sharedMenuForwardsTheWatchProjection() {
    let hidden = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .remove, surface: .episodeList, queueAvailability: .both)
    #expect(hidden.contains(.sendToWatch) == false)
    #expect(hidden.contains(.removeFromWatch) == false)

    let sendable = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .remove, surface: .episodeList, queueAvailability: .both,
      watchCopy: .notOnWatch)
    // The Watch entry is the device section once the removal has moved to the last section; the
    // progress section still follows it.
    #expect(
      sendable.firstIndex(of: .sendToWatch)
        == sendable.firstIndex(of: .openShow).map { $0 + 1 }, "it opens the device section")
    #expect(sendable.last == .removeDownload)

    let onWatch = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .remove, surface: .episodeList, queueAvailability: .both,
      watchCopy: .onWatch)
    #expect(
      onWatch.firstIndex(of: .removeFromWatch)
        == onWatch.firstIndex(of: .openShow).map { $0 + 1 })
    #expect(onWatch.last == .removeDownload)

    #expect(
      MediaItemAction(actionID: PodcastEpisodeViewAction.sendToWatch.rawValue)
        == .sendToWatch)
    #expect(
      MediaItemAction(actionID: PodcastEpisodeViewAction.removeFromWatch.rawValue)
        == .removeFromWatch)
  }

  @Test("the Watch entries use the one copy and glyph pair")
  func watchContextActionCopyAndGlyph() {
    let send = PodcastShowViewPresentation.contextAction(.sendToWatch, creator: nil)
    #expect(send?.label == "Send to Watch")
    #expect(send?.systemImage == "applewatch")

    let remove = PodcastShowViewPresentation.contextAction(.removeFromWatch, creator: nil)
    #expect(remove?.label == "Remove from Watch")
    #expect(remove?.systemImage == "applewatch.slash")
  }

  @Test("saved context-action copy comes from the shared menu entry")
  func savedContextActionUsesSharedCopyAndGlyph() {
    let cases: [(MediaItemAction, Bool, String)] = [
      (.saveForLater, false, "Saves this episode to Saved for Later."),
      (.removeFromSaved, true, "Removes this episode from Saved for Later."),
    ]

    for (action, isSaved, hint) in cases {
      let entry = ItemContextMenuPresentation.savedEntry(isSaved: isSaved)
      let contextAction = PodcastShowViewPresentation.contextAction(action, creator: nil)
      #expect(contextAction?.label == entry.title)
      #expect(contextAction?.systemImage == entry.systemImage)
      #expect(contextAction?.hint == hint)
      #expect(contextAction?.role == .standard)
    }
  }

  @Test("podcast progress entries adapt the shared three-state policy")
  func podcastProgressEntriesMatchPlaybackState() {
    func progressActions(_ status: ItemPlaybackStatus?) -> [MediaItemAction] {
      ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: .download, surface: .episodeList, queueAvailability: .both, playbackStatus: status
      ).filter {
        $0 == .markAsFinished || $0 == .resetProgress || $0 == .removeFromContinueListening
      }
    }

    #expect(progressActions(nil) == [.markAsFinished])
    #expect(
      progressActions(.inProgress)
        == [.markAsFinished, .resetProgress, .removeFromContinueListening])
    #expect(progressActions(.finished) == [.resetProgress])
  }

  @Test("podcast removal is withheld for hidden or currently playing progress")
  func podcastRemovalRespectsVisibilityAndPlayback() {
    let hidden = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .download, surface: .episodeList, queueAvailability: .both, playbackStatus: .inProgress,
      isHidden: true)
    let playing = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .download, surface: .episodeList, queueAvailability: .both, playbackStatus: .inProgress,
      isCurrentlyPlaying: true)

    #expect(hidden.contains(.removeFromContinueListening) == false)
    #expect(playing.contains(.removeFromContinueListening) == false)
  }

  @MainActor
  @Test("context menu reads Continue Listening visibility from its action model")
  func contextMenuReadsVisibilityFromActionModel() throws {
    let identity = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "ep-1"))
    let hiddenActions = makeActions(hidden: [identity])
    let visibleActions = makeActions(hidden: [])

    func entries(for actions: ItemActionsModel) -> [MediaItemAction] {
      ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: .download, surface: .episodeList,
        queueAvailability: .both,
        playbackStatus: .inProgress,
        isHidden: actions.isHiddenFromContinueListening(itemID: "show-1", episodeID: "ep-1"))
    }

    #expect(entries(for: hiddenActions).contains(.removeFromContinueListening) == false)
    #expect(entries(for: visibleActions).contains(.removeFromContinueListening))
  }

  /// `checkmark` means selection in menus and on the Library filter, so a Mark as Finished row
  /// wearing it reads as already chosen. `checkmark.circle` is Apple's mark-as-played glyph and
  /// cannot be mistaken for a selection tick.
  @Test("every progress surface shares full menu copy and symbols")
  func progressEntriesUseSharedPresentation() {
    #expect(ItemContextMenuPresentation.progressEntry(.markAsFinished).title == "Mark as Finished")
    #expect(
      ItemContextMenuPresentation.progressEntry(.markAsFinished).systemImage == "checkmark.circle")
    #expect(ItemContextMenuPresentation.progressEntry(.resetProgress).title == "Reset Progress")
    #expect(
      ItemContextMenuPresentation.progressEntry(.resetProgress).systemImage
        == "arrow.counterclockwise")
    #expect(
      ItemContextMenuPresentation.progressEntry(.removeFromContinueListening).title
        == ContinueListeningCopy.action)
    #expect(
      ItemContextMenuPresentation.progressEntry(.removeFromContinueListening).systemImage
        == "eye.slash")
  }

  @Test("Continue Reading uses reading-specific removal copy")
  func continueReadingRemovalUsesReadingCopy() {
    #expect(
      ItemContextMenuPresentation.progressEntry(
        .removeFromContinueListening, usesEbookProgress: true
      ).title == "Remove from Continue Reading")
    #expect(
      ItemContextMenuPresentation.progressEntry(
        .removeFromContinueListening, usesEbookProgress: true
      ).systemImage == "eye.slash")
  }

  /// A book's menu drew three red rows in a row (Delete Download, Mark as Finished, Reset
  /// Progress), which made a seven-row menu read as a wall of warnings. Red means data is
  /// destroyed, and the Mark and Reset rows only move a progress marker.
  @Test("moving a progress marker is not destructive on any surface")
  func progressActionsAreNotDestructive() {
    #expect(ItemContextMenuPresentation.progressEntry(.markAsFinished).role == .standard)
    #expect(ItemContextMenuPresentation.progressEntry(.resetProgress).role == .standard)
    #expect(ItemContextMenuPresentation.progressEntry(.markAsFinished).buttonRole == nil)
    #expect(ItemContextMenuPresentation.progressEntry(.resetProgress).buttonRole == nil)
  }

  /// Removing a download deletes bytes from the device, so it is the one red row left. This
  /// half of the rule must keep failing if someone drops the role wholesale.
  @Test("deleting a download stays destructive")
  func removingADownloadStaysDestructive() {
    let entry = ItemContextMenuPresentation.removeDownloadEntry
    let showRow = PodcastShowViewPresentation.contextAction(.removeDownload, creator: nil)

    #expect(entry.title == "Remove Download")
    #expect(entry.systemImage == "trash")
    #expect(entry.role == .destructive)
    #expect(showRow?.label == entry.title)
    #expect(showRow?.systemImage == entry.systemImage)
    #expect(
      showRow?.role == entry.role)
  }

  /// The role is carried by the entry rather than spelled at each surface, so this menu, the
  /// player's overflow and the episode row's menu and swipe table cannot answer differently. The
  /// swipe buttons copy the row's role.
  @Test("every surface takes a progress action's role from the one entry")
  func progressRolesComeFromOneEntry() {
    for (action, progress) in [
      (AppModel.MediaItemAction.markAsFinished, MediaProgressAction.markAsFinished),
      (.resetProgress, .resetProgress),
    ] {
      let entry = ItemContextMenuPresentation.progressEntry(progress)
      #expect(PodcastShowViewPresentation.contextAction(action, creator: nil)?.role == entry.role)
      #expect(PodcastShowViewPresentation.swipeButton(for: action)?.role == entry.role)
      #expect(
        PodcastShowViewPresentation.contextAction(action, creator: nil)?.systemImage
          == entry.systemImage)
    }
  }

  /// Anti-drift check from the App side: this menu is the canonical list for `.episodeList` and
  /// nothing else.
  @Test func sharedEpisodeMenuMatchesCanonicalList() {
    for (downloadAction, status) in [
      (ItemContextMenuDownloadAction.download, ItemDownloadStatus.notDownloaded),
      (.remove, .completed),
      (.unavailable, .completed),
    ] {
      #expect(
        ItemContextMenuPresentation.podcastEpisodeEntries(
          downloadAction: downloadAction, surface: .episodeList, queueAvailability: .both)
          == PodcastShowPresentation.episodeActions(
            status: status, isAvailableOnServer: true, surface: .episodeList))
    }

    let shared = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .download, surface: .episodeList, queueAvailability: .both)
    #expect(shared.contains(.playNext), "Up Next was unreachable from every list surface")
    #expect(shared.contains(.addToUpNext))
  }

  /// Known gap: this surface reads `DownloadStatusStore`, which is coarse, so it cannot tell a
  /// paused transfer from a queued one and never offers Pause or Resume. Making it able to would
  /// put a per-episode status observation back on the scroll path.
  @Test func sharedEpisodeMenuCannotOfferPauseOrResumeFromCoarsePresence() {
    for downloadAction in [
      ItemContextMenuDownloadAction.download, .remove, .unavailable,
    ] {
      let entries = ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: downloadAction, surface: .episodeList, queueAvailability: .both)
      #expect(entries.contains(.pauseDownload) == false)
      #expect(entries.contains(.resumeDownload) == false)
    }
  }

  // MARK: - Queue availability

  /// With nothing playing or retained there is no queue to add to, so the entries are absent
  /// rather than present but inert. Home, Library and Search all raise this one menu.
  @Test("the shared menu offers no queue entries without a Now Playing identity")
  func sharedMenuOffersNoQueueEntriesWithoutNowPlaying() {
    let availability = ListeningQueueActionPolicy.availability(
      itemID: "show-1", episodeID: "ep-1", category: .podcast, nowPlaying: nil)
    let entries = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .download, surface: .episodeList, queueAvailability: availability)

    #expect(entries.contains(.playNext) == false)
    #expect(entries.contains(.addToUpNext) == false)
    #expect(entries.contains(.playPause), "Play is still offered")
  }

  /// The audiobook branch renders `availability.actions` directly, so the policy is its menu.
  @Test("an audiobook menu gains both queue entries once something is playing")
  func audiobookMenuGainsQueueEntriesOnceSomethingIsPlaying() {
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: "book-1", episodeID: nil, category: .audiobook, nowPlaying: nil
      ).actions.isEmpty)
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: "book-1", episodeID: nil, category: .audiobook,
        nowPlaying: .audiobook(itemID: "book-2")
      ).actions == [.playNext, .addToUpNext])
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: "book-1", episodeID: nil, category: .audiobook,
        nowPlaying: .audiobook(itemID: "book-1")
      ).actions.isEmpty,
      "no queue action for the book already playing")
  }

  /// The two entries read the same in a book's menu as in an episode's, from one shared mapping.
  @Test func queueEntryCopyMatchesTheCanonicalEpisodeCopy() {
    #expect(
      ItemContextMenuPresentation.queueEntry(.playNext).title
        == PodcastShowViewPresentation.contextAction(.playNext, creator: nil)?.label)
    #expect(
      ItemContextMenuPresentation.queueEntry(.addToUpNext).title
        == PodcastShowViewPresentation.contextAction(.addToUpNext, creator: nil)?.label)
    #expect(
      ItemContextMenuPresentation.queueEntry(.playNext).systemImage
        == PodcastShowViewPresentation.contextAction(.playNext, creator: nil)?.systemImage)
  }

  /// Every menu-bearing surface takes its two queue entries from the same
  /// `ListeningQueueActionPolicy` answer, so none offers an action the policy withheld or
  /// withholds one it allowed. Item detail (audiobook) is absent: it has no item-action menu,
  /// only a play button and a download bubble.
  @Test(
    "Home, Library, Search, the show screen and the episode card all follow one policy",
    arguments: [ListeningQueueActionAvailability.none, .both])
  func everySurfaceDerivesItsQueueEntriesFromOnePolicy(
    availability: ListeningQueueActionAvailability
  ) {
    // Home, Library, Search and the Podcasts tab share one long-press menu.
    let shared = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .download, surface: .episodeList, queueAvailability: availability)
    #expect(shared.contains(.playNext) == availability.offersPlayNext)
    #expect(shared.contains(.addToUpNext) == availability.offersAddToUpNext)

    // The podcast show screen's rows.
    let showRow = PodcastShowViewPresentation.episode(
      Self.episode(), creator: "Creator", queueAvailability: availability)
    #expect(
      showRow.actions.contains { $0.id == PodcastEpisodeViewAction.playNext.rawValue }
        == availability.offersPlayNext)
    #expect(
      showRow.actions.contains { $0.id == PodcastEpisodeViewAction.addUpNext.rawValue }
        == availability.offersAddToUpNext)

    // The episode card.
    let cardRows = PodcastEpisodeCardViewPresentation.actionRows(
      for: PodcastEpisodeCardPresentation(
        context: PodcastEpisodeContext(
          episode: Self.episode(), showTitle: "Show", showAuthor: "Creator",
          artworkURL: nil, artworkFeedURL: nil)),
      queueAvailability: availability)
    #expect(cardRows.contains { $0.action == .playNext } == availability.offersPlayNext)
    #expect(cardRows.contains { $0.action == .addToUpNext } == availability.offersAddToUpNext)

    // Everything else the canonical list carries is untouched by the queue decision.
    #expect(shared.contains(.playPause))
    #expect(showRow.actions.contains { $0.id == PodcastEpisodeViewAction.playPause.rawValue })
    // The card is the exception, but not because of the queue policy: it presents Play as its own
    // capsule, so `.episodeDetail` suppresses the row. Its queue entries still come from the same
    // availability every other surface reads.
    #expect(cardRows.contains { $0.action == .playPause } == false)
  }
  @MainActor
  private func makeActions(hidden: Set<ListeningIdentity>) -> ItemActionsModel {
    ItemActionsModel(
      downloadStatus: DownloadStatusStore(downloadReading: NoOpDownloadReading()),
      downloadIntents: NoOpDownloadIntents(),
      progressIntents: NoOpItemProgressIntents(),
      extrasAccess: NoOpItemDetailExtrasAccess(),
      continueListeningVisibility: ContinueListeningVisibilityStore(hidden: hidden))
  }

  /// Every episode menu offers Transcript on the same terms as the card: downloaded, and only
  /// where the app can transcribe at all. A purge in flight is no longer a download to read.
  @Test("Home, Library, Search and the show screen offer Transcript for a downloaded episode")
  func listMenusOfferTranscriptForADownloadedEpisode() {
    func shared(_ download: ItemContextMenuDownloadAction, offers: Bool) -> [MediaItemAction] {
      ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: download, surface: .episodeList, queueAvailability: .both,
        offersTranscript: offers)
    }
    #expect(shared(.remove, offers: true).contains(.transcript))
    #expect(shared(.download, offers: true).contains(.transcript) == false)
    #expect(shared(.unavailable, offers: true).contains(.transcript) == false)
    #expect(shared(.remove, offers: false).contains(.transcript) == false)

    func showRow(_ status: ItemDownloadStatus, offers: Bool) -> [String] {
      PodcastShowViewPresentation.episode(
        Self.episode(downloadStatus: status), creator: "Creator", queueAvailability: .both,
        offersTranscript: offers
      ).actions.map(\.id)
    }
    let transcript = PodcastEpisodeViewAction.transcript.rawValue
    #expect(showRow(.completed, offers: true).contains(transcript))
    #expect(showRow(.notDownloaded, offers: true).contains(transcript) == false)
    #expect(showRow(.completed, offers: false).contains(transcript) == false)
  }

  private static func episode(downloadStatus: ItemDownloadStatus = .notDownloaded)
    -> PodcastEpisodeSummary
  {
    PodcastEpisodeSummary(
      id: "ep-1", title: "Episode", subtitle: "Subtitle", episodeDescription: nil,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: 100,
      sizeBytes: 10, publishedAt: Date(timeIntervalSince1970: 0), progressSeconds: 0,
      isPlayed: false, isFinished: false, downloadStatus: downloadStatus,
      isAvailableOnServer: true)
  }

}
