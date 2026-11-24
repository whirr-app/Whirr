import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

// Sheets read `player.state` lazily inside their own presented content (never in `body`), so a
// sheet re-rendering while open stays isolated to the sheet and never re-runs the page.

struct PlayerChaptersSheet: View {
  let itemID: String
  let episodeID: String?
  let player: any PlaybackControlling
  let playback: PlaybackModel
  let finishedStatus: FinishedStatusStore
  let fallbackChapterMap: PlaybackChapterMap?
  /// The item's bookmarks, shown behind the sheet's Chapters | Bookmarks switch.
  var bookmarksModel: AudioBookmarksModel? = nil
  let actions: ItemActionsModel
  @Binding var isPresented: Bool

  private var queueChapter: ((ChapterQueueAction, ListeningQueueChapter) -> Void)? {
    guard ChapterQueueAction.isOffered(playingEpisodeID: episodeID) else { return nil }
    return { [actions, itemID] action, chapter in
      Task {
        switch action {
        case .playNext: await actions.playNext(itemID: itemID, chapter: chapter)
        case .addToUpNext: await actions.addToUpNext(itemID: itemID, chapter: chapter)
        }
      }
    }
  }

  var body: some View {
    let item = ExpandedPlayerPresentation.livePlayerItem(
      itemID: itemID, episodeID: episodeID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, playerItem: player.state.item)
    let chapterMap = item?.chapters ?? fallbackChapterMap
    let chapters = chapterMap?.chapters ?? []
    let currentTime = playback.displayedPositionSeconds(itemID: itemID, episodeID: episodeID, persisted: 0)
    // The finished flag belongs to the library item; an episode's own finished state is not it.
    let isFinished = episodeID == nil && finishedStatus.isFinished(itemID)
    return ChapterSelectorSheet(
      chapters: chapters, currentTime: currentTime, isFinished: isFinished,
      bookmarksModel: bookmarksModel,
      onSelectBookmark: { bookmark in
        // The same route as the item-detail chapter jump: seek the loaded item, or start it first.
        Task {
          await playback.startOrSeek(itemID: itemID, toGlobalOffset: bookmark.time)
        }
        isPresented = false
      },
      onQueueChapter: queueChapter,
      onQueueChapters: queueChapter == nil
        ? nil
        : { [actions, itemID] chapters in
          Task { await actions.addToUpNext(itemID: itemID, chapters: chapters) }
        },
      onSelect: { chapter in
        if item != nil {
          player.send(.selectChapter(chapter))
        } else {
          Task {
            await playback.startOrSeek(
              itemID: itemID, toGlobalOffset: chapter.start, episodeID: episodeID)
          }
        }
        isPresented = false
      }
    )
    // The player's own banner sits under this sheet, so the confirmation is shown here too.
    .queueFeedbackBanner(
      message: actions.queueFeedbackMessage, onDismiss: { actions.dismissQueueFeedback() })
  }
}

/// The item-detail History tab's section in its own presentation, so one place decides what a past
/// session looks like and what tapping it does. `ItemDetailHistorySection` draws a plain stack
/// (the detail screen scrolls it as page content), so this sheet supplies the scrolling.
struct PlayerHistorySheet: View {
  let historyModel: ItemHistoryModel?
  let itemID: String
  let playback: PlaybackModel
  @Binding var isPresented: Bool

  var body: some View {
    ItemDetailHistorySheet(
      historyModel: historyModel,
      onSelectEntry: { entry in
        Task {
          await playback.startOrSeek(itemID: itemID, toGlobalOffset: entry.startPosition)
        }
        isPresented = false
      },
      onClose: { isPresented = false }
    )
    .accessibilityIdentifier(PlayerAccessibilityID.historySheet)
    // The session that just ended is the one a listener is most likely looking for, and only a
    // drained refresh can see it. The model's construction walk skips the upload drain.
    .task { await historyModel?.refresh() }
  }
}

struct PlayerUpNextSheet: View {
  let model: ListeningQueueModel
  let coverClient: any ArtworkServing
  let playback: PlaybackModel
  let navigation: NavigationModel
  let onPlayNowCommitted: (PlayerMetadataSeed) -> Void
  /// Raises an episode's card over the player. Without it an episode opens its show instead.
  var onOpenEpisode: ((NavigationModel.PodcastEpisodeRef) -> Void)? = nil
  var style: ListeningQueueSheet.Style = .sheet
  @Binding var isPresented: Bool

  var body: some View {
    ListeningQueueSheet(
      model: model,
      coverClient: coverClient,
      playback: playback,
      onOpen: { identity, category in
        let destination = ListeningQueueSheetPresentation.openDestination(
          identity: identity, category: category)
        if case .episodeCard(let ref) = destination, let onOpenEpisode {
          onOpenEpisode(ref)
          return
        }
        ListeningQueueSheetPresentation.closeQueue(&isPresented)
        navigation.revealFromPlayer(
          PodcastNavigationPresentation.route(itemID: identity.itemID, category: category))
        navigation.collapsePlayer()
      },
      onDismiss: { ListeningQueueSheetPresentation.closeQueue(&isPresented) },
      onPlayNowCommitted: onPlayNowCommitted,
      style: style
    )
  }
}

struct PlayerSleepTimerSheet: View {
  static let compactDetents: Set<PresentationDetent> = [.custom(SleepTimerSheetDetent.self), .large]

  let player: any PlaybackControlling

  var body: some View {
    SleepTimerSheet { duration in
      player.send(.setSleepTimer(duration))
    }
  }
}

/// What `ExpandedPlayerView` needs to host an episode's card from View Details: the card's model
/// factory, and the palette service its artwork draws from. Bundled so the page's memberwise
/// initialiser gains one defaulted property rather than two.
struct PlayerEpisodeCardDependencies {
  let makeModel: (String, String) -> PodcastEpisodeCardModel
  let paletteService: CoverPaletteService
  var transcriptCoordinator: EpisodeTranscriptCoordinator? = nil
}

/// The episode card over the player delegates to the same shared host as the library shell. The
/// player supplies its own model factory and leaving actions, while the card resolves its own play
/// accent from its wash and the shared host owns sheet presentation.
struct PlayerEpisodeCardSheet: View {
  let ref: NavigationModel.PodcastEpisodeRef
  let dependencies: PlayerEpisodeCardDependencies
  let coverClient: any ArtworkServing
  let navigation: NavigationModel
  let playback: PlaybackModel
  let host: PodcastEpisodeCardHost

  var body: some View {
    PodcastEpisodeCardSheet(
      itemID: ref.itemID,
      episodeID: ref.episodeID,
      coverClient: coverClient,
      paletteService: dependencies.paletteService,
      navigation: navigation,
      playback: playback,
      makeModel: { dependencies.makeModel(ref.itemID, ref.episodeID) },
      host: host,
      transcriptCoordinator: dependencies.transcriptCoordinator
    )
  }
}
