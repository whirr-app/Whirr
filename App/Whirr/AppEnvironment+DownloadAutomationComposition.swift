import AppModel
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine

extension AppEnvironment {
  struct StorageComposition {
    let storageCeilingSummaryReading: any StorageCeilingSummaryReading
    let storageReading: any StorageReading
    let storageCeilingCoordinator: StorageCeilingCoordinator?
  }

  struct DownloadAutomationComposition {
    let listeningQueueReading: any ListeningQueueReading
    let listeningQueueStoring: any ListeningQueueStoring
    let savedShelfStoring: any SavedShelfStoring
    let savedShelfReading: (any SavedShelfReading)?
    let recentSearchStore: any RecentSearchStoring
    let podcastShowOrdering: any PodcastShowOrdering
    let carPlayBrowseSources: CarPlayBrowseSources
    let queueAutoDownloadReconciler: QueueAutoDownloadReconciler?
    let downloadAutomationTasks: [Task<Void, Never>]
  }

  @MainActor
  static func makeDownloadAutomationComposition(
    database: AppDatabase,
    resolvedAccount: AccountRecord?,
    lifecycle: ScenePhaseAppLifecycle,
    networkConditions: NetworkConditionsReducer,
    diagnostics: DiagnosticsStore,
    downloadCoordinator: DownloadCoordinator,
    downloadPreferences: any DownloadPreferences,
    storageReading: any StorageReading,
    storageCeilingCoordinator: StorageCeilingCoordinator?,
    pinnedListReconciler: PinnedListDownloadReconciler?,
    smartListDownloads: (reconciler: SmartListDownloadReconciler, store: SmartListDownloadStore)?
  ) -> DownloadAutomationComposition {
    // Account-scoped: `listeningQueueEntry` cascades with the account.
    let listeningQueueReading: any ListeningQueueReading
    let listeningQueueStoring: any ListeningQueueStoring
    let queueAutoDownloadReconciler: QueueAutoDownloadReconciler?
    // Account-scoped: `savedShelfEntry` cascades with the account, so neither boundary sees
    // another account's shelf.
    let savedShelfStoring: any SavedShelfStoring
    let savedShelfReading: (any SavedShelfReading)?
    // Account-scoped (`recentSearch` table). With no signed-in account (defensive; the
    // authenticated path always has one) this falls back to the no-op rather than invent an id.
    let recentSearchStore: any RecentSearchStoring
    // Account-scoped: `podcastShowOrder`/`podcastShowOrderEntry` cascade with the account.
    let podcastShowOrdering: any PodcastShowOrdering
    // The car's show page reads the account's show order, so its readers are account-scoped too.
    let carPlayBrowseSources: CarPlayBrowseSources
    if let accountId = resolvedAccount?.id {
      let listeningQueue = ListeningQueueStore(database: database, accountId: accountId)
      listeningQueueReading = listeningQueue
      listeningQueueStoring = QueueAutoDownload(
        store: listeningQueue,
        requesting: downloadCoordinator,
        preferences: downloadPreferences,
        networkConditions: networkConditions,
        diagnostics: diagnostics,
        accountId: accountId,
        declines: listeningQueue)
      queueAutoDownloadReconciler = QueueAutoDownloadReconciler(
        candidateProvider: listeningQueue,
        requesting: downloadCoordinator,
        preferences: downloadPreferences,
        networkConditions: networkConditions,
        diagnostics: diagnostics,
        accountId: accountId,
        declines: listeningQueue)
      let savedShelf = SavedShelfStore(database: database, accountId: accountId)
      // Decorates the write seam like `QueueAutoDownload`, so every save passes through it and
      // no call site changes.
      savedShelfStoring = SavedShelfAutoDownload(
        store: savedShelf,
        targets: savedShelf,
        requesting: downloadCoordinator,
        preferences: downloadPreferences,
        networkConditions: networkConditions,
        diagnostics: diagnostics,
        accountId: accountId)
      savedShelfReading = DefaultSavedShelfReading(database: database, accountId: accountId)
      recentSearchStore = RecentSearchStore(database: database, accountId: accountId)
      podcastShowOrdering = DefaultPodcastShowOrdering(database: database, accountId: accountId)
      let audioPaging = DefaultAudioBrowsePaging(database: database)
      carPlayBrowseSources = CarPlayBrowseSources(
        queue: listeningQueue,
        audiobooks: audioPaging,
        entities: audioPaging,
        serverPodcasts: DefaultPodcastBrowsePaging(database: database, accountId: accountId),
        followedPodcasts: RSSPodcastReading(database: database),
        serverDownloads: audioPaging,
        followedDownloads: DefaultRSSDownloadsReading(database: database))
    } else {
      listeningQueueReading = NoOpListeningQueueStore()
      listeningQueueStoring = NoOpListeningQueueStore()
      queueAutoDownloadReconciler = nil
      savedShelfStoring = NoOpSavedShelfStore()
      savedShelfReading = nil
      recentSearchStore = NoOpRecentSearchStoring()
      podcastShowOrdering = NoOpPodcastShowOrdering()
      carPlayBrowseSources = .empty
    }

    var downloadAutomationTasks: [Task<Void, Never>] = []
    let smartListReconciler = smartListDownloads?.reconciler
    if queueAutoDownloadReconciler != nil || storageCeilingCoordinator != nil
      || smartListReconciler != nil
    {
      let lifecycleTransitions = lifecycle.transitions
      downloadAutomationTasks.append(
        Task { [weak queueAutoDownloadReconciler, weak storageCeilingCoordinator, smartListReconciler] in
          for await transition in lifecycleTransitions {
            guard Task.isCancelled == false else { return }
            guard transition == .foreground else { continue }
            // Reconcile-then-evict cannot churn the rows it just requested: an Up Next identity is
            // excluded from `StorageEvictionStore`'s candidate query (and its revalidation in the
            // claim transaction), and a requested download no longer matches the reconciler's
            // "queue identities without downloads" candidacy.
            if let queueAutoDownloadReconciler {
              await queueAutoDownloadReconciler.run()
            }
            // Claimed Smart List episodes are excluded from eviction, so requesting them first
            // is stable for the same reason.
            await smartListReconciler?.run()
            if let storageCeilingCoordinator {
              _ = await storageCeilingCoordinator.enforce()
            }
          }
        })
    }
    if queueAutoDownloadReconciler != nil || pinnedListReconciler != nil
      || smartListReconciler != nil
    {
      let networkChanges = networkConditions.changes
      downloadAutomationTasks.append(
        Task { [weak queueAutoDownloadReconciler, weak pinnedListReconciler, smartListReconciler] in
          var previousIsConstrainedOrCellular: Bool?
          for await snapshot in networkChanges {
            guard Task.isCancelled == false else { return }
            defer { previousIsConstrainedOrCellular = snapshot.isConstrainedOrCellular }
            guard
              previousIsConstrainedOrCellular == true,
              snapshot.isConstrainedOrCellular == false
            else { continue }
            await queueAutoDownloadReconciler?.run()
            // A pinned download held for Wi-Fi resumes on its own; this picks up members that
            // joined a list while the pass was skipped or capped.
            await pinnedListReconciler?.run()
            // Cellular admission is judged per request, so a pass refused on cellular is retried
            // here.
            await smartListReconciler?.run()
          }
        })
    }
    if let smartListDownloads {
      // A change to what an auto-download list wants (membership, order, a finished episode)
      // re-runs the pass; the reconciler debounces the burst.
      let reconciler = smartListDownloads.reconciler
      let store = smartListDownloads.store
      downloadAutomationTasks.append(
        Task {
          let changes = await store.observeWantedEpisodes()
          await reconciler.runOnChanges(changes)
        })
    }
    if let storageCeilingCoordinator {
      let completedTotals = storageReading.observeCompletedDownloadTotals()
      downloadAutomationTasks.append(
        Task { [weak storageCeilingCoordinator] in
          for await completedBytes in completedTotals {
            guard Task.isCancelled == false else { return }
            guard let storageCeilingCoordinator else { return }
            _ = await storageCeilingCoordinator.enforce(completedBytes: completedBytes)
          }
        })

      let ceilingChanges = downloadPreferences.storageCeilingBytesChanges
      downloadAutomationTasks.append(
        Task { [weak storageCeilingCoordinator] in
          for await _ in ceilingChanges {
            guard Task.isCancelled == false else { return }
            guard let storageCeilingCoordinator else { return }
            _ = await storageCeilingCoordinator.enforce()
          }
        })
    }

    return DownloadAutomationComposition(
      listeningQueueReading: listeningQueueReading,
      listeningQueueStoring: listeningQueueStoring,
      savedShelfStoring: savedShelfStoring,
      savedShelfReading: savedShelfReading,
      recentSearchStore: recentSearchStore,
      podcastShowOrdering: podcastShowOrdering,
      carPlayBrowseSources: carPlayBrowseSources,
      queueAutoDownloadReconciler: queueAutoDownloadReconciler,
      downloadAutomationTasks: downloadAutomationTasks)
  }

