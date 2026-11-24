import CoreSupport

#if DEBUG
  import AdSkip
  import AppModel
  import Foundation
  import Persistence
  import PlayerCore
  import os

  /// A debug-only trigger: requests the listener transcript of
  /// the episode loaded in the player through the real coordinator, before the sheet exists, and
  /// measures it.
  ///
  /// Armed for one launch by `-com.remoteconcern.whirr.transcriptRequest 1`. Once a downloaded
  /// episode is loaded it requests that episode's transcript, then logs a `sample` line every 10 s
  /// and a `session` line when the transcript is complete, fails or stops, to
  /// `AdSkipMeasurements/measurements.jsonl` in mode `T`: counts, seconds and device readings,
  /// never an episode, name or text. The transcript itself is saved as a listener's would be.
  @MainActor
  enum TranscriptDebugTrigger {
    static let key = "com.remoteconcern.whirr.transcriptRequest"
    static let mode = "T"
    static let sampleInterval: Duration = .seconds(10)

    private static let log = CoreLogging.logger(category: "Transcript")

    /// The file the player most recently loaded, until the request is made.
    private static var loadedFile: URL?
    private static var isStarted = false

    /// From the launch argument only, so a Home Screen relaunch is unarmed.
    static func isArmed(in defaults: UserDefaults = .standard) -> Bool {
      defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil
    }

    /// The player's skip-range source, watched for the loaded file when armed.
    static func observing(
      _ source: (any PlaybackSkipRangeSource)?
    ) -> (any PlaybackSkipRangeSource)? {
      guard let source, isArmed() else { return source }
      return LoadedFileObserver(base: source) { url in
        Task { @MainActor in
          guard isStarted == false else { return }
          loadedFile = url
        }
      }
    }

    /// Waits for a loaded downloaded episode, requests it, and measures until it ends. Returns at
    /// once when unarmed.
    static func runIfArmed() async {
      guard isStarted == false, isArmed() else { return }
      log.notice("Transcript request armed")
      while Task.isCancelled == false {
        if let file = loadedFile, let coordinator = TranscriptComposition.coordinator,
          let database = DatabaseHardware.sharedIfAvailable(),
          let episode = try? await AdSkipComposition.makeLocalEpisodeReader(database: database)
            .localEpisodes().first(where: { $0.fileURL.standardizedFileURL == file.standardizedFileURL })
        {
          isStarted = true
          await measure(episode.identity, coordinator: coordinator)
          return
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }

    private static func measure(
      _ identity: AdSkipEpisodeIdentity, coordinator: EpisodeTranscriptCoordinator
    ) async {
      let recorder = AdSkipMeasurement.Recorder(
        log: .standard(), mode: mode,
        readDevice: { await AdSkipMeasurement.DeviceReading.current() })
      let before = await recorder.readDevice()
      let startMeter = ProcessMeter.read()
      let started = ContinuousClock.now
      let countsBefore = await coordinator.currentCounts()
      func wall() -> Double {
        let elapsed = ContinuousClock.now - started
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      }
      func covered(_ status: EpisodeTranscriptStatus) -> Double? {
        switch status {
        case .waiting(_, let covered), .generating(let covered), .stopped(let covered): covered
        case .complete: 1
        case .unavailable, .notStarted, .failed: nil
        }
      }

      let changes = await coordinator.statusChanges(of: identity)
      await coordinator.request(identity)
      log.notice("Transcript request made")
      let latest = LatestStatus()
      let sampler = Task {
        while Task.isCancelled == false {
          try? await Task.sleep(for: sampleInterval)
          guard Task.isCancelled == false else { return }
          var event = recorder.event(
            kind: "sample", outcome: "ok", detail: AdSkipMeasurement.Detail(), wall: wall(),
            cpu: ProcessMeter.read().cpuSeconds - startMeter.cpuSeconds,
            meter: ProcessMeter.read(), before: before, after: await recorder.readDevice())
          event.coveredSeconds = latest.status.flatMap(covered)
          recorder.log.append(event)
        }
      }
      var outcome = "stopped"
      for await status in changes {
        latest.status = status
        switch status {
        case .complete: outcome = "ok"
        case .failed: outcome = "failed"
        case .stopped, .unavailable: outcome = "stopped"
        case .notStarted, .waiting, .generating: continue
        }
        break
      }
      sampler.cancel()

      let counts = await coordinator.currentCounts()
      let words = (try? await coordinator.transcript(for: identity))?.words.count
      let end = ProcessMeter.read()
      var event = recorder.event(
        kind: "session", outcome: outcome,
        detail: AdSkipMeasurement.Detail(
          audioSeconds: (try? await coordinator.transcript(for: identity))?.duration),
        wall: wall(), cpu: end.cpuSeconds - startMeter.cpuSeconds, meter: end, before: before,
        after: await recorder.readDevice())
      event.coveredSeconds = latest.status.flatMap(covered)
      event.words = words
      event.sessions = counts.sessions - countsBefore.sessions
      event.holds = counts.holds - countsBefore.holds
      event.checkpoints = counts.checkpoints - countsBefore.checkpoints
      event.joinRepeats = counts.joinRepeatsDropped - countsBefore.joinRepeatsDropped
      event.thermalStateBefore = before.thermalState
      recorder.log.append(event)
      log.notice("Transcript request finished: \(outcome, privacy: .public)")
    }

    /// The last status seen, for the sampler.
    private final class LatestStatus: @unchecked Sendable {
      var status: EpisodeTranscriptStatus?
    }

    /// Forwards everything to the player's real source and reports each downloaded episode the
    /// player loads.
    nonisolated struct LoadedFileObserver: PlaybackSkipRangeSource {
      let base: any PlaybackSkipRangeSource
      let loaded: @Sendable (URL) -> Void

      func skipRanges(for request: PlaybackSkipRangeRequest) async -> [PlayerSkipRange] {
        if request.episodeID != nil, request.fileURL.isFileURL { loaded(request.fileURL) }
        return await base.skipRanges(for: request)
      }

      func skipRangeChanges() -> AsyncStream<Void> {
        base.skipRangeChanges()
      }

      func undoSkip(_ range: PlayerSkipRange, for request: PlaybackSkipRangeRequest) async {
        await base.undoSkip(range, for: request)
      }

      func analysisStatus(for request: PlaybackSkipRangeRequest) async -> PlaybackAdAnalysisStatus {
        await base.analysisStatus(for: request)
      }

      func analysisStatusChanges() -> AsyncStream<Void> {
        base.analysisStatusChanges()
      }

      func checkNow(for request: PlaybackSkipRangeRequest) async {
        await base.checkNow(for: request)
      }
    }
  }
#endif
