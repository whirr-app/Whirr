import AdSkip
import AppModel
import Foundation
import Persistence
import PlayerCore

/// The process-lifetime Trim Silences analysis, composed once per launch against the shared
/// database like `AdSkipComposition`, and the trim ports each account's `PlaybackModel` is given.
///
/// Show settings are split by owner: RSS shows' are device-owned, ABS shows' belong to the account.
/// The coordinator outlives accounts, so it hears overrides through a relay each account
/// environment points at its own settings.
@MainActor
enum PauseTrimComposition {
  /// Not built, and `nil`, while the database cannot open (a background launch before the first
  /// unlock); a later call builds it.
  static var coordinator: PauseTrimCoordinator? {
    if instance == nil, let database = DatabaseHardware.sharedIfAvailable() {
      instance = PauseTrimCoordinator(
        dependencies: .init(
          store: PauseTrimEpisodeStore(database: database), analyser: AudioFilePauseAnalyser()))
    }
    return instance
  }

  private static var instance: PauseTrimCoordinator?
  private static var isStarted = false
  private static let overrides = AsyncStream.makeStream(
    of: [String: TrimSilencesShowOverride].self, bufferingPolicy: .bufferingNewest(1))
  private static var relay: Task<Void, Never>?
  private static var hasAccountSettings = false

  static let preferences = UserDefaultsTrimSilencesPreferences()

  static func runForLaunch() async {
    guard isStarted == false, let coordinator, let database = DatabaseHardware.sharedIfAvailable() else {
      return
    }
    isStarted = true
    // Until an account environment says otherwise, only the device-owned RSS settings exist.
    if hasAccountSettings == false {
      relayOverrides(
        from: RoutingTrimSilencesShowSettingsAccess(
          abs: NoAccountTrimSilencesSettings(), rss: RSSFeedSettingsStore(database: database)))
    }
    await coordinator.start(
      localEpisodes: AdSkipComposition.makeLocalEpisodeReader(database: database).observeLocalEpisodes(),
      defaults: preferences.observeDefault(),
      overrides: overrides.stream,
      // Trimming is a playback feature the listener turned on, not a backlog job: it does not
      // wait for power, only for a cool phone outside Low Power Mode.
      isAllowed: AdSkipAnalysisConditions.changesIgnoringCharging())
  }

  /// The trim ports for one account's `PlaybackModel`; the account's merged show settings also
  /// become what the analysis queue follows. Nil while the database cannot open.
  static func playbackDependencies(
    engine: AVQueuePlayerAudioEngine,
    showSettings: RoutingTrimSilencesShowSettingsAccess
  ) -> PlaybackTrimDependencies? {
    guard let coordinator else { return nil }
    hasAccountSettings = true
    relayOverrides(from: showSettings)
    let preparer = CompositionTrimPreparer { [weak engine] url, map, asset in
      engine?.configureTrimmed(fileURL: url, map: map, asset: asset)
    }
    return PlaybackTrimDependencies(
      source: coordinator, preparer: preparer, defaults: preferences, showSettings: showSettings)
  }

  /// Points the relay at `settings`, replacing what it followed before.
  private static func relayOverrides(from settings: any TrimSilencesShowSettingsReading) {
    relay?.cancel()
    let continuation = overrides.continuation
    let stream = settings.observeTrimSilencesOverrides()
    relay = Task {
      for await values in stream {
        guard Task.isCancelled == false else { return }
        continuation.yield(values)
      }
    }
  }
}

/// The ABS half before any account is signed in: no shows, so no settings.
private struct NoAccountTrimSilencesSettings: TrimSilencesShowSettingsReading,
  TrimSilencesShowSettingsWriting
{
  func fetchTrimSilencesOverrides() async throws -> [String: TrimSilencesShowOverride] { [:] }

  func observeTrimSilencesOverrides() -> AsyncStream<[String: TrimSilencesShowOverride]> {
    AsyncStream { continuation in
      continuation.yield([:])
    }
  }

  func setTrimSilencesOverride(itemID: String, override: TrimSilencesShowOverride) async throws {
    throw PodcastSettingsStoreError.itemNotFound
  }
}
