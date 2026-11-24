import ABSApi
import AppModel
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import Testing

@testable import Whirr

/// Composition identity: `AppEnvironment` is rebuilt at login and logout
/// (`RootView.rebuildAfterAuthentication`, `.handleLoggedOut`); a rebuild must never re-register
/// remote commands or build a second `PlayerController`.
///
/// Builds the real production graph on an in-memory database, a temporary storage root and an
/// injected `RemoteCommandRegistering` fake, so none touches user data or `MPRemoteCommandCenter`.
@MainActor
@Suite("Production composition identity", .serialized)
struct AppEnvironmentCompositionTests {

  @Test("an unauthenticated launch composes only the setup services")
  func unauthenticatedLaunchUsesLightweightComposition() {
    let fakeCenter = FakeRemoteCommandRegistering()
    let hardware = PlaybackHardware(remoteCommandCenter: fakeCenter)
    let environment = Self.environment(hardware: hardware, mode: .automatic)

    #expect(environment.composition == .setup)
    #expect(environment.dependencies.isRemovalPendingSynchronously() == false)
    #expect(environment.dependencies.account is AccountLifecycleService)
    #expect(environment.dependencies.downloadIntents is NoOpDownloadIntents)
    #expect(environment.dependencies.downloadReading is NoOpDownloadReading)
    #expect(environment.dependencies.storageReading is NoOpStorageReading)
    #expect(
      environment.dependencies.deviceStorageCapacityReading
        is NoOpDeviceStorageCapacityReading)
    #expect(environment.dependencies.homeReading is NoOpHomeReading)
    #expect(fakeCenter.setterCallCount == 10)
  }

  @Test("a pending removal composes only the removal graph")
  func pendingRemovalUsesRemovalOnlyComposition() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let journal = AccountRemovalJournalStore(database: database)
    try journal.clear()
    defer { try? journal.clear() }
    try journal.create(
      AccountRemovalJournalRecord(
        serverBaseURL: "https://pending-removal.invalid",
        serverUserId: "pending-removal-user",
        accountRowId: 1,
        downloadsRootRelativePath: "Downloads",
        createdAt: Date()
      ))

    let environment = Self.environment(
      hardware: hardware, mode: .automatic, database: database)

    #expect(environment.composition == .removalPending)
    // `RootModel.init` resolves the shell synchronously, so the removal gate must be readable
    // there. Left at its `{ false }` default, the composition would paint a shell frame over a
    // mid-removal account before the async resume raised the gate.
    #expect(environment.dependencies.isRemovalPendingSynchronously())
    #expect(environment.dependencies.downloadIntents is NoOpDownloadIntents)
    #expect(environment.dependencies.downloadReading is NoOpDownloadReading)
    #expect(environment.dependencies.storageReading is NoOpStorageReading)
    #expect(environment.dependencies.homeReading is NoOpHomeReading)
    #expect(environment.dependencies.podcastReading is NoOpPodcastReading)
    #expect(environment.dependencies.podcastRefreshing is NoOpPodcastRefreshing)
    #expect(environment.dependencies.sync is SetupSyncCoordinator)
    #expect(environment.authRecoveryModel == nil)
    guard let account = environment.dependencies.account as? AccountLifecycleService else {
      Issue.record("expected the removal-only AccountLifecycleService")
      return
    }
    let removalCoordinator = Mirror(reflecting: account).children.first(where: {
      $0.label == "removalCoordinator"
    })
    #expect(removalCoordinator.map { Mirror(reflecting: $0.value).children.count } == 1)
  }

  @Test("PlaybackHardware registers every remote command exactly once at construction")
  func remoteCommandRegistersExactlyOnce() {
    let fakeCenter = FakeRemoteCommandRegistering()
    _ = PlaybackHardware(remoteCommandCenter: fakeCenter)

    // One `set*Handler` call per command that `RemoteCommandAdapter.register()` wires: play, pause,
    // toggle, stop, skip forward and backward, next and previous track, change position and change
    // rate.
    #expect(fakeCenter.setterCallCount == 10)
  }

  @Test("two independent PlaybackHardware instances never share a player or engine")
  func distinctHardwareInstancesAreIndependent() {
    let first = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let second = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())

    #expect(ObjectIdentifier(first.player) != ObjectIdentifier(second.player))
    #expect(ObjectIdentifier(first.engine) != ObjectIdentifier(second.engine))
  }

  @Test("rebuilding AppEnvironment against the same hardware reuses one player and never re-registers remote commands")
  func appEnvironmentRebuildReusesSharedHardware() {
    let fakeCenter = FakeRemoteCommandRegistering()
    let hardware = PlaybackHardware(remoteCommandCenter: fakeCenter)
    #expect(fakeCenter.setterCallCount == 10)

    // Mirrors `RootView.rebuildAfterAuthentication` and `.handleLoggedOut`: a fresh
    // `AppEnvironment` over the same shared `hardware`.
    let firstEnvironment = Self.environment(hardware: hardware)
    let secondEnvironment = Self.environment(hardware: hardware)

    #expect(fakeCenter.setterCallCount == 10)
    #expect(fakeCenter.removeAllTargetsCallCount == 0)

    let firstPlayer = firstEnvironment.dependencies.player as AnyObject
    let secondPlayer = secondEnvironment.dependencies.player as AnyObject
    #expect(ObjectIdentifier(firstPlayer) == ObjectIdentifier(secondPlayer))
    #expect(ObjectIdentifier(firstPlayer) == ObjectIdentifier(hardware.player))
  }

  @Test("the root composition wires the process-wide logout preflight into settings")
  func rootCompositionWiresLogoutPreflight() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let composition = RootComposition(
      hardware: hardware, mode: .runtime, database: try AppDatabase.inMemory(), watchCompanionRuntime: nil)

    #expect(composition.logoutPreflight is PlaybackLogoutPreflight)
  }

  // MARK: - Downloads/resolution/removal production graph

  @Test("AppDependencies wires the real download, resolution and removal conformances, not the no-op defaults")
  func downloadAndResolutionDependenciesAreRealConformances() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware)

    // Signed out, the smart-list wrapper sits straight over the coordinator.
    let smartDeclining = environment.dependencies.downloadIntents as? SmartListDecliningDownloadIntents
    #expect(smartDeclining?.wrapped is DownloadCoordinator)
    #expect(environment.dependencies.resolutionCenterAccess is ResolutionCenter)
    #expect(environment.dependencies.account is AccountLifecycleService)
    #expect((environment.dependencies.downloadReading is NoOpDownloadReading) == false)
    #expect((environment.dependencies.storageReading is NoOpStorageReading) == false)
    #expect(
      environment.dependencies.deviceStorageCapacityReading
        is FileSystemDeviceStorageCapacityReader)
    #expect((environment.dependencies.downloadPreferences is NoOpDownloadPreferences) == false)
  }

  // MARK: - Platform baseline (B10)

  @Test("the runtime graph's sync, playback and artwork boundaries are the live instances")
  func runtimeCompositionUsesLiveBaselineSlots() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: try Self.authenticatedDatabase())

    // These three are the boundaries a no-op default used to hide. If a future default returns,
    // the runtime graph runs with a dead sync, playback or cover-cache boundary and nothing fails.
    #expect(environment.dependencies.sync is SyncEngine)
    #expect(environment.dependencies.playbackSync is StreamConfiguringPlaybackSyncing)
    #expect(environment.dependencies.artworkCacheAccess is ArtworkCacheService)
    #expect((environment.dependencies.sync is SetupSyncCoordinator) == false)
    #expect((environment.dependencies.playbackSync is SetupPlaybackSync) == false)
    #expect((environment.dependencies.artworkCacheAccess is NoOpArtworkCacheAccess) == false)
  }

  @Test("the removal graph builds from the inert platform baseline")
  func removalCompositionUsesThePlatformBaseline() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let journal = AccountRemovalJournalStore(database: database)
    try journal.clear()
    defer { try? journal.clear() }
    try journal.create(
      AccountRemovalJournalRecord(
        serverBaseURL: "https://baseline-removal.invalid",
        serverUserId: "baseline-removal-user",
        accountRowId: 1,
        downloadsRootRelativePath: "Downloads",
        createdAt: Date()))

    let environment = Self.environment(
      hardware: hardware, mode: .automatic, database: database)

    #expect(environment.composition == .removalPending)
    // `platform(...)` carries the no-op boundaries this graph is allowed to use.
    #expect(environment.dependencies.sync is SetupSyncCoordinator)
    #expect(environment.dependencies.playbackSync is SetupPlaybackSync)
    #expect(environment.dependencies.artworkCacheAccess is NoOpArtworkCacheAccess)
    #expect(environment.dependencies.downloadIntents is NoOpDownloadIntents)
    #expect(environment.dependencies.downloadReading is NoOpDownloadReading)
    #expect(environment.dependencies.serverAccountReading is NoOpServerAccountReading)
    #expect(environment.dependencies.librarySelectionReading is NoOpLibrarySelectionStore)
    #expect(environment.dependencies.librarySelectionWriting is NoOpLibrarySelectionStore)
    // The one slot the removal graph overrides, so the launch gate is readable synchronously.
    #expect(environment.dependencies.isRemovalPendingSynchronously())
  }

  @Test("the setup graph adds its selection and notification extras to the baseline")
  func setupCompositionAddsItsExtrasToTheBaseline() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware, mode: .automatic)

    #expect(environment.composition == .setup)
    #expect(environment.dependencies.librarySelectionReading is LibrarySelectionStore)
    #expect(environment.dependencies.librarySelectionWriting is LibrarySelectionStore)
    #expect(environment.dependencies.librarySelectionDiscovery is LibrarySelectionDiscoveryService)
    #expect(
      environment.dependencies.rssNotificationLifecycle is RSSNotificationLifecycleCoordinator)
    // Still inert: the baseline supplies these, and setup must not open account-owned reads.
    #expect(environment.dependencies.sync is SetupSyncCoordinator)
    #expect(environment.dependencies.artworkCacheAccess is NoOpArtworkCacheAccess)
    #expect(environment.dependencies.serverAccountReading is NoOpServerAccountReading)
  }

  // MARK: - Item detail extras/history (detail-screen-redesign)

  @Test(
    "AppDependencies wires the real ItemDetailExtrasService/ListeningHistoryCoordinator, not the NoOp defaults"
  )
  func detailExtrasAndHistoryDependenciesAreRealConformances() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware)

    #expect(environment.dependencies.extrasAccess is ItemDetailExtrasService)
    #expect(environment.dependencies.historyAccess is ListeningHistoryCoordinator)
    #expect((environment.dependencies.extrasAccess is NoOpItemDetailExtrasAccess) == false)
    #expect((environment.dependencies.historyAccess is NoOpListeningHistoryProviding) == false)
  }

  @Test("AppDependencies wires the real ListeningStatsCoordinator, not the NoOp default")
  func listeningStatsDependencyIsTheRealCoordinator() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware)

    #expect(environment.dependencies.listeningStatsAccess is ListeningStatsCoordinator)
  }

  // MARK: - Home (phase-4b-home-screen.md T4B.7b)

  @Test("AppDependencies wires the real DefaultHomeReading, not the NoOp default")
  func homeDependencyIsRealConformance() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware)

    #expect(environment.dependencies.homeReading is DefaultHomeReading)
    #expect((environment.dependencies.homeReading is NoOpHomeReading) == false)
  }

  /// A missed composition is silent. The merge still runs and the no-op still emits its one empty
  /// value, so Continue Listening never shows a device-owned row. This is the failure the test
  /// pins.
  @Test("runtime composes the device-owned Continue Listening reader, setup keeps the no-op")
  func nativeContinueListeningReaderIsComposedOnlyAtRuntime() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())

    let runtime = Self.environment(hardware: hardware)
    #expect(runtime.dependencies.nativeContinueListeningReading is RSSContinueListeningReading)

    // The RSS tables survive an account, but a signed-out shell must not open an observation
    // against them.
    let setup = Self.environment(hardware: hardware, mode: .automatic)
    #expect(setup.composition == .setup)
    #expect(setup.dependencies.nativeContinueListeningReading is NoOpNativeContinueListeningReading)
  }

  @Test("runtime composition wires real podcast readers, refresher, and durable queue")
  func podcastDependenciesAreRealConformances() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "podcast-composition",
        serverBaseURL: "https://podcast-composition.invalid",
        serverUserId: "podcast-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "podcast-library"))
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: database)

    #expect(environment.dependencies.podcastReading is RoutingPodcastReading)
    #expect(environment.dependencies.podcastRefreshing is RoutingPodcastRefreshing)
    #expect(
      environment.dependencies.rssFeedRefreshCoordinator
        is RSSRefreshAutomationCoordinator)
    // One queue store per account graph. The podcast-only pair that once sat beside it is gone, so
    // this is the queue the show screen, the player and item actions share.
    #expect(environment.dependencies.listeningQueueReading is ListeningQueueStore)
    #expect(environment.dependencies.listeningQueueStoring is QueueAutoDownload)
  }

  // MARK: - Server save composition

  @Test("runtime composition wires the real NP12 save coordinator and status projection")
  func signedInCompositionWiresServerSave() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "server-save-composition",
        serverBaseURL: "https://server-save-composition.invalid",
        serverUserId: "server-save-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "server-save-library"))
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: database)

    #expect(environment.dependencies.nativeEpisodeServerSaving is NativeEpisodeServerSaveCoordinator)
    #expect(
      (environment.dependencies.nativeEpisodeServerSaving is NoOpNativeEpisodeServerSaving) == false)
    #expect(
      environment.dependencies.nativeEpisodeServerSaveRecovering
        is NativeEpisodeServerSaveCoordinator)
    #expect(
      environment.dependencies.nativeEpisodeServerSaveStatusReading
        is NativeEpisodeServerSaveStatusProjection)
    #expect(
      environment.dependencies.serverPodcastMutationCapabilityReading
        is ServerPodcastMutationCapabilityService)
    #expect(
      environment.dependencies.serverPodcastAutomationSettingsWriting
        is ServerPodcastAutomationSettingsService)
    #expect(environment.dependencies.accountIdentityReading is DefaultAccountIdentityReading)
  }

  /// Without an account there is nothing to save to, so every server-save seam stays inert rather
  /// than answering as though a server were reachable.
  @Test("setup composition leaves every NP12 server-save seam inert")
  func signedOutCompositionKeepsServerSaveInert() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware, mode: .automatic)

    #expect(environment.composition == .setup)
    #expect(environment.dependencies.nativeEpisodeServerSaving is NoOpNativeEpisodeServerSaving)
    #expect(
      environment.dependencies.nativeEpisodeServerSaveRecovering
        is NoOpNativeEpisodeServerSaveRecovering)
    #expect(
      environment.dependencies.nativeEpisodeServerSaveStatusReading
        is NoOpNativeEpisodeServerSaveStatusReading)
    #expect(
      environment.dependencies.serverPodcastMutationCapabilityReading
        is NoOpServerPodcastMutationCapabilityReading)
    #expect(
      environment.dependencies.serverPodcastAutomationSettingsWriting
        is NoOpServerPodcastAutomationSettingsWriting)
    #expect(environment.dependencies.accountIdentityReading is NoOpAccountIdentityReading)
  }

  /// The coordinator serialises save and remove flights per feed and episode inside one actor. Two
  /// instances would each serialise only against themselves, so the shared-services cache must vend
  /// one per server and account.
  @Test("one save coordinator per server and account, and never shared across accounts")
  func sharedServicesVendsOneSaveCoordinator() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "shared-save-composition",
        serverBaseURL: "https://shared-save-composition.invalid",
        serverUserId: "shared-save-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "shared-save-library"))

    let first = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let second = Self.environment(hardware: hardware, mode: .runtime, database: database)

    let firstCoordinator = try #require(
      first.dependencies.nativeEpisodeServerSaving as? NativeEpisodeServerSaveCoordinator)
    let secondCoordinator = try #require(
      second.dependencies.nativeEpisodeServerSaving as? NativeEpisodeServerSaveCoordinator)
    #expect(firstCoordinator === secondCoordinator)
    // The relaunch recovery seam uses the same actor, so recovery serialises against live flights.
    let recovering = try #require(
      first.dependencies.nativeEpisodeServerSaveRecovering as? NativeEpisodeServerSaveCoordinator)
    #expect(recovering === firstCoordinator)
  }

  /// Removal drops this graph from the cache but cannot stop whatever still retains it. The client
  /// it vends is bound to the signed-in account, so a retained copy cannot authenticate as the next
  /// account on this server.
  @Test("the runtime's shared client is bound to the signed-in account and refuses any other")
  func runtimeSharedClientRefusesAReplacementAccount() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "bound-client-composition",
        serverBaseURL: "https://bound-client-composition.invalid",
        serverUserId: "bound-client-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "bound-client-library"))
    let accountId = try #require(account.id)
    let expectedAccount = try account.credentialTokenAccount
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let downloadCoordinator = try #require(
      handDownloadCoordinator(environment))
    // Hand removals pass through the Up Next wrapper, the smart-list one, then the pinned-list
    // one; each declines.
    let upNextDeclining = try #require(
      environment.dependencies.downloadIntents as? UpNextDecliningDownloadIntents)
    let smartDeclining = try #require(
      upNextDeclining.wrapped as? SmartListDecliningDownloadIntents)
    #expect(smartDeclining.wrapped is PinnedListDecliningDownloadIntents)

    // A cache hit under the environment's own key. The key names no account, so a miss would
    // compose an unbound client and fail below rather than pass vacuously.
    let server = try ABSServerConfig(url: try #require(URL(string: account.serverBaseURL)))
    let services = PodcastBackgroundRefreshHardware.sharedServices(
      key: AppEnvironment.sharedServicesKey(server: server, accountID: accountId),
      server: server,
      tokenAccount: nil,
      tokenStore: try KeychainTokenStore(),
      database: database,
      diagnostics: DiagnosticsStore(database: database),
      accountLifecycle: AccountLifecycleService(
        tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
        accountEndpointDAO: AccountEndpointDAO(database: database),
        accountRemover: AccountRemover(database: database)),
      appLifecycle: environment.dependencies.appLifecycle,
      networkConditions: NetworkConditionsReducer(path: RealPathObserving(), power: RealPowerObserving()),
      podcastSettingsReading: PodcastSettingsStore(database: database, accountId: accountId),
      accountId: accountId)
    #expect(services.downloadCoordinator === downloadCoordinator)
    #expect(services.client.boundAccount == expectedAccount)

    // The refusal is local: it comes before the Keychain read, so no request is built.
    let replacement = try TokenAccount(
      credentialNamespace: "account:replacement-client", userID: "replacement-user")
    await #expect(throws: APIError.cancelled) {
      _ = try await services.client.listLibraries(account: replacement)
    }
  }

  /// Removal's cancel-foreground-sync step is this environment's engine shutdown, so a traversal in
  /// flight at sign-out ends before the purge and the credential wipe.
  @Test("runtime removal shuts down the live sync engine")
  func runtimeRemovalShutsDownTheLiveSyncEngine() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "removal-drain-composition",
        serverBaseURL: "https://removal-drain-composition.invalid",
        serverUserId: "removal-drain-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "removal-drain-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let engine = try #require(environment.dependencies.sync as? SyncEngine)
    let service = try #require(environment.dependencies.account as? AccountLifecycleService)
    // An `Optional` reflects `.some(x)` as one child holding `x`.
    let removalCoordinatorChild = try #require(
      Mirror(reflecting: service).children.first(where: { $0.label == "removalCoordinator" })?.value)
    let removalCoordinator = try #require(
      Mirror(reflecting: removalCoordinatorChild).children.first?.value as? AccountRemovalCoordinator)
    let cancelForegroundSync = try #require(
      Mirror(reflecting: removalCoordinator).children
        .first { $0.label == "cancelForegroundSync" }?.value
        // Core's closure type. This target's approachable concurrency would otherwise spell it
        // `nonisolated(nonsending)` and fail to match.
        as? @concurrent @Sendable () async -> Void)
    #expect(Self.isShutDown(engine) == false)

    await cancelForegroundSync()

    #expect(Self.isShutDown(engine) == true)
  }

  /// Removal gets the live graph's drain, so unsent progress has one bounded send before the
  /// outbox is deleted with the account.
  @Test("runtime removal is given an outbox drain")
  func runtimeRemovalIsGivenAnOutboxDrain() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "removal-outbox-composition",
        serverBaseURL: "https://removal-outbox-composition.invalid",
        serverUserId: "removal-outbox-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "removal-outbox-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let service = try #require(environment.dependencies.account as? AccountLifecycleService)
    let removalCoordinatorChild = try #require(
      Mirror(reflecting: service).children.first(where: { $0.label == "removalCoordinator" })?.value)
    let removalCoordinator = try #require(
      Mirror(reflecting: removalCoordinatorChild).children.first?.value as? AccountRemovalCoordinator)
    let drain = try #require(
      Mirror(reflecting: removalCoordinator).children
        .first { $0.label == "drainOutboxBeforeRemoval" }?.value
        as? @concurrent @Sendable () async -> Void)

    // An empty outbox: the shared drain returns without sending anything.
    await drain()
  }

  /// Removal reuses the runtime graph's live playback and transfer engine rather than composing
  /// its own.
  @Test("runtime removal reuses the live playback and download coordinator")
  func runtimeRemovalReusesTheLiveGraph() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "removal-live-graph",
        serverBaseURL: "https://removal-live-graph.invalid",
        serverUserId: "removal-live-graph-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "removal-live-graph-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let coordinator = try Self.removalCoordinator(in: environment)

    let downloadCoordinator = try #require(handDownloadCoordinator(environment))
    let download = try Self.liveCollaborator(named: "downloadCoordinator", of: coordinator)
    #expect(try #require(download as? DownloadCoordinator) === downloadCoordinator)

    let playback = try Self.liveCollaborator(named: "playback", of: coordinator)
    #expect(playback is StreamConfiguringPlaybackSyncing)
  }

  /// The removal-only graph has no live playback, transfer engine, sync shutdown or drain. The
  /// coordinator's optional collaborators are how that absence is observable.
  @Test("pending removal composes the coordinator with no live collaborators")
  func pendingRemovalCoordinatorHasNoLiveGraph() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let journal = AccountRemovalJournalStore(database: database)
    try journal.clear()
    defer { try? journal.clear() }
    try journal.create(
      AccountRemovalJournalRecord(
        serverBaseURL: "https://pending-live-graph.invalid",
        serverUserId: "pending-live-graph-user",
        accountRowId: 1,
        downloadsRootRelativePath: "Downloads",
        createdAt: Date()))

    let environment = Self.environment(
      hardware: hardware, mode: .automatic, database: database)
    let coordinator = try Self.removalCoordinator(in: environment)

    // `Optional`'s `Mirror` reflects `nil` as no children and `.some(x)` as one.
    for label in ["playback", "downloadCoordinator"] {
      let child = try #require(
        Mirror(reflecting: coordinator).children.first { $0.label == label }?.value)
      #expect(Mirror(reflecting: child).children.isEmpty, "\(label) must stay inert")
    }
  }

  /// An endpoint switch rebuilds without any removal, so the old sync graph must still shut down
  /// first.
  @Test("retiring an environment shuts down its sync engine; a setup environment has none")
  func retiringAnEnvironmentShutsDownItsSyncEngine() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "retire-sync-composition",
        serverBaseURL: "https://retire-sync-composition.invalid",
        serverUserId: "retire-sync-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "retire-sync-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let engine = try #require(environment.dependencies.sync as? SyncEngine)
    #expect(Self.isShutDown(engine) == false)

    let shutdown = try #require(environment.shutDownSync())
    await shutdown.value

    #expect(Self.isShutDown(engine) == true)
    #expect(Self.environment(hardware: hardware, mode: .automatic).shutDownSync() == nil)
  }

  // MARK: - Podcast auto-download composition

  @Test("runtime composition wires the real PodcastSettingsStore, not the NoOp defaults")
  func podcastSettingsDependenciesAreRealConformances() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "podcast-settings-composition",
        serverBaseURL: "https://podcast-settings-composition.invalid",
        serverUserId: "podcast-settings-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "podcast-settings-library"))
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: database)

    #expect(environment.dependencies.podcastSettingsReading is PodcastSettingsStore)
    #expect(environment.dependencies.podcastSettingsWriting is PodcastSettingsStore)
    #expect((environment.dependencies.podcastSettingsReading is NoOpPodcastSettingsAccess) == false)
  }

  // MARK: - Podcast show ordering composition

  @Test("runtime composition wires the account-scoped DefaultPodcastShowOrdering, not the NoOp default")
  func podcastShowOrderingIsRealAccountScopedConformance() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "show-ordering-composition",
        serverBaseURL: "https://show-ordering-composition.invalid",
        serverUserId: "show-ordering-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "show-ordering-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)

    let ordering = environment.dependencies.podcastShowOrdering
    #expect(ordering is DefaultPodcastShowOrdering)
    #expect((ordering is NoOpPodcastShowOrdering) == false)
    // Scoped to this account. Order rows are account-owned, so a store built against the wrong id
    // would silently show another account's arrangement.
    let scopedAccountId = try #require(
      Mirror(reflecting: ordering).children.first(where: { $0.label == "accountId" })?.value as? Int64)
    #expect(scopedAccountId == account.id)
  }

  @Test("an unauthenticated launch keeps no-op ordering and opens no account-owned show observation")
  func setupOnlyCompositionLeavesShowOrderingInert() async {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware, mode: .automatic)

    #expect(environment.composition == .setup)
    #expect(environment.dependencies.podcastShowOrdering is NoOpPodcastShowOrdering)
    // No account exists before login, so the setup graph must not open a `ValueObservation` over
    // the account-owned order tables. The no-op's stream finishes immediately rather than emitting
    // a fabricated snapshot.
    var iterator = environment.dependencies.podcastShowOrdering.observeShows().makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  @Test("an unauthenticated launch never constructs the account-scoped auto-download observations")
  func setupOnlyCompositionLeavesAutoDownloadInert() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware, mode: .automatic)

    #expect(environment.composition == .setup)
    // The setup graph's `AppDependencies` init (`AppEnvironment.swift`) supplies none of
    // `podcastSettingsReading`, `podcastSettingsWriting` or `downloadIntents`. Each stays at its
    // `NoOp` default, which proves this path never reaches `PodcastSettingsStore` or
    // `PodcastBackgroundRefreshHardware.sharedServices`, the call that would construct the
    // account-scoped auto-download coordinator and reaper.
    #expect(environment.dependencies.podcastSettingsReading is NoOpPodcastSettingsAccess)
    #expect(environment.dependencies.podcastSettingsWriting is NoOpPodcastSettingsAccess)
    #expect(environment.dependencies.downloadIntents is NoOpDownloadIntents)
  }

  @Test(
    "a same-process background wake resolves the identical shared services, including connectivity"
  )
  func runtimeCompositionSharesDownloadAndAutoDownloadInstancesWithBackgroundWake() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "bg-share-client",
        serverBaseURL: "https://bg-share-composition.invalid",
        serverUserId: "bg-share-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "bg-share-library"))
    let accountId = try #require(account.id)

    // Mirrors `RootView`'s single construction point: an `AppEnvironment` is already alive, and the
    // background wake shares this process.
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    guard let downloadCoordinator = handDownloadCoordinator(environment)
    else {
      Issue.record("expected the production DownloadCoordinator conformance")
      return
    }

    // Simulates `PodcastBackgroundRefreshHardware.handle()` resolving the same server and account
    // key `AppEnvironment.init` used, which is a cache hit. Every field below is the identical
    // instance `environment` already uses internally (the SyncEngine trigger, `podcastShowRefresh`,
    // the `PlaybackSessionCoordinator` reap closure), not a second competing construction.
    let server = try ABSServerConfig(
      url: try #require(URL(string: "https://bg-share-composition.invalid")))
    let services = PodcastBackgroundRefreshHardware.sharedServices(
      key: AppEnvironment.sharedServicesKey(server: server, accountID: accountId),
      server: server,
      tokenAccount: try account.credentialTokenAccount,
      tokenStore: try KeychainTokenStore(),
      database: database,
      diagnostics: DiagnosticsStore(database: database),
      accountLifecycle: AccountLifecycleService(
        tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
        accountEndpointDAO: AccountEndpointDAO(database: database),
        accountRemover: AccountRemover(database: database)),
      appLifecycle: environment.dependencies.appLifecycle,
      networkConditions: NetworkConditionsReducer(path: RealPathObserving(), power: RealPowerObserving()),
      podcastSettingsReading: PodcastSettingsStore(database: database, accountId: accountId),
      accountId: accountId)

    #expect(services.downloadCoordinator === downloadCoordinator)
    #expect(services.podcastAutoDownload != nil)
    #expect(services.podcastAutoDownloadReaper != nil)
    let connectivityModel = try #require(environment.connectivityModel)
    #expect(services.connectivityModel === connectivityModel)

    // The observer passed to `ABSClient.production` is kept in this bundle for inspection. Its
    // forwarding path must reach the cached monitor the model projects. A second monitor would
    // leave this state at `.unknown`.
    await services.serverReachabilityObserver.reachabilityEvent(.responded)
    #expect(services.serverReachabilityMonitor.current == .reachable)

    // The monitor gates recovery probing on the foreground, and this bundle outlives every
    // `AppEnvironment` rebuilt over it. The scene adapter it was built with must be the one
    // `RootView` keeps driving, not a per-environment copy that goes silent after the first rebuild
    // or background wake.
    #expect(environment.dependencies.appLifecycle as AnyObject === AppEnvironment.sharedLifecycle)
  }

  @Test("a background-session or overnight-analysis wake joins the live environment's coordinator")
  func backgroundServicesResolveTheEnvironmentsDownloadCoordinator() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "bg-entry-client",
        serverBaseURL: "https://bg-entry-composition.invalid",
        serverUserId: "bg-entry-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "bg-entry-library"))
    let environment = Self.environment(hardware: hardware, mode: .runtime, database: database)
    let downloadCoordinator = try #require(
      handDownloadCoordinator(environment))

    // Built by hand rather than through `backgroundAccount()`, whose custom-header read fails in
    // the unsigned test host (`errSecMissingEntitlement`). The test covers the shared-cache join.
    let resolved = PodcastBackgroundRefreshHardware.BackgroundAccount(
      database: database, accountId: try #require(account.id),
      tokenAccount: try account.credentialTokenAccount,
      server: try ABSServerConfig(url: try #require(URL(string: account.serverBaseURL))),
      tokenStore: try KeychainTokenStore(), customHeaderStore: try KeychainCustomHeaderStore(),
      feedCredentialStore: try KeychainFeedCredentialStore())
    let services = PodcastBackgroundRefreshHardware.services(
      for: resolved,
      networkConditions: NetworkConditionsReducer(path: RealPathObserving(), power: RealPowerObserving()))

    #expect(services.downloadCoordinator === downloadCoordinator)
  }

  @Test("a background entry with no account composes nothing")
  func backgroundServicesWithoutAnAccountComposeNothing() throws {
    let database = try AppDatabase.inMemory()

    #expect(PodcastBackgroundRefreshHardware.backgroundServices(database: database) == nil)
  }

  @Test(
    "the cold-launch-safe background composition alone (no AppEnvironment) resolves a working auto-download coordinator/reaper and nothing beyond client/downloads/show-refresh"
  )
  func coldBackgroundLaunchStartsTheAutoDownloadPassAndNothingElse() throws {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "cold-launch-client",
        serverBaseURL: "https://cold-launch-composition.invalid",
        serverUserId: "cold-launch-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "cold-launch-library"))
    let accountId = try #require(account.id)
    let server = try ABSServerConfig(
      url: try #require(URL(string: "https://cold-launch-composition.invalid")))
    let key = AppEnvironment.sharedServicesKey(server: server, accountID: accountId)

    // Constructs no `AppEnvironment` or `RootComposition`. This mirrors
    // `PodcastBackgroundRefreshHardware.handle()`, which does not build an `AppEnvironment` and so
    // has no playback session recovery or item-progress coordinator.
    let appLifecycle = ScenePhaseAppLifecycle(
      backgroundTaskProviding: FakeBackgroundTaskProviding())
    func resolve() throws -> PodcastBackgroundRefreshHardware.SharedServices {
      PodcastBackgroundRefreshHardware.sharedServices(
        key: key,
        server: server,
        tokenAccount: try account.credentialTokenAccount,
        tokenStore: try KeychainTokenStore(),
        database: database,
        diagnostics: DiagnosticsStore(database: database),
        accountLifecycle: AccountLifecycleService(
          tokenStore: try KeychainTokenStore(), accountDAO: AccountDAO(database: database),
          accountEndpointDAO: AccountEndpointDAO(database: database),
          accountRemover: AccountRemover(database: database)),
        appLifecycle: appLifecycle,
        networkConditions: NetworkConditionsReducer(
          path: RealPathObserving(), power: RealPowerObserving()),
        podcastSettingsReading: PodcastSettingsStore(database: database, accountId: accountId),
        accountId: accountId,
        applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
          "whirr-cold-launch-\(UUID().uuidString)", isDirectory: true))
    }

    let services = try resolve()
    #expect(services.podcastAutoDownload != nil)
    #expect(services.podcastAutoDownloadReaper != nil)

    // A second, overlapping cold wake under the same key never builds a competing
    // `DownloadCoordinator`. It joins the one already cached.
    let again = try resolve()
    #expect(again.downloadCoordinator === services.downloadCoordinator)
    #expect(again.podcastAutoDownload === services.podcastAutoDownload)
  }

  // MARK: - Playback origin routing

  @Test("runtime composition routes playback between server and device-owned coordinators")
  func playbackSyncingRoutesByOrigin() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "playback-routing-composition",
        serverBaseURL: "https://playback-routing.invalid",
        serverUserId: "playback-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "playback-library"))
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: database)

    #expect(environment.dependencies.playbackSync is StreamConfiguringPlaybackSyncing)
    let routed = try #require(
      Mirror(reflecting: environment.dependencies.playbackSync).children
        .first(where: { $0.label == "underlying" })?.value)
    #expect(routed is RoutingPlaybackSyncing)

    let legs = Mirror(reflecting: routed).children
    #expect(legs.first { $0.label == "absSyncing" }?.value is PlaybackSessionCoordinator)
    #expect(legs.first { $0.label == "rssSyncing" }?.value is RSSPlaybackCoordinator)
  }

  @Test("the playback composition's run model uses the environment's SmartListServices")
  func playbackRunModelUsesTheEnvironmentSmartListServices() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: try Self.authenticatedDatabase())

    // Only the full instance the environment builds supplies the run observation and the save-time
    // expansion; a bare `SmartListServices(database:subscriptions:accountIdentity:)` leaves them
    // at their no-op defaults.
    let services = try #require(environment.smartListServices)
    #expect(services.observeActiveRunListID != nil)

    // `@Observable` stores the property as `_services`; read either spelling so the assertion is
    // about the wiring, not the macro's storage detail.
    let runModel = try #require(environment.dependencies.smartListRun)
    let storedServices = Mirror(reflecting: runModel).children
      .first { $0.label == "services" || $0.label == "_services" }?.value
    let runServices = try #require(storedServices as? SmartListServices)
    #expect(runServices.observeActiveRunListID != nil)
  }

  /// Finishing a device-owned episode must reap device-owned auto-downloads. The account-owned
  /// reaper only sees server rows, so wiring it here would leave RSS retention to the next feed
  /// refresh.
  @Test("finishing an RSS episode reaps RSS auto-downloads")
  func rssPlaybackFinishReapsRSSAutoDownloads() async throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "rss-finish-reap",
        serverBaseURL: "https://rss-finish-reap.invalid",
        serverUserId: "rss-finish-reap-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "rss-finish-reap-library"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-composition-\(UUID().uuidString)", isDirectory: true)
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: database,
      applicationSupportDirectory: directory)

    try await NativePodcastSettingsStore(database: database).setGlobalDeleteAfterPlayed(true)
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: try #require(URL(string: "https://feeds.invalid/finish-reap.xml")), title: "Show",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "finished", guid: "finished", title: "Finished",
          enclosureURL: try #require(URL(string: "https://cdn.invalid/finished.mp3")),
          enclosureType: "audio/mpeg", declaredBytes: 100,
          publishedAt: Date(timeIntervalSince1970: 100), durationSeconds: 60)
      ])
    let episodeID = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
      })
    let downloads = try RSSDownloadStore(database: database)
    let claimed = try downloads.claimOrCreate(
      episodeId: episodeID, origin: .automatic, decidedStamp: Date(timeIntervalSince1970: 500))
    let downloadID = try #require(claimed.id)
    // A completed row needs its file. The launch integrity sweep demotes a completed row without
    // one to failed, and the reaper only claims completed rows.
    let file = directory.appendingPathComponent("Downloads", isDirectory: true)
      .appendingPathComponent(claimed.relativePath)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: 100).write(to: file)
    _ = try downloads.transition(downloadId: downloadID, to: .downloading)
    _ = try downloads.complete(downloadId: downloadID, actualBytes: 100)
    _ = try await RSSEpisodeStateStore(database: database).recordTick(
      episodeId: episodeID, position: 60, finished: true, capturedSequence: 0,
      now: Date(timeIntervalSince1970: 600))
    // Composition starts the launch integrity sweep detached, so under load it can land after the
    // seeding above. Running it here makes that ordering the only one this test sees.
    let downloadCoordinator = try #require(
      handDownloadCoordinator(environment))
    await downloadCoordinator.reconcileAfterLaunch()

    let routed = try #require(
      Mirror(reflecting: environment.dependencies.playbackSync).children
        .first(where: { $0.label == "underlying" })?.value)
    let rssCoordinator = try #require(
      Mirror(reflecting: routed).children.first { $0.label == "rssSyncing" }?.value
        as? RSSPlaybackCoordinator)
    let reap = try #require(
      Mirror(reflecting: rssCoordinator).children
        .first { $0.label == "requestPodcastAutoDownloadReap" }?.value
        // Core's closure type. This target's approachable concurrency would otherwise spell it
        // `nonisolated(nonsending)` and fail to match.
        as? @concurrent @Sendable () async -> Void)

    await reap()

    #expect(try downloads.fetch(episodeId: episodeID) == nil)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
  }

  // MARK: - Search

  @Test("runtime composition wires the real cross-library search, recents, and author/series reading")
  func searchDependenciesAreRealConformances() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "search-composition",
        serverBaseURL: "https://search-composition.invalid",
        serverUserId: "search-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "search-library"))
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: database)

    #expect(environment.dependencies.searchReading is DefaultSearchReading)
    #expect(environment.dependencies.recentSearchStore is RecentSearchStore)
    #expect(environment.dependencies.authorSeriesReading is AuthorSeriesService)
    #expect((environment.dependencies.searchReading is NoOpSearchReading) == false)
    #expect((environment.dependencies.recentSearchStore is NoOpRecentSearchStoring) == false)
    #expect((environment.dependencies.authorSeriesReading is NoOpAuthorSeriesReading) == false)
  }

  @Test("rebuilding AppEnvironment never creates a second background-download session/adapter")
  func appEnvironmentRebuildReusesSharedBackgroundDownloadAdapter() {
    // Touch the adapter first, as either wake route does in production, before any `AppEnvironment`
    // exists. This proves construction never replaces it.
    let adapterBefore = ObjectIdentifier(BackgroundDownloadHardware.adapter)
    let sessionIdentifierBefore = BackgroundDownloadHardware.adapter.sessionIdentifier

    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let first = Self.environment(hardware: hardware)
    let second = Self.environment(hardware: hardware)

    #expect(ObjectIdentifier(BackgroundDownloadHardware.adapter) == adapterBefore)
    #expect(BackgroundDownloadHardware.adapter.sessionIdentifier == sessionIdentifierBefore)
    #expect(handDownloadCoordinator(first) != nil)
    #expect(handDownloadCoordinator(second) != nil)
  }

  @Test("a rebuilt environment becomes foreground when seeded with the current scene phase")
  func rebuiltEnvironmentCanBeSeededFromCurrentScenePhase() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let environment = Self.environment(
      hardware: hardware, mode: .runtime, database: database)

    // Seed the starting state rather than assume it. The lifecycle is one object per process,
    // shared by every rebuilt environment, so whether it is foreground here depends on what ran
    // earlier. The test checks that a rebuilt environment picks up the phase, not what it
    // inherited.
    environment.handleScenePhase(.background)
    #expect(environment.dependencies.appLifecycle.isForeground == false)

    environment.handleScenePhase(.active)

    #expect(environment.dependencies.appLifecycle.isForeground)
  }

  /// One per process, threaded through every rebuild, as `PlaybackHardware` does.
  /// `RootView.rebuildAfterAuthentication` runs on the main thread the instant login succeeds. A
  /// per-environment `AppDatabase` would open a second `DatabasePool` on the same file, re-run
  /// migrations, and contend with the outgoing environment's open pool (`busyMode = .timeout(5)`
  /// blocks rather than failing fast) in the first-launch window.
  @Test("every environment rebuild shares the process's one database rather than opening a second pool")
  func environmentRebuildSharesOneDatabase() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try AppDatabase.inMemory()
    let first = Self.environment(
      hardware: hardware, mode: .automatic, database: database)
    let second = Self.environment(
      hardware: hardware, mode: .runtime, database: database)

    let firstDatabase = try #require(
      Mirror(reflecting: first).children.first(where: { $0.label == "database" })?.value as? AppDatabase)
    let secondDatabase = try #require(
      Mirror(reflecting: second).children.first(where: { $0.label == "database" })?.value as? AppDatabase)

    #expect(firstDatabase === secondDatabase)
  }

  @Test(
    "AccountLifecycleService composes a real, non-nil AccountRemovalCoordinator so logout resolves to the full removal sequence"
  )
  func accountLifecycleComposesRemovalCoordinator() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let environment = Self.environment(hardware: hardware)

    guard let service = environment.dependencies.account as? AccountLifecycleService else {
      Issue.record("expected the production AccountLifecycleService conformance")
      return
    }

    guard
      let removalCoordinatorChild = Mirror(reflecting: service).children.first(where: {
        $0.label == "removalCoordinator"
      })
    else {
      Issue.record("AccountLifecycleService no longer stores a removalCoordinator property")
      return
    }

    // `Optional`'s `Mirror` reflects `.some(x)` as one child and `nil` as none. This separates the
    // composed `AccountRemovalCoordinator` from the older default (`removalCoordinator: nil`),
    // which sent `logout()` down the inline database-only path instead of the full removal
    // sequence.
    #expect(Mirror(reflecting: removalCoordinatorChild.value).children.count == 1)
  }

  /// The proxy-header Keychain read can fail while the account row is readable
  /// (`AfterFirstUnlockThisDeviceOnly` before first unlock; `errSecMissingEntitlement` on an
  /// unsigned host). That must cost only the headers: demoting to the unconfigured literal would
  /// point the client, artwork scope and downloads at the wrong server, key `sharedServices` on
  /// it, and let a later rebuild compose a second `DownloadCoordinator`.
  @Test("an unreadable header Keychain costs the headers, not the account's own server")
  func headerStoreFailureKeepsTheAccountServer() {
    let account = AccountRecord(
      clientUUID: "header-store-failure",
      serverBaseURL: "https://header-store-failure.invalid",
      serverUserId: "header-store-failure-user",
      serverVersion: "2.35.1",
      defaultLibraryId: "header-store-failure-library")

    let config = AppEnvironment.serverConfig(
      for: account, factory: ABSServerConfigFactory(customHeaderStore: FailingCustomHeaderStore()))

    #expect(config.baseURL.absoluteString == "https://header-store-failure.invalid")
    #expect(config.customHeaders == .none)
  }

  /// Every downloads-root site — the ABS and RSS file stores, account removal and ad-skip's
  /// local-episode reader — must derive the same root from the same injected Application Support
  /// directory.
  @Test("ad-skip's episode reader resolves the shared downloads root from the injected seam")
  func adSkipReaderUsesTheInjectedApplicationSupportDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-downloads-root-\(UUID().uuidString)", isDirectory: true)
    let database = try AppDatabase.inMemory()

    let reader = AdSkipComposition.makeLocalEpisodeReader(
      database: database, applicationSupportDirectory: directory)

    #expect(
      reader.downloadsRootURL == DownloadLocations.root(applicationSupportDirectory: directory))
    #expect(
      reader.downloadsRootURL == directory.appendingPathComponent("Downloads", isDirectory: true))
  }

  private static func removalCoordinator(
    in environment: AppEnvironment
  ) throws -> AccountRemovalCoordinator {
    let service = try #require(environment.dependencies.account as? AccountLifecycleService)
    // An `Optional` reflects `.some(x)` as one child holding `x`.
    let stored = try #require(
      Mirror(reflecting: service).children.first(where: { $0.label == "removalCoordinator" })?.value)
    return try #require(Mirror(reflecting: stored).children.first?.value as? AccountRemovalCoordinator)
  }

  /// One of the coordinator's stored optional collaborators, unwrapped out of its `Optional`.
  private static func liveCollaborator(
    named label: String, of coordinator: AccountRemovalCoordinator
  ) throws -> Any {
    let child = try #require(
      Mirror(reflecting: coordinator).children.first { $0.label == label }?.value)
    return try #require(Mirror(reflecting: child).children.first?.value)
  }

  /// `SyncEngine` exposes no shutdown state, so the stored flag is read once the engine is
  /// quiescent.
  private static func isShutDown(_ engine: SyncEngine) -> Bool? {
    Mirror(reflecting: engine).children.first { $0.label == "isShutdown" }?.value as? Bool
  }

  private static func authenticatedDatabase() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "app-environment-composition",
        serverBaseURL: "https://app-environment-composition.invalid",
        serverUserId: "app-environment-composition-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "app-environment-composition-library"))
    return database
  }

  private static func environment(
    hardware: PlaybackHardware,
    mode: AppEnvironment.Mode = .runtime,
    database: AppDatabase? = nil,
    applicationSupportDirectory: URL? = nil
  ) -> AppEnvironment {
    let database = database ?? (try! AppDatabase.inMemory())
    let directory =
      applicationSupportDirectory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "whirr-composition-\(UUID().uuidString)", isDirectory: true)
    return AppEnvironment(
      hardware: hardware,
      mode: mode,
      database: database,
      applicationSupportDirectory: directory)
  }
}

