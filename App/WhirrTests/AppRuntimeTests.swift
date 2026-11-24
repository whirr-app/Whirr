import AppModel
import Foundation
import Observation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// `AppRuntime` is the one owner of the current `RootComposition` for every entry point: the phone
/// scene, App Intents, the Watch and CarPlay. Each test injects a factory that builds the real
/// graph against an isolated in-memory store, a temporary storage root and a fake remote-command
/// centre, as `RootCompositionTests` does.
@MainActor
@Suite("App runtime", .serialized)
struct AppRuntimeTests {

  @Test("the launch graph is composed once, on first use, in automatic mode")
  func launchGraphIsComposedOnceOnFirstUse() {
    let factory = Factory()
    let runtime = factory.runtime()

    #expect(runtime.current == nil)
    #expect(factory.modes.isEmpty)

    let first = runtime.composition
    let second = runtime.composition

    #expect(first === second)
    #expect(runtime.current === first)
    #expect(factory.modes == [.automatic])
  }

  @Test("composing the launch graph publishes no observable change")
  func composingLaunchGraphPublishesNoChange() {
    let runtime = Factory().runtime()
    let changed = Flag()
    withObservationTracking {
      _ = runtime.current
    } onChange: {
      changed.set()
    }

    // The first reader can be a view body, so reading must not invalidate itself.
    _ = runtime.composition

    #expect(changed.isSet == false)
    #expect(runtime.generation == 0)
  }

  @Test("a headless entry before the first unlock composes nothing, and a later one starts")
  func headlessEntryWaitsForStorage() {
    let factory = Factory()
    let storage = Storage(isAvailable: false)
    let runtime = factory.runtime(bootstrap: { storage.isAvailable ? factory.ready() : .storageUnavailable })

    #expect(runtime.prepare() == nil)
    #expect(factory.modes.isEmpty)
    #expect(runtime.current == nil)

    storage.isAvailable = true
    let started = runtime.prepare()

    #expect(started != nil)
    #expect(started === runtime.current)
    #expect(factory.modes == [.automatic])
  }

  @Test("a headless entry returns the graph a scene already composed, whatever storage says")
  func headlessEntryReusesComposedGraph() {
    let factory = Factory()
    let storage = Storage(isAvailable: true)
    let runtime = factory.runtime(bootstrap: { storage.isAvailable ? factory.ready() : .storageUnavailable })
    let composed = runtime.composition

    storage.isAvailable = false

    #expect(runtime.prepare() === composed)
    #expect(factory.modes == [.automatic])
  }

  @Test("a rebuild replaces the graph with a runtime one and invalidates its readers")
  func rebuildReplacesGraph() {
    let factory = Factory()
    let runtime = factory.runtime()
    let launch = runtime.composition
    launch.root.navigation.section = .podcasts
    let changed = Flag()
    withObservationTracking {
      _ = runtime.composition
    } onChange: {
      changed.set()
    }

    runtime.rebuild()

    #expect(factory.modes == [.automatic, .runtime])
    #expect(runtime.composition !== launch)
    #expect(runtime.generation == 1)
    #expect(changed.isSet)
    // An account boundary starts the new graph on Home.
    #expect(runtime.composition.root.navigation.section == .home)
  }

  @Test("a rebuild that keeps navigation adopts the outgoing graph's location")
  func rebuildKeepingNavigationAdoptsLocation() {
    let runtime = Factory().runtime()
    runtime.composition.root.navigation.section = .podcasts

    runtime.rebuild(keepingPreparedArtwork: true, keepingNavigation: true)

    #expect(runtime.composition.root.navigation.section == .podcasts)
  }

  @Test("a logout resets the outgoing graph and replaces it with an automatic one")
  func logoutReplacesGraph() {
    let factory = Factory()
    let runtime = factory.runtime()
    let launch = runtime.composition
    launch.root.navigation.section = .podcasts

    runtime.resetAfterLogout()

    #expect(factory.modes == [.automatic, .automatic])
    #expect(runtime.composition !== launch)
    #expect(runtime.generation == 1)
    #expect(launch.root.navigation.section == .home)
  }

  @Test("starting runs the launch sequence once, however many entry points ask")
  func startIsSingleFlight() async {
    let factory = Factory()
    let runtime = factory.runtime()

    let first = runtime.start()
    let second = runtime.start()
    await first?.value

    #expect(first != nil)
    #expect(first == second)
    #expect(runtime.start() == first)
    #expect(factory.modes == [.automatic])
  }

