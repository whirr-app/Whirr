import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// Podcasts use a different hierarchy from books: episodes are the active content and shows are
/// the collection. This root keeps that distinction visible instead of presenting shows as
/// "recently added" titles.
struct PodcastsView: View {
  @Bindable var listeningModel: HomeModel
  @Bindable var latestModel: HomeMoreModel
  /// The same `PodcastShowsModel` instance the pushed
  /// `.podcastShows` all-shows page renders (`RootComposition` composes it once), so the root's
  /// bounded preview and the full page can never disagree about order.
  @Bindable var showsModel: PodcastShowsModel
  @Bindable var nativeShowsModel: NativePodcastShowsModel
  let hasIncludedPodcastLibrary: Bool
  let nativeSubscriptionsEnabled: Bool
  let rssDownloadsReading: any RSSDownloadsReading
  let downloadIntents: any DownloadIntents
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let downloadStatus: DownloadStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// The shell's one notification model, shared with Settings. Nil hosts never show the offer.
  let notificationModel: PodcastNotificationSettingsModel?
  let notificationOffer: any PodcastNotificationOfferMarking
  /// The selected show itself is carried through so the destination can paint its first frame
  /// without a synchronous metadata lookup.
  let onSelectShow: (ItemSummary) -> Void
  /// A show tile tapped under the Downloads filter opens the show on its downloaded episodes,
  /// matching Home's and Library's downloaded-podcast deep link.
  let onSelectDownloadedShow: (ItemSummary) -> Void
  /// Every cross-show episode surface opens the episode card instead of pushing the show. The
  /// continue-listening card and the latest-episode row both resolve here.
  let onSelectEpisode: (String, String) -> Void
  /// Opens the same podcast-filtered detail lists as the matching headings on Home.
  let onOpenContinueListening: () -> Void
  let onOpenLatestEpisodes: () -> Void
  /// The one Your Shows heading forwards to the shell. The shell chooses the initial source from
  /// the currently followed collection while the destination still preserves the route token.
  let onOpenShows: () -> Void
  let onAddFeed: () -> Void
  /// A smart list's row opens its screen; the section heading opens Edit Smart Lists.
  let onOpenSmartList: (Int64) -> Void
  let onOpenSmartLists: () -> Void
  let onSearch: (String) -> Void
  /// The one-time introduction sheet's seen marker; the harness passes an already-seen value.
  let introduction: any PodcastIntroductionMarking

  @Environment(\.displayScale) var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  /// Nil where smart lists are not composed; the section then never draws.
  @Environment(\.smartLists) var smartLists
  @State var smartListEditorRequest: SmartListEditorRequest?
  @State var filter: PodcastsViewPresentation.Filter = .all
  @State private var deferredRSSDownloads = DeferredModel<RSSDownloadsModel>()
  @State var homeWashProvider: HomeWashProvider
  @State private var artworkPrefetchController = HomeArtworkPrefetchController()
  @State private var availableWidth: CGFloat = 0
  /// Measured because the filter row moves with Dynamic Type and the placeholder fills the rest.
  @State private var filterRowHeight: CGFloat = 0
  /// Not `@AppStorage`: this is a tab root, and that invalidates on any `UserDefaults` write.
  /// See `HomeSectionPreferencesStore`.
  let sectionPreferences = HomeSectionPreferencesStore.shared
  /// Which All-layout sections show and in what order; the continuation-card preference above
  /// stays on Home's store.
  let rootSectionPreferences = PodcastsSectionPreferencesStore.shared

  static let cardSize: CGFloat = HomeView.cardCoverSize