/// Test double for `CustomHeaderStoring` whose reads fail the way `KeychainCustomHeaderStore`'s do
/// when the item is unreadable (locked before first unlock, or an unsigned host).
/// `AppEnvironment.serverConfig(for:factory:)` must survive that without losing the account's
/// server.
private struct FailingCustomHeaderStore: CustomHeaderStoring {
  struct Failure: Error {}

  func save(_ headers: CustomHeaders, for serverURL: URL) throws { throw Failure() }
  func load(for serverURL: URL) throws -> CustomHeaders? { throw Failure() }
  func clear(for serverURL: URL) throws { throw Failure() }
}

/// The coordinator behind the app's download intents. With an account they are the Up Next
/// declining wrapper over the smart-list one over the pinned-list one; without one, the smart-list
/// wrapper over the coordinator itself. So a hand removal is recorded before it reaches the
/// coordinator.
@MainActor
func handDownloadCoordinator(_ environment: AppEnvironment) -> DownloadCoordinator? {
  var intents = environment.dependencies.downloadIntents
  if let upNext = intents as? UpNextDecliningDownloadIntents { intents = upNext.wrapped }
  if let smart = intents as? SmartListDecliningDownloadIntents { intents = smart.wrapped }
  if let declining = intents as? PinnedListDecliningDownloadIntents {
    return declining.wrapped as? DownloadCoordinator
  }
  return intents as? DownloadCoordinator
}
