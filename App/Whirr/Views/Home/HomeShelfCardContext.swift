import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct HomeShelfCardActions {
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onResumeListening: (String, String?) -> Void
  let onSelectDownloadedPodcast: (ItemSummary) -> Void
  let onSelectEpisode: (String, String) -> Void
  let onSearch: (String) -> Void

  func perform(_ selection: HomeCardSelection) {
    switch selection {
    case .item(let summary): onSelectItem(summary)
    case .read(let itemID, let title, let category): onPresentReader(itemID, title, category)
    case .resume(let itemID, let episodeID): onResumeListening(itemID, episodeID)
    case .downloadedPodcast(let summary): onSelectDownloadedPodcast(summary)
    case .episode(let itemID, let episodeID): onSelectEpisode(itemID, episodeID)
    }
  }
}

struct HomeShelfCardContext {
  let coverClient: any ArtworkServing
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let washProvider: HomeWashProvider
  let opensContinueCardImmediately: Bool
  /// Which inventory case this host's item cards raise their menu as: the one card view serves
  /// Home's shelves and the Podcasts tab's Continue Listening rail.
  let itemCardPlacement: PodcastMenuBearingSurface
  let callbacks: HomeShelfCardActions
}

/// The shared episode menu a card raises under its artwork. Here rather than on one card because
/// both the episode shelf card and the saved shelf card put it around what they draw.
@ViewBuilder
func homePodcastEpisodeContextMenu<Content: View>(
  _ card: Content,
  episode: HomePodcastEpisode,
  context: HomeShelfCardContext
) -> some View {
  card.itemContextMenu(
    ItemMenuSubject(
      episode: episode, coverClient: context.coverClient, playback: context.playback,
      actions: context.actions),
    placement: .homeEpisodeCard,
    onOpen: {
      context.callbacks.onSelectItem(episode.showSummary)
    },
    onSearch: context.callbacks.onSearch)
}