  /// The one inset every regular-width section of this screen shares. See
  /// `PodcastsViewPresentation.pageColumnInset` for why the root does not use
  /// `boundedRowHorizontalInset`'s own centering, which applies only to the podcast show detail
  /// screen.
  var pageColumnInset: CGFloat {
    PodcastsViewPresentation.pageColumnInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  /// The width inside `pageColumnInset` on both edges. Episode columns, the shows grid, and the
  /// preview limit all derive from this one value.
  var pageColumnWidth: CGFloat {
    PodcastsViewPresentation.pageColumnWidth(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  init(
    listeningModel: HomeModel,
    latestModel: HomeMoreModel,
    showsModel: PodcastShowsModel,
    nativeShowsModel: NativePodcastShowsModel,
    hasIncludedPodcastLibrary: Bool,
    nativeSubscriptionsEnabled: Bool,
    rssDownloadsReading: any RSSDownloadsReading = NoOpRSSDownloadsReading(),
    downloadIntents: any DownloadIntents = NoOpDownloadIntents(),
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    downloadStatus: DownloadStatusStore,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    notificationModel: PodcastNotificationSettingsModel? = nil,
    notificationOffer: any PodcastNotificationOfferMarking = PodcastNotificationOfferPreference(
      defaults: UserDefaults.standard),
    onSelectShow: @escaping (ItemSummary) -> Void,
    onSelectDownloadedShow: @escaping (ItemSummary) -> Void,
    onSelectEpisode: @escaping (String, String) -> Void,
    onOpenContinueListening: @escaping () -> Void,
    onOpenLatestEpisodes: @escaping () -> Void,
    onOpenShows: @escaping () -> Void,
    onAddFeed: @escaping () -> Void,
    onOpenSmartList: @escaping (Int64) -> Void = { _ in },
    onOpenSmartLists: @escaping () -> Void = {},
    onSearch: @escaping (String) -> Void,
    introduction: any PodcastIntroductionMarking = PodcastIntroductionPreference(
      defaults: UserDefaults.standard)
  ) {
    _listeningModel = Bindable(listeningModel)
    _latestModel = Bindable(latestModel)
    _showsModel = Bindable(showsModel)
    _nativeShowsModel = Bindable(nativeShowsModel)
    self.hasIncludedPodcastLibrary = hasIncludedPodcastLibrary
    self.nativeSubscriptionsEnabled = nativeSubscriptionsEnabled
    self.rssDownloadsReading = rssDownloadsReading
    self.downloadIntents = downloadIntents
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.downloadStatus = downloadStatus
    self.playback = playback
    self.actions = actions
    self.notificationModel = notificationModel
    self.notificationOffer = notificationOffer
    self.onSelectShow = onSelectShow
    self.onSelectDownloadedShow = onSelectDownloadedShow
    self.onSelectEpisode = onSelectEpisode
    self.onOpenContinueListening = onOpenContinueListening
    self.onOpenLatestEpisodes = onOpenLatestEpisodes
    self.onOpenShows = onOpenShows
    self.onAddFeed = onAddFeed
    self.onOpenSmartList = onOpenSmartList
    self.onOpenSmartLists = onOpenSmartLists
    self.onSearch = onSearch
    self.introduction = introduction
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Self.cardSize, displayScale: 1, artworkRole: .homeCard))
  }

  var body: some View {
    CleanRoomPerformanceSignposts.withInterval("PodcastsView.body") {
      content
        .itemActionErrorAlert(actions)
        .smartListEditorSheet(request: $smartListEditorRequest)
        .navigationTitle("Podcasts")
        // Add Podcast is declared by the shell (`LibraryShellPresentation.rootToolbarTrailingOrder`),
        // not here: two `.toolbar` declarations at two levels leave neither one deciding their
        // relative order. `onAddFeed` is still used by the empty state below.
        .refreshable { await listeningModel.refresh() }
        .onDisappear {
          homeWashProvider.retireAllScrollSources()
          artworkPrefetchController.cancelAll()
        }
        .podcastIntroduction(
          marking: introduction, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
          hasServerAccount: hasIncludedPodcastLibrary)
    }
  }

  private var rssDownloadsModel: RSSDownloadsModel {
    deferredRSSDownloads.resolve {
      RSSDownloadsModel(reading: rssDownloadsReading, downloadIntents: downloadIntents)
    }
  }

  private var content: some View {
    // Merged once, uncapped, so the footer can count what the preview leaves out; the preview is
    // a prefix of that same order, exactly as a capped merge would return it.
    let allShows = PodcastsViewPresentation.showsSectionShows(
      nativeShows: nativeShows,
      nativeMode: nativeShowsModel.sortMode,
      serverShows: visibleServerShows,
      serverMode: showsModel.sortMode,
      nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
      hasIncludedPodcastLibrary: hasIncludedPodcastLibrary)
    let showsPreview = Array(
      allShows.prefix(
        PodcastsViewPresentation.showsSectionLimit(
          filter: filter, columnWidth: pageColumnWidth, horizontalSizeClass: horizontalSizeClass,
          isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)))
    let showsSectionIsReachable = showsPreview.isEmpty == false
    // A list is content: a tab whose only content is a smart list must not draw the empty state
    // over it.
    let hasContent =
      listeningModel.continueListening.isEmpty == false
      || latestModel.podcastEpisodes.isEmpty == false
      || showsSectionIsReachable
      || smartListCount > 0
    let hasFilterContent: Bool
    switch filter {
    case .all: hasFilterContent = hasContent
    case .yourShows: hasFilterContent = showsSectionIsReachable
    case .downloaded: hasFilterContent = downloadedShows.isEmpty == false
    }

    let placeholder = PodcastsViewPresentation.placeholder(
      for: filter,
      continueListening: listeningModel.state,
      latestEpisodes: latestModel.state,
      shows: showsModel.state,
      nativeShows: nativeShowsModel.state,
      rssDownloadsHaveLoaded: rssDownloadsHaveLoaded,
      nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
      hasIncludedPodcastLibrary: hasIncludedPodcastLibrary,
      hasContent: hasFilterContent)
    let washSubjects = PodcastsViewPresentation.latestEpisodeWashSubjects(
      for: filter, episodes: latestModel.podcastEpisodes)

    // A stack, not a `List`, for the reason Home gives (`HomeView.content`): on iOS 27 a card menu
    // inside a list cell does not present, and a cell holding several cards resolves them as
    // one. Here every card owns its own menu and no row needs hosting.
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        filterPicker
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            filterRowHeight = $0
          }
          .padding(.top, HomePodcastsBrowseLayout.filterRowTopSpacing)

        // In the stack, under the filter row: the placeholder overlay clears only that row, so
        // the card is never offered while a placeholder is due.
        if let notificationModel {
          PodcastNotificationOfferCard(
            model: notificationModel, marking: notificationOffer,
            nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
            hasFollowedShows: nativeShows.isEmpty == false,
            filterShowsOffer: PodcastsViewPresentation.showsNotificationOffer(for: filter),
            hasPlaceholder: placeholder != nil,
            horizontalInset: pageColumnInset)
        }

        filterContent(
          shows: showsPreview, totalShowCount: allShows.count,
          showsSectionIsReachable: showsSectionIsReachable
        )
        .transition(.opacity)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // Scoped to the content, never the container (see `filterChangeMotion`).
      .animation(
        PodcastsViewPresentation.filterChangeMotion(reduceMotion: reduceMotion), value: filter
      )
      .swipeActionsContainerWhereSupported()
    }
    .scrollContentBackground(.hidden)
    .scrollIndicators(.hidden, axes: .vertical)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { _, width in
      availableWidth = width
    }
    .primaryScrollEdgeEffect()
    .onScrollPhaseChange { _, phase in
      homeWashProvider.setScrollInteractionActive(
        phase, source: homeWashProvider.scrollSource(for: .podcastsOuter))
    }
    // An overlay, not list content: the placeholder must never add height to the scroll host.
    .overlay {
      if let placeholder {
        placeholderView(placeholder, filter: filter)
          .padding(.top, filterRowHeight)
          .allowsHitTesting(placeholder.allowsHitTesting)
      }
    }
    // Owned by the page so it starts on appear, not when a lazy row is built. Keyed on the
    // show/item-ID set so episode-only or player/model ticks don't rerun it; filters without the
    // episode list give an empty set, which the guard makes a no-op.
    .task(id: Set(washSubjects)) {
      // One batched records-only preload, published as a single mutation before the user can
      // scroll: warm items across all three sections are colored from the first frame. Only
      // record misses take the lazy (idle-deferred) resolution path below.
      await homeWashProvider.preloadCachedWashes(
        washSubjects
          + listeningModel.continueListening.map(\.washSubject)
          + showsPreview.map(\.washSubject))
      guard washSubjects.isEmpty == false else { return }
      homeWashProvider.request(
        washSubjects,
        intent: .bulk,
        displaySize: PodcastsViewPresentation.episodeThumbnailSize,
        displayScale: displayScale,
        artworkRole: .libraryThumbnail)
    }
  }

  @ViewBuilder
  private func filterContent(
    shows: [ItemSummary], totalShowCount: Int, showsSectionIsReachable: Bool
  ) -> some View {
    switch filter {
    case .all:
      // One eager child of the lazy page, as Home's page is eager: every section here is a capped
      // preview, and a lazy page rebuilds a section that left range when it scrolls back.
      VStack(alignment: .leading, spacing: 0) {
        allContent(
          shows: shows, totalShowCount: totalShowCount,
          showsSectionIsReachable: showsSectionIsReachable)
      }
    case .yourShows:
      if showsSectionIsReachable {
        showsGridSection(
          title: PodcastsViewPresentation.showsSectionTitle,
          onSelect: onOpenShows, shows: shows, totalShowCount: totalShowCount, isFirst: true)
      }
    case .downloaded:
      if downloadedShows.isEmpty == false {
        showsSection(downloadedShows)
          .padding(.vertical, WhirrSpacing.medium)
      }
    }
  }

  /// Home's own shelf, so the two Continue Listening rails cannot drift apart. Its heading's
  /// route is `.podcastContinueListening` by construction; the shell's callback owns navigation.
  private func continueListeningShelf(_ section: HomeViewPresentation.Section) -> some View {
    HomeShelfView(
      section: section,
      selectedFilter: .podcasts,
      context: HomeShelfCardContext(
        coverClient: coverClient,
        playback: playback,
        actions: actions,
        washProvider: homeWashProvider,
        opensContinueCardImmediately: sectionPreferences.opensContinueCardImmediately,
        itemCardPlacement: .podcastsTabContinueListeningCard,
        callbacks: HomeShelfCardActions(
          onSelectItem: onSelectShow,
          onPresentReader: { _, _, _ in
            assertionFailure("A podcast continuation cannot open the reader")
          },
          onResumeListening: { itemID, episodeID in
            Task { await playback.start(itemID: itemID, episodeID: episodeID) }
          },
          onSelectDownloadedPodcast: onSelectDownloadedShow,
          onSelectEpisode: onSelectEpisode,
          onSearch: onSearch)),
      artworkPrefetchController: artworkPrefetchController,
      displayScale: displayScale,
      reduceMotion: reduceMotion,
      horizontalInset: pageColumnInset,
      onOpenSection: { _ in onOpenContinueListening() })
  }

  @ViewBuilder
  private func allContent(
    shows: [ItemSummary], totalShowCount: Int, showsSectionIsReachable: Bool
  ) -> some View {
    let drawn = PodcastsViewPresentation.drawnRootSections(
      visible: PodcastsViewPresentation.visibleRootSections(
        hiddenSections: rootSectionPreferences.hiddenSections,
        sectionOrder: rootSectionPreferences.sectionOrder),
      hasContinueListening: listeningModel.continueListening.isEmpty == false,
      hasLatestEpisodes: latestModel.podcastEpisodes.isEmpty == false,
      hasSmartLists: smartListsSectionIsDrawn(showsSectionIsReachable: showsSectionIsReachable),
      showsSectionIsReachable: showsSectionIsReachable)

    ForEach(Array(drawn.enumerated()), id: \.element) { index, section in
      switch section {
      case .continueListening:
        if let shelf = PodcastsViewPresentation.continueListeningSection(
          listeningModel.continueListening)
        {
          continueListeningShelf(shelf)
            .padding(.top, HomePodcastsBrowseLayout.shelfTopSpacing(isFirst: index == 0))
        }
      case .latestEpisodes:
        BrowseSectionHeaderView(
          title: HomeCopy.latestEpisodesTitle,
          accessibilityHint: HomeCopy.detailHint(section: .newEpisodes, filter: .podcasts),
          onSelect: onOpenLatestEpisodes
        )
        .padding(.horizontal, pageColumnInset)
        .padding(.top, HomePodcastsBrowseLayout.shelfTopSpacing(isFirst: index == 0))
        .padding(.bottom, HomePodcastsBrowseLayout.headerToContentSpacing)

        latestEpisodesSection
      case .smartLists:
        smartListsSection(isFirst: index == 0)
      case .yourShows:
        showsGridSection(
          title: PodcastsViewPresentation.showsSectionTitle,
          onSelect: onOpenShows, shows: shows, totalShowCount: totalShowCount,
          isFirst: index == 0)
      }
    }
  }

  private var filterPicker: some View {
    MediaFilterPicker(
      title: PodcastsViewPresentation.Filter.title,
      labels: PodcastsViewPresentation.Filter.allCases.map(\.label),
      selectedIndex: PodcastsViewPresentation.Filter.allCases.firstIndex(of: filter) ?? 0,
      style: .chips,
      onSelect: { index in
        guard PodcastsViewPresentation.Filter.allCases.indices.contains(index) else { return }
        filter = PodcastsViewPresentation.Filter.allCases[index]
      }
    )
    // The chip strip already carries `WhirrSpacing.medium` internally (`MediaFilterPicker`'s own
    // `.chips` layout); only the page inset's excess over that base margin belongs out here, so the
    // chips' visible edge matches every other section's without double-padding the common case.
    .padding(.horizontal, pageColumnInset - WhirrSpacing.medium)
    .padding(.bottom, HomePodcastsBrowseLayout.filterBottomSpacing)
    .accessibilityIdentifier(PodcastAccessibilityID.filterPicker)
  }

  @ViewBuilder
  private func placeholderView(
    _ placeholder: PodcastsViewPresentation.Placeholder,
    filter: PodcastsViewPresentation.Filter
  ) -> some View {
    switch placeholder {
    case .loading:
      LoadingStateView(message: "Loading podcasts…")
    case .empty:
      let content = PodcastsViewPresentation.emptyState(
        for: filter,
        nativeSubscriptionsEnabled: nativeSubscriptionsEnabled)
      EmptyStateView(
        title: content.title, message: content.message, systemImage: content.systemImage,
        actionLabel: content.actionLabel,
        action: content.actionLabel == nil ? nil : onAddFeed)
    case .error(let action):
      EmptyStateView(
        title: "Couldn't Load Podcasts", message: PodcastShowsCopy.error,
        systemImage: "exclamationmark.triangle", actionLabel: action.label
      ) {
        switch action {
        case .retry:
          Task { await listeningModel.refresh() }
        }
      }
    }
  }

  private var shows: [ItemSummary] {
    PodcastsViewPresentation.shows(in: showsModel.state)
  }

  private var nativeShows: [ItemSummary] { nativeShowsModel.shows }

  private var visibleServerShows: [ItemSummary] {
    guard
      PodcastsViewPresentation.showsServerSection(
        hasIncludedPodcastLibrary: hasIncludedPodcastLibrary, serverShows: shows)
    else { return [] }
    return shows
  }

  private var downloadedShows: [ItemSummary] {
    PodcastsViewPresentation.downloadedShows(
      serverShows: shows,
      nativeShows: nativeShows,
      downloadedServerIDs: downloadStatus.downloadedPodcastItemIDs,
      downloadedNativeFeedIDs: downloadedRSSFeedIDs)
  }

  /// The RSS observer is dormant until Downloads is selected, and remains dormant altogether when
  /// native subscriptions are disabled. `||` and the guard short-circuit resolution.
  private var rssDownloadsHaveLoaded: Bool {
    filter != .downloaded || nativeSubscriptionsEnabled == false || rssDownloadsModel.hasLoaded
  }

  private var downloadedRSSFeedIDs: Set<Int64> {
    guard filter == .downloaded, nativeSubscriptionsEnabled else { return [] }
    return Set(rssDownloadsModel.feeds.map(\.id))
  }
}
