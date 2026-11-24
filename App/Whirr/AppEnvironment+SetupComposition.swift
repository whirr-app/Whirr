import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine

extension AppEnvironment {
  @MainActor
  static func makeRemovalDependencies(
    account: any AccountLifecycle,
    database: AppDatabase,
    hardware: PlaybackHardware,
    lifecycle: ScenePhaseAppLifecycle,
    diagnostics: DiagnosticsStore
  ) -> AppDependencies {
    AppDependencies.platform(
      player: hardware.player,
      library: DefaultLibraryReading(database: database),
      reader: ReadiumEPUBRenderer(),
      networkConditions: SetupNetworkConditions(),
      account: account,
      sync: SetupSyncCoordinator(),
      playbackSync: SetupPlaybackSync(),
      appLifecycle: lifecycle,
      diagnostics: diagnostics,
      // This whole composition exists because the journal read said a removal survived to this
      // launch, so `RootModel.init` can raise the removal gate before the first frame rather
      // than a scheduling hop into it. Reasserting the known answer
      // instead of re-reading the journal.
      isRemovalPendingSynchronously: { true })
  }

  @MainActor
  static func makeSetupDependencies(
    account: any AccountLifecycle,
    database: AppDatabase,
    accountDAO: AccountDAO,
    hardware: PlaybackHardware,
    lifecycle: ScenePhaseAppLifecycle,
    diagnostics: DiagnosticsStore,
    serverConfigFactory: ABSServerConfigFactory,
    tokenStore: KeychainTokenStore,
    customHeaderStore: any CustomHeaderStoring,
    clearCachedArtwork: @escaping @Sendable () async -> Void
  ) -> AppDependencies {
    let libraryReading = DefaultLibraryReading(database: database)
    let librarySelectionStore = LibrarySelectionStore(database: database)
    let librarySelectionDiscovery = LibrarySelectionDiscoveryService(
      database: database, selectionReading: librarySelectionStore,
      clientFactory: { account in
        guard let url = URL(string: account.serverBaseURL) else {
          throw LibrarySelectionDiscoveryError.malformedAccount
        }
        return ABSClient.production(
          server: try serverConfigFactory.make(for: url), account: try account.credentialTokenAccount,
          tokenStore: tokenStore, customHeaderStore: customHeaderStore,
          clearCachedArtwork: clearCachedArtwork)
      })
    return AppDependencies.platform(
      player: hardware.player,
      library: libraryReading,
      reader: ReadiumEPUBRenderer(),
      networkConditions: SetupNetworkConditions(),
      account: account,
      sync: SetupSyncCoordinator(),
      playbackSync: SetupPlaybackSync(),
      appLifecycle: lifecycle,
      diagnostics: diagnostics,
      isLibrarySelectionPending: { (try? accountDAO.fetch())?.librarySelectionMode == .pending },
      librarySelectionReading: librarySelectionStore,
      librarySelectionWriting: librarySelectionStore,
      librarySelectionDiscovery: librarySelectionDiscovery,
      rssNotificationLifecycle: RSSNotificationLifecycleCoordinator(
        ledger: RSSNotificationLedgerStore(database: database),
        scheduler: PodcastLocalNotificationCenter.shared)
    )
  }
}
