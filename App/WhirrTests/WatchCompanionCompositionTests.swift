import AppModel
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import Testing
import WatchProtocol

@testable import Whirr

/// Composition boundaries for the process-lifetime Watch companion. The runtime is injected into
/// composition in these tests so account binding can be observed without activating WCSession or
/// sending a catalogue payload anywhere.
@MainActor
@Suite("Watch companion composition", .serialized)
struct WatchCompanionCompositionTests {

  @Test("the indicator and the handoff asker judge a Watch report by the same window")
  func playingReportWindowsAgree() {
    #expect(CompanionDevicePlayback.expiry == WatchPlayingReport.expiry)
    #expect(CompanionDevicePlayback.futureSkewTolerance == WatchProtocolVersion.commandFutureSkewTolerance)
  }

  @Test("an authenticated composition binds account actions and its catalogue publisher")
  func authenticatedCompositionBindsRuntimeAccountGraph() throws {
    let runtime = WatchCompanionRuntime()
    let hardware = PlaybackHardware(
      remoteCommandCenter: FakeRemoteCommandRegistering())
    let composition = try Self.composition(
      mode: .runtime, hardware: hardware, database: Self.authenticatedDatabase(), runtime: runtime)

    #expect(composition.environment.composition == .runtime)
    #expect(composition.companionPlaybackActions != nil)
    #expect(composition.watchCataloguePublisher != nil)
    #expect(runtime.bridge.isBound)
  }

  @Test("the same runtime is unbound when the composition returns to setup")
  func setupRebuildClearsTheAccountBinding() async throws {
    let runtime = WatchCompanionRuntime()
    let hardware = PlaybackHardware(
      remoteCommandCenter: FakeRemoteCommandRegistering())
    let database = try Self.authenticatedDatabase()
    let signedIn = try Self.composition(mode: .runtime, hardware: hardware, database: database, runtime: runtime)
    #expect(runtime.bridge.isBound)

    await signedIn.logoutPreflight.prepareForLogout()
    #expect(runtime.bridge.isBound == false)
    try AccountDAO(database: database).delete()
    let setup = try Self.composition(mode: .automatic, hardware: hardware, database: database, runtime: runtime)

    #expect(signedIn.environment !== setup.environment)
    #expect(setup.environment.composition == .setup)
    #expect(setup.companionPlaybackActions == nil)
    #expect(setup.watchCataloguePublisher == nil)
    #expect(runtime.bridge.isBound == false)
    #expect(runtime.latestSnapshot == nil)
  }

  @Test("enriching a published snapshot keeps every phone preference")
  func enrichmentCarriesEveryPreference() throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    let authenticated = try WatchAccountStamp(accountIdentityHash: "user", serverIdentityHash: "server")
    let snapshot = try WatchCatalogueSnapshot(
      accountStamp: stamp, items: [], playbackState: .playing, playbackRate: 1.35,
      skipBackwardSeconds: 15, skipForwardSeconds: 45, playbackRatePresets: [0.9, 1, 1.1],
      followedPodcastsEnabled: true, removePlayedNativeEpisodes: false)
    let enriched = WatchCompanionRuntime.enriched(snapshot, authenticatedStamp: authenticated)
    #expect(enriched.authenticatedAccountStamp == authenticated)
    #expect(enriched.playbackRate == 1.35)
    #expect(enriched.skipBackwardSeconds == 15 && enriched.skipForwardSeconds == 45)
    #expect(enriched.playbackRatePresets == [0.9, 1, 1.1])
    #expect(enriched.followedPodcastsEnabled == true)
    #expect(enriched.removePlayedNativeEpisodes == false)
  }

  @Test("composition can omit the Watch runtime")
  func compositionCanOmitCompanionRuntime() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let composition = try Self.composition(
      mode: .runtime, hardware: hardware, database: Self.authenticatedDatabase())

    #expect(composition.companionPlaybackActions == nil)
    #expect(composition.watchCataloguePublisher == nil)
  }

  @Test("the authenticated composition owns actions and the publisher for its account lifetime")
  func compositionRetainsAccountScopedCompanionObjects() async throws {
    let runtime = WatchCompanionRuntime()
    let hardware = PlaybackHardware(
      remoteCommandCenter: FakeRemoteCommandRegistering())
    weak var releasedActions: CompanionPlaybackActions?
    weak var releasedPublisher: WatchCataloguePublisher?

    do {
      let composition = try Self.composition(
        mode: .runtime, hardware: hardware, database: Self.authenticatedDatabase(), runtime: runtime)
      releasedActions = composition.companionPlaybackActions
      releasedPublisher = composition.watchCataloguePublisher
      #expect(releasedActions != nil)
      #expect(releasedPublisher != nil)
      #expect(runtime.bridge.isBound)

      // The composition preflight is the account teardown hook. It clears the bridge while the
      // composition still owns both account-scoped objects, so an old command cannot reach them.
      await composition.logoutPreflight.prepareForLogout()
      #expect(runtime.bridge.isBound == false)
    }

    #expect(releasedActions == nil)
    #expect(releasedPublisher == nil)
  }

  @Test("each runtime owns copies models of its own")
  func runtimesHoldTheirOwnCopiesModels() {
    let first = WatchCompanionRuntime()
    let second = WatchCompanionRuntime()

    #expect(first.episodeCopies !== second.episodeCopies)
    #expect(first.absCopies !== second.absCopies)
  }

  @Test("a runtime keeps the copies models it was built with")
  func runtimeKeepsInjectedCopiesModels() {
    let episodes = WatchEpisodeCopiesModel()
    let audiobookshelf = ABSWatchCopiesModel()

    let runtime = WatchCompanionRuntime(episodeCopies: episodes, absCopies: audiobookshelf)

    #expect(runtime.episodeCopies === episodes)
    #expect(runtime.absCopies === audiobookshelf)
  }

  /// The runtime's own availability refresh writes the setup model's readiness into both copies
  /// models. An unactivated runtime never reports one, so readiness planted first makes that write
  /// visible; a second runtime keeps the readiness it was given, since the call reached only the
  /// runtime whose model made it.
  @Test("the copies model is connected to the runtime that built it")
  func theCopiesModelReachesTheRuntimeThatConnectedIt() {
    let runtime = WatchCompanionRuntime()
    let other = WatchCompanionRuntime()
    runtime.episodeCopies.applyReadiness(.canFetch)
    runtime.absCopies.applyReadiness(.needsUpdate)
    other.absCopies.applyReadiness(.needsUpdate)

    runtime.episodeCopies.refreshWatchAvailability()

    #expect(runtime.episodeCopies.watchAppReadiness == .unknown)
    #expect(runtime.absCopies.readiness == .unknown)
    #expect(other.absCopies.readiness == .needsUpdate)
  }

  private static func composition(
    mode: AppEnvironment.Mode,
    hardware: PlaybackHardware,
    database: AppDatabase,
    runtime: WatchCompanionRuntime? = nil
  ) throws -> RootComposition {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-watch-composition-\(UUID().uuidString)", isDirectory: true)
    return RootComposition(
      hardware: hardware, mode: mode, database: database,
      applicationSupportDirectory: directory, watchCompanionRuntime: runtime)
  }

  private static func authenticatedDatabase() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "watch-composition",
        serverBaseURL: "https://watch-composition.invalid",
        serverUserId: "watch-composition-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "watch-composition-library"))
    return database
  }
}
