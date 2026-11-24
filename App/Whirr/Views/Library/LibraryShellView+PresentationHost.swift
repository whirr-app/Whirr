import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import ReaderCore
import SwiftUI
import SyncEngine

extension LibraryShellView {
  /// Every shell-level presentation and the observers that follow its state, kept out of `body`
  /// so `ShellPresentationHost` evaluates them in its own observation scope.
  ///
  /// Composed from named segments, innermost first, so the modifier order is unchanged: the
  /// transcript sheet and player are applied to the content, then the four sheets, then the
  /// observers. Each segment is a short chain of its own, which also keeps the type checker from
  /// solving the whole tree in one expression.
  @ViewBuilder
  func presentationChain(_ content: some View) -> some View {
    presentationObservers(
      settingsSheet(
        addFeedSheet(
          itemDetailSheet(
            episodeSheet(
              playerAndTranscriptHost(content))))))
  }

  /// Innermost, so the transcript opener reaches the sections' lists but not the player or the
  /// cards: the shell cannot present over those, so each keeps a transcript sheet of its own.
  private func playerAndTranscriptHost(_ content: some View) -> some View {
    content
      .episodeTranscriptHost(coordinator: TranscriptComposition.coordinator, playback: playback)
      .interactivePlayerPresentation(
        isPresented: playerPresentationBinding,
        collapseStyle: navigation.playerCollapseStyle,
        morphGeometry: playerMorphGeometry,
        chromeColorScheme: effectiveAppColorScheme,
        onDismissCompleted: {
          expandedPlayerPresentation.state.reset()
          updateEditorialWashSuspension()
        },
        content: {
          if let entry = expandedPlayerPresentation.state.committed {
            ExpandedPlayerView(
              itemID: entry.identity.itemID, episodeID: entry.identity.episodeID,
              metadataSeed: entry.metadataSeed,
              playback: playback, connectivityModel: dependencies.connectivityModel,
              player: dependencies.player, library: dependencies.library,
              nativePodcastShowsReading: dependencies.nativePodcastShowsReading,
              coverClient: dependencies.coverClient,
              navigation: navigation, paletteService: dependencies.paletteService,
              followedShowArtworkSources: followedShowArtworkSources,
              episodeArtwork: playerEpisodeArtwork, actions: actions,
              playbackRate: playbackRate,
              finishedStatus: finishedStatus,
              extrasAccess: dependencies.extrasAccess,
              authorSeriesReading: dependencies.authorSeriesReading,
              makeListeningQueueModel: makeListeningQueueModel,
              makeItemHistoryModel: makeItemHistoryModel,
              makeAudioBookmarksModel: makeAudioBookmarksModel,
              makeSupplementsModel: makeSupplementsModel,
              transcriptCoordinator: TranscriptComposition.coordinator,
              effectiveAppColorScheme: effectiveAppColorScheme,
              onQueuePresented: { expandedPlayerPresentation.state.freeze() },
              onQueueDismissed: {
                guard navigation.playerPresentation == .expanded else { return }
                let outcome = expandedPlayerPresentation.state.reconcileFromLive(
                  playback.nowPlayingIdentity)
                // With nothing live any more, the dismissed sheet cannot hand the page a title to
                // show, so the player leaves rather than reconciling to an empty cover.
                if outcome == .collapse {
                  navigation.collapsePlayer(style: .slide)
                }
              },
              onPlayNowCommitted: { seed in
                expandedPlayerPresentation.state.stage(
                  identity: seed.identity, metadataSeed: seed)
              },
              episodeCard: PlayerEpisodeCardDependencies(
                makeModel: makePodcastEpisodeCardModel,
                paletteService: dependencies.paletteService,
                transcriptCoordinator: TranscriptComposition.coordinator),
              onSearch: showSearch
            )
            .environment(\.playerMorphGeometry, playerMorphGeometry)
          }
        })
  }

