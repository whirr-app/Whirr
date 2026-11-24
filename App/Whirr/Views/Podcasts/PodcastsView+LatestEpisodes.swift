import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

extension PodcastsView {
  var latestEpisodesSection: some View {
    // One read of the player's identity for the whole list: resolving it per row would make every
    // row a dependent of the player. `nowPlayingIdentity` is deduplicated, so this wakes on an
    // identity change, not on the playhead.
    let nowPlaying = playback.nowPlayingIdentity
    let isPlaybackActive = playback.isPlaybackIntended
    let columnWidth = pageColumnWidth
    let columnCount = PodcastsViewPresentation.episodeColumnCount(
      columnWidth: columnWidth, horizontalSizeClass: horizontalSizeClass)
    // Each card leaves its date to the day heading above it, so the list says the day once.
    let sections = HomePodcastEpisodeDaySection.sections(
      PodcastsViewPresentation.latestEpisodePreview(latestModel.podcastEpisodes),
      now: .now, calendar: .current)

    return Group {
      ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
        dayHeading(section.title, isFirst: index == 0)
        if columnCount == 2 {
          let cardWidth = PodcastsViewPresentation.episodeColumnWidth(columnWidth: columnWidth)
          let pairs = PodcastsViewPresentation.episodePairs(section.episodes)
          ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
            latestEpisodePairRow(
              pair, cardWidth: cardWidth, nowPlaying: nowPlaying,
              isPlaybackActive: isPlaybackActive)
          }
        } else {
          ForEach(section.episodes) { episode in
            latestEpisodeRow(episode, nowPlaying: nowPlaying, isPlaybackActive: isPlaybackActive)
          }
        }
      }
    }
    // Stack content, not list rows: no `List` paints a row background here, so the card's fill
    // is drawn inside the row.
    .editorialCardRowOutsideList()
  }

  /// Subordinate to the section's display-type "Latest Episodes" heading: headline weight in
  /// secondary ink, so it orders the cards without competing with their titles.
  private func dayHeading(_ title: String, isFirst: Bool) -> some View {
    Text(title)
      .font(WhirrTypeToken.headline.font)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, pageColumnInset)
      .padding(.top, isFirst ? 0 : WhirrSpacing.small)
      .padding(.bottom, WhirrSpacing.xxSmall)
      .accessibilityAddTraits(.isHeader)
  }

  /// The card plus its long-press menu, shared by both column layouts. Swipe actions are added only
  /// by the single-column caller below (`latestEpisodePairRow` explains why).
  private func latestEpisodeCardWithMenu(
    _ episode: HomePodcastEpisode,
    nowPlaying: ListeningIdentity?,
    isPlaybackActive: Bool
  ) -> PodcastEpisodeCardWithMenu {
    PodcastEpisodeCardWithMenu(
      episode: episode,
      nowPlaying: nowPlaying,
      isPlaybackActive: isPlaybackActive,
      showsDate: false,
      placement: .podcastsTabLatestEpisodeRow,
      washProvider: homeWashProvider,
      coverClient: coverClient,
      downloadStatus: downloadStatus,
      playback: playback,
      actions: actions,
      // This row's tap opens the episode itself, not its show.
      onSelect: { onSelectEpisode(episode.itemID, episode.episodeID) },
      onStart: { Task { await playback.start(itemID: episode.itemID, episodeID: episode.episodeID) } },
      onOpenShow: { onSelectShow(episode.showSummary) },
      onSearch: onSearch)
  }

  private func latestEpisodeRow(
    _ episode: HomePodcastEpisode,
    nowPlaying: ListeningIdentity?,
    isPlaybackActive: Bool
  ) -> some View {
    PodcastEpisodeListRow(
      card: latestEpisodeCardWithMenu(
        episode, nowPlaying: nowPlaying, isPlaybackActive: isPlaybackActive),
      cardWidth: PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: pageColumnWidth),
      horizontalInset: pageColumnInset)
  }

  /// Two cards side by side. Neither carries `.podcastEpisodeSwipeActions`: a swipe reveals its
  /// actions across the row's width, and two cards sharing a row would each claim it. Every swipe
  /// action is also in the card's `.itemContextMenu`.
  private func latestEpisodePairRow(
    _ pair: [HomePodcastEpisode],
    cardWidth: CGFloat,
    nowPlaying: ListeningIdentity?,
    isPlaybackActive: Bool
  ) -> some View {
    HStack(alignment: .top, spacing: PodcastsViewPresentation.episodeColumnGutter) {
      ForEach(pair) { episode in
        latestEpisodeCardWithMenu(
          episode, nowPlaying: nowPlaying, isPlaybackActive: isPlaybackActive
        )
        .frame(width: cardWidth)
      }
      // An odd trailing row holds one card at column width in the leading column, not stretched
      // to the pair's width.
      if pair.count == 1 {
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, pageColumnInset)
    .padding(.vertical, PodcastEpisodeCardRowMetrics.verticalInset)
  }
}
