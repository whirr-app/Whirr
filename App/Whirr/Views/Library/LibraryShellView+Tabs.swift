import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import ReaderCore
import SwiftUI
import SyncEngine

extension LibraryShellView {
  /// One tab per `NavigationModel.Section`, with the adaptive `.sidebarAdaptable`/
  /// `.tabBarMinimizeBehavior` styling. Split out from `body` so `.tabViewBottomAccessory` can
  /// attach to (or omit) the same view without rebuilding it inline in two `if`/`else` branches.
  /// Each tab's content is its own property, so no one expression carries all four screens.
  var tabs: some View {
    TabView(selection: tabSelectionBinding) {
      Tab("Home", systemImage: "house", value: NavigationModel.Section.home) {
        homeTabContent
      }

      Tab("Library", systemImage: "books.vertical", value: NavigationModel.Section.library) {
        libraryTabContent
      }

      if showsPodcastsTab {
        Tab("Podcasts", systemImage: "antenna.radiowaves.left.and.right", value: NavigationModel.Section.podcasts) {
          podcastsTabContent
        }
      }

      Tab("Search", systemImage: "magnifyingglass", value: NavigationModel.Section.search, role: .search) {
        searchTabContent
      }

    }
    // Let the search tab own activation; manual focus requests race its native tab-bar morph.
    .tabViewSearchActivation(.searchTabSelection)
    .tabViewStyle(.sidebarAdaptable)
    // A design choice, not a performance one. Minimising puts the accessory at `.inline`, where
    // `MiniPlayerView.showsSkipControls` is false, so a scroll would silently remove skip-back,
    // the control an audiobook listener reaches for most. Extra bottom viewport is not worth that.
    // Enabling it means changing what the accessory keeps when inline, not just this line.
    .tabBarMinimizeBehavior(.never)
  }

  private var homeTabContent: some View {
    section(.home) {
      HomeView(
        model: homeModel,
        latestEpisodesModel: podcastLatestModel,
        listeningStatsModel: listeningStatsModel,
        coverClient: dependencies.coverClient,
        paletteService: dependencies.paletteService,
        playback: playback,
        actions: actions,
        catalogued: { dependencies.library.currentItemDetail(itemId: $0) },
        onSelectItem: { item in
          select(
            item, artworkRole: .homeCard,
            displaySize: HomeView.cardCoverSize)
        },
        onPresentReader: presentReader,
        onResumeListening: resumeListening,
        onSelectDownloadedPodcast: { item in
          navigation.navigate(
            to: PodcastNavigationPresentation.route(item: item, podcastFilter: .downloaded))
        },
        onSelectEpisode: selectEpisode,
        onOpenSection: { navigation.navigate(to: $0) },
        onSearch: showSearch
      )
    }
  }

  @ViewBuilder private var libraryTabContent: some View {
    section(.library) {
      #if PERF_INVESTIGATION
        if MicrostutterAblation.deferInactiveLibrary, navigation.section != .library {
          Color.clear
        } else {
          libraryBrowseRoot
        }
      #else
        libraryBrowseRoot
      #endif
    }
  }

  private var podcastsTabContent: some View {
    section(.podcasts) {
      PodcastsView(
        listeningModel: podcastListeningModel,
        latestModel: podcastLatestModel,
        showsModel: podcastShowsOrderedModel,
        nativeShowsModel: nativePodcastShowsModel,
        hasIncludedPodcastLibrary: root.hasIncludedPodcastLibrary,
        nativeSubscriptionsEnabled: root.nativeSubscriptionsEnabled,
        rssDownloadsReading: dependencies.rssDownloadsReading,
        downloadIntents: dependencies.downloadIntents,
        coverClient: dependencies.coverClient,
        paletteService: dependencies.paletteService,
        downloadStatus: downloadStatus,
        playback: playback,
        actions: actions,
        notificationModel: podcastNotificationSettingsModel,
        onSelectShow: {
          navigation.navigate(to: PodcastNavigationPresentation.route(item: $0))
        },
        onSelectDownloadedShow: {
          navigation.navigate(
            to: PodcastNavigationPresentation.route(item: $0, podcastFilter: .downloaded))
        },
        onSelectEpisode: selectEpisode,
        onOpenContinueListening: {
          navigation.navigate(to: .podcastContinueListening)
        },
        onOpenLatestEpisodes: {
          navigation.navigate(to: .latestEpisodes)
        },
        // One Your Shows heading picks the initial source from the current followed
        // collection and keeps both route tokens.
        onOpenShows: {
          navigation.navigate(
            to: PodcastShowsHostViewPresentation.headingRoute(
              nativeSubscriptionsEnabled: root.nativeSubscriptionsEnabled,
              hasFollowedShows: nativePodcastShowsModel.shows.isEmpty == false))
        },
        onAddFeed: {
          addFeedModel.reset()
          isAddFeedPresented = true
          updateEditorialWashSuspension()
        },
        onOpenSmartList: { navigation.navigate(to: .smartList(id: $0)) },
        onOpenSmartLists: { navigation.navigate(to: .smartLists) },
        onSearch: showSearch)
    }
  }

  private var searchTabContent: some View {
    section(.search) {
      SearchView(
        model: searchModel,
        library: dependencies.library,
        coverClient: dependencies.coverClient, downloadStatus: downloadStatus,
        finishedStatus: finishedStatus,
        actions: actions, playback: playback,
        onSelect: { item in
          select(
            item, artworkRole: .libraryThumbnail,
            displaySize: WhirrMetric.minimumTouchTarget)
        },
        onSelectWithSource: { item, source in
          select(
            item, artworkRole: .libraryThumbnail,
            displaySize: WhirrMetric.minimumTouchTarget,
            transitionSource: source)
        },
        onSelectRoute: { navigation.navigate(to: $0) },
        onSelectEpisode: selectEpisode,
        onPresentReader: presentReader,
        onSearch: showSearch)
    }
  }

