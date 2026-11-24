import AppModel
import Persistence
import SyncEngine

extension AppEnvironment {
  /// The Collections boundary, or `.unavailable` signed out. Returned directly, as
  /// `AccountComposition`'s builders do, since there is nothing else to unpack.
  @MainActor
  static func makeLibraryCollectionsComposition(
    database: AppDatabase,
    account: AccountRecord?,
    libraryCollectionService: LibraryCollectionService,
    queue: any ListeningQueueStoring,
    pinnedListStore: PinnedListStore,
    pinnedListReconciler: PinnedListDownloadReconciler?,
    downloadCoordinator: DownloadCoordinator
  ) -> LibraryCollectionsAccess {
    account?.id.map { accountID in
      LibraryCollectionsAccess(
        reading: DefaultLibraryCollectionReading(database: database, accountID: accountID),
        queue: queue,
        fill: { force in
          await libraryCollectionService.refreshAll(force: force)
          await pinnedListReconciler?.run()
        },
        pins: pinnedListReconciler.map {
          PinnedListDownloads(
            accountID: accountID, store: pinnedListStore, reconciler: $0,
            intents: downloadCoordinator)
        } ?? NoOpPinnedListDownloads())
    } ?? .unavailable
  }
}
