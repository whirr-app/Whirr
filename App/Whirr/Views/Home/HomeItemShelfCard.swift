import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct HomeItemShelfCard: View {
  let item: HomeItem
  let occurrence: String
  let section: HomeMoreSection
  let showsProgress: Bool
  let usesDismissalMotion: Bool
  let reduceMotion: Bool
  /// Whether this card's shelf mixes server podcasts with followed feeds, and so wants its server
  /// ones marked. Resolved once per shelf by `HomeShelfView`, never per card.
  let surfaceMixesSources: Bool
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
    @ViewBuilder
    private var staticCard: some View {
      let card = StaticHomeShelfCard(
        layout: layout,
        accessibilityIdentifier: HomeAccessibilityID.cardIdentifier(itemID: item.serverItemId),
        accessibilityLabel: item.title,
        onSelect: {
          selectItem()
        })
      if usesDismissalMotion {
        card.transition(dismissalTransition)
      } else {
        card
      }
    }

  #endif

  @ViewBuilder
  private var fullBody: some View {
    #if PERF_INVESTIGATION
      let _ = MicrostutterAblation.logViewChanges ? Self._logChanges() : ()
      let _ = MicrostutterProbe.shared.note("HomeItemShelfCard.body")
    #endif
    let usesEbookProgress = section == .continueReading
    // The playhead is read inside the reader, below the context menu installed further down, so a
    // tick redraws the card without rebuilding an open menu; see `DisplayedPositionReader`.
    let card = DisplayedPositionReader(
      playback: context.playback, itemID: item.serverItemId, episodeID: item.episodeID,
      // Only a card that prints listening progress asks for it, so no other card depends on it.
      persisted: showsProgress && usesEbookProgress == false ? item.progressSeconds : nil
    ) { progressSeconds in
      itemCard(usesEbookProgress: usesEbookProgress, progressSeconds: progressSeconds)
    }

    let menuCard = Group {
      if ItemContextMenuAvailability.offersMenu(for: item.category) {
        card.itemContextMenu(
          ItemMenuSubject(
            item: item,
            usesEbookProgress: HomeMoreSelectionPolicy.usesEbookProgress(for: item, in: section),
            coverClient: context.coverClient,
            playback: context.playback,
            actions: context.actions),
          placement: context.itemCardPlacement,
          onOpen: { openDetail() },
          onRead: {
            context.callbacks.onPresentReader(item.serverItemId, item.title, item.category)
          },
          onSearch: context.callbacks.onSearch)
      } else {
        card
      }
    }

    if usesDismissalMotion {
      menuCard.transition(dismissalTransition)
    } else {
      menuCard
    }
  }

  /// The drawn card at `progressSeconds`, which `DisplayedPositionReader` resolves in its own body.
  @ViewBuilder
  private func itemCard(usesEbookProgress: Bool, progressSeconds: Double?) -> some View {
    let presentation = HomeViewPresentation.card(
      for: item,
      showsProgress: showsProgress,
      usesEbookProgress: usesEbookProgress,
      progressSeconds: progressSeconds,
      // This title's own speed, not the live player's speed for whichever title is loaded.
      playbackRate: context.playback.effectiveRate(for: item.serverItemId),
      surfaceMixesSources: surfaceMixesSources)
    HomeCardView(
      title: presentation.title,
      subtitle: presentation.subtitle,
      badgeKind: presentation.badgeKind,
      badgeLabel: presentation.badgeLabel,
      sourceMarkSymbol: presentation.sourceMark?.symbolName,
      sourceMarkLabel: presentation.sourceMark?.accessibilityLabel,
      progressFraction: presentation.progressFraction,
      trailingCaption: presentation.trailingCaption,
      finishedLabel: presentation.finishedLabel,
      titleLineLimit: layout.textPolicy.titleLineLimit,
      subtitleLineLimit: layout.textPolicy.subtitleLineLimit,
      accessibilityHint: HomeCopy.continueCardHint(
        for: item.category, in: section,
        opensContinueCardImmediately: context.opensContinueCardImmediately),
      wash: context.washProvider.wash(for: item.washSubject),
      cover: {
        HomeShelfCover(
          itemID: item.serverItemId,
          title: item.title,
          author: item.author,
          presentation: item.category == .podcast ? .fill : .fitTransparent,
          client: context.coverClient,
          source: item.itemSummary.providerArtworkSource,
          revision: item.artworkRevision,
          layout: layout
        )
        .bookZoomTransitionSource(
          bookZoomTransition?.source(item: item.itemSummary, occurrence: occurrence))
      },
      onSelect: {
        selectItem()
      }
    )
    .frame(width: layout.cardWidth)
    #if PERF_INVESTIGATION
      .modifier(MicrostutterCardLayoutAblation())
    #endif
    .accessibilityIdentifier(HomeAccessibilityID.cardIdentifier(itemID: item.serverItemId))
  }

  private func selectItem() {
    let selection = HomeCardSelection.destination(
      for: item, in: section,
      opensContinueCardImmediately: context.opensContinueCardImmediately)
    switch selection {
    case .item(let summary):
      if let bookZoomTransition,
        bookZoomTransition.selectBook(
          summary, occurrence: occurrence, artworkRole: .homeCard,
          displaySize: HomeView.cardCoverSize)
      {
        return
      } else {
        context.callbacks.perform(selection)
      }
    default:
      context.callbacks.perform(selection)
    }
  }

  private func openDetail() {
    if let bookZoomTransition,
      bookZoomTransition.selectBook(
        item.itemSummary, occurrence: occurrence, artworkRole: .homeCard,
        displaySize: HomeView.cardCoverSize)
    {
      return
    }
    context.callbacks.onSelectItem(item.itemSummary)
  }

  private var dismissalTransition: AnyTransition {
    let motion = HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: reduceMotion)
    return .asymmetric(
      insertion: .opacity,
      removal: .scale(scale: motion.removalScale, anchor: .center).combined(with: .opacity))
  }
}
