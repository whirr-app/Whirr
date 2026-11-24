import AdSkip
import AppModel
import CoreSupport
import Foundation
import Persistence
import UIKit
import os

/// The process-lifetime ad-skip coordinator. It is device-owned rather than account-owned, like
/// the native podcast state, so it is composed once per launch against the shared database
/// instead of with each account's `AppEnvironment`, which only hands it to playback as the
/// range source.
@MainActor
enum AdSkipComposition {
  /// Built on first use, so an environment composed before the launch task runs gets the same
  /// instance. Construction is cheap: nothing is read or loaded until `runForLaunch` starts it.
  ///
  /// Not built, and `nil`, while the database cannot open (a background launch before the first
  /// unlock); a later call builds it.
  static var coordinator: AdSkipCoordinator? {
    if isBuilt == false {
      guard let database = DatabaseHardware.sharedIfAvailable() else { return nil }
      isBuilt = true
      instance = makeCoordinator(database: database)
    }
    return instance
  }

  /// True only while the database has not yet opened in this process, as opposed to ad skip being
  /// unavailable for good.
  static var isAwaitingDatabase: Bool {
    _ = coordinator
    return isBuilt == false
  }

  private static var isBuilt = false
  private static var instance: AdSkipCoordinator?
  private static var isStarted = false

  /// Transcript files live beside the database and downloads, never in Caches (SECURITY.md
  /// rule 20).
  static let directoryName = "AdSkip"

  private static let log = CoreLogging.logger(category: "AdSkip")

  /// Reads downloaded episodes against the same root `DownloadFileStore` and `RSSFileStore`
  /// resolve relative paths against. `applicationSupportDirectory` is the same test seam
  /// `AppEnvironment` is built with; production passes nothing.
  static func makeLocalEpisodeReader(
    database: AppDatabase, applicationSupportDirectory: URL? = nil
  ) -> AdSkipLocalEpisodeReader {
    AdSkipLocalEpisodeReader(
      database: database,
      downloadsRootURL: DownloadLocations.root(
        applicationSupportDirectory: applicationSupportDirectory
          ?? AppEnvironment.applicationSupportDirectory()))
  }

  static func runForLaunch() async {
    guard isStarted == false, let coordinator, let database = DatabaseHardware.sharedIfAvailable() else {
      return
    }
    isStarted = true
    #if DEBUG
      await prepareMeasurement()
    #endif
    let reader = makeLocalEpisodeReader(database: database)
    await coordinator.start(
      localEpisodes: reader.observeLocalEpisodes(),
      isEnabled: AdSkipPreference.changes(),
      isAllowed: AdSkipAnalysisConditions.changes(),
      priorityConditions: AdSkipAnalysisConditions.changesIgnoringCharging())
  }

  private static func makeCoordinator(database: AppDatabase) -> AdSkipCoordinator? {
    let support = AppEnvironment.applicationSupportDirectory()
    let transcripts: AdSkipTranscriptFileStore
    let bundledScorer: ArbiterStepScorer
    do {
      transcripts = try AdSkipTranscriptFileStore(
        rootURL: support.appendingPathComponent(directoryName, isDirectory: true),
        fileAttributes: POSIXFileAttributeApplier())
      bundledScorer = try ArbiterStepScorer.bundled()
    } catch {
      // Ad skipping stays off for this launch. Only the error's type is logged, never a path.
      log.error("Ad-skip unavailable: \(String(describing: type(of: error)), privacy: .public)")
      return nil
    }
    let episodes = AdSkipEpisodeStore(database: database)
    let signatures = AdSignatureStore(database: database)
    var transcriber: any EpisodeTranscribing = SpeechEpisodeTranscriber()
    var audioPrinter: any AudioPrinting = AudioFileAnalysisDecoder()
    var scorer: any AdStepScoring = bundledScorer
    var transcribesWholeFiles = false
    var matchingMeasurement: (any AdSkipMatchingMeasuring)?
    #if DEBUG
      let mode = AdSkipWholeFileSwitch.launchMode(argument: AdSkipWholeFileSwitch.launchArgument())
      transcribesWholeFiles = mode.isOn
      let recorder = AdSkipMeasurement.Recorder.standard(wholeFiles: mode.isOn)
      transcriber = AdSkipMeasurement.MeasuredTranscriber(base: transcriber, recorder: recorder)
      audioPrinter = AdSkipMeasurement.MeasuredAudioPrinter(base: audioPrinter, recorder: recorder)
      scorer = AdSkipMeasurement.MeasuredScorer(base: scorer, recorder: recorder)
      matchingMeasurement = AdSkipMeasurement.MeasuredMatching(recorder: recorder)
      measurement = MeasurementSetup(
        recorder: recorder, isWholeFileModeChanged: mode.hasChanged, episodes: episodes,
        signatures: signatures, transcripts: transcripts)
    #endif
    // Outside the measurement wrapper, so recorded timings leave out time spent waiting for a
    // transcript session.
    transcriber = TranscriptComposition.gate.gating(transcriber)
    return AdSkipCoordinator(
      dependencies: .init(
        episodes: episodes,
        signatures: signatures,
        transcripts: transcripts,
        transcriber: transcriber,
        audioPrinter: audioPrinter,
        scorer: scorer,
        transcriberRevision: SpeechEpisodeTranscriber.revision,
        transcribesWholeFiles: transcribesWholeFiles,
        matchingMeasurement: matchingMeasurement,
        // Nil when transcripts are unavailable: ad skip then finds no host reads.
        listenerTranscripts: TranscriptComposition.coordinator))
  }

