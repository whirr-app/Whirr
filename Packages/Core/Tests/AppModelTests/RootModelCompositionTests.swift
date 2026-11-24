import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

extension RootModelTests {
  // MARK: - Composition wiring

  @Test("the Home More factory forwards Continue Listening native dependencies")
  func homeMoreFactoryForwardsContinueListeningDependencies() async {
    let nativeContinue = FakeNativeContinueReading()
    let subscriptions = RootNativeSubscriptionsAccess(enabled: false)
    let model = RootModel(
      dependencies: makeDependencies(
        nativeContinueListeningReading: nativeContinue,
        nativePodcastSubscriptionsReading: subscriptions))
    await waitUntil { subscriptions.observeEnabledCallCount >= 1 }

    _ = model.makeHomeMoreModel(section: .continueListening, filter: .podcasts)

    await waitUntil { subscriptions.observeEnabledCallCount >= 2 }
    #expect(nativeContinue.observeCallCount == 1)
    #expect(subscriptions.observeEnabledCallCount == 2)
  }

  @Test func podcastEpisodeIntentsFactoryReceivesSharedPlaybackAndIsExposed() {
    let playbackBox = RootPlaybackBox()
    let model = RootModel(
      dependencies: makeDependencies(
        makePodcastEpisodeIntents: { playback in
          playbackBox.value = playback
          return NoOpPodcastEpisodeIntents()
        }))

    #expect(model.podcastEpisodeIntents is NoOpPodcastEpisodeIntents)
    #expect(playbackBox.value === model.playback)
  }

  @Test func podcastEpisodeIntentsDefaultsToPlaybackImplementation() {
    let model = RootModel(dependencies: makeDependencies())

    #expect(model.podcastEpisodeIntents is PlaybackPodcastEpisodeIntents)
  }

  @Test func defaultDependenciesLeaveSavedStatusUnwired() {
    let model = RootModel(dependencies: makeDependencies())

    #expect(model.savedStatus == nil)
  }

  @Test func podcastShowFactoryThreadsTheSharedSavedStatus() async {
    let savedReading = FakeSavedShelfReading()
    let model = RootModel(
      dependencies: makeDependencies(
        savedShelfReading: savedReading, podcastReading: RootPodcastReading()))
    let show = model.makePodcastShowModel(itemID: "show-1")
    let identity = SavedShelfIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1")

    #expect(model.savedStatus != nil)
    #expect(show.isSaved(episodeID: "episode-1") == nil)

    savedReading.pushSavedIdentities([identity])
    #expect(await waitUntil { show.isSaved(episodeID: "episode-1") == true })
  }

  @Test func podcastEpisodeFactoryThreadsTheSharedSavedStatus() async {
    let savedReading = FakeSavedShelfReading()
    let model = RootModel(
      dependencies: makeDependencies(
        savedShelfReading: savedReading, podcastReading: RootPodcastReading()))
    let show = model.makePodcastShowModel(itemID: "show-1")
    let card = model.makePodcastEpisodeCardModel(itemID: "show-1", episodeID: "episode-1")
    let identity = SavedShelfIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1")

    #expect(card.isSaved == nil)

    savedReading.pushSavedIdentities([identity])
    #expect(await waitUntil { show.isSaved(episodeID: "episode-1") == true })
    #expect(await waitUntil { card.isSaved == true })
  }

