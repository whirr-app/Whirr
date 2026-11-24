import AppModel
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// Constructing `RootView` must not build its dependency graph. SwiftUI reconstructs it inside the
/// render loop, so setup (an `AVQueuePlayer`, a keychain read, a `SyncEngine`, the synchronous
/// launch-recovery writes in `OutboxStore` and `DownloadStore`) would block the main thread for
/// seconds per pass: the eager-model defect `DeferredModel` documents.
///
/// Factory tests follow `AppEnvironmentCompositionTests`' injection pattern (in-memory
/// `AppDatabase`, temporary storage root, `FakeRemoteCommandRegistering`) so nothing touches user
/// data or the process-wide `MPRemoteCommandCenter`; the first test injects an `AppRuntime` too.
@MainActor
@Suite("Root composition", .serialized)
struct RootCompositionTests {

  @Test("constructing RootView repeatedly never composes a dependency graph")
  func repeatedRootViewConstructionComposesNothing() throws {
    var compositions = 0
    let runtime = AppRuntime(
      bootstrap: {
        AppBootstrap.run(database: { try? AppDatabase.inMemory() }, isProtectedDataAvailable: { true })
      },
      makeComposition: { mode, database, _ in
        compositions += 1
        return try! Self.composition(mode: mode, database: database)
      })

    for _ in 0..<50 { _ = RootView(runtime: runtime) }

    #expect(compositions == 0)
    #expect(runtime.current == nil)
    // A `@State` holding the graph would evaluate its default per construction on SDKs that do not
    // defer it. This suite catches that.
    #expect(Self.storesComposition(RootView(runtime: runtime)) == false)
  }

  @Test("the composition factory wires every model to the environment it was built from")
  func factoryWiresModelsToItsOwnEnvironment() throws {
    let composition = try Self.composition(mode: .runtime, database: Self.authenticatedDatabase())

    #expect(composition.environment.composition == .runtime)
    #expect(composition.homeModel.filter == .all)
    #expect(composition.podcastListeningModel.filter == .podcasts)
    // The root's shows preview and the all-shows page share this one model. It observes the
    // environment's account-scoped `DefaultPodcastShowOrdering`, not the no-op default used during
    // incremental composition, which would drop a custom order.
    let showsModelOrdering = try #require(
      Mirror(reflecting: composition.podcastShowsOrderedModel).children.first(where: {
        $0.label == "ordering"
      })?.value)
    #expect(showsModelOrdering is DefaultPodcastShowOrdering)
    #expect(composition.environment.dependencies.podcastShowOrdering is DefaultPodcastShowOrdering)
    #expect(composition.podcastLatestModel.section == .newEpisodes)
    #expect(composition.podcastLatestModel.filter == .podcasts)
    // The write seam is the decorator, as `listeningQueueStoring` is `QueueAutoDownload` over the
    // store. Every save still reaches `SavedShelfStore`.
    #expect(composition.environment.dependencies.savedShelfStoring is SavedShelfAutoDownload)
    #expect(composition.environment.dependencies.savedShelfReading is DefaultSavedShelfReading)

