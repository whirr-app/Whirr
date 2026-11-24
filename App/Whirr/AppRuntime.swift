import AppModel
import Observation
import Persistence

/// The process's one owner of the current `RootComposition`.
///
/// The phone scene, an App Intent, a Watch wake and a CarPlay scene can each be first to need the
/// graph; one held in a scene's `@State` is invisible to the others and stale after a rebuild. All
/// read this, and login/endpoint switch and logout replace the graph here. Constructing composes
/// nothing: the first `composition` read builds the launch graph, so `RootView` reconstruction in
/// the render loop costs a reference load.
@MainActor
@Observable
final class AppRuntime {
  static let shared = AppRuntime()

  /// Counts replacements of the graph, not its first composition: the launch graph is built
  /// lazily from whichever reader comes first, possibly a view body, and that must not publish
  /// an observable change. A reader that tracks `composition` is invalidated through this.
  private(set) var generation = 0

  enum Readiness: Equatable {
    /// No entry point has asked for the graph yet.
    case starting
    /// Before the first unlock since boot; `start()` retries when protected data returns.
    case storageUnavailable
    case failed(AppBootstrap.Failure)
    case ready
  }

  /// Whether a graph exists, and if not, why. A scene presents this rather than assuming the
  /// store opened; nothing is composed in any state but `.ready`.
  private(set) var readiness = Readiness.starting

  typealias MakeComposition =
    @MainActor (AppEnvironment.Mode, AppDatabase, AccountLaunchState?) -> RootComposition

  @ObservationIgnored private var stored: RootComposition?
  /// The store the bootstrap opened; every graph of the process is composed against it.
  @ObservationIgnored private var database: AppDatabase?
  @ObservationIgnored private let bootstrap: @MainActor () -> AppBootstrap.Outcome
  @ObservationIgnored private let makeComposition: MakeComposition
  @ObservationIgnored private let storageWakeUps: @MainActor () -> AsyncStream<Void>
  @ObservationIgnored private var storageRetry: Task<Void, Never>?
  @ObservationIgnored private let clearNotificationRoutes: @MainActor () -> Void
  @ObservationIgnored private var launchTask: Task<Void, Never>?
  @ObservationIgnored private var carPlayActionsCache: CarPlayPlaybackActions?
  @ObservationIgnored private var carPlayBrowseCache: CarPlayBrowseModel?
  @ObservationIgnored private let makeEndpointTriggers: @MainActor (AppRuntime) -> EndpointSwitchTriggers

  /// Re-selects the server address for whichever graph is current; started with the runtime.
  @ObservationIgnored private(set) lazy var endpointTriggers = makeEndpointTriggers(self)

  init(
    bootstrap: @escaping @MainActor () -> AppBootstrap.Outcome = { AppBootstrap.production() },
    makeComposition: @escaping MakeComposition = {
      RootComposition(hardware: .shared, mode: $0, database: $1, accountState: $2)
    },
    storageWakeUps: @escaping @MainActor () -> AsyncStream<Void> = { ProtectedDataWakeUp.stream() },
    clearNotificationRoutes: @escaping @MainActor () -> Void = {
      PodcastNotificationRouteMailbox.shared.clear()
    },
    makeEndpointTriggers: @escaping @MainActor (AppRuntime) -> EndpointSwitchTriggers = {
      .production(for: $0)
    }
  ) {
    self.bootstrap = bootstrap
    self.makeComposition = makeComposition
    self.storageWakeUps = storageWakeUps
    self.clearNotificationRoutes = clearNotificationRoutes
    self.makeEndpointTriggers = makeEndpointTriggers
  }

  /// The current graph without composing one; nil until some entry point has started the runtime.
  var current: RootComposition? {
    _ = generation
    return stored
  }

  /// The current graph, for a reader that exists only once the runtime is ready: the phone's
  /// `RootView` sits behind a readiness gate, and the account boundaries below replace a graph
  /// that already exists. Every other entry point uses `prepare()` or `start()`.
  var composition: RootComposition {
    _ = generation
    guard let graph = prepare() else {
      preconditionFailure("AppRuntime.composition read while \(readiness); use prepare()")
    }
    return graph
  }

  /// Composes the launch graph on first use and returns it, or nil while the store cannot be used.
  /// `.automatic` picks setup-only with no account or removal to resume, removal-only for a pending
  /// removal; login replaces setup with `.runtime`. Safe from a view body: the graph is stored
  /// without publishing (see `generation`).
  @discardableResult
  func prepare() -> RootComposition? {
    if let stored { return stored }
    switch launchSpan("bootstrap", { bootstrap() }) {
    case .storageUnavailable:
      setReadiness(.storageUnavailable)
      return nil
    case .failed(let failure):
      setReadiness(.failed(failure))
      return nil
    case .ready(let launch):
      database = launch.database
      let graph = launchSpan("composition") {
        makeComposition(.automatic, launch.database, launch.accountState)
      }
      stored = graph
      setReadiness(.ready)
      return graph
    }
  }

  private func setReadiness(_ next: Readiness) {
    if readiness != next { readiness = next }
  }

  /// Runs the launch sequence once per process, whichever entry point asks first: the phone
  /// scene, or one that has no view to hang a `.task` on. Later callers get the same task. Nil
  /// while the store cannot be used, having started nothing; before the first unlock it then
  /// starts by itself when protected data becomes available.
  @discardableResult
  func start() -> Task<Void, Never>? {
    if let launchTask { return launchTask }
    guard prepare() != nil else {
      if readiness == .storageUnavailable { retryWhenStorageWakes() }
      return nil
    }
    storageRetry?.cancel()
    storageRetry = nil
    endpointTriggers.start()
    let task = Task { await runLaunchSequence() }
    launchTask = task
    return task
  }