  @MainActor
  static func makeStorageComposition(
    database: AppDatabase,
    resolvedAccount: AccountRecord?,
    podcastServices: PodcastBackgroundRefreshHardware.SharedServices,
    downloadCoordinator: DownloadCoordinator,
    downloadPreferences: any DownloadPreferences
  ) -> StorageComposition {
    let storageCeilingSummaryStore = UserDefaultsStorageCeilingSummaryStore(
      accountId: resolvedAccount?.id)
    let storageReading: any StorageReading = DefaultStorageReading(database: database)
    let storageCeilingCoordinator: StorageCeilingCoordinator?
    if let accountId = resolvedAccount?.id {
      storageCeilingCoordinator = StorageCeilingCoordinator(
        preferences: downloadPreferences,
        storageReading: storageReading,
        evictionClaiming: StorageEvictionStore(
          database: database, accountId: accountId,
          activeRSSExclusionProvider: {
            podcastServices.rssActivePlaybackTracker.activeEpisodeRowIDs
          }),
        purging: downloadCoordinator,
        summaryStoring: storageCeilingSummaryStore)
    } else {
      storageCeilingCoordinator = nil
    }
    return StorageComposition(
      storageCeilingSummaryReading: storageCeilingSummaryStore,
      storageReading: storageReading,
      storageCeilingCoordinator: storageCeilingCoordinator)
  }
}
