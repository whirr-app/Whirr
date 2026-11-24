import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// The episode card plus its long-press menu: the one place a cross-show episode list builds the
/// card, shared by Latest Episodes (both column layouts) and a smart list's screen. Swipe actions
/// are added only by `PodcastEpisodeListRow`, because a two-up layout cannot carry them.
struct PodcastEpisodeCardWithMenu: View {
  let episode: HomePodcastEpisode
  let nowPlaying: ListeningIdentity?
  let isPlaybackActive: Bool
  /// False under a day heading; a list ordered by something other than date keeps it.
  let showsDate: Bool
  /// The call site names its UI; the inventory derives the menu's suppression context from it.
  let placement: PodcastMenuBearingSurface
  let washProvider: HomeWashProvider
  let coverClient: any ArtworkServing
  let downloadStatus: DownloadStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// The row's tap. It opens the episode itself, not its show.
  let onSelect: () -> Void
  /// A play tap on an episode that is not the playing one. The caller decides how it starts, so a
  /// smart list can begin its run.
  let onStart: () -> Void
  let onOpenShow: () -> Void
  let onSearch: (String) -> Void

  var body: some View {
    let isPlaying = PodcastsViewPresentation.isPlaying(
      episode: episode, nowPlaying: nowPlaying, isPlaybackActive: isPlaybackActive)
    WideCompactCard(
      episode: episode,
      provider: washProvider,
      coverClient: coverClient,
      downloadStatus: downloadStatus,
      playback: playback,
      isPlaying: isPlaying,
      showsDate: showsDate,
      onSelect: onSelect,
      onPlay: {
        if isPlaying {
          playback.togglePlayPause(itemID: episode.itemID, episodeID: episode.episodeID)
        } else {
          onStart()
        }
      }
    )
    .accessibilityHint(PodcastsViewPresentation.episodeRowAccessibilityHint)
    .itemContextMenu(
      ItemMenuSubject(
        episode: episode, coverClient: coverClient, playback: playback, actions: actions),
      placement: placement,
      onOpen: onOpenShow,
      onSearch: onSearch
    )
  }
}

/// A single-column episode row: the card with its menu, the shared swipe vocabulary, and the page
/// column's leading alignment and insets. Latest Episodes and a smart list's screen both draw it,
/// so the two cannot drift apart.
struct PodcastEpisodeListRow: View {
  let card: PodcastEpisodeCardWithMenu
  let cardWidth: CGFloat
  let horizontalInset: CGFloat
  /// A smart list's Hide, offered innermost on the trailing edge. Nil elsewhere.
  var onHide: (() -> Void)?

  var body: some View {
    card
      .podcastEpisodeSwipeActions(
        episode: card.episode, nowPlaying: card.nowPlaying, playback: card.playback,
        actions: card.actions, hide: onHide
      )
      // Leading-aligned, not centred: the page column is what centres on an oversized window, so a
      // card narrower than the column sits at its start.
      .frame(maxWidth: cardWidth, alignment: .leading)
      .padding(.horizontal, horizontalInset)
      .padding(.vertical, PodcastEpisodeCardRowMetrics.verticalInset)
  }
}