  #if DEBUG
    /// What `runForLaunch` needs for the device measurement, kept from composition.
    private struct MeasurementSetup {
      let recorder: AdSkipMeasurement.Recorder
      let isWholeFileModeChanged: Bool
      let episodes: AdSkipEpisodeStore
      let signatures: AdSignatureStore
      let transcripts: AdSkipTranscriptFileStore
    }

    private static var measurement: MeasurementSetup?

    /// Before the coordinator starts: a flipped S/T switch clears the analysis so the run in the
    /// new mode starts clean (and is recorded only once that worked, so a failed reset is tried
    /// again next launch), then the launch is logged, and the matching benchmark runs if asked.
    private static func prepareMeasurement() async {
      guard let measurement else { return }
      let wholeFiles = measurement.recorder.mode == "S"
      if measurement.isWholeFileModeChanged {
        do {
          try await AdSkipMeasurement.resetAnalysis(
            episodes: measurement.episodes, signatures: measurement.signatures,
            transcripts: measurement.transcripts)
          AdSkipWholeFileSwitch.record(wholeFiles)
        } catch {
          log.error("Ad-skip reset failed: \(String(describing: type(of: error)), privacy: .public)")
        }
      }
      await measurement.recorder.recordLaunch()
      if UserDefaults.standard.bool(forKey: AdSkipMeasurement.matchBenchmarkKey) {
        await AdSkipMeasurement.runMatchBenchmark(
          transcripts: measurement.transcripts, recorder: measurement.recorder)
      }
    }
  #endif
}

/// Debug-only switch that transcribes every episode in full instead of audio-gated, so both can be
/// measured in one device session. Set with `-com.remoteconcern.whirr.adSkipWholeFiles YES` (or
/// `NO`); it persists across Home Screen relaunches, and a change of mode clears the analysis.
/// Removed before release.
nonisolated enum AdSkipWholeFileSwitch {
  /// The launch argument.
  static let key = "com.remoteconcern.whirr.adSkipWholeFiles"
  /// The mode the analysis on this phone was made in.
  static let storedKey = "com.remoteconcern.whirr.adSkipWholeFilesStored"

  /// The launch argument, when one was given.
  static func launchArgument(in defaults: UserDefaults = .standard) -> Bool? {
    guard defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil else {
      return nil
    }
    return defaults.bool(forKey: key)
  }

  /// This launch's mode: the argument when given, else the recorded mode, which is audio-gated until
  /// one is recorded. `hasChanged` until `record` stores the new mode.
  static func launchMode(
    argument: Bool?, in defaults: UserDefaults = .standard
  ) -> (isOn: Bool, hasChanged: Bool) {
    #if DEBUG
      let stored = defaults.bool(forKey: storedKey)
      let isOn = argument ?? stored
      return (isOn, isOn != stored)
    #else
      (false, false)
    #endif
  }

  static func record(_ isOn: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(isOn, forKey: storedKey)
  }
}

/// The Reduce Ads setting, off by default. Read from `UserDefaults` so a settings toggle
/// and iCloud key-value sync both reach the coordinator without going through a setter.
nonisolated enum AdSkipPreference {
  static let key = "com.remoteconcern.whirr.adSkipEnabled"

  static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }

  /// Analyse only on external power. Off by default: only the stretches that recur are
  /// transcribed, so analysis is cheap outside a large batch. Kept on this device rather than
  /// synced: whether battery can be spared is a property of the phone, not the listener.
  static let onlyWhileChargingKey = "com.remoteconcern.whirr.adSkipOnlyWhileCharging"

  static func isOnlyWhileCharging(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: onlyWhileChargingKey)
  }

  /// The current value, then the value after every defaults change. Repeats are harmless: the
  /// coordinator ignores an unchanged value.
  static func changes(in defaults: UserDefaults = .standard) -> AsyncStream<Bool> {
    // `UserDefaults` is thread-safe but not annotated `Sendable`.
    nonisolated(unsafe) let defaults = defaults
    return AsyncStream { continuation in
      continuation.yield(isEnabled(in: defaults))
      let observer = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
      ) { _ in
        continuation.yield(isEnabled(in: defaults))
      }
      nonisolated(unsafe) let token = observer
      continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
    }
  }
}