    let rootSavedStatus = try #require(composition.root.savedStatus)
    let actionsSavedStatus = try #require(
      Mirror(reflecting: composition.actions).children
        .first(where: { $0.label == "savedStatus" })?.value as? SavedStatusStore)
    #expect(actionsSavedStatus === rootSavedStatus)

    // The context menu and every row read the same download projection: one observation per
    // composition, not one per consumer.
    let actionsDownloadStatus = try #require(
      Mirror(reflecting: composition.actions).children.first(where: { $0.label == "downloadStatus" })?.value
        as? DownloadStatusStore)
    #expect(actionsDownloadStatus === composition.downloadStatus)
  }

  @Test("authenticated saved membership resolves and round-trips through item actions")
  func savedMembershipRoundTripsThroughActions() async throws {
    let composition = try Self.composition(
      mode: .runtime, database: try Self.authenticatedDatabaseWithSaveableItem())
    let actions = composition.actions

    #expect(await Self.waitUntil { actions.hasResolvedSavedMembership })
    #expect(actions.isSaved(itemID: "book-1") == false)

    await actions.saveForLater(itemID: "book-1")
    #expect(await Self.waitUntil { actions.isSaved(itemID: "book-1") })

    await actions.removeFromSaved(itemID: "book-1")
    #expect(await Self.waitUntil { actions.isSaved(itemID: "book-1") == false })
  }

  /// `LibraryShellView` passes `podcastShowsOrderedModel` to both the Podcasts root
  /// (`PodcastsView(showsModel:)`) and the pushed `.podcastShows` destination
  /// (`PodcastShowsView(model:)`). The two can only disagree about order if the composition vends a
  /// second model, so it must not.
  @Test("the composition vends exactly one PodcastShowsModel for the root preview and the all-shows route")
  func rootPreviewAndAllShowsRouteShareOneShowsModel() throws {
    let composition = try Self.composition(mode: .runtime, database: Self.authenticatedDatabase())

    let showsModels = Mirror(reflecting: composition).children.compactMap {
      $0.value as? PodcastShowsModel
    }
    #expect(showsModels.count == 1)
    #expect(showsModels.first === composition.podcastShowsOrderedModel)
  }

  /// The stale-offline caption on the Podcasts list is the only place a server outage is explained
  /// for that section, so the production composition must reach that state by itself. It uses the
  /// real `DefaultPodcastShowOrdering`/`DefaultLibraryReading` pair, not fakes, and keeps the
  /// cached show editable while the server is unreachable.
  @Test("the production shows model settles into its stale-offline state")
  func productionShowsModelSettlesStaleOffline() async throws {
    let composition = try Self.composition(
      mode: .runtime, database: try Self.authenticatedDatabaseWithStaleShow())
    let showsModel = composition.podcastShowsOrderedModel

    #expect(
      await Self.waitUntil {
        if case .staleOffline = showsModel.state { return true }
        return false
      })
    #expect(showsModel.shows.map(\.serverItemId) == ["show-1"])
    #expect(showsModel.isEditingAllowed)
  }

  @Test("Home, Podcasts, and the pushed list have one durable Latest Episodes model")
  func latestEpisodeSurfacesShareOneModel() throws {
    let composition = try Self.composition(mode: .runtime, database: Self.authenticatedDatabase())

    let latestModels = Mirror(reflecting: composition).children.compactMap {
      $0.value as? HomeMoreModel
    }
    #expect(latestModels.count == 1)
    #expect(latestModels.first === composition.podcastLatestModel)
    #expect(composition.podcastLatestModel.section == .newEpisodes)
    #expect(composition.podcastLatestModel.filter == .podcasts)
  }

  /// There is one runtime queue store and model per account graph. Item actions, playback
  /// consumption and the player's queue sheet each hold a queue boundary, and all three must hold
  /// the environment's single `ListeningQueueStore`. The podcast queue store must not appear in the
  /// graph at all, not even injected but unread.
  @Test("one listening queue reaches item actions, playback, and the player's queue presentation")
  func oneListeningQueueReachesEveryConsumer() throws {
    let composition = try Self.composition(mode: .runtime, database: Self.authenticatedDatabase())
    let dependencies = composition.environment.dependencies

    #expect(dependencies.listeningQueueStoring is QueueAutoDownload)

    let actionsQueue = try #require(
      Mirror(reflecting: composition.actions).children
        .first(where: { $0.label == "listeningQueue" })?.value)
    #expect(actionsQueue is QueueAutoDownload)

    let playbackQueue = try #require(
      Mirror(reflecting: composition.root.playback).children
        .first(where: { $0.label == "listeningQueue" })?.value)
    #expect(playbackQueue is QueueAutoDownload)

    let sheetQueue = try #require(
      Mirror(reflecting: composition.root.makeListeningQueueModel()).children
        .first(where: { $0.label == "storing" })?.value)
    #expect(sheetQueue is QueueAutoDownload)

    // The episode intents the show screen and episode card drive share it too.
    #expect(composition.root.podcastEpisodeIntents is PlaybackPodcastEpisodeIntents)
    let intentsQueue = try #require(
      Mirror(reflecting: composition.root.podcastEpisodeIntents).children
        .first(where: { $0.label == "queue" })?.value)
    #expect(intentsQueue is QueueAutoDownload)
  }

  @Test("an unauthenticated composition still selects the setup-only graph")
  func unauthenticatedCompositionUsesSetupGraph() throws {
    let composition = try Self.composition(mode: .automatic)

    #expect(composition.environment.composition == .setup)
    #expect(composition.environment.dependencies.downloadReading is NoOpDownloadReading)
    #expect(composition.environment.dependencies.savedShelfStoring is NoOpSavedShelfStore)
    #expect(composition.environment.dependencies.savedShelfReading == nil)
    #expect(composition.root.savedStatus == nil)
  }

  @Test("login and logout swap in a fresh environment while keeping the one PlaybackHardware")
  func rebuildSwapsEnvironmentButKeepsHardware() throws {
    let center = FakeRemoteCommandRegistering()
    let hardware = PlaybackHardware(remoteCommandCenter: center)
    let database = try AppDatabase.inMemory()

    let launch = try Self.composition(mode: .automatic, hardware: hardware, database: database)
    let afterLogin = try Self.composition(mode: .runtime, hardware: hardware, database: database)
    let afterLogout = try Self.composition(mode: .automatic, hardware: hardware, database: database)

    #expect(launch.environment !== afterLogin.environment)
    #expect(afterLogin.environment !== afterLogout.environment)
    #expect(launch.root !== afterLogin.root)
    #expect(launch.downloadStatus !== afterLogin.downloadStatus)

    // One player, coordinator and remote-command registration across `RootView`'s rebuild path.
    // `RootComposition.init` enables remote commands only for a `.runtime` graph, so the sequence
    // balances: register once at construction (10 setters, one per command), the setup-only launch
    // tears down, login registers the same adapter again, logout tears down. No register may be
    // live twice; `RemoteCommandAdapter.register()` is guarded by `isRegistered` since a second
    // would leave stale handlers on the command center.
    let launchPlayer = launch.environment.dependencies.player as AnyObject
    let loginPlayer = afterLogin.environment.dependencies.player as AnyObject
    let logoutPlayer = afterLogout.environment.dependencies.player as AnyObject
    #expect(launchPlayer === loginPlayer)
    #expect(loginPlayer === logoutPlayer)
    #expect(loginPlayer === hardware.player)
    #expect(center.setterCallCount == 20)
    #expect(center.removeAllTargetsCallCount == 2)
  }

  // MARK: - Fixtures

  /// Whether `RootView.composition`'s `@State` holds a `RootComposition`. SwiftUI's backing types
  /// are not API, so the check matches the type's name. A future SDK that renames it arrives as
  /// `.unrecognised` and fails loudly rather than passing silently.
  private static func storesComposition(_ view: RootView) -> Bool {
    Mirror(reflecting: view).children.contains { child in
      String(describing: type(of: child.value)).contains("RootComposition")
    }
  }

  /// An isolated in-memory store with an account row already saved. Every composition path that
  /// resolves an account-scoped store (`DefaultPodcastShowOrdering`, `ListeningQueueStore`,
  /// `RecentSearchStore`, `SavedShelfStore`) needs this before it can build anything but a no-op.
  private static func authenticatedDatabase() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "root-composition",
        serverBaseURL: "https://root-composition.invalid",
        serverUserId: "root-composition-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "root-composition-library"))
    return database
  }

  private static func authenticatedDatabaseWithSaveableItem() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "root-composition-saved-item",
        serverBaseURL: "https://root-composition-saved-item.invalid",
        serverUserId: "root-composition-saved-item-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "saved-item-library"))
    let library = try LibraryDAO(database: database).upsert(
      LibraryRecord(
        accountId: account.id!, serverLibraryId: "saved-item-library", mediaType: "book",
        name: "Books"))
    try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "book-1",
        mediaKind: "book", title: "Book", sortTitle: "book"))
    return database
  }

  private static func authenticatedDatabaseWithStaleShow() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "root-composition-stale-show",
        serverBaseURL: "https://root-composition-stale-show.invalid",
        serverUserId: "root-composition-stale-show-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "podcast-library"))
    let library = try LibraryDAO(database: database).upsert(
      LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcast-library", mediaType: "podcast",
        name: "Podcasts"))
    try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show-1",
        mediaKind: "podcast", title: "Stale Show", sortTitle: "stale show"))
    let syncRuns = SyncRunDAO(database: database)
    let run = try syncRuns.startRun(
      accountId: account.id!, libraryId: library.id!, reason: "test", generation: 1,
      sortRequested: nil, startedAt: Date(timeIntervalSince1970: 1))
    try syncRuns.finish(
      runId: run.id!, state: .incomplete, completedAt: Date(timeIntervalSince1970: 2),
      errorCategory: "offline")
    return database
  }

  private static func composition(
    mode: AppEnvironment.Mode,
    hardware: PlaybackHardware? = nil,
    database: AppDatabase? = nil
  ) throws -> RootComposition {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-root-composition-\(UUID().uuidString)", isDirectory: true)
    return RootComposition(
      hardware: hardware ?? PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering()),
      mode: mode,
      database: try database ?? AppDatabase.inMemory(),
      applicationSupportDirectory: directory, watchCompanionRuntime: nil)
  }

  /// The observations behind a runtime composition are real GRDB `ValueObservation`s delivering
  /// from a database reader, so the condition itself is the synchronization point.
  @MainActor
  private static func waitUntil(
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    // No `observing:`: the caller passes a bare predicate, so the only state to report is its own
    // value, which the timeout already implies. Call `awaitCondition` directly for a real
    // diagnostic.
    await awaitCondition(
      "a root composition condition",
      timeout: timeout,
      sourceLocation: sourceLocation,
      until: { condition() }
    ).isObserved
  }
}
