import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import ReaderCore
import SwiftUI
import SyncEngine

extension LibraryShellView {
  /// One section's stack. `navigationDestination` resolves pushed routes for every section
  /// identically, so a deep link into any tab lands on the same screen it would by tapping.
  func section<Root: View>(
    _ section: NavigationModel.Section,
    @ViewBuilder content: () -> Root
  ) -> some View {
    NavigationStack(path: pathBinding(for: section)) {
      content()
        .toolbarTitleDisplayMode(
          LibraryShellPresentation.hidesRootTitle(in: section)
            ? .inline
            : LibraryShellPresentation.usesInlineLargeTitle(in: section) ? .inlineLarge : .automatic
        )
        .toolbar(removing: LibraryShellPresentation.hidesRootTitle(in: section) ? .title : nil)
        .toolbar {
          rootToolbar(for: section)
        }
        .navigationDestination(for: NavigationModel.Route.self) { route in
          // Every pushed screen gets its route's title mode here, so none inherits the bar of
          // the screen it was pushed from: a bar that changes mode mid-push re-lays-out under the
          // incoming title.
          Group {
            switch route {
            case .itemDetail(let itemID, let seed):
              let path = navigation[pathFor: section]
              itemDetailDestination(
                itemID: itemID,
                seed: seed,
                transitionSource: path.last == route
                  ? bookZoomRegistry.sourceForDestination(
                    section: section, path: path, route: route)?.source
                  : nil)
            case .podcastShow(let itemID, let filter, let seed):
              PodcastShowView(
                itemID: itemID,
                seed: seed,
                library: dependencies.library,
                nativePodcastShowsReading: dependencies.nativePodcastShowsReading,
                coverClient: dependencies.coverClient,
                paletteService: dependencies.paletteService,
                followedShowArtworkSources: followedShowArtworkSources,
                playback: playback,
                makeModel: { makePodcastShowModel(itemID, filter) },
                onSearch: showSearch,
                onPresentEpisode: { navigation.presentEpisode($0) },
                onOpenShowSettings: { title in
                  navigation.navigate(
                    to: PodcastShowViewPresentation.showSettingsDestination(
                      itemID: itemID, titleSeed: title))
                }
              )
              .onDisappear { artworkPreflight.destinationDisappeared(itemID: itemID) }
            case .homeMore(let section, let filter):
              if section == .savedForLater {
                savedForLaterDestination(filter: filter)
              } else if section == .listeningStats {
                ListeningStatsView(
                  model: listeningStatsModel,
                  nativePodcastsEnabled: root.nativeSubscriptionsEnabled,
                  coverClient: dependencies.coverClient,
                  catalogued: { dependencies.library.currentItemDetail(itemId: $0) },
                  onSelectItem: { item in
                    select(
                      item, artworkRole: .libraryThumbnail,
                      displaySize: WhirrMetric.minimumTouchTarget)
                  })
              } else if section == .smartLists {
                // Home opens `.smartLists` itself; this is a restored path that names the section.
                if let smartLists {
                  EditSmartListsView(
                    access: smartLists, coverClient: dependencies.coverClient,
                    onOpenList: { navigation.navigate(to: .smartList(id: $0)) })
                }
              } else if section == .downloaded {
                downloadsDestination(filter: filter)
              } else {
                HomeMoreView(
                  section: section,
                  filter: filter,
                  makeModel: {
                    section == .newEpisodes
                      ? podcastLatestModel
                      : makeHomeMoreModel(section, filter)
                  },
                  coverClient: dependencies.coverClient,
                  paletteService: dependencies.paletteService,
                  downloadStatus: downloadStatus,
                  actions: actions,
                  playback: playback,
                  onSelectItem: { item in
                    select(
                      item, artworkRole: .libraryThumbnail,
                      displaySize: WhirrMetric.minimumTouchTarget)
                  },
                  onPresentReader: presentReader,
                  onResumeListening: resumeListening,
                  onSelectDownloadedPodcast: { item in
                    navigation.navigate(
                      to: PodcastNavigationPresentation.route(
                        item: item, podcastFilter: .downloaded))
                  },
                  onSelectEpisode: selectEpisode,
                  onSearch: showSearch)
              }
            case .podcastShows, .nativePodcastShows:
              PodcastShowsHostView(
                model: podcastShowsOrderedModel,
                nativeModel: nativePodcastShowsModel,
                originatingRoute: route,
                nativeSubscriptionsEnabled: root.nativeSubscriptionsEnabled,
                coverClient: dependencies.coverClient,
                paletteService: dependencies.paletteService,
                playback: playback,
                actions: actions,
                onSelectShow: {
                  navigation.navigate(to: PodcastNavigationPresentation.route(item: $0))
                },
                onSearch: showSearch,
                onNativeOriginDisabled: truncateNativeShowsDestination)
            case .storage:
              downloadsDestination(filter: .all)
            case .resolutionCenter:
              ResolutionCenterView(access: dependencies.resolutionCenterAccess)
            // Entity links open the complete shelf, independently of the active tab's filter.
            // Keep the root filters intact so returning to browsing restores the same list.
            case .author(let id, let libraryID, let seed):
              AuthorSeriesView(
                makeModel: {
                  AuthorSeriesModel(
                    target: .author(id: id, libraryID: libraryID), reading: dependencies.authorSeriesReading,
                    library: dependencies.library, filters: .unfiltered, seed: seed)
                },
                coverClient: dependencies.coverClient,
                paletteService: dependencies.paletteService,
                finishedStatus: finishedStatus,
                playback: playback,
                actions: actions,
                onSelectItem: { item in
                  select(
                    item, artworkRole: .homeCard,
                    displaySize: AuthorSeriesView.artworkDisplaySize)
                },
                onPresentReader: presentReader,
                onSearch: showSearch)
            case .series(let id, let libraryID, let seed):
              AuthorSeriesView(
                makeModel: {
                  AuthorSeriesModel(
                    target: .series(id: id, libraryID: libraryID), reading: dependencies.authorSeriesReading,
                    library: dependencies.library, filters: .unfiltered, seed: seed)
                },
                coverClient: dependencies.coverClient,
                paletteService: dependencies.paletteService,
                finishedStatus: finishedStatus,
                playback: playback,
                actions: actions,
                onSelectItem: { item in
                  select(
                    item, artworkRole: .homeCard,
                    displaySize: AuthorSeriesView.artworkDisplaySize)
                },
                onPresentReader: presentReader,
                onSearch: showSearch)
            case .authorName(let name):
              AuthorSeriesView(
                makeModel: {
                  AuthorSeriesModel(
                    target: .authorName(name: name), reading: dependencies.authorSeriesReading,
                    library: dependencies.library, filters: .unfiltered)
                },
                coverClient: dependencies.coverClient,
                paletteService: dependencies.paletteService,
                finishedStatus: finishedStatus,
                playback: playback,
                actions: actions,
                onSelectItem: { item in
                  select(
                    item, artworkRole: .homeCard,
                    displaySize: AuthorSeriesView.artworkDisplaySize)
                },
                onPresentReader: presentReader,
                onSearch: showSearch)
            case .seriesName(let name):
              AuthorSeriesView(
                makeModel: {
                  AuthorSeriesModel(
                    target: .seriesName(name: name), reading: dependencies.authorSeriesReading,
                    library: dependencies.library, filters: .unfiltered)
                },
                coverClient: dependencies.coverClient,
                paletteService: dependencies.paletteService,
                finishedStatus: finishedStatus,
                playback: playback,
                actions: actions,
                onSelectItem: { item in
                  select(
                    item, artworkRole: .homeCard,
                    displaySize: AuthorSeriesView.artworkDisplaySize)
                },
                onPresentReader: presentReader,
                onSearch: showSearch)
            case .narrator(let name):
              AuthorSeriesView(
                makeModel: {
                  AuthorSeriesModel(
                    target: .narrator(name: name), reading: dependencies.authorSeriesReading,
                    library: dependencies.library, filters: .unfiltered)
                },
                coverClient: dependencies.coverClient,
                paletteService: dependencies.paletteService,
                finishedStatus: finishedStatus,
                playback: playback,
                actions: actions,
                onSelectItem: { item in
                  select(
                    item, artworkRole: .homeCard,
                    displaySize: AuthorSeriesView.artworkDisplaySize)
                },
                onPresentReader: presentReader,
                onSearch: showSearch)
            case .smartLists:
              if let smartLists {
                EditSmartListsView(
                  access: smartLists, coverClient: dependencies.coverClient,
                  onOpenList: { navigation.navigate(to: .smartList(id: $0)) })
              }
            case .smartList(let listID):
              if let smartLists {
                SmartListView(
                  listID: listID,
                  access: smartLists,
                  coverClient: dependencies.coverClient,
                  paletteService: dependencies.paletteService,
                  downloadStatus: downloadStatus,
                  playback: playback,
                  actions: actions,
                  onSelectEpisode: { itemID, episodeID, context in
                    navigation.presentEpisode(
                      .init(itemID: itemID, episodeID: episodeID, listContext: context))
                  },
                  onOpenShow: { navigation.navigate(to: PodcastNavigationPresentation.route(item: $0)) },
                  onSearch: showSearch)
              }
            case .podcastSettings:
              PodcastSettingsView(
                reading: dependencies.podcastSettingsReading, writing: dependencies.podcastSettingsWriting,
                podcastReading: dependencies.podcastReading, podcastRefreshing: dependencies.podcastRefreshing,
                playbackRate: playbackRate, playback: playback,
                nativeSubscriptionsReading: dependencies.nativePodcastSubscriptionsReading,
                nativeSubscriptionsWriting: dependencies.nativePodcastSubscriptionsWriting,
                notificationModel: podcastNotificationSettingsModel,
                nativeFeedManaging: dependencies.nativeFeedManaging,
                nativeShowsReading: dependencies.nativePodcastShowsReading,
                subscriptionOPMLModel: subscriptionOPMLModel,
                serverMutationCapability: dependencies.serverPodcastMutationCapabilityReading,
                automationSettingsWriting: dependencies.serverPodcastAutomationSettingsWriting)
            case .podcastShowSettings(let itemID, let titleSeed):
              PodcastShowSettingsView(
                itemID: itemID, titleSeed: titleSeed, reading: dependencies.podcastSettingsReading,
                writing: dependencies.podcastSettingsWriting, podcastReading: dependencies.podcastReading,
                podcastRefreshing: dependencies.podcastRefreshing, playbackRate: playbackRate,
                nativeFeedManaging: dependencies.nativeFeedManaging,
                nativeShowsReading: dependencies.nativePodcastShowsReading,
                notificationModel: podcastNotificationSettingsModel,
                serverMutationCapability: dependencies.serverPodcastMutationCapabilityReading,
                automationSettingsWriting: dependencies.serverPodcastAutomationSettingsWriting)
            case .libraryCollection(let kind, let serverID, let libraryID):
              LibraryCollectionView(
                kind: kind,
                makeModel: {
                  LibraryCollectionModel(
                    key: LibraryCollectionKey(
                      serverLibraryID: libraryID, kind: kind, serverID: serverID),
                    reading: dependencies.libraryCollections.reading,
                    queue: dependencies.libraryCollections.queue,
                    startPlayback: { [playback] itemID, episodeID, fromStart in
                      await playback.startReportingSuccess(
                        itemID: itemID, episodeID: episodeID, fromStart: fromStart)
                    })
                },
                makePinModel: {
                  PinnedListDownloadModel(
                    key: LibraryCollectionKey(
                      serverLibraryID: libraryID, kind: kind, serverID: serverID),
                    pins: dependencies.libraryCollections.pins)
                },
                coverClient: dependencies.coverClient,
                actions: actions,
                playback: playback,
                onSelectItem: { item in
                  select(
                    item, artworkRole: .libraryThumbnail,
                    displaySize: WhirrMetric.minimumTouchTarget)
                },
                onSelectEpisode: selectEpisode)
            }
          }
          .toolbarTitleDisplayMode(
            LibraryShellPresentation.titleDisplayMode(for: route).toolbarTitleDisplayMode)
        }
    }
    .id(LibraryShellPresentation.navigationStackIdentity(for: section))
    .onChange(of: navigation[pathFor: section], initial: true) { _, path in
      // A path change is the authoritative signal that a route was removed or replaced. A
      // destination's `onDisappear` also fires when a child is pushed or a tab is switched, so it
      // cannot own source retirement.
      bookZoomRegistry.reconcile(section: section, path: path)
    }
  }

