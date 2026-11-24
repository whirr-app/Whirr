import ABSApi
import Persistence
import SyncEngine

extension AppEnvironment {
  /// The catalogue services one runtime graph shares: `podcastShowRefresh` is the shared-services
  /// alias the background pass and the sync traversal also drive, and the two actors are captured
  /// by `SyncEngine`'s traversal closures and handed to `AppDependencies` as the same instances.
  struct CatalogueRefreshComposition {
    let podcastShowRefresh: PodcastRefreshCoordinator
    let recentEpisodes: RecentEpisodeRefreshCoordinator
    let podcastProgressHydration: PodcastProgressHydrationCoordinator
    let authorSeriesService: AuthorSeriesService
    let libraryCollectionService: LibraryCollectionService
  }

  @MainActor
  static func makeCatalogueRefreshComposition(
    database: AppDatabase,
    client: ABSClient,
    showRefresh: PodcastRefreshCoordinator
  ) -> CatalogueRefreshComposition {
    // Home's new-episodes row is fed from the server's own newest-episodes shelf instead: one
    // request per podcast library per refresh, one commit for the payload.
    let recentEpisodes = RecentEpisodeRefreshCoordinator(database: database, client: client)

    // Podcast progress is episode-keyed, so a library pull has nowhere to put it until that show's
    // episodes exist locally. This expands only the shows the account has part-heard,
    // so signing in surfaces them without the user opening each one by hand.
    let podcastProgressHydration = PodcastProgressHydrationCoordinator(
      database: database, showRefresh: showRefresh)

    let authorSeriesService = AuthorSeriesService(database: database, client: client)
    // An ancillary pass after each completed catalogue traversal, beside the author and series
    // hand-off, plus the Collections mode's own fill.
    let libraryCollectionService = LibraryCollectionService(database: database, client: client)

    return CatalogueRefreshComposition(
      podcastShowRefresh: showRefresh,
      recentEpisodes: recentEpisodes,
      podcastProgressHydration: podcastProgressHydration,
      authorSeriesService: authorSeriesService,
      libraryCollectionService: libraryCollectionService)
  }
}
