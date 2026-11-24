import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct HomeShelfView: View {
  let section: HomeViewPresentation.Section
  let selectedFilter: MediaFilter
  let context: HomeShelfCardContext
  let artworkPrefetchController: HomeArtworkPrefetchController
  let displayScale: CGFloat
  let reduceMotion: Bool
  /// The leading and trailing inset of the header and the card strip. Both browse roots pass
  /// `HomePodcastsBrowseLayout.pageInset`, so a shelf lines up with the rest of its page.
  var horizontalInset: CGFloat = WhirrSpacing.medium
  let onOpenSection: (NavigationModel.Route) -> Void

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// The outer VStack is the bounded shelf viewport. Measuring the horizontal ScrollView would
  /// read its unbounded content width and make card capacity depend on how many items it holds.
  @State private var shelfViewportWidth: CGFloat = 0

  var body: some View {
    #if PERF_INVESTIGATION
      let _ = MicrostutterAblation.logViewChanges ? Self._logChanges() : ()
      let _ = MicrostutterProbe.shared.note("HomeShelfView.body")
    #endif
    let layout = shelfLayout
    let source = context.washProvider.scrollSource(for: .homeRail(section.kind))
    VStack(alignment: .leading, spacing: HomePodcastsBrowseLayout.headerToContentSpacing) {
      BrowseSectionHeaderView(
        title: section.title,
        accessibilityHint: HomeCopy.detailHint(section: section.kind, filter: selectedFilter),
        onSelect: {
          onOpenSection(
            HomeViewPresentation.detailRoute(
              for: section.kind, selectedFilter: selectedFilter))
        }
      )
      .padding(.horizontal, horizontalInset)

      ScrollView(.horizontal, showsIndicators: false) {
        cardStrip(layout: layout)
      }
      .onScrollPhaseChange { _, phase in
        context.washProvider.setScrollInteractionActive(phase, source: source)
      }
      .onDisappear { context.washProvider.retireScrollSource(source) }
      // The empty value for every other shelf makes this modifier inert outside Continue Listening.
      .animation(dismissalMotion.animation, value: dismissalItemIDs)
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      shelfViewportWidth = $0
    }
    .accessibilityIdentifier(HomeAccessibilityID.sectionIdentifier(for: section.kind))
  }

  @ViewBuilder
  private func cardStrip(layout: HomeViewPresentation.ShelfLayout) -> some View {
    let orderedIDs = HomeArtworkPrefetching.orderedIDs(for: section.content)
    let sourcesByID = HomeArtworkPrefetching.sourcesByID(for: section.content)
    let revisionsByID = HomeArtworkPrefetching.revisionsByID(for: section.content)
    // Resolved once for the whole strip, not per card: a shelf marks provenance only when it
    // actually holds both kinds, and every card on it must agree about which shelf it is on.
    let mixesSources = shelfMixesPodcastSources
    // Resolved once for the same reason: every card on the shelf holds the bar's line or none does.
    let reservesProgressLine = shelfReservesProgressLine
    LazyHStack(alignment: .top, spacing: WhirrSpacing.small) {
      switch section.content {
      case .items(let items):
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
          observedCard(
            index: index, orderedIDs: orderedIDs, sourcesByID: sourcesByID,
            revisionsByID: revisionsByID
          ) {
            HomeItemShelfCard(
              item: item,
              occurrence: "home/\(section.kind.rawValue)/\(item.serverItemId)",
              section: section.kind,
              showsProgress: section.kind.showsProgress,
              usesDismissalMotion: section.kind == .continueListening,
              reduceMotion: reduceMotion,
              surfaceMixesSources: mixesSources,
              context: context,
              layout: layout)
          }
        }
      case .podcastEpisodes(let episodes):
        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
          observedCard(
            index: index, orderedIDs: orderedIDs, sourcesByID: sourcesByID,
            revisionsByID: revisionsByID
          ) {
            HomePodcastEpisodeShelfCard(
              episode: episode, surfaceMixesSources: mixesSources,
              reservesProgressLine: reservesProgressLine, context: context, layout: layout)
          }
        }
      case .savedEntries(let entries):
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
          observedCard(
            index: index, orderedIDs: orderedIDs, sourcesByID: sourcesByID,
            revisionsByID: revisionsByID
          ) {
            HomeSavedShelfCard(
              entry: entry,
              occurrence: "home/\(section.kind.rawValue)/\(entry.id)",
              surfaceMixesSources: mixesSources,
              reservesProgressLine: reservesProgressLine,
              context: context,
              layout: layout)
          }
        }
      case .listeningStats, .smartLists:
        // Drawn by `HomeListeningStatsSection` and `SmartListsSectionView`, never as a strip.
        EmptyView()
      }
    }
    .padding(.horizontal, horizontalInset)
  }

  private var shelfMixesPodcastSources: Bool {
    switch section.content {
    case .items(let items): HomeViewPresentation.shelfMixesPodcastSources(items: items)
    case .podcastEpisodes(let episodes):
      HomeViewPresentation.shelfMixesPodcastSources(episodes: episodes)
    case .savedEntries(let entries):
      HomeViewPresentation.shelfMixesPodcastSources(savedEntries: entries)
    case .listeningStats, .smartLists: false
    }
  }

  private var shelfReservesProgressLine: Bool {
    switch section.content {
    // Item shelves decide progress per section kind, and Continue Listening never mixes.
    case .items: false
    case .podcastEpisodes(let episodes):
      HomeViewPresentation.shelfReservesProgressLine(episodes: episodes)
    case .savedEntries(let entries):
      HomeViewPresentation.shelfReservesProgressLine(savedEntries: entries)
    case .listeningStats, .smartLists: false
    }
  }

  private var shelfLayout: HomeViewPresentation.ShelfLayout {
    HomeViewPresentation.ShelfLayout.resolve(
      horizontalSizeClass: horizontalSizeClass,
      availableWidth: HomeViewPresentation.shelfContentWidth(
        viewportWidth: shelfViewportWidth, horizontalInset: horizontalInset),
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  private func observedCard<Content: View>(
    index: Int,
    orderedIDs: [String],
    sourcesByID: [String: ArtworkSource],
    revisionsByID: [String: ArtworkRevision],
    @ViewBuilder content: () -> Content
  ) -> some View {
    content().onAppear {
      #if PERF_INVESTIGATION
        let perfStart = ProcessInfo.processInfo.systemUptime
        defer {
          MicrostutterProbe.shared.note(
            "HomeShelf.cardAppear", elapsed: ProcessInfo.processInfo.systemUptime - perfStart)
        }
      #endif
      harnessNote(.shelfCardAppear)
      if HarnessSwitch.skipsShelfPrefetch == false {
        harnessNote(.prefetchObserve)
        artworkPrefetchController.observe(
          section: section.kind,
          visibleIndex: index,
          orderedIDs: orderedIDs,
          displaySize: HomeView.cardCoverSize,
          displayScale: displayScale,
          client: context.coverClient,
          sourcesByID: sourcesByID,
          revisionsByID: revisionsByID)
      }
      guard orderedIDs.indices.contains(index) else { return }
      let visibleID = orderedIDs[index]
      if HarnessSwitch.skipsVisibleWashRequest == false {
        context.washProvider.request(
          [
            EditorialWashSubject(
              itemID: visibleID, artworkSource: sourcesByID[visibleID],
              artworkRevision: revisionsByID[visibleID] ?? .unversioned)
          ],
          intent: .visible, displaySize: HomeView.cardCoverSize, displayScale: displayScale,
          artworkRole: .homeCard)
      }
      if HarnessSwitch.skipsBulkWashRequest == false {
        context.washProvider.request(
          orderedIDs.filter { $0 != visibleID }.map {
            EditorialWashSubject(
              itemID: $0, artworkSource: sourcesByID[$0],
              artworkRevision: revisionsByID[$0] ?? .unversioned)
          },
          intent: .bulk, displaySize: HomeView.cardCoverSize, displayScale: displayScale,
          artworkRole: .homeCard)
      }
    }
  }

  private var dismissalItemIDs: [String] {
    section.kind == .continueListening ? section.items.map(\.serverItemId) : []
  }

  private var dismissalMotion: HomeViewPresentation.ContinueListeningDismissalMotion {
    HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: reduceMotion)
  }
}
