import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Proves the dependency-injection story end to end on the macOS host: every
/// lower-layer boundary can be satisfied by a fake, with no concrete network,
/// keychain, database, or AV type anywhere in the graph.
@Suite struct AppModelWiringTests {

  /// `RootModel` is `@MainActor @Observable` (ARCHITECTURE.md), so its construction
  /// is main-actor isolated and the test has to be too.
  @MainActor
  @Test func constructsWithFakes() {
    let dependencies = AppDependencies(
      account: FakeAccountLifecycle(),
      sync: FakeSyncCoordinating(),
      library: FakeLibraryReading(),
      player: FakePlaybackControlling(),
      playbackSync: FakePlaybackSyncing(),
      reader: FakeEPUBRendering(),
      networkConditions: FakeNetworkConditions(),
      appLifecycle: FakeAppLifecycle(),
      diagnostics: FakeDiagnosticsRecording(),
      downloadReading: NoOpDownloadReading(),
      storageReading: NoOpStorageReading(),
      rssDownloadsReading: NoOpRSSDownloadsReading(),
      deviceStorageCapacityReading: NoOpDeviceStorageCapacityReading(),
      downloadIntents: NoOpDownloadIntents(),
      itemProgressIntents: NoOpItemProgressIntents(),
      downloadPreferences: NoOpDownloadPreferences(),
      artworkCacheAccess: NoOpArtworkCacheAccess(),
      resolutionCenterAccess: NoOpResolutionCenterAccess(),
      extrasAccess: NoOpItemDetailExtrasAccess(),
      historyAccess: NoOpListeningHistoryProviding(),
      listeningStatsAccess: NoOpListeningStatsProviding(),
      audioBookmarkIntents: NoOpAudioBookmarkIntents(),
      homeReading: NoOpHomeReading(),
      nativeLatestPodcastEpisodesReading: NoOpNativeLatestPodcastEpisodesReading(),
      nativeContinueListeningReading: NoOpNativeContinueListeningReading(),
      playbackBookmarkStoring: NoOpPlaybackBookmarkStoring(),
      podcastReading: NoOpPodcastReading(),
      podcastRefreshing: NoOpPodcastRefreshing(),
      rssFeedRefreshCoordinator: NoOpRSSFeedRefreshCoordinator(),
      listeningQueueReading: NoOpListeningQueueStore(),
      listeningQueueStoring: NoOpListeningQueueStore(),
      savedShelfStoring: NoOpSavedShelfStore(),
      itemPlaybackSettingsReading: NoOpItemPlaybackSettingsAccess(),
      itemPlaybackSettingsWriting: NoOpItemPlaybackSettingsAccess(),
      playbackPreferences: NoOpPlaybackPreferences(),
      podcastSettingsReading: NoOpPodcastSettingsAccess(),
      podcastSettingsWriting: NoOpPodcastSettingsAccess(),
      podcastShowOrdering: NoOpPodcastShowOrdering(),
      carPlayBrowseSources: .empty,
      searchReading: NoOpSearchReading(),
      recentSearchStore: NoOpRecentSearchStoring(),
      authorSeriesReading: NoOpAuthorSeriesReading(),
      libraryCollections: .unavailable,
      serverAccountReading: NoOpServerAccountReading(),
      librarySelectionReading: NoOpLibrarySelectionStore(),
      nativePodcastSubscriptionsReading: NoOpNativePodcastSubscriptionsReading(),
      accountIdentityReading: NoOpAccountIdentityReading(),
      nativePodcastSubscriptionsWriting: NoOpNativePodcastSubscriptionsWriting(),
      nativeEpisodeServerSaving: NoOpNativeEpisodeServerSaving(),
      nativeEpisodeServerSaveBatchSaving: NoOpNativeEpisodeServerSaveBatchSaving(),
      nativeEpisodeServerSaveRecovering: NoOpNativeEpisodeServerSaveRecovering(),
      nativeEpisodeServerSaveStatusReading: NoOpNativeEpisodeServerSaveStatusReading(),
      nativeEpisodeIDResolving: NoOpNativeEpisodeIDResolving(),
      serverPodcastMutationCapabilityReading: NoOpServerPodcastMutationCapabilityReading(),
      serverPodcastAutomationSettingsWriting: NoOpServerPodcastAutomationSettingsWriting(),
      ebookDelivery: NoOpEbookDelivering(),
      notificationIntentReading: DisabledRSSNotificationIntent(),
      notificationIntentWriting: DisabledRSSNotificationIntent(),
      localNotificationAuthorizer: NoOpRSSLocalNotificationAuthorizer(),
      rssNotificationLifecycle: NoOpRSSNotificationLifecycle(),
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
      nativeFeedRecoveryReading: NoOpNativeFeedRecoveryReading(),
      librarySelectionWriting: NoOpLibrarySelectionStore(),
      nativeFeedFollowing: NoOpNativeFeedFollowing(),
      nativeFeedManaging: NoOpNativeFeedManaging(),
      nativeSubscriptionOPMLExporter: NoOpNativeSubscriptionOPMLExporter(),
      nativePodcastShowOrdering: NoOpNativePodcastShowOrdering()
    )
    let model = RootModel(dependencies: dependencies)
    let queue = ListeningQueueModel(
      reading: dependencies.listeningQueueReading,
      storing: dependencies.listeningQueueStoring)

    #expect(model.displayName == "ABS")
    #expect(queue.state == .loading)
  }

  /// The degraded-cadence inputs behind API-CONVENTIONS rule 7 have to be reachable
  /// through the boundary rather than read directly by a Core target.
  @Test func networkConditionsAreObservableThroughTheBoundary() {
    let conditions = FakeNetworkConditions()
    conditions.isLowPowerMode = true
    conditions.isConstrainedOrCellular = true

    #expect(conditions.isLowPowerMode)
    #expect(conditions.isConstrainedOrCellular)
  }

  /// Diagnostics record a category only, never a payload (ARCHITECTURE.md).
  @Test func diagnosticsRecordCategoriesOnly() async {
    let diagnostics = FakeDiagnosticsRecording()
    await diagnostics.record(
      DiagnosticsEvent(category: .syncRun, statusClass: .success, durationMilliseconds: 12),
      accountId: 1)

    #expect(diagnostics.recorded.map(\.category) == [.syncRun])
  }
}
