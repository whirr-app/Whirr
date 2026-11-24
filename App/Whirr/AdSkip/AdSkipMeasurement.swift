import CoreSupport

#if DEBUG
  import AdSkip
  import AppModel
  import Darwin
  import Foundation
  import Persistence
  import Synchronization
  import UIKit
  import os

  /// Debug-build timing of every decode, transcription, scoring pass, replan and recompute, one
  /// JSON line each in `Application Support/AdSkipMeasurements/measurements.jsonl` (copied off with
  /// `devicectl`). Numbers only: no episode, file name or text. Kept while the incremental-matching
  /// shadow check and store-expiry tuning run.
  nonisolated enum AdSkipMeasurement {
    /// Beside the ad-skip directory, not inside it: the transcript store's sweep removes files it
    /// does not know.
    static let directoryName = "AdSkipMeasurements"

    /// Runs the matching benchmark once at launch; for `devicectl device process launch`.
    static let matchBenchmarkKey = "com.remoteconcern.whirr.adSkipMatchBenchmark"

    private static let logger = CoreLogging.logger(category: "AdSkip")

    /// Upper bounds, in days, of `Event.storeMatchAgeCounts`' buckets but the last, which holds the
    /// rest. The store expires a creative unseen for 90 days, so 60 and 75 show what a shorter
    /// expiry would lose and a crowded last bucket what a longer one might keep.
    static let storeMatchAgeBounds: [Double] = [1, 7, 30, 60, 75]

    struct Event: Codable, Equatable, Sendable {
      var at: Date
      /// `launch`, `decode`, `transcribe`, `score`, `match`, `replan`, `recompute` or
      /// `replanMismatch`.
      var kind: String
      /// `S` (whole files) or `T` (audio-gated).
      var mode: String
      /// `ok`, `cancelled`, `deferred` or `failed`.
      var outcome: String
      /// Audio the unit read: the file for a decode, the windows for a transcription, every print
      /// for a match.
      var audioSeconds: Double?
      var steps: Int?
      var librarySize: Int?
      /// Stage-1 audio queries a `replan`, `recompute` or `replanMismatch` ran.
      var queries: Int?
      /// Candidates a `recompute` read, and rows it saved.
      var episodesRead: Int?
      var episodesSaved: Int?
      /// Kept episodes an incremental `replan` or `recompute` checked against an added print.
      var pairChecks: Int?
      /// Kept plans a `replanMismatch` found differing from a full query's.
      var windowMismatches: Int?
      /// Learned creatives a `recompute` matched, counted by the days each had gone unseen: under
      /// 1, 7, 30, 60 and 75 (`storeMatchAgeBounds`), then 75 or more.
      var storeMatchAgeCounts: [Int]?
      /// The longest any of them had gone unseen, in days.
      var storeMatchMaxAgeDays: Double?
      var wallSeconds: Double
      /// The process's CPU time over the unit, every thread, so concurrent work is included.
      var cpuSeconds: Double
      var footprintMB: Double
      /// The process's peak footprint so far, not the unit's.
      var peakFootprintMB: Double
      var batteryBefore: Float?
      var batteryAfter: Float?
      var isOnExternalPower: Bool?
      var thermalState: Int
      var isLowPowerModeEnabled: Bool
      /// Transcript lines only: the retired thermal soak run (mode `R`) and the transcript request
      /// trigger (`TranscriptDebugTrigger`, mode `T`), each a `session` line and periodic `sample`
      /// lines. Counts and seconds, never text.
      var variant: String?
      var leadSeconds: Double?
      var coveredSeconds: Double?
      var words: Int?
      var finals: Int?
      var holds: Int?
      var heldSeconds: Double?
      var rests: Int?
      var restedSeconds: Double?
      var stalls: Int?
      var maxLeadSeconds: Double?
      var thermalStateBefore: Int?
      var sessions: Int?
      var checkpoints: Int?
      var joinRepeats: Int?
    }

    struct DeviceReading: Sendable {
      /// Nil when the level is unknown.
      var batteryLevel: Float?
      var isOnExternalPower: Bool?
      var thermalState: Int
      var isLowPowerModeEnabled: Bool

      @MainActor
      static func current() -> DeviceReading {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let processInfo = ProcessInfo.processInfo
        return DeviceReading(
          batteryLevel: device.batteryLevel < 0 ? nil : device.batteryLevel,
          isOnExternalPower: device.batteryState == .unknown
            ? nil : device.batteryState == .charging || device.batteryState == .full,
          thermalState: processInfo.thermalState.rawValue,
          isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled)
      }
    }

    /// Appends lines; a write that fails is dropped, since measurement must never stop analysis.
    final class Log: Sendable {
      let fileURL: URL
      private let lock = Mutex(())

      init(fileURL: URL) {
        self.fileURL = fileURL
      }

      static func standard() -> Log {
        let directory = DatabaseHardware.applicationSupportDirectory()
          .appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Log(fileURL: directory.appendingPathComponent("measurements.jsonl"))
      }

      func append(_ event: Event) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let line = try? encoder.encode(event) else { return }
        lock.withLock { _ in
          if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
          }
          guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
          defer { try? handle.close() }
          _ = try? handle.seekToEnd()
          try? handle.write(contentsOf: line + Data("\n".utf8))
        }
      }
    }

    /// What a unit reports about itself once it has run.
    struct Detail: Sendable {
      var audioSeconds: Double?
      var steps: Int?
      var librarySize: Int?
      var queries: Int?
      var episodesRead: Int?
      var episodesSaved: Int?
      var pairChecks: Int?
      var windowMismatches: Int?
      var storeMatchAgeCounts: [Int]?
      var storeMatchMaxAgeDays: Double?
    }

    struct Recorder: Sendable {
      let log: Log
      let mode: String
      let readDevice: @Sendable () async -> DeviceReading

      static func standard(wholeFiles: Bool) -> Recorder {
        Recorder(
          log: .standard(), mode: wholeFiles ? "S" : "T",
          readDevice: { await DeviceReading.current() })
      }

      func recordLaunch() async {
        let device = await readDevice()
        let meter = ProcessMeter.read()
        log.append(
          event(
            kind: "launch", outcome: "ok", detail: Detail(), wall: 0, cpu: 0, meter: meter,
            before: device, after: device))
      }

      /// Runs `body`, logs it, and returns or rethrows its result. `detail` describes a failed
      /// unit, whose own detail never arrived.
      func measure<T: Sendable>(
        kind: String, detail: Detail = Detail(),
        _ body: () async throws -> (T, Detail)
      ) async throws -> T {
        let before = await readDevice()
        let start = ProcessMeter.read()
        let clock = ContinuousClock.now
        let outcome: Result<(T, Detail), Error>
        do {
          outcome = .success(try await body())
        } catch {
          outcome = .failure(error)
        }
        let wall = ContinuousClock.now - clock
        let end = ProcessMeter.read()
        let after = await readDevice()
        let label: String
        let reported: Detail
        switch outcome {
        case .success(let (_, unitDetail)):
          label = "ok"
          reported = unitDetail
        case .failure(let error):
          label =
            error is CancellationError
            ? "cancelled" : error is AdSkipAnalysisDeferred ? "deferred" : "failed"
          reported = detail
        }
        log.append(
          event(
            kind: kind, outcome: label, detail: reported,
            wall: Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18,
            cpu: end.cpuSeconds - start.cpuSeconds, meter: end, before: before, after: after))
        return try outcome.get().0
      }

      func event(
        kind: String, outcome: String, detail: Detail, wall: Double, cpu: Double,
        meter: ProcessMeter, before: DeviceReading, after: DeviceReading
      ) -> Event {
        Event(
          at: Date(), kind: kind, mode: mode, outcome: outcome, audioSeconds: detail.audioSeconds,
          steps: detail.steps, librarySize: detail.librarySize, queries: detail.queries,
          episodesRead: detail.episodesRead, episodesSaved: detail.episodesSaved,
          pairChecks: detail.pairChecks, windowMismatches: detail.windowMismatches,
          storeMatchAgeCounts: detail.storeMatchAgeCounts,
          storeMatchMaxAgeDays: detail.storeMatchMaxAgeDays, wallSeconds: wall, cpuSeconds: cpu,
          footprintMB: meter.footprintMB, peakFootprintMB: meter.peakFootprintMB,
          batteryBefore: before.batteryLevel, batteryAfter: after.batteryLevel,
          isOnExternalPower: after.isOnExternalPower, thermalState: after.thermalState,
          isLowPowerModeEnabled: after.isLowPowerModeEnabled)
      }
    }

    // MARK: - Adapters

    struct MeasuredAudioPrinter: AudioPrinting {
      let base: any AudioPrinting
      let recorder: Recorder

      func decode(fileAt url: URL) async throws -> DecodedAudio {
        try await recorder.measure(kind: "decode") {
          let decoded = try await base.decode(fileAt: url)
          return (decoded, Detail(audioSeconds: decoded.duration))
        }
      }
    }

    struct MeasuredTranscriber: EpisodeTranscribing {
      let base: any EpisodeTranscribing
      let recorder: Recorder

      func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
        let detail = Detail(audioSeconds: windows.reduce(0) { $0 + $1.duration })
        return try await recorder.measure(kind: "transcribe", detail: detail) {
          (try await base.transcript(ofFileAt: url, windows: windows), detail)
        }
      }
    }

    struct MeasuredScorer: AdStepScoring {
      let base: any AdStepScoring
      let recorder: Recorder

      func adProbabilities(forStepTexts texts: [String]) async throws -> [Double] {
        let detail = Detail(steps: texts.count)
        return try await recorder.measure(kind: "score", detail: detail) {
          (try await base.adProbabilities(forStepTexts: texts), detail)
        }
      }
    }

    /// The coordinator's own matching. A `replan` that ran no query and no pairwise check is not
    /// logged: most passes choose their next unit from plans already made.
    final class MeasuredMatching: AdSkipMatchingMeasuring {
      private struct Start: Sendable {
        let device: DeviceReading
        let meter: ProcessMeter
        let clock: ContinuousClock.Instant
      }

      let recorder: Recorder
      /// The worker runs one unit of each kind at a time; a recompute's own queries are counted in
      /// its line, never as a nested replan.
      private let starts = Mutex<[AdSkipMatchingUnit: Start]>([:])

      init(recorder: Recorder) {
        self.recorder = recorder
      }

      func willStart(_ unit: AdSkipMatchingUnit) async {
        let device = await recorder.readDevice()
        let start = Start(device: device, meter: ProcessMeter.read(), clock: .now)
        starts.withLock { $0[unit] = start }
      }

      func didFinish(_ unit: AdSkipMatchingUnit, _ detail: AdSkipMatchingDetail) async {
        guard let start = starts.withLock({ $0.removeValue(forKey: unit) }),
          unit == .recompute || detail.queries > 0 || (detail.pairChecks ?? 0) > 0
        else { return }
        let wall = ContinuousClock.now - start.clock
        let end = ProcessMeter.read()
        let after = await recorder.readDevice()
        let ageDays = detail.storeMatchAges?.map { $0 / 86_400 }
        recorder.log.append(
          recorder.event(
            kind: unit.rawValue, outcome: detail.succeeded ? "ok" : "failed",
            detail: Detail(
              librarySize: detail.librarySize, queries: detail.queries,
              episodesRead: detail.episodesRead, episodesSaved: detail.episodesSaved,
              pairChecks: detail.pairChecks, windowMismatches: detail.windowMismatches,
              storeMatchAgeCounts: ageDays.map(Self.bucketed), storeMatchMaxAgeDays: ageDays?.max()),
            wall: Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18,
            cpu: end.cpuSeconds - start.meter.cpuSeconds, meter: end, before: start.device,
            after: after))
      }

      private static func bucketed(_ days: [Double]) -> [Int] {
        let bounds = AdSkipMeasurement.storeMatchAgeBounds
        var counts = Array(repeating: 0, count: bounds.count + 1)
        for age in days { counts[bounds.firstIndex { age < $0 } ?? bounds.count] += 1 }
        return counts
      }
    }

    // MARK: - Matching benchmark

    /// Matches every stored audio print against the others, as the coordinator does once per change
    /// to the library, and logs one `match` line: the matching cost at this phone's library.
    static func runMatchBenchmark(
      transcripts: AdSkipTranscriptFileStore, recorder: Recorder
    ) async {
      // Every file is offered; `readAudioPrint` refuses any name that is not an audio print's.
      let names =
        (try? FileManager.default.contentsOfDirectory(atPath: transcripts.rootURL.path))?.sorted() ?? []
      let library = names.enumerated().compactMap { index, name -> AudioRecurrence.Reference? in
        guard let data = try? transcripts.readAudioPrint(fileName: name),
          let print = AudioPrint(littleEndianData: data)
        else { return nil }
        return AudioRecurrence.Reference(print: print, keys: [EpisodeKey("\(index)")])
      }
      let seconds = library.reduce(0) { $0 + Double($1.print.count) * AudioPrint.hopSeconds }
      let detail = Detail(audioSeconds: seconds, librarySize: library.count)
      _ = try? await recorder.measure(kind: "match", detail: detail) {
        await Task.detached(priority: .utility) {
          for query in library.indices { _ = AudioRecurrence.runs(of: query, in: library) }
        }.value
        return ((), detail)
      }
    }

    // MARK: - Reset

    /// Removes every analysed episode, its files and every learned ad, so a run in the other mode
    /// starts from nothing. Runs before the coordinator starts.
    static func resetAnalysis(
      episodes: AdSkipEpisodeStore, signatures: AdSignatureStore,
      transcripts: AdSkipTranscriptFileStore
    ) async throws {
      let rows = try await episodes.allEpisodes()
      let names = try await episodes.deleteEpisodes(rows.map(\.identity))
      transcripts.delete(fileNames: names)
      _ = try transcripts.sweep(keeping: [], modifiedBefore: .distantFuture)
      try await signatures.deleteAll()
      logger.notice("Ad-skip analysis reset for a new S/T mode")
    }
  }

  /// The process's CPU time and memory footprint, the figure iOS's memory limit is enforced on.
  nonisolated struct ProcessMeter {
    var cpuSeconds: Double
    var footprintMB: Double
    var peakFootprintMB: Double

    static func read() -> ProcessMeter {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      let cpu =
        Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      let megabyte = 1_048_576.0
      guard result == KERN_SUCCESS else { return ProcessMeter(cpuSeconds: cpu, footprintMB: 0, peakFootprintMB: 0) }
      return ProcessMeter(
        cpuSeconds: cpu, footprintMB: Double(info.phys_footprint) / megabyte,
        peakFootprintMB: Double(info.ledger_phys_footprint_peak) / megabyte)
    }
  }
#endif