  /// One declaration supplies every root navigation bar, so SwiftUI resizes one Liquid Glass group
  /// across tab transitions. Built from `rootToolbarTrailingOrder`: declarations below follow
  /// `RootToolbarTrailingItem.allCases`, of which each section's order is a subsequence
  /// (`toolbarOrdersAreExpressibleByTheShell` pins it). A `ForEach` doesn't satisfy
  /// `ToolbarContentBuilder` here.
  ///
  /// `nil` when reachability is unknown or fine; the indicator is absent, not dimmed.
  var connectivityStatus: ConnectivityStatusDescription? {
    guard let connectivityModel = dependencies.connectivityModel else { return nil }
    return ConnectivityStatusPolicy.indicator(for: connectivityModel.reachability)
  }

  @ToolbarContentBuilder
  func rootToolbar(
    for section: NavigationModel.Section
  ) -> some ToolbarContent {
    let order = LibraryShellPresentation.rootToolbarTrailingOrder(
      in: section,
      nativeSubscriptionsEnabled: root.nativeSubscriptionsEnabled,
      isSelecting: selectionChrome.isSelecting)

    // Leading, and unconditional across sections: reachability is one shell-wide fact, so a
    // per-section answer would let three tabs imply by silence that the server is fine. Not part
    // of `rootToolbarTrailingOrder`, which only arbitrates per-section trailing controls.
    if let status = connectivityStatus {
      ToolbarItem(placement: .topBarLeading) {
        ShellStatusIndicatorView(
          title: status.title,
          message: status.message,
          systemImage: status.systemImage,
          actionTitle: status.retryTitle,
          onAction: dependencies.requestReachabilityProbe)
      }
    }

    // Leading and unconditional: whether this device's stored sign-in still works is one
    // shell-wide fact. It follows connectivity because while the server is unreachable,
    // reconnecting cannot succeed. Never a banner: it must not cover the Settings button beside
    // it, the only route to signing out of an account the server no longer recognises.
    if let authRecoveryPresentation, authRecoveryPresentation.isIndicatorVisible {
      ToolbarItem(placement: .topBarLeading) {
        ShellStatusIndicatorView(
          title: AuthRecoveryCopy.indicatorTitle,
          message: AuthRecoveryCopy.indicatorMessage,
          systemImage: AuthRecoveryCopy.indicatorSystemImage,
          actionTitle: AuthRecoveryCopy.reconnectActionLabel,
          actionAccessibilityHint: AuthRecoveryCopy.reconnectActionAccessibilityHint,
          onAction: { authRecoveryPresentation.presentSheet() }
        )
        .accessibilityIdentifier(AuthRecoveryAccessibilityID.indicator)
      }
    }

    // `showsSelectionEntry` decides presence, not enablement: Authors and Series have no selection
    // at all, so the control is absent there rather than permanently dim. An empty Titles list
    // keeps it and dims it, as the other three screens do. Presence comes from the browse mode
    // this shell owns, not from a flag the browse root writes on appearance.
    if order.contains(.select),
      LibraryShellPresentation.showsSelectionEntry(in: libraryBrowseMode)
    {
      ToolbarItem(placement: .topBarTrailing) {
        SelectionEntryButton(
          screen: .libraryTitles, isEnabled: librarySelectionEntry.hasSelectableRows
        ) {
          librarySelectionEntry.editMode = .active
        }
      }
    }

    if order.contains(.filter) {
      ToolbarItem(placement: .topBarTrailing) {
        // Both tabs mount the same funnel over their own model.
        if section == .search {
          BrowseFilterMenu(model: searchModel)
        } else {
          BrowseFilterMenu(
            model: browseModel, appliesCategoriesOnly: libraryBrowseMode == .collections)
        }
      }
    }

    if order.contains(.addFeed) {
      ToolbarItem(placement: .topBarTrailing) {
        Button(PodcastsViewPresentation.addPodcastActionLabel, systemImage: "plus") {
          addFeedModel.reset()
          isAddFeedPresented = true
          updateEditorialWashSuspension()
        }
      }
    }

    if order.contains(.settings) {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          navigation.presentSettings()
        } label: {
          Label(
            "Settings",
            systemImage: LibraryShellPresentation.settingsSystemImage
          )
        }
      }
    }
  }

  /// Home's Downloads shelf and Settings' Downloads row resolve this same destination.
  /// Only the Home entry may carry its current media filter; Settings opens the complete list.
  func downloadsDestination(filter: MediaFilter) -> some View {
    DownloadsView(
      makeHomeModel: { makeHomeMoreModel(.downloaded, filter) },
      makePodcastShowModel: makePodcastShowModel,
      storageReading: dependencies.storageReading,
      rssDownloadsReading: dependencies.rssDownloadsReading,
      nativeSubscriptionsEnabled: root.nativeSubscriptionsEnabled,
      storageCeilingSummaryReading: dependencies.storageCeilingSummaryReading,
      downloadIntents: dependencies.downloadIntents,
      coverClient: dependencies.coverClient,
      paletteService: dependencies.paletteService,
      playback: playback,
      actions: actions,
      onSelectItem: { item in
        select(
          item, artworkRole: .libraryThumbnail,
          displaySize: WhirrMetric.minimumTouchTarget)
      },
      onPresentReader: presentReader,
      onSearch: showSearch
    )
  }

  func savedForLaterDestination(filter: MediaFilter) -> some View {
    SavedForLaterView(
      makeModel: { makeSavedListModel(filter) },
      coverClient: dependencies.coverClient,
      paletteService: dependencies.paletteService,
      downloadStatus: downloadStatus,
      finishedStatus: finishedStatus,
      actions: actions,
      playback: playback,
      onSelectItem: { item in
        select(
          item, artworkRole: .libraryThumbnail,
          displaySize: WhirrMetric.minimumTouchTarget)
      },
      onPresentReader: presentReader,
      onSelectEpisode: selectEpisode,
      onSearch: showSearch)
  }

}