  @Test("starting before storage is available composes nothing and can be retried")
  func startWaitsForStorage() async {
    let factory = Factory()
    let storage = Storage(isAvailable: false)
    let runtime = factory.runtime(bootstrap: { storage.isAvailable ? factory.ready() : .storageUnavailable })

    #expect(runtime.start() == nil)
    #expect(factory.modes.isEmpty)

    storage.isAvailable = true
    await runtime.start()?.value

    #expect(factory.modes == [.automatic])
  }

  @Test("readiness follows the bootstrap: starting, then ready once a graph exists")
  func readinessBecomesReady() {
    let runtime = Factory().runtime()
    #expect(runtime.readiness == .starting)

    #expect(runtime.prepare() != nil)

    #expect(runtime.readiness == .ready)
  }

  @Test("storage that cannot open yet is reported as unavailable, then ready after a retry")
  func readinessReportsUnavailableStorage() {
    let factory = Factory()
    let storage = Storage(isAvailable: false)
    let runtime = factory.runtime(bootstrap: { storage.isAvailable ? factory.ready() : .storageUnavailable })

    #expect(runtime.prepare() == nil)
    #expect(runtime.readiness == .storageUnavailable)

    storage.isAvailable = true
    #expect(runtime.prepare() != nil)
    #expect(runtime.readiness == .ready)
  }

  @Test("a failed bootstrap is a bounded error state that composes and starts nothing")
  func failedBootstrapComposesNothing() {
    let factory = Factory()
    let runtime = factory.runtime(bootstrap: { .failed(.accountUnreadable) })

    #expect(runtime.prepare() == nil)
    #expect(runtime.start() == nil)

    #expect(runtime.readiness == .failed(.accountUnreadable))
    #expect(factory.modes.isEmpty)
    #expect(runtime.current == nil)
  }

  @Test("a change of readiness invalidates its readers")
  func readinessChangeIsObservable() {
    let runtime = Factory().runtime()
    let changed = Flag()
    withObservationTracking {
      _ = runtime.readiness
    } onChange: {
      changed.set()
    }

    runtime.prepare()

    #expect(changed.isSet)
  }

  @Test("a start refused for storage runs once the storage wake-up fires")
  func startRetriesOnStorageWakeUp() async {
    let factory = Factory()
    let storage = Storage(isAvailable: false)
    let (wakeUps, wake) = AsyncStream.makeStream(of: Void.self)
    let runtime = factory.runtime(
      bootstrap: { storage.isAvailable ? factory.ready() : .storageUnavailable },
      storageWakeUps: { wakeUps })

    #expect(runtime.start() == nil)
    // A wake-up while the store still cannot open keeps waiting.
    wake.yield()
    await awaitQuiescence("runtime still waiting for storage") { "\(runtime.current == nil)|\(runtime.readiness)" }
    #expect(runtime.current == nil)

    storage.isAvailable = true
    wake.yield()
    await waitUntil("runtime opened after the wake-up") { runtime.current != nil }

    #expect(runtime.readiness == .ready)
    #expect(factory.modes == [.automatic])
    await runtime.start()?.value
    #expect(factory.modes == [.automatic])
  }

  @Test("the bootstrap's account state reaches the launch graph")
  func launchGraphUsesBootstrapAccountState() {
    let factory = Factory()
    let runtime = factory.runtime(bootstrap: {
      guard case .ready(let launch) = factory.ready() else { return .storageUnavailable }
      return .ready(
        .init(database: launch.database, accountState: .init(account: nil, removalIsPending: true)))
    })

    #expect(runtime.prepare()?.environment.composition == .removalPending)
  }

  @Test("the car has no commands until a signed-in runtime graph exists")
  func carPlayActionsNeedARuntimeGraph() {
    let runtime = Factory().runtime()
    #expect(runtime.carPlayActions == nil)

    // The launch graph of an empty store is the setup graph.
    runtime.prepare()
    #expect(runtime.carPlayActions == nil)

    runtime.rebuild()
    let actions = runtime.carPlayActions
    #expect(actions != nil)
    #expect(actions?.generation == runtime.generation)
    #expect(runtime.carPlayActions === actions)
  }

  @Test("replacing the graph leaves the outgoing car commands refusing everything")
  func replacedGraphRevokesCarPlayActions() async throws {
    let runtime = Factory().runtime()
    runtime.prepare()
    runtime.rebuild()
    let outgoing = try #require(runtime.carPlayActions)

    runtime.rebuild(keepingPreparedArtwork: true, keepingNavigation: true)

    let current = try #require(runtime.carPlayActions)
    #expect(current !== outgoing)
    #expect(current.generation == runtime.generation)
    #expect(await outgoing.resumeLastPlayed() == .rejected(.staleGeneration))
    #expect(outgoing.setRate(1.5, generation: outgoing.generation) == .rejected(.staleGeneration))
  }