  /// The episode card is state-driven like settings below: a shell-level `.sheet(item:)` bound
  /// to `NavigationModel.presentedEpisode`. The shared wrapper resolves its local size class,
  /// sheet sizing, and explicit Close affordance. Its editorial wash uses the shared shell
  /// coordinator and the displayed 72pt artwork key, and stays neutral while sheet-covered
  /// work is held.
  private func episodeSheet(_ content: some View) -> some View {
    content
      .sheet(
        item: presentedEpisodeBinding,
        onDismiss: { updateEditorialWashSuspension() },
        content: { ref in
          PodcastEpisodeCardSheet(
            itemID: ref.itemID,
            episodeID: ref.episodeID,
            coverClient: dependencies.coverClient,
            paletteService: dependencies.paletteService,
            navigation: navigation,
            playback: playback,
            makeModel: { makePodcastEpisodeCardModel(ref.itemID, ref.episodeID) },
            host: PodcastEpisodeCardHost(
              // `navigate(to:)` clears `presentedEpisode` first, so the card drops and the show
              // pushes in one call.
              openShow: { route in navigation.navigate(to: route) },
              search: { query in
                navigation.dismissEpisode()
                showSearch(query)
              }),
            listContext: ref.listContext,
            transcriptCoordinator: TranscriptComposition.coordinator
          )
          // `.sheet(item:)` rebuilds in place and doesn't derive identity from `item.id`. A second
          // episode presented while the first card's dismissal is in flight (an interactive
          // swipe-down) keeps the card's `@State`: `DeferredModel` returns the first episode's model
          // (ids bound at `init`), `onAppear` never re-fires, and the wash is never re-requested.
          // Keying on the ref restores per-episode identity.
          .id(ref.id)
        })
  }

  /// ADR 0008: at regular width item detail is raised here as a centred card over the dimmed
  /// section root instead of being pushed. Same shape as the episode card above: a shell-level
  /// `.sheet(item:)` over a `NavigationModel` property whose binding writes `nil` back, so the
  /// swipe and `dismissItemDetail()` take one path. Only one of the two cards can stand at a
  /// time: `presentEpisode` and `navigate(to:)` each clear the other's state in the model.
  private func itemDetailSheet(_ content: some View) -> some View {
    content
      .sheet(
        item: presentedItemDetailBinding,
        onDismiss: {
          updateEditorialWashSuspension()
          releaseReaderHeldByItemDetail()
        },
        content: { ref in
          ItemDetailCardSheet {
            itemDetailDestination(itemID: ref.itemID, seed: ref.seed)
          }
        })
  }

  private func addFeedSheet(_ content: some View) -> some View {
    content
      .sheet(
        isPresented: $isAddFeedPresented,
        onDismiss: {
          let followedFeedItemID = addFeedModel.followedFeedItemID
          addFeedModel.reset()
          if let followedFeedItemID {
            navigation.navigate(
              to: NavigationModel.Destination(
                section: .podcasts,
                path: [.podcastShow(itemID: followedFeedItemID)]))
          }
          updateEditorialWashSuspension()
        },
        content: {
          AddFeedSheetView(
            model: addFeedModel, opmlModel: subscriptionOPMLModel,
            artworkClient: dependencies.coverClient, paletteService: dependencies.paletteService
          )
          .adaptiveSheetPresentation(role: .large)
        })
  }

