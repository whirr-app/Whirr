import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct HomePodcastEpisodeShelfCard: View {
  let episode: HomePodcastEpisode
  /// Whether this card's shelf mixes server podcasts with followed feeds, and so wants its server
  /// ones marked. Resolved once per shelf by `HomeShelfView`, never per card.
  let surfaceMixesSources: Bool
  /// The shelf's decision, not this card's: see `HomeViewPresentation.shelfReservesProgressLine`.
  var reservesProgressLine = false
  let context: HomeShelfCardContext
  let layout: HomeViewPresentation.ShelfLayout

  @ViewBuilder
  var body: some View {
    #if PERF_INVESTIGATION
      if MicrostutterAblation.staticCards {
        staticCard
      } else {
        fullBody
      }
    #else
      fullBody
    #endif
  }

  #if PERF_INVESTIGATION
    private var staticCard: some View {
      StaticHomeShelfCard(
        layout: layout,
        accessibilityIdentifier: HomeAccessibilityID.episodeCardIdentifier(
          itemID: episode.itemID, episodeID: episode.episodeID),
        accessibilityLabel: episode.title,
        onSelect: {
          context.callbacks.onSelectEpisode(episode.itemID, episode.episodeID)
        })
    }

  #endif

  @ViewBuilder
  private var fullBody: some View {
    #if PERF_INVESTIGATION
      let _ = MicrostutterAblation.logViewChanges ? Self._logChanges() : ()
      let _ = MicrostutterProbe.shared.note("HomePodcastEpisodeShelfCard.body")
    #endif
    // Read below the context menu, so a tick redraws the card and not an open menu; see
    // `DisplayedPositionReader`.
    let card = DisplayedPositionReader(
      playback: context.playback, itemID: episode.itemID, episodeID: episode.episodeID,
      persisted: episode.progressSeconds
    ) { progressSeconds in
      episodeCard(progressSeconds: progressSeconds)
    }

    homePodcastEpisodeContextMenu(card, episode: episode, context: context)
  }

  /// The drawn card at `progressSeconds`, which `DisplayedPositionReader` resolves in its own body.
  @ViewBuilder
  private func episodeCard(progressSeconds: Double?) -> some View {
    let presentation = HomeViewPresentation.episodeCard(
      for: episode,
      progressSeconds: progressSeconds,
      surfaceMixesSources: surfaceMixesSources)
    HomeCardView(
      title: presentation.title,
      subtitle: presentation.subtitle,
      badgeKind: presentation.badgeKind,
      badgeLabel: presentation.badgeLabel,
      sourceMarkSymbol: presentation.sourceMark?.symbolName,
      sourceMarkLabel: presentation.sourceMark?.accessibilityLabel,
      progressFraction: presentation.progressFraction,
      reservesProgressLine: reservesProgressLine,
      showsEmptyProgressTrack: HomeViewPresentation.episodeShelfShowsEmptyProgressTrack,
      trailingCaption: presentation.trailingCaption,
      titleLineLimit: layout.textPolicy.titleLineLimit,
      subtitleLineLimit: layout.textPolicy.subtitleLineLimit,
      wash: context.washProvider.wash(for: episode.washSubject),
      cover: {
        HomeShelfCover(
          itemID: episode.itemID, title: episode.showTitle, author: nil,
          presentation: .fill, client: context.coverClient,
          source: episode.providerArtworkSource, revision: episode.artworkRevision,
          layout: layout)
      },
      onSelect: {
        context.callbacks.onSelectEpisode(episode.itemID, episode.episodeID)
      }
    )
    .frame(width: layout.cardWidth)
    #if PERF_INVESTIGATION
      .modifier(MicrostutterCardLayoutAblation())
    #endif
    .accessibilityIdentifier(
      HomeAccessibilityID.episodeCardIdentifier(
        itemID: episode.itemID, episodeID: episode.episodeID))
  }
}