  @Test("the car's lists belong to one generation and are replaced with the graph")
  func carPlayBrowseFollowsTheGraph() throws {
    let runtime = Factory().runtime()
    runtime.prepare()
    #expect(runtime.carPlayBrowse == nil)

    runtime.rebuild()
    let first = try #require(runtime.carPlayBrowse)
    #expect(first.generation == runtime.generation)
    #expect(runtime.carPlayBrowse === first)

    runtime.rebuild(keepingPreparedArtwork: true, keepingNavigation: true)
    let second = try #require(runtime.carPlayBrowse)
    #expect(second !== first)
    #expect(second.generation == runtime.generation)
    // A row from the outgoing lists carries a generation the current commands refuse.
    #expect(first.generation != runtime.carPlayActions?.generation)
  }

  /// The fixture's removal cannot finish, since its journal names no reachable account. That half
  /// is pinned here. The reset after a completed removal needs the real removal sequence and is not
  /// covered by this suite.
  @Test("a removal still pending after launch keeps its removal-only graph")
  func launchKeepsUnfinishedRemovalGraph() async throws {
    let database = try AppDatabase.inMemory()
    try AccountRemovalJournalStore(database: database).create(
      AccountRemovalJournalRecord(
        serverBaseURL: "https://pending-removal.invalid",
        serverUserId: "pending-removal-user",
        accountRowId: 1,
        downloadsRootRelativePath: "Downloads",
        createdAt: Date()
      ))
    let factory = Factory(database: database)
    let runtime = factory.runtime()
    let launch = runtime.composition
    #expect(launch.environment.composition == .removalPending)

    await runtime.start()?.value

    #expect(factory.modes == [.automatic])
    #expect(runtime.composition === launch)
    #expect(launch.root.navigation.presentation == .removalPending)
    #expect(factory.clears.isEmpty)
  }

  @Test("a logout clears the notification route")
  func logoutClearsProcessWideState() {
    let factory = Factory()
    let runtime = factory.runtime()

    runtime.resetAfterLogout()

    #expect(factory.clears == [.notificationRoutes])
  }

  @MainActor
  private final class Factory {
    enum Clear { case notificationRoutes }

    private(set) var modes: [AppEnvironment.Mode] = []
    private(set) var clears: [Clear] = []
    /// The one store every graph of this factory's runtime is composed against, as on disk. An
    /// in-memory store cannot fail to open, so a trap here means a broken fixture.
    private let opened: AppDatabase

    init(database: AppDatabase? = nil) {
      opened = database ?? (try! AppDatabase.inMemory())
    }

    /// What a successful bootstrap hands the runtime: one store for every graph it composes.
    func ready() -> AppBootstrap.Outcome {
      AppBootstrap.run(database: { [self] in opened }, isProtectedDataAvailable: { true })
    }

    func runtime(
      bootstrap: (@MainActor () -> AppBootstrap.Outcome)? = nil,
      storageWakeUps: @escaping @MainActor () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
    ) -> AppRuntime {
      AppRuntime(
        bootstrap: bootstrap ?? { [self] in ready() },
        makeComposition: { [self] mode, database, accountState in
          modes.append(mode)
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "whirr-app-runtime-\(UUID().uuidString)", isDirectory: true)
          return RootComposition(
            hardware: PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering()),
            mode: mode, database: database, accountState: accountState,
            applicationSupportDirectory: directory, watchCompanionRuntime: nil)
        }, storageWakeUps: storageWakeUps,
        clearNotificationRoutes: { [self] in clears.append(.notificationRoutes) },
        // Inert. The production triggers watch the process's real player and network.
        makeEndpointTriggers: { _ in
          EndpointSwitchTriggers(
            observe: {
              .init(
                graphGeneration: 0, switchGeneration: nil, isServerUnreachable: false,
                isPlaybackIntended: false)
            }, hasGraph: { false }, perform: { _ in }, networkChanges: { _ in })
        })
    }
  }

  @MainActor
  private final class Storage {
    var isAvailable: Bool
    init(isAvailable: Bool) { self.isAvailable = isAvailable }
  }

  /// `withObservationTracking`'s `onChange` is `@Sendable`. Every use here is on the main actor.
  private final class Flag: @unchecked Sendable {
    private(set) nonisolated(unsafe) var isSet = false
    nonisolated func set() { isSet = true }
  }
}
