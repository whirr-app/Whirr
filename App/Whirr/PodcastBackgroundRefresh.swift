import ABSApi
import AppModel
import BackgroundTasks
import Foundation
import Persistence
import SyncEngine

enum PodcastBackgroundRefreshHardware {
  static let identifier = "com.remoteconcern.whirr.podcast-refresh"
  static let nextRequestDelay: TimeInterval = 4 * 60 * 60

  @MainActor static var cachedServices: (key: String, value: SharedServices)?

  enum RefreshRequestAction: Equatable {
    case submit
    case cancel
  }

  /// With no database (a wake before the first unlock) the request is kept: an earlier process
  /// only submitted it while signed in, and cancelling here would end the wake chain until the
  /// app next leaves the foreground. The next wake checks the account again.
  static func refreshRequestAction(database: AppDatabase?) -> RefreshRequestAction {
    guard let database else { return .submit }
    let removalPending =
      ((try? AccountRemovalJournalStore(database: database).fetch()) ?? nil) != nil
    guard !removalPending, (try? AccountDAO(database: database).fetch()) != nil else { return .cancel }
    return .submit
  }

  /// Best-effort system scheduling. BGTaskScheduler chooses the actual execution time.
  @MainActor
  static func scheduleIfAuthenticated() {
    guard refreshRequestAction(database: DatabaseHardware.sharedIfAvailable()) == .submit else {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
      return
    }
    let request = BGAppRefreshTaskRequest(identifier: identifier)
    request.earliestBeginDate = Date().addingTimeInterval(nextRequestDelay)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Unavailable/not-permitted/too-many-pending are opportunistic scheduler outcomes. The
      // foreground and explicit paths remain the correctness mechanism.
    }
  }

  @MainActor
  static func cancelScheduledRefresh() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    cachedServices = nil
  }

  /// The signed-in account and its keychain stores, resolved for a background entry: the refresh
  /// task, a background-session wake, or the overnight ad-analysis task. `nil` whenever there is
  /// nothing to compose for: removal pending, no account, or the database or keychain unreadable
  /// (before first unlock).
  struct BackgroundAccount {
    let database: AppDatabase
    let accountId: Int64
    let tokenAccount: TokenAccount
    let server: ABSServerConfig
    let tokenStore: KeychainTokenStore
    let customHeaderStore: KeychainCustomHeaderStore
    let feedCredentialStore: KeychainFeedCredentialStore
  }

  @MainActor
  static func backgroundAccount(
    database: AppDatabase? = DatabaseHardware.sharedIfAvailable()
  ) -> BackgroundAccount? {
    guard
      let database,
      ((try? AccountRemovalJournalStore(database: database).fetch()) ?? nil) == nil,
      let account = try? AccountDAO(database: database).fetch(),
      let url = URL(string: account.serverBaseURL),
      let customHeaderStore = try? KeychainCustomHeaderStore(),
      let server = try? ABSServerConfigFactory(customHeaderStore: customHeaderStore).make(for: url),
      let tokenStore = try? KeychainTokenStore(),
      let feedCredentialStore = try? KeychainFeedCredentialStore()
    else { return nil }
    // A background wake can be the first process entry after the v63 migration.
    _ = CredentialNamespaceMigration.run(
      accountDAO: AccountDAO(database: database), tokenStore: tokenStore)
    guard
      let accountId = account.id,
      let tokenAccount = try? account.credentialTokenAccount
    else { return nil }
    return BackgroundAccount(
      database: database, accountId: accountId, tokenAccount: tokenAccount, server: server,
      tokenStore: tokenStore, customHeaderStore: customHeaderStore,
      feedCredentialStore: feedCredentialStore)
  }

  /// The process's shared services for `resolved`, through the same server+account cache
  /// `AppEnvironment` uses, so every entry route joins one `DownloadCoordinator`. Composing
  /// constructs both download stores and starts the coordinator's launch reconcile.
  @MainActor
  static func services(
    for resolved: BackgroundAccount, networkConditions: any NetworkConditions,
    applicationSupportDirectory: URL? = nil
  ) -> SharedServices {
    let database = resolved.database
    let accountLifecycle = AccountLifecycleService(
      tokenStore: resolved.tokenStore,
      accountDAO: AccountDAO(database: database),
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: AccountRemover(database: database),
      customHeaderStore: resolved.customHeaderStore)
    return sharedServices(
      key: AppEnvironment.sharedServicesKey(server: resolved.server, accountID: resolved.accountId),
      server: resolved.server,
      tokenAccount: resolved.tokenAccount,
      tokenStore: resolved.tokenStore,
      customHeaderStore: resolved.customHeaderStore,
      feedCredentialStore: resolved.feedCredentialStore,
      database: database,
      diagnostics: DiagnosticsStore(database: database),
      accountLifecycle: accountLifecycle,
      appLifecycle: AppEnvironment.sharedLifecycle,
      networkConditions: networkConditions,
      podcastSettingsReading: PodcastSettingsStore(database: database, accountId: resolved.accountId),
      nativePodcastSubscriptions: NativePodcastSubscriptionsPreference(defaults: UserDefaults.standard),
      notificationIntent: PodcastNotificationPreference(defaults: UserDefaults.standard),
      notificationScheduler: PodcastLocalNotificationCenter.shared,
      accountId: resolved.accountId,
      applicationSupportDirectory: applicationSupportDirectory)
  }

  /// Composes the shared services for a background entry that records transfer outcomes rather
  /// than spending data: no network guard, because a transfer the system has already completed
  /// must be recorded whatever the current path. Download preferences still decide whether new
  /// transfers start.
  @MainActor
  static func backgroundServices(
    database: AppDatabase? = DatabaseHardware.sharedIfAvailable(),
    networkConditions: (any NetworkConditions)? = nil
  ) -> SharedServices? {
    guard let resolved = backgroundAccount(database: database) else { return nil }
    return services(
      for: resolved,
      networkConditions: networkConditions
        ?? NetworkConditionsReducer(path: RealPathObserving(), power: RealPowerObserving()))
  }

  /// The app-refresh task's body: ask for the next wake, then refresh within its ~30 s budget.
  static func handle() async {
    await MainActor.run { scheduleIfAuthenticated() }
    await refreshFollowedShows(rssTrigger: .background, timeLimit: backgroundPassTimeLimit)
  }

  /// One refresh of followed ABS and native RSS shows, planning their auto-downloads. Shared by
  /// the app-refresh task and the overnight ad-analysis task, which differ only in the RSS budget
  /// and whole-pass limit. Cold-launch-safe: builds only account/token/API, persistence, network
  /// gate and podcast refresh/download services, not `AppEnvironment`, and resolves through the
  /// `sharedServices` cache to the same coordinators a live `AppEnvironment` uses, so a warm
  /// background wake (suspended, not evicted) joins that work.
  static func refreshFollowedShows(rssTrigger: RSSFeedRefreshTrigger, timeLimit: Duration) async {
    guard let resolved = backgroundAccount() else { return }
    // A cold background launch has no path until the monitor's first update, and the reducer
    // snapshots it on construction. With no reported path the guard below would read "not
    // cellular", so a pass that cannot learn its path within the wait does not run.
    let path = RealPathObserving()
    guard let firstPath = await path.firstPath(within: firstPathWait), firstPath.isSatisfied else { return }
    let network = NetworkConditionsReducer(path: path, power: RealPowerObserving())
    // A system-scheduled wake never spends the user's cellular data or fights low power mode. Kept
    // at the call site because the shelf refresh is also used interactively and must not silently
    // skip in those conditions. Checked before composing, so such a wake constructs nothing.
    guard network.isLowPowerMode == false, network.isConstrainedOrCellular == false else { return }

    let database = resolved.database
    let accountId = resolved.accountId
    let tokenAccount = resolved.tokenAccount
    let services = services(for: resolved, networkConditions: network)

    // A background wake is still allowed to perform the small account-wide discovery request.
    // Reconcile it before selecting podcast libraries so a server-side addition uses the same
    // `all`/`selected` policy as foreground refresh, and a returned tombstone revives with its
    // saved inclusion flag. A failed discovery leaves the last reconciled selection intact; this
    // opportunistic pass can still refresh its already-known included podcasts.
    let selectionStore = LibrarySelectionStore(database: database)
    let libraryDiscovery = LibrarySelectionDiscoveryService(
      database: database,
      selectionReading: selectionStore,
      clientFactory: { _ in services.client })
    // One request per podcast library and a single commit, comfortably inside a
    // `BGAppRefreshTask`'s budget.
    let recentEpisodes = RecentEpisodeRefreshCoordinator(
      database: database, client: services.client)
    let smartListExpansion = SmartListShowExpansion(
      database: database, client: services.client, showRefresh: services.showRefresh)
    let pass = Task {
      await runBackgroundPass(
        shelfRefresh: {
          await refreshLibraryDiscovery(libraryDiscovery)
          let podcastLibraryIDs =
            ((try? LibraryDAO(database: database).fetchIncluded(accountId: accountId)) ?? [])
            .filter { $0.mediaType == "podcast" }
            .map(\.serverLibraryId)
          guard podcastLibraryIDs.isEmpty == false else {
            return RecentEpisodeRefreshResult(writtenCount: 0, failedLibraryIDs: [])
          }
          return try await recentEpisodes.refresh(
            account: tokenAccount, accountId: accountId, podcastLibraryIDs: podcastLibraryIDs)
        },
        podcastAutoDownload: services.podcastAutoDownload,
        podcastAutoDownloadReaper: services.podcastAutoDownloadReaper,
        rssFeedRefreshCoordinator: services.rssFeedRefreshCoordinator,
        rssTrigger: rssTrigger,
        smartListShowExpansion: { _ = await smartListExpansion.expandDueShows() },
        smartListDownloads: { [reconciler = services.smartListDownloadReconciler] in
          await reconciler.run()
        },
        timeLimit: timeLimit)
    }
    await withTaskCancellationHandler {
      _ = await pass.value
    } onCancel: {
      pass.cancel()
    }
  }

  /// The testable core of the `BGAppRefreshTask` body: commit the shelf, then one background
  /// auto-download pass and reap. Enqueue only; it never awaits a transfer
  /// (`PodcastAutoDownloadCoordinator.run` awaits only the selection query and planning boundary).
  /// The deadline supplements the system's cancellation and covers the whole pass.
  nonisolated static let backgroundPassTimeLimit: Duration = .seconds(25)
  /// The overnight ad-analysis task's limit: a processing task has minutes, and what the refresh
  /// does not use goes to transcription.
  nonisolated static let overnightPassTimeLimit: Duration = .seconds(120)
  /// How long a background entry waits for the path monitor's first update. Spent before the
  /// pass limit starts, so it must leave the app-refresh task's ~30 s budget room for both.
  nonisolated static let firstPathWait: Duration = .seconds(2)

  static func runBackgroundPass(
    shelfRefresh: @escaping @Sendable () async throws -> RecentEpisodeRefreshResult,
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    rssFeedRefreshCoordinator: any RSSFeedRefreshCoordinating =
      NoOpRSSFeedRefreshCoordinator(),
    rssTrigger: RSSFeedRefreshTrigger = .background,
    smartListShowExpansion: (@Sendable () async -> Void)? = nil,
    smartListDownloads: (@Sendable () async -> Void)? = nil,
    timeLimit: Duration = backgroundPassTimeLimit
  ) async {
    await withTaskCancellationHandler {
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            guard Task.isCancelled == false else { return }
            if (try? await shelfRefresh())?.commitOutcome == .committed,
              Task.isCancelled == false
            {
              await podcastAutoDownload?.run()
              guard Task.isCancelled == false else { return }
              await podcastAutoDownloadReaper?.reap()
            }
            guard Task.isCancelled == false else { return }
            _ = await rssFeedRefreshCoordinator.run(rssTrigger)
            // Smart-list show expansion: a cancellable stage with no timer of its own, run after
            // the podcast surfaces and not gated on whether the shelf committed. It stops with
            // the pass (deadline or system cancellation) and keeps what it has committed.
            guard Task.isCancelled == false else { return }
            await smartListShowExpansion?()
            // After expansion, so a show the pass just opened up is in the wanted set. Enqueue
            // only, like the stages above.
            guard Task.isCancelled == false else { return }
            await smartListDownloads?()
          }
          group.addTask {
            try await Task.sleep(for: timeLimit)
            await podcastAutoDownload?.cancel()
            await podcastAutoDownloadReaper?.cancel()
            await rssFeedRefreshCoordinator.cancel(rssTrigger)
            throw BackgroundPassDeadline()
          }
          _ = try await group.next()
          group.cancelAll()
        }
      } catch {
        // A failed/rolled-back commit, cancellation, or expired whole-pass budget never triggers
        // selection or reaping after the shelf stage.
      }
    } onCancel: {
      Task {
        await podcastAutoDownload?.cancel()
        await podcastAutoDownloadReaper?.cancel()
        await rssFeedRefreshCoordinator.cancel(rssTrigger)
      }
    }
  }

  private struct BackgroundPassDeadline: Error {}

  /// Kept as a small test seam because `handle()` resolves process services directly. The
  /// concrete discovery service owns policy reconciliation; a transient discovery failure is
  /// non-fatal for an opportunistic background shelf pass using the last known selection.
  static func refreshLibraryDiscovery(_ discovery: any LibrarySelectionDiscovering) async {
    _ = try? await discovery.discoverAccessibleLibraries()
  }
}
