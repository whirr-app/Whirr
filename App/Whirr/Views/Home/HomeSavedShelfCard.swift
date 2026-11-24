import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct HomeSavedShelfCard: View {
  let entry: SavedShelfItem
  let occurrence: String
  /// Whether this card's shelf mixes server podcasts with followed feeds, and so wants its server
  /// ones marked. Resolved once per shelf by `HomeShelfView`, never per card.
  let surfaceMixesSources: Bool
  /// The shelf's decision, not this card's: see `HomeViewPresentation.shelfReservesProgressLine`.
  var reservesProgressLine = false
  let context: HomeShelfCardContext
  let layout: HomeViewPresentation.ShelfLayout
  @Environment(\.bookZoomTransitionContext) private var bookZoomTransition

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
        accessibilityIdentifier: accessibilityIdentifier,
        accessibilityLabel: entry.episode?.title ?? entry.subjectTitle,
        onSelect: {
          guard entry.isUnavailable == false else { return }
          if let episode = entry.episode {
            context.callbacks.onSelectEpisode(episode.itemID, episode.episodeID)
          } else if let summary = entry.itemSummary {
            selectItem(summary)
          }
        })
    }

  #endif

  @ViewBuilder
  private var fullBody: some View {
    #if PERF_INVESTIGATION
      let _ = MicrostutterAblation.logViewChanges ? Self._logChanges() : ()
      let _ = MicrostutterProbe.shared.note("HomeSavedShelfCard.body")
    #endif
    // Only an episode prints listening progress. Read below the context menu, so a tick redraws
    // the card and not an open menu; see `DisplayedPositionReader`.
    let card = DisplayedPositionReader(
      playback: context.playback, itemID: entry.episode?.itemID ?? entry.identity.itemID,
      episodeID: entry.episode?.episodeID, persisted: entry.episode?.progressSeconds
    ) { progressSeconds in
      savedCard(progressSeconds: progressSeconds)
    }

    // The menu's title and availability do not depend on the position.
    savedCardWithMenu(
      card,
      presentation: HomeViewPresentation.savedCard(
        for: entry, surfaceMixesSources: surfaceMixesSources))
  }

  /// The drawn card at `progressSeconds`, which `DisplayedPositionReader` resolves in its own body.
  @ViewBuilder
  private func savedCard(progressSeconds: Double?) -> some View {
    let presentation = HomeViewPresentation.savedCard(
      for: entry,
      progressSeconds: progressSeconds,
      surfaceMixesSources: surfaceMixesSources)
    let itemID = entry.identity.itemID
    HomeCardView(
      title: presentation.title,
      subtitle: presentation.subtitle,
      badgeKind: presentation.badgeKind,
      badgeLabel: presentation.badgeLabel,
      sourceMarkSymbol: presentation.sourceMark?.symbolName,
      sourceMarkLabel: presentation.sourceMark?.accessibilityLabel,
      progressFraction: presentation.progressFraction,
      reservesProgressLine: reservesProgressLine,
      trailingCaption: presentation.trailingCaption,
      finishedLabel: presentation.finishedLabel,
      titleLineLimit: layout.textPolicy.titleLineLimit,
      subtitleLineLimit: layout.textPolicy.subtitleLineLimit,
      wash: context.washProvider.wash(for: entry.washSubject),
      cover: {
        HomeShelfCover(
          itemID: itemID,
          title: entry.contextTitle ?? entry.subjectTitle,
          author: entry.episode?.showAuthor ?? entry.itemSummary?.author,
          presentation: entry.episode == nil ? .fitTransparent : .fill,
          client: context.coverClient,
          source: entry.episode?.providerArtworkSource ?? entry.itemSummary?.providerArtworkSource,
          revision: entry.artworkRevision,
          layout: layout
        )
        .bookZoomTransitionSource(
          entry.itemSummary.flatMap {
            bookZoomTransition?.source(item: $0, occurrence: occurrence)
          })
      },
      onSelect: {
        guard entry.isUnavailable == false else { return }
        if let episode = entry.episode {
          context.callbacks.onSelectEpisode(episode.itemID, episode.episodeID)
        } else if let summary = entry.itemSummary {
          selectItem(summary)
        }
      }
    )
    .frame(width: layout.cardWidth)
    #if PERF_INVESTIGATION
      .modifier(MicrostutterCardLayoutAblation())
    #endif
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  private var accessibilityIdentifier: String {
    if let episode = entry.episode {
      return HomeAccessibilityID.episodeCardIdentifier(
        itemID: episode.itemID, episodeID: episode.episodeID)
    }
    return HomeAccessibilityID.cardIdentifier(itemID: entry.identity.itemID)
  }

  @ViewBuilder
  private func savedCardWithMenu<Content: View>(
    _ card: Content,
    presentation: HomeViewPresentation.Card
  ) -> some View {
    let menuCard = Group {
      if entry.isUnavailable == false, presentation.usesItemContextMenu {
        if let episode = entry.episode {
          homePodcastEpisodeContextMenu(card, episode: episode, context: context)
        } else if let summary = entry.itemSummary {
          card.itemContextMenu(
            ItemMenuSubject(
              summary: summary,
              title: presentation.title,
              category: entry.category,
              coverClient: context.coverClient,
              source: summary.providerArtworkSource,
              revision: summary.artworkRevision,
              playback: context.playback,
              actions: context.actions),
            placement: .homeItemCard,
            onOpen: { selectItem(summary) },
            onRead: {
              context.callbacks.onPresentReader(summary.serverItemId, summary.title, entry.category)
            },
            onSearch: context.callbacks.onSearch)
        } else {
          card
        }
      } else {
        card
      }
    }

    if entry.isUnavailable {
      let identity = entry.identity
      let removePresentation = ItemContextMenuPresentation.savedEntry(isSaved: true)
      // Keep the tombstone tap disabled while leaving its one viable removal action enabled.
      menuCard
        .disabled(true)
        .contextMenu {
          Button {
            Task {
              await context.actions.removeFromSaved(
                itemID: identity.itemID, episodeID: identity.episodeID)
            }
          } label: {
            Label(removePresentation.title, systemImage: removePresentation.systemImage)
          }
        }
    } else {
      menuCard
    }
  }

  private func selectItem(_ summary: ItemSummary) {
    if bookZoomTransition?.selectBook(
      summary, occurrence: occurrence, artworkRole: .homeCard,
      displaySize: HomeView.cardCoverSize) != true
    {
      context.callbacks.onSelectItem(summary)
    }
  }
}