/// Why analysis is held back, for the progress line on the Reduce Ads page.
nonisolated enum AdSkipPauseReason: Equatable, Sendable {
  case notCharging
  case lowPowerMode
  case warm
}

/// Whether analysis may run now: on external power unless the listener allows battery,
/// not in Low Power Mode, and below serious thermal state. Transcription keeps the Neural Engine
/// and CPU busy for minutes per episode, so a backlog analysed on battery heats and drains the
/// phone. Re-emitted whenever the app becomes active, which is also when the coordinator retries
/// an analysis it deferred because the speech asset was missing.
nonisolated enum AdSkipAnalysisConditions {
  struct Snapshot: Equatable {
    var isLowPowerModeEnabled: Bool
    var thermalState: ProcessInfo.ThermalState
    var isOnExternalPower: Bool
    var onlyWhileCharging: Bool
  }

  /// Nil when analysis may run. Waiting for power is named first: it is the one condition the
  /// listener chose, and plugging in is what lifts it.
  static func pauseReason(_ snapshot: Snapshot) -> AdSkipPauseReason? {
    if snapshot.onlyWhileCharging, snapshot.isOnExternalPower == false { return .notCharging }
    if snapshot.isLowPowerModeEnabled { return .lowPowerMode }
    switch snapshot.thermalState {
    case .nominal, .fair: return nil
    case .serious, .critical: return .warm
    @unknown default: return .warm
    }
  }

  /// Battery state is reported only while monitoring is on, and `UIDevice` is main-actor bound.
  @MainActor
  static func current(defaults: UserDefaults = .standard) -> Snapshot {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let processInfo = ProcessInfo.processInfo
    return Snapshot(
      isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
      thermalState: processInfo.thermalState,
      // `.unknown` (monitoring unavailable) counts as battery: the safe reading.
      isOnExternalPower: device.batteryState == .charging || device.batteryState == .full,
      onlyWhileCharging: AdSkipPreference.isOnlyWhileCharging(in: defaults))
  }

  @MainActor
  static func currentPauseReason() -> AdSkipPauseReason? {
    pauseReason(current())
  }

  @MainActor
  static func isAllowed() -> Bool {
    currentPauseReason() == nil
  }

  /// Whether Check Now may analyse the loaded episode: everything but Only While Charging, which
  /// is the one condition the listener chose and so the one they may override.
  @MainActor
  static func isAllowedIgnoringCharging() -> Bool {
    var snapshot = current()
    snapshot.onlyWhileCharging = false
    return pauseReason(snapshot) == nil
  }

  /// A move to battery cancels the episode being transcribed, which is transcribed again on the
  /// next charge. Activation always re-emits, to retry a deferred analysis; the other sources
  /// emit only a change, since every defaults write in the app posts one of them and each
  /// emission wakes a coordinator pass.
  @MainActor
  static func changes() -> AsyncStream<Bool> {
    observed(reemitsOnActivation: true, isAllowed)
  }

  /// `changes()` without Only While Charging, for Check Now. A move to Low Power Mode or heat
  /// stops a Check Now; unplugging does not.
  @MainActor
  static func changesIgnoringCharging() -> AsyncStream<Bool> {
    observed(reemitsOnActivation: false, isAllowedIgnoringCharging)
  }

  /// Why analysis waits, for the expanded player's status.
  @MainActor
  static func pauseReasonChanges() -> AsyncStream<AdSkipPauseReason?> {
    observed(reemitsOnActivation: false, currentPauseReason)
  }

  /// `read()` now, then whenever a power, thermal, battery or defaults change alters it, and on
  /// every activation when `reemitsOnActivation`.
  @MainActor
  private static func observed<Value: Equatable & Sendable>(
    reemitsOnActivation: Bool, _ read: @escaping @MainActor () -> Value
  ) -> AsyncStream<Value> {
    PreferenceChanges.stream(
      read: { MainActor.assumeIsolated { read() } },
      reemitOnActivate: reemitsOnActivation,
      notificationNames: [
        .NSProcessInfoPowerStateDidChange,
        ProcessInfo.thermalStateDidChangeNotification,
        UIDevice.batteryStateDidChangeNotification,
        // The Only While Charging toggle.
        UserDefaults.didChangeNotification,
        UIApplication.didBecomeActiveNotification,
      ],
      activationName: UIApplication.didBecomeActiveNotification,
      queue: .main,
      // Unbounded, as before: these are rare and a coordinator pass must see each one.
      bufferingPolicy: .unbounded)
  }
}