  /// Settings is raised over whichever section is showing rather than owning a bottom-bar
  /// item: its entry point is that section's toolbar, and Done/swipe-down puts the user back on
  /// the section they left. A card `.sheet` (not the player's UIKit transition) fits because
  /// settings has no edge-to-edge canvas to run under the status bar.
  private func settingsSheet(_ content: some View) -> some View {
    content
      .sheet(
        isPresented: settingsPresentationBinding,
        onDismiss: {
          guard navigation.settingsPresentation == .dismissed else { return }
          root.finishSettingsPresentation()
          updateEditorialWashSuspension()
        },
        content: {
          section(.settings) {
            SettingsView(
              account: dependencies.account, downloadPreferences: dependencies.downloadPreferences,
              logoutPreflight: dependencies.logoutPreflight,
              resolutionCenterAccess: dependencies.resolutionCenterAccess,
              serverAccountReading: dependencies.serverAccountReading,
              serverAddressesModel: serverAddressesModel,
              librarySelectionReading: dependencies.librarySelectionReading,
              nativePodcastSubscriptionsReading: dependencies.nativePodcastSubscriptionsReading,
              nativePodcastSubscriptionsWriting: dependencies.nativePodcastSubscriptionsWriting,
              podcastNotificationSettingsModel: podcastNotificationSettingsModel,
              subscriptionOPMLModel: subscriptionOPMLModel,
              librarySelectionWriting: dependencies.librarySelectionWriting,
              sync: dependencies.sync,
              artworkCacheAccess: dependencies.artworkCacheAccess,
              coverClient: dependencies.coverClient,
              storageReading: dependencies.storageReading,
              deviceStorageCapacityReading: dependencies.deviceStorageCapacityReading,
              playbackRate: playbackRate, playback: playback,
              podcastSettingsReading: dependencies.podcastSettingsReading,
              nativePodcastSettingsAccess: dependencies.nativePodcastSettingsAccess,
              podcastSettingsWriting: dependencies.podcastSettingsWriting,
              podcastReading: dependencies.podcastReading,
              podcastRefreshing: dependencies.podcastRefreshing,
              nativeFeedManaging: dependencies.nativeFeedManaging,
              serverPodcastMutationCapabilityReading: dependencies.serverPodcastMutationCapabilityReading,
              serverPodcastAutomationSettingsWriting: dependencies.serverPodcastAutomationSettingsWriting,
              ambientColorScheme: colorScheme,
              problemReportSources: dependencies.problemReportSources,
              problemReportExportDirectory: dependencies.problemReportExportDirectory,
              // The same bodies the `.storage`/`.resolutionCenter` destination arms build, so a tap
              // inside Settings and a deep link land on the same screen. They are pushed as views:
              // Settings' own sub-screens are not in the settings stack's `path`, and a route
              // appended from one of them installs its destination underneath.
              manageDownloadsDestination: { downloadsDestination(filter: .all) },
              resolutionCenterDestination: {
                ResolutionCenterView(access: dependencies.resolutionCenterAccess)
              },
              onLoggedOut: onLoggedOut
            )
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) {
                  navigation.dismissSettings()
                }
              }
            }
            #if PERF_INVESTIGATION
              .modifier(MicrostutterSheetAblation(onDismiss: { navigation.dismissSettings() }))
            #endif
            .adaptiveSheetPresentation(role: .large)
          }
        })
  }

  /// The observers sit outside every sheet, as they did at the end of the one chain.
  private func presentationObservers(_ content: some View) -> some View {
    content
      .onChange(of: navigation.settingsPresentation) { _, newValue in
        guard newValue == NavigationModel.SettingsPresentation.presented else { return }
        root.beginSettingsPresentation()
        updateEditorialWashSuspension()
      }
      .onChange(of: navigation.presentedEpisode) { _, newValue in
        guard newValue != nil else { return }
        updateEditorialWashSuspension()
      }
      .onChange(of: navigation.presentedItemDetail) { _, newValue in
        guard newValue != nil else { return }
        updateEditorialWashSuspension()
      }
      .onChange(of: navigation.playerPresentation) { _, newValue in
        guard newValue == .expanded else { return }
        snapshotExpandedPlayerPresentation()
        updateEditorialWashSuspension()
      }
  }
}

/// Why the chain above is a modifier, not in `body`: its `.sheet(item:)` and `.onChange(of:)` read
/// `NavigationModel`'s presentation properties, so in `LibraryShellView.body` every present and
/// dismiss invalidated the shell and its `TabView`, rebuilding retained unselected tabs offscreen
/// (`LibraryBrowseRootView.body`, `LibraryBrowseTitlesView.body` on Home). A modifier's body is its
/// own observation scope over an already-built `content`.
struct ShellPresentationHost: ViewModifier {
  let shell: LibraryShellView

  func body(content: Content) -> some View {
    shell.presentationChain(content)
  }
}