  private func retryWhenStorageWakes() {
    guard storageRetry == nil else { return }
    let wakeUps = storageWakeUps()
    storageRetry = Task { [weak self] in
      for await _ in wakeUps {
        guard let self, self.launchTask == nil else { return }
        if self.start() != nil { return }
      }
      self?.storageRetry = nil
    }
  }

  /// Each step reads the graph that is current when it runs: resuming a pending library
  /// selection can complete a login, which replaces the graph mid-sequence.
  private func runLaunchSequence() async {
    // Resume a removal that survived to this launch before anything else (including resolving
    // the library) runs against a possibly mid-removal account.
    let isRemovalOnlyComposition = composition.environment.composition == .removalPending
    launchMark("launchSequence.begin")
    await composition.root.resumePendingRemovalIfNeeded()
    if isRemovalOnlyComposition && composition.root.navigation.presentation == .setup {
      // A completed removal uses the same reset as a confirmed logout. The removal-only graph
      // must not become the post-removal setup graph's long-lived owner.
      resetAfterLogout()
      return
    }
    if composition.root.navigation.presentation == .setup {
      await composition.root.setupFlow.resumePendingLibrarySelection()
    }
    // The non-pulling variant: the first scene to become active gives the engine a
    // `.foreground`, and that is the traversal. See `RootModel.resolveLibraryAtColdLaunch()`.
    composition.root.resolveLibraryAtColdLaunch()
    launchMark("launchSequence.end")
  }

  /// `SyncEngine`/`CoverImageClient` bind to a server config at construction (ARCHITECTURE.md), so
  /// login or an endpoint switch replaces the graph with one on the same on-disk database.
  /// `keepingPreparedArtwork` is for the same account at another address (the artwork scope is
  /// address-independent); `keepingNavigation` for an unrequested same-account rebuild, which would
  /// otherwise drop the user on Home. Every graph reads the process-wide
  /// `AppEnvironment.sharedLifecycle`, which `SceneRegistry` alone feeds.
  func rebuild(keepingPreparedArtwork: Bool = false, keepingNavigation: Bool = false) {
    let outgoing = composition
    // Stop the outgoing engine and, at an account boundary, purge prepared artwork before
    // discarding the graph.
    outgoing.environment.shutDownSync()
    if keepingPreparedArtwork == false {
      outgoing.environment.purgePreparedArtwork()
    }
    let fresh = compose(.runtime)
    if keepingNavigation {
      fresh.root.navigation.adoptLocation(from: outgoing.root.navigation)
    }
    install(fresh)
    fresh.root.resolveLibraryIfAuthenticated()
  }

  /// A confirmed logout, or a removal that completed at launch: the outgoing graph's account
  /// state is reset and a setup graph replaces it. A notification route from the outgoing account
  /// must not reach the next one, whether or not a phone scene is attached to clear it.
  func resetAfterLogout() {
    let outgoing = composition
    // The sign-out has completed, so the previous account's Watch set can go now. `logoutPreflight`
    // is the protocol type, whose only requirement is the pre-logout hook; the account-removed
    // hook exists only on the App's composition.
    if let preflight = outgoing.logoutPreflight as? PlaybackLogoutPreflight {
      Task { await preflight.accountRemoved() }
    }
    clearNotificationRoutes()
    outgoing.root.resetForLogout()
    outgoing.environment.shutDownSync()
    outgoing.environment.purgePreparedArtwork()
    let fresh = compose(.automatic)
    install(fresh)
  }

  /// A replacement graph reads the account itself: a login or a removal has just changed it.
  private func compose(_ mode: AppEnvironment.Mode) -> RootComposition {
    guard let database else {
      preconditionFailure("AppRuntime replaced a graph before the bootstrap opened the store")
    }
    return makeComposition(mode, database, nil)
  }

  private func install(_ fresh: RootComposition) {
    stored = fresh
    carPlayActionsCache = nil
    carPlayBrowseCache = nil
    generation += 1
  }

  /// The car's commands for the current graph, or nil when there is no signed-in runtime graph
  /// to command. One facade per generation: it holds a lease on the generation it was made in
  /// and refuses every command once the graph has been replaced, so a car scene that kept an
  /// old one, or a row built before the replacement, cannot reach the new account's player.
  var carPlayActions: CarPlayPlaybackActions? {
    _ = generation
    if let carPlayActionsCache { return carPlayActionsCache }
    guard let stored, stored.environment.composition == .runtime else { return nil }
    let dependencies = stored.environment.dependencies
    let actions = CarPlayPlaybackActions(
      generation: generation,
      currentGeneration: { [weak self] in self?.generation ?? -1 },
      playback: stored.root.playback,
      player: dependencies.player,
      account: dependencies.account,
      bookmarkStore: dependencies.playbackBookmarkStoring)
    carPlayActionsCache = actions
    return actions
  }

  /// The car's lists for the current graph, on the same terms as `carPlayActions`: one model per
  /// generation, none without a signed-in runtime graph. The caller starts it.
  var carPlayBrowse: CarPlayBrowseModel? {
    _ = generation
    if let carPlayBrowseCache { return carPlayBrowseCache }
    guard let stored, stored.environment.composition == .runtime else { return nil }
    let dependencies = stored.environment.dependencies
    let model = CarPlayBrowseModel(
      generation: generation,
      currentGeneration: { [weak self] in self?.generation ?? -1 },
      home: dependencies.homeReading,
      nativeContinueListening: dependencies.nativeContinueListeningReading,
      nativeLatestEpisodes: dependencies.nativeLatestPodcastEpisodesReading,
      nativeSubscriptions: dependencies.nativePodcastSubscriptionsReading,
      sources: dependencies.carPlayBrowseSources)
    carPlayBrowseCache = model
    return model
  }
}