  @Test func podcastEpisodeIntentFactoryThreadsTheSavedShelfWriter() async throws {
    let savedShelf = RootRecordingSavedShelf()
    let model = RootModel(dependencies: makeDependencies(savedShelfStoring: savedShelf))

    try await model.podcastEpisodeIntents.saveForLater(
      itemID: "show-1", episodeID: "episode-1")

    #expect(
      await savedShelf.calls
        == [.save(.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))])
  }

  @Test func settingsSelectionIsHeldUntilSettingsDismissal() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { selection.isObserving && model.canChooseLibraries })
    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })
    model.navigation.section = .podcasts
    model.navigation.navigate(to: .podcastShows)
    model.navigation.presentSettings()
    model.beginSettingsPresentation()

    let removed = Self.mixedSelectionSnapshot(podcastIncluded: false)
    selection.emit(removed)
    #expect(await waitUntil { model.pendingSelectionSnapshot == removed })
    #expect(model.hasIncludedPodcastLibrary)
    #expect(model.navigation.section == .podcasts)
    #expect(model.navigation[pathFor: .podcasts] == [.podcastShows])

    model.navigation.dismissSettings()
    model.finishSettingsPresentation()

    #expect(model.hasIncludedPodcastLibrary == false)
    #expect(model.navigation.section == .home)
    #expect(model.navigation[pathFor: .podcasts].isEmpty)
  }

  @Test func latestQueuedSelectionIsAppliedOnce() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { selection.isObserving && model.canChooseLibraries })
    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })
    model.navigation.section = .podcasts
    model.navigation.navigate(to: .podcastShows)
    model.navigation.presentSettings()
    model.beginSettingsPresentation()

    let removed = Self.mixedSelectionSnapshot(podcastIncluded: false)
    let restored = Self.mixedSelectionSnapshot(podcastIncluded: true)
    selection.emit(removed)
    #expect(await waitUntil { model.pendingSelectionSnapshot == removed })
    selection.emit(restored)
    #expect(await waitUntil { model.pendingSelectionSnapshot == restored })

    #expect(model.hasIncludedPodcastLibrary)
    #expect(model.navigation.section == .podcasts)
    #expect(model.navigation[pathFor: .podcasts] == [.podcastShows])

    model.navigation.dismissSettings()
    model.finishSettingsPresentation()
    model.finishSettingsPresentation()

    #expect(model.hasIncludedPodcastLibrary)
    #expect(model.navigation.section == .podcasts)
    #expect(model.navigation[pathFor: .podcasts] == [.podcastShows])
  }

  @Test func nonPodcastSectionAndPathSurviveDeferredSelection() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { selection.isObserving && model.canChooseLibraries })
    model.navigation.section = .library
    model.navigation.navigate(to: .itemDetail(itemID: "book-1"))
    model.navigation.presentSettings()
    model.beginSettingsPresentation()

    let removed = Self.mixedSelectionSnapshot(podcastIncluded: false)
    selection.emit(removed)
    #expect(await waitUntil { model.pendingSelectionSnapshot == removed })
    #expect(model.navigation.section == .library)
    #expect(model.navigation[pathFor: .library] == [.itemDetail(itemID: "book-1")])

    model.navigation.dismissSettings()
    model.finishSettingsPresentation()

    #expect(model.hasIncludedPodcastLibrary == false)
    #expect(model.navigation.section == .library)
    #expect(model.navigation[pathFor: .library] == [.itemDetail(itemID: "book-1")])
  }

  @Test func staleDismissalCallbackDoesNotApplyWhileSettingsIsRepresented() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { selection.isObserving && model.canChooseLibraries })
    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })
    model.navigation.section = .podcasts
    model.navigation.navigate(to: .podcastShows)

    model.navigation.presentSettings()
    model.beginSettingsPresentation()
    let removed = Self.mixedSelectionSnapshot(podcastIncluded: false)
    selection.emit(removed)
    #expect(await waitUntil { model.pendingSelectionSnapshot == removed })

    // S1 has dismissed, but S2 is already represented before S1's stale callback arrives.
    model.navigation.dismissSettings()
    model.navigation.presentSettings()
    model.beginSettingsPresentation()
    model.finishSettingsPresentation()

    #expect(model.hasIncludedPodcastLibrary)
    #expect(model.navigation.settingsPresentation == .presented)
    #expect(model.pendingSelectionSnapshot == removed)
    #expect(model.navigation.section == .podcasts)
    #expect(model.navigation[pathFor: .podcasts] == [.podcastShows])

    model.navigation.dismissSettings()
    model.finishSettingsPresentation()

    #expect(model.hasIncludedPodcastLibrary == false)
    #expect(model.navigation.section == .home)
    #expect(model.navigation[pathFor: .podcasts].isEmpty)
  }

  @Test func resetForLogoutClearsDeferredSelection() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { selection.isObserving && model.canChooseLibraries })
    model.navigation.presentSettings()
    model.beginSettingsPresentation()
    let removed = Self.mixedSelectionSnapshot(podcastIncluded: false)
    selection.emit(removed)
    #expect(await waitUntil { model.pendingSelectionSnapshot == removed })

    model.resetForLogout()
    model.finishSettingsPresentation()

    #expect(model.pendingSelectionSnapshot == nil)
    #expect(model.navigation.presentation == .setup)
    #expect(model.navigation.settingsPresentation == .dismissed)
    #expect(model.hasIncludedPodcastLibrary)
  }

  /// A cold launch must not issue a duplicate traversal.
  ///
  /// A cold launch already gives `SyncEngine` a `.foreground` (the scene's first `.active` is a
  /// real phase change), and that traversal is the catalogue pull. A second would arrive as
  /// `.explicit`, which is neither satisfiable by the run it joins nor subject to the minimum
  /// foreground interval, so it would walk all three libraries again. The resolution itself must
  /// still run in full; only the pull is skipped.
  @Test func coldLaunchResolutionEntersTheShellWithoutPullingTheCatalogueItself() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = RootDiscoverySync()
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, sync: sync, hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryAtColdLaunch()

    #expect(model.browseModel != nil)
    #expect(model.searchModel != nil)
    #expect(model.navigation.presentation == .shell)
    // The pull would have been an unstructured task, so settle before denying it.
    await awaitQuiescence("cold-launch refresh requests") { "\(sync.refreshCount)" }
    #expect(sync.refreshCount == 0)
    #expect(sync.discoveryRefreshCount == 0)
  }

  /// The other half of the same decision.
  ///
  /// `AppEnvironment.sharedLifecycle` is process-wide, so when `RootView` hands over a rebuilt
  /// composition the adapter's last phase is already `.active` and `ScenePhaseLifecycleMapper`
  /// emits no transition. A graph composed after login or an endpoint switch never receives a
  /// `.foreground`, so this pull is its only trigger: without it a fresh login never syncs.
  @Test func aFreshlyComposedGraphStillPullsBecauseNoForegroundWillReachIt() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = RootDiscoverySync()
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, sync: sync, hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()

    #expect(await waitUntil("catalogue pull requested") { sync.refreshCount == 1 })
  }

  @Test func resolveLibraryIfAuthenticatedEntersTheShellOnceSignedIn() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let model = RootModel(dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()

    #expect(model.browseModel != nil)
    #expect(model.searchModel != nil)
    #expect(model.navigation.presentation == .shell)
    #expect(model.navigation.section == .home)
  }

  /// Library resolution has to hand both models their real dependencies, not just construct them:
  /// each one's own offline state is the only place that outage is explained.
  @Test func resolvedLibraryModelsReachTheirOwnOfflineStates() async {
    struct Offline: Error {}
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let library = FakeLibraryReading()
    let sync = FakeSyncCoordinating()
    sync.stubSearch(.failure(Offline()))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, library: library, sync: sync, hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()
    let item = ItemSummary(
      serverItemId: "book-1", mediaKind: "book", title: "Book", author: nil, durationSeconds: nil)
    library.pushBrowseList([item])
    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: false, lastRunIncomplete: true, lastCompletedAt: nil))
    #expect(await waitUntil { model.browseModel?.state == .staleOffline([item]) })
  }

  @Test func thePodcastShowFactoryProducesAModelWiredToItsDependencies() async {
    let reading = RootPodcastReading()
    let refreshing = RootPodcastRefreshing()
    let model = RootModel(
      dependencies: makeDependencies(
        podcastReading: reading, podcastRefreshing: refreshing))
    let show = model.makePodcastShowModel(itemID: "show-1")
    reading.push([RootPodcastReading.episode], itemID: "show-1")
    #expect(await waitUntil { show.episodes == [RootPodcastReading.episode] })

    await refreshing.stub(.failure(RootPodcastError.offline))
    await show.refresh()

    #expect(show.state == .staleOffline)
  }

  @Test("the podcast show factory wires playback stop ahead of native feed deletion")
  func podcastShowFactoryWiresUnfollowPlaybackStop() async throws {
    struct StopFailure: Error {}

    let playbackSync = FakePlaybackSyncing()
    playbackSync.stubStopSession(throwing: StopFailure())
    let feedManaging = RootRecordingNativeFeedManaging()
    let model = RootModel(
      dependencies: makeDependencies(
        playbackSync: playbackSync, nativeFeedManaging: feedManaging))
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.playback.setActive(itemID: itemID, episodeID: "episode-7")
    model.playback.setLoaded(itemID: itemID, episodeID: "episode-7", isStreaming: true)
    let show = model.makePodcastShowModel(itemID: itemID)

    #expect(await show.unsubscribe() == false)
    #expect(await feedManaging.unsubscribeFeedIDs.isEmpty)
    #expect(show.actionErrorMessage == PodcastCopy.unsubscribePlaybackStopFailed)
  }

  @Test func selectionChangesDoNotReplaceExistingShellModels() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let model = RootModel(dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { true }))
    model.resolveLibraryIfAuthenticated()
    let firstBrowseModel = model.browseModel

    model.resolveLibraryIfAuthenticated()

    #expect(model.browseModel === firstBrowseModel)
  }

  @Test func doesNotRenavigateAwayFromSearchOrSettingsOnceAlreadyInTheShell() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let model = RootModel(dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { true }))
    model.resolveLibraryIfAuthenticated()
    model.navigation.section = .settings

    model.resolveLibraryIfAuthenticated()

    #expect(model.navigation.presentation == .shell)
    #expect(model.navigation.section == .settings)
  }

  /// A pushed item detail is the user's place in the shell too, so re-resolving the same library
  /// (a foreground re-entry, say) must not silently pop them back to the section root.
  @Test func doesNotClearAPushedDetailOnceAlreadyInTheShell() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let model = RootModel(dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { true }))
    model.resolveLibraryIfAuthenticated()
    model.navigation.section = .library
    model.navigation.navigate(to: .itemDetail(itemID: "abc"))

    model.resolveLibraryIfAuthenticated()

    #expect(model.navigation[pathFor: .library] == [.itemDetail(itemID: "abc")])
  }

  // MARK: - Initial sync trigger

  /// The browse model is observation-only, and the foreground transition fires before login
  /// against the pre-account engine, so nothing else issues the first `refresh()`. Resolving the
  /// library for the first time (login or an already-authenticated cold launch, both
  /// explicit-user-action paths per API-CONVENTIONS) must trigger exactly one refresh.
  @Test func firstLibraryResolutionTriggersExactlyOneRefresh() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = FakeSyncCoordinating()
    let model = RootModel(
      dependencies: makeDependencies(account: account, sync: sync, hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()
    await waitUntil { sync.refreshCount >= 1 }
    #expect(sync.refreshCount == 1)

    model.resolveLibraryIfAuthenticated()
    #expect(sync.refreshCount == 1, "repeat resolutions for the same library must not re-sync")
  }

  /// The first pull must not be gated on `browseModel == nil`: `init` consumes that, so a graph
  /// rebuilt by login or an endpoint switch would reach `resolveLibraryIfAuthenticated()` with its
  /// models already built, skip the pull, and never sync after login. Construction and the
  /// one-per-graph pull are separate conditions, and this pins them apart.
  @Test func aRebuiltGraphStillPullsEvenThoughInitAlreadyBuiltItsModels() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = FakeSyncCoordinating()
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, sync: sync, hasConfiguredIncludedLibrary: { true }))

    // The post-login state: `init` resolved, so both models exist before the pull decision.
    #expect(model.browseModel != nil)
    #expect(model.searchModel != nil)
    #expect(sync.refreshCount == 0)

    model.resolveLibraryIfAuthenticated()

    #expect(await waitUntil("login pull requested") { sync.refreshCount == 1 })
    #expect(model.navigation.presentation == .shell)
  }

  @Test func repeatedSelectionResolutionDoesNotRecreateTheShellOrRestartRefresh() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = SuspendingSyncCoordinating()
    defer { sync.release() }
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, sync: sync, hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()
    #expect(await waitUntil { sync.refreshStartCount == 1 })

    model.resolveLibraryIfAuthenticated()

    #expect(sync.refreshStartCount == 1)
    #expect(sync.cancelledRefreshCount == 0)
  }

  @Test func deinitCancelsAnInFlightRefresh() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = SuspendingSyncCoordinating()
    defer { sync.release() }
    var model: RootModel? = RootModel(
      dependencies: makeDependencies(account: account, sync: sync, hasConfiguredIncludedLibrary: { true }))

    model?.resolveLibraryIfAuthenticated()
    #expect(await waitUntil { sync.refreshStartCount == 1 })

    model = nil

    #expect(await waitUntil { sync.cancelledRefreshCount == 1 })
  }

  @Test func noRefreshIsTriggeredWhileSignedOut() async {
    let sync = FakeSyncCoordinating()
    let model = RootModel(dependencies: makeDependencies(sync: sync, hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()
    #expect(sync.refreshCount == 0)
  }

  // MARK: - Shared playback model

  /// The mini-player is global to the shell (ARCHITECTURE.md): browse, item detail and search
  /// must all drive the same `PlaybackModel`, not one each, and it must survive section changes
  /// rather than being rebuilt.
  @Test func rootModelExposesOneSharedPlaybackModelThatSurvivesSectionChanges() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let model = RootModel(dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { true }))
    let playback = model.playback

    model.resolveLibraryIfAuthenticated()
    model.navigation.section = .search
    model.navigation.section = .settings
    model.navigation.section = .library

    #expect(model.playback === playback, "one shared instance across every section, not rebuilt per-section")
  }

  @Test func podcastShowEpisodeActionsUseSharedPlaybackAndDurableQueue() async throws {
    let playbackSync = FakePlaybackSyncing()
    let queue = RootRecordingListeningQueue()
    let downloadIntents = FakeDownloadIntents()
    let model = RootModel(
      dependencies: makeDependencies(
        playbackSync: playbackSync,
        downloadIntents: downloadIntents,
        listeningQueueStoring: queue
      ))
    let show = model.makePodcastShowModel(itemID: "show-1")
    let queuedEpisode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-2"))

    await show.episodeTapped("episode-1")
    await show.addToUpNext("episode-2")
    await show.download("episode-3")
    await show.pauseDownload("episode-3")
    await show.resumeDownload("episode-3")
    await show.removeDownload("episode-3")

    #expect(
      playbackSync.calls.contains(
        .startSession(itemID: "show-1", episodeID: "episode-1")))
    #expect(await queue.appendCalls == [queuedEpisode])
    #expect(
      downloadIntents.calls
        == [
          .requestEpisodeDownload(itemID: "show-1", episodeID: "episode-3"),
          .pauseEpisodeDownload(itemID: "show-1", episodeID: "episode-3"),
          .resumeEpisodeDownload(itemID: "show-1", episodeID: "episode-3"),
          .purgeEpisodeDownload(
            itemID: "show-1", episodeID: "episode-3", source: .podcastEpisodeRemoval),
        ])
  }

  /// There is one runtime queue store/model per account graph, so the episode intents the
  /// show/episode-card screens drive, the queue model the player's sheet presents, and
  /// `PlaybackModel`'s own consumption must all land on the same injected boundary. A second live
  /// queue store would show up here as a mutation this recorder never saw.
  @Test func oneSharedListeningQueueServesEpisodeIntentsPlaybackAndTheQueueModel() async throws {
    let reading = RootListeningQueueReading()
    let storing = RootRecordingListeningQueue()
    let playbackSync = FakePlaybackSyncing()
    playbackSync.stubStartSession(
      .success(
        PreparedPlayback(
          itemID: "book", episodeID: nil, startPosition: 0, duration: 100,
          tracks: [
            PreparedPlaybackTrack(
              index: 0, startOffset: 0, duration: 100,
              url: URL(string: "https://example.test/book.m4b")!,
              mimeType: "audio/mp4", title: "book")
          ], chapters: [])))
    let model = RootModel(
      dependencies: makeDependencies(
        playbackSync: playbackSync,
        listeningQueueReading: reading, listeningQueueStoring: storing))
    let book = try #require(ListeningIdentity.audiobook(itemID: "book"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode"))

    // 1. Item/episode actions.
    await model.makePodcastShowModel(itemID: "show").addToUpNext("episode")

    // 2. The player's queue presentation: same reading boundary, same storing boundary.
    let queue = model.makeListeningQueueModel()
    let row = ListeningQueueItem(
      id: 1, position: 0, identity: book, primaryTitle: "Book",
      secondaryTitle: "Author", category: .audiobook, isTombstone: false)
    reading.push([row])
    await waitUntil { queue.items == [row] }
    await queue.remove(rowID: row.id)

    // 3. Playback consumption: a successful start acknowledges the identity on the same store.
    await model.playback.start(itemID: "book")

    #expect(queue.items == [row])
    #expect(await storing.appendCalls == [episode])
    #expect(await storing.removedRowIDs == [row.id])
    #expect(await storing.acknowledgedCalls == [book])
  }
}
