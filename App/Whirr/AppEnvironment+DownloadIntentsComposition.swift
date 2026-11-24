import Persistence
import SyncEngine

extension AppEnvironment {
  /// One pinned-list store behind the reconciler, the declining wrapper and the Collections
  /// `PinnedListDownloads`, and the one hand-download intent chain both `AppDependencies` and the
  /// episode-intents factory receive.
  struct DownloadIntentsComposition {
    let pinnedListStore: PinnedListStore
    let pinnedListReconciler: PinnedListDownloadReconciler?
    let handDownloadIntents: any DownloadIntents
  }

  @MainActor
  static func makeDownloadIntentsComposition(
    database: AppDatabase,
    account: AccountRecord?,
    downloadCoordinator: DownloadCoordinator,
    diagnostics: DiagnosticsStore,
    smartListDownloadStore: SmartListDownloadStore
  ) -> DownloadIntentsComposition {
    // Built before the sync engine so the list refresh can run a pass.
    // Its own requests and releases reach the coordinator directly; only the listener's hand
    // actions go through the declining wrapper, so a pass never declines anything.
    let pinnedListStore = PinnedListStore(database: database)
    let pinnedListReconciler = account?.id.map {
      PinnedListDownloadReconciler(
        accountID: $0, store: pinnedListStore, requesting: downloadCoordinator,
        diagnostics: diagnostics)
    }
    let pinnedDecliningIntents: any DownloadIntents =
      account?.id.map {
        PinnedListDecliningDownloadIntents(
          wrapping: downloadCoordinator, declining: pinnedListStore, accountID: $0)
      } ?? downloadCoordinator
    // Smart lists decline native episodes signed out too, so this wrapper is always present.
    let smartDecliningIntents: any DownloadIntents = SmartListDecliningDownloadIntents(
      wrapping: pinnedDecliningIntents, declining: smartListDownloadStore,
      accountID: account?.id)
    // Up Next exists only signed in, as does its wrapper.
    let handDownloadIntents: any DownloadIntents =
      account?.id.map {
        UpNextDecliningDownloadIntents(
          wrapping: smartDecliningIntents,
          declining: ListeningQueueStore(database: database, accountId: $0))
      } ?? smartDecliningIntents
    return DownloadIntentsComposition(
      pinnedListStore: pinnedListStore,
      pinnedListReconciler: pinnedListReconciler,
      handDownloadIntents: handDownloadIntents)
  }
}
