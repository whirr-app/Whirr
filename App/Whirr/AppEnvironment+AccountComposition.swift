import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine

/// What a runtime removal must reuse from the live graph. Pending removal has no live graph, so
/// it passes `nil`: the set is either complete or absent, never a partly filled row of optionals.
private nonisolated struct RemovalLiveCollaborators: Sendable {
  let client: ABSClient
  let playback: any PlaybackSyncing
  let downloadCoordinator: DownloadCoordinator
  let syncEngine: SyncEngine
  let requestDrain: @Sendable () async -> Void
}

extension AppEnvironment {
  /// The account lifecycle for the removal-only graph: the coordinator that finishes a durable
  /// removal, and nothing that could start an authenticated client.
  @MainActor
  static func makePendingRemovalAccountLifecycle(
    database: AppDatabase,
    accountDAO: AccountDAO,
    tokenStore: KeychainTokenStore,
    customHeaderStore: KeychainCustomHeaderStore,
    accountRemover: AccountRemover,
    applicationSupportDirectory: URL?,
    diagnosticsRootURL: URL,
    clearCachedArtwork: @escaping @Sendable () async -> Void
  ) -> AccountLifecycleService {
    // The resumed removal must still delete the account's on-disk artifacts. Both roots are
    // derivable without composing the download or cover services: the downloads root mirrors
    // `PodcastBackgroundRefresh`'s spelling exactly, and the cover root is the client's own
    // disposable-cache directory.
    let downloadsRootURL = DownloadLocations.root(
      applicationSupportDirectory: applicationSupportDirectory
        ?? AppEnvironment.applicationSupportDirectory())
    let removalCoordinator = Self.makeRemovalCoordinator(
      database: database,
      accountDAO: accountDAO,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      accountRemover: accountRemover,
      downloadsRootURL: downloadsRootURL,
      diagnosticsRootURL: diagnosticsRootURL,
      widgetRootURLs: WidgetFileStore.production(applicationSupportDirectory: applicationSupportDirectory)
        .removalRootURLs,
      clearCachedArtwork: clearCachedArtwork,
      live: nil)
    return AccountLifecycleService(
      tokenStore: tokenStore,
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: accountRemover,
      customHeaderStore: customHeaderStore,
      removalCoordinator: removalCoordinator,
      clearCachedArtwork: clearCachedArtwork)
  }

  /// The runtime graph's removal sequence, bound to the live client and download state.
  @MainActor
  static func makeRuntimeRemovalCoordinator(
    database: AppDatabase,
    accountDAO: AccountDAO,
    tokenStore: KeychainTokenStore,
    customHeaderStore: KeychainCustomHeaderStore,
    accountRemover: AccountRemover,
    client: ABSClient,
    playbackSyncing: any PlaybackSyncing,
    downloadCoordinator: DownloadCoordinator,
    syncEngine: SyncEngine,
    requestDrain: @escaping @Sendable () async -> Void,
    downloadsRootURL: URL,
    diagnosticsRootURL: URL,
    widgetRootURLs: [URL],
    clearCachedArtwork: @escaping @Sendable () async -> Void
  ) -> AccountRemovalCoordinator {
    Self.makeRemovalCoordinator(
      database: database,
      accountDAO: accountDAO,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      accountRemover: accountRemover,
      downloadsRootURL: downloadsRootURL,
      diagnosticsRootURL: diagnosticsRootURL,
      widgetRootURLs: widgetRootURLs,
      clearCachedArtwork: clearCachedArtwork,
      live: RemovalLiveCollaborators(
        client: client,
        playback: playbackSyncing,
        downloadCoordinator: downloadCoordinator,
        syncEngine: syncEngine,
        requestDrain: requestDrain))
  }

  /// The one removal-coordinator construction. Only `live` distinguishes the two graphs, so a
  /// missed collaborator cannot reach the runtime sequence by falling back to a default.
  @MainActor
  private static func makeRemovalCoordinator(
    database: AppDatabase,
    accountDAO: AccountDAO,
    tokenStore: KeychainTokenStore,
    customHeaderStore: KeychainCustomHeaderStore,
    accountRemover: AccountRemover,
    downloadsRootURL: URL,
    diagnosticsRootURL: URL,
    widgetRootURLs: [URL],
    clearCachedArtwork: @escaping @Sendable () async -> Void,
    live: RemovalLiveCollaborators?
  ) -> AccountRemovalCoordinator {
    let clientFactory: AccountRemovalCoordinator.ClientFactory?
    let cancelForegroundSync: @Sendable () async -> Void
    let drainOutboxBeforeRemoval: @Sendable () async -> Void
    if let live {
      // Account removal must invalidate the same cached AuthenticatedHTTPClient that serves the
      // live graph. The default factory would create a fresh client and leave in-memory tokens,
      // the refresh task, and the reauthentication latch on `live.client` untouched.
      clientFactory = { _, _ in live.client }
      // Awaited at removal's step 4: the live engine's traversal ends before the purge and the
      // credential wipe.
      cancelForegroundSync = { await live.syncEngine.shutdown() }
      // The live graph's shared drain, so unsent progress gets one bounded send before the
      // account row and its outbox are deleted.
      drainOutboxBeforeRemoval = { await live.requestDrain() }
    } else {
      clientFactory = nil
      cancelForegroundSync = {}
      drainOutboxBeforeRemoval = {}
    }

    return AccountRemovalCoordinator(
      tokenStore: tokenStore,
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      journalStore: AccountRemovalJournalStore(database: database),
      accountRemover: accountRemover,
      customHeaderStore: customHeaderStore,
      clientFactory: clientFactory,
      playback: live?.playback,
      downloadCoordinator: live?.downloadCoordinator,
      cancelForegroundSync: cancelForegroundSync,
      drainOutboxBeforeRemoval: drainOutboxBeforeRemoval,
      // `CoverImageClient`'s own disposable-cache directory (the cover cache is always
      // disposable). Read from the client rather than re-derived, since the Library Cache clear
      // measures and empties the same directory and two spellings of it would drift.
      downloadsRootURL: downloadsRootURL,
      coverCacheRootURL: CoverImageClient.disposableCacheDirectoryURL,
      exportedDiagnosticsRootURL: diagnosticsRootURL,
      widgetRootURLs: widgetRootURLs,
      clearCachedArtwork: clearCachedArtwork)
  }

  /// Lifecycle with a real `removalCoordinator`, so `logout()` runs the full removal sequence.
  ///
  /// `clientFactory` returns the shared `client`, not a fresh `ABSClient.production(...)`: rotated
  /// tokens saved through another client would miss the live `AuthenticatedHTTPClient`'s cached
  /// tokens and rejection latch. Safe because this instance only calls `reauthenticate` and
  /// `logout` for the stored account. The pre-authentication setup lifecycle keeps the default
  /// factory.
  @MainActor
  static func makeRuntimeAccountLifecycle(
    database: AppDatabase,
    accountDAO: AccountDAO,
    tokenStore: KeychainTokenStore,
    customHeaderStore: KeychainCustomHeaderStore,
    accountRemover: AccountRemover,
    client: ABSClient,
    removalCoordinator: AccountRemovalCoordinator,
    clearCachedArtwork: @escaping @Sendable () async -> Void
  ) -> AccountLifecycleService {
    AccountLifecycleService(
      tokenStore: tokenStore,
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: accountRemover,
      customHeaderStore: customHeaderStore,
      clientFactory: { _, _ in client },
      removalCoordinator: removalCoordinator,
      clearCachedArtwork: clearCachedArtwork
    )
  }
}