  /// Extracted so the diagnostic above can substitute a placeholder without duplicating this
  /// argument list in two branches. Ordinary builds render it unconditionally.
  @ViewBuilder private var libraryBrowseRoot: some View {
    #if PERF_INVESTIGATION
      if MicrostutterAblation.unboundedLibraryTab {
        unboundedLibraryBrowseRoot
      } else {
        boundedLibraryBrowseRoot
      }
    #else
      boundedLibraryBrowseRoot
    #endif
  }

  /// `.equatable()` stops a `LibraryShellView` body evaluation (which `TabView` runs for every
  /// retained tab on every tab switch) from reaching the Library's catalogue rows. See
  /// `LibraryTabContent`.
  private var boundedLibraryBrowseRoot: some View {
    LibraryTabContent(
      mode: $libraryBrowseMode,
      selectionEntry: librarySelectionEntry,
      browseModel: browseModel,
      authorSeriesReading: dependencies.authorSeriesReading,
      libraryCollections: dependencies.libraryCollections,
      coverClient: dependencies.coverClient,
      downloadStatus: downloadStatus,
      finishedStatus: finishedStatus,
      actions: actions,
      playback: playback,
      relay: refreshedLibraryTabRelay,
      scrollToTopRequest: libraryReselectRequests.count
    )
    .equatable()
  }

  /// The relay's closures are rewritten on every body evaluation so they see the current copy of
  /// this view, while the relay reference (and so `LibraryTabContent`'s equality) is unchanged.
  /// The relay is a plain class, not observed state, so writing it here is not a state mutation
  /// during update.
  private var refreshedLibraryTabRelay: LibraryTabRelay {
    libraryTabRelay.onSelectTitle = { [self] item in
      select(
        item, artworkRole: .libraryThumbnail,
        displaySize: WhirrMetric.minimumTouchTarget,
        podcastFilter: browseModel.filters.downloadedOnly ? .downloaded : nil)
    }
    libraryTabRelay.onSelectEntity = { [self] group in
      let seed = AuthorSeriesDestinationSeed(entity: group.entity, items: group.items)
      switch group.kind {
      case .author:
        navigation.navigate(
          to: .author(
            id: group.entityID, libraryID: group.libraryID, seed: seed))
      case .series:
        navigation.navigate(
          to: .series(
            id: group.entityID, libraryID: group.libraryID, seed: seed))
      case .book, .podcast, .episode:
        break
      }
    }
    libraryTabRelay.onPresentReader = { [self] itemID, title, category in
      presentReader(itemID: itemID, title: title, category: category)
    }
    libraryTabRelay.onSearch = { [self] query in showSearch(query) }
    libraryTabRelay.onSelectCollection = { [self] key in
      navigation.navigate(
        to: .libraryCollection(
          kind: key.kind, serverID: key.serverID, libraryID: key.serverLibraryID))
    }
    return libraryTabRelay
  }

  #if PERF_INVESTIGATION
    /// Closures handed straight to the root, so every shell body evaluation invalidates it. Lets
    /// an A/B/A run compare both shapes on one frozen binary.
    private var unboundedLibraryBrowseRoot: some View {
      LibraryBrowseRootView(
        mode: $libraryBrowseMode,
        selectionEntry: librarySelectionEntry,
        browseModel: browseModel,
        authorSeriesReading: dependencies.authorSeriesReading,
        libraryCollections: dependencies.libraryCollections,
        coverClient: dependencies.coverClient,
        downloadStatus: downloadStatus,
        finishedStatus: finishedStatus,
        actions: actions,
        playback: playback,
        onSelectTitle: { item in
          select(
            item, artworkRole: .libraryThumbnail,
            displaySize: WhirrMetric.minimumTouchTarget,
            podcastFilter: browseModel.filters.downloadedOnly ? .downloaded : nil)
        },
        onSelectEntity: { group in
          let seed = AuthorSeriesDestinationSeed(entity: group.entity, items: group.items)
          switch group.kind {
          case .author:
            navigation.navigate(
              to: .author(
                id: group.entityID, libraryID: group.libraryID, seed: seed))
          case .series:
            navigation.navigate(
              to: .series(
                id: group.entityID, libraryID: group.libraryID, seed: seed))
          case .book, .podcast, .episode:
            break
          }
        },
        onPresentReader: presentReader,
        onSearch: showSearch,
        onSelectCollection: { key in
          navigation.navigate(
            to: .libraryCollection(
              kind: key.kind, serverID: key.serverID, libraryID: key.serverLibraryID))
        },
        scrollToTopRequest: libraryReselectRequests.count
      )
    }
  #endif

  /// Wraps the section binding rather than observing `navigation.section`, because a reselect is a
  /// write of the value the tab bar already holds, so `onChange` sees no change. The binding goes
  /// through `tabSelectionRelay` so it is the same location on every body evaluation.
  var tabSelectionBinding: Binding<NavigationModel.Section> {
    tabSelectionRelay.read = { [navigation] in navigation.section }
    tabSelectionRelay.write = { [self] selection in
      if LibraryReselectRequests.isReselect(selection, current: navigation.section) {
        libraryReselectRequests.record(selection, current: navigation.section)
      }
      navigation.section = selection
      if selection == .podcasts { root.podcastsTabSelected() }
    }
    return Bindable(tabSelectionRelay).selection
  }

}
