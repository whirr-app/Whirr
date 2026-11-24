#if DEBUG
  import AdSkip
  import AppModel
  import Foundation
  import Persistence
  import Testing

  @testable import Whirr

  /// The debug-only device measurement: one line per unit of work. The S/T switch is kept across
  /// launches, and a clean start follows whenever it flips.
  @Suite("Ad skip measurement")
  struct AdSkipMeasurementTests {

    private func isolatedDefaults() throws -> UserDefaults {
      let name = "AdSkipMeasurementTests-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      defaults.removePersistentDomain(forName: name)
      return defaults
    }

    private func temporaryDirectory() throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AdSkipMeasurementTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    private func recorder(logAt url: URL, mode: String = "T") -> AdSkipMeasurement.Recorder {
      AdSkipMeasurement.Recorder(
        log: AdSkipMeasurement.Log(fileURL: url), mode: mode,
        readDevice: {
          AdSkipMeasurement.DeviceReading(
            batteryLevel: 0.5, isOnExternalPower: false, thermalState: 0, isLowPowerModeEnabled: false)
        })
    }

    private func events(at url: URL) throws -> [AdSkipMeasurement.Event] {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try decoder.decode(AdSkipMeasurement.Event.self, from: Data($0.utf8))
      }
    }

    // MARK: - Switch

    @Test("no launch argument and nothing kept is audio-gated, unchanged")
    func defaultMode() throws {
      let defaults = try isolatedDefaults()
      let mode = AdSkipWholeFileSwitch.launchMode(argument: nil, in: defaults)
      #expect(mode.isOn == false)
      #expect(mode.hasChanged == false)
    }

    @Test("the launch argument turns whole files on, and is kept for a relaunch without it")
    func argumentIsKept() throws {
      let defaults = try isolatedDefaults()
      let first = AdSkipWholeFileSwitch.launchMode(argument: true, in: defaults)
      #expect(first.isOn && first.hasChanged)
      AdSkipWholeFileSwitch.record(first.isOn, in: defaults)

      let relaunch = AdSkipWholeFileSwitch.launchMode(argument: nil, in: defaults)
      #expect(relaunch.isOn && relaunch.hasChanged == false)

      let back = AdSkipWholeFileSwitch.launchMode(argument: false, in: defaults)
      #expect(back.isOn == false && back.hasChanged)
    }

    @Test("a mode not yet recorded still reads as changed on the next launch")
    func unrecordedModeStaysChanged() throws {
      let defaults = try isolatedDefaults()
      _ = AdSkipWholeFileSwitch.launchMode(argument: true, in: defaults)
      #expect(AdSkipWholeFileSwitch.launchMode(argument: true, in: defaults).hasChanged)
    }

    // MARK: - Recorder

    @Test("a decode is logged with its audio, mode and device reading")
    func decodeIsLogged() async throws {
      let url = try temporaryDirectory().appendingPathComponent("m.jsonl")
      let printer = AdSkipMeasurement.MeasuredAudioPrinter(
        base: StubPrinter(duration: 1_800), recorder: recorder(logAt: url, mode: "S"))

      let decoded = try await printer.decode(fileAt: URL(filePath: "/dev/null"))

      #expect(decoded.duration == 1_800)
      let logged = try events(at: url)
      #expect(logged.count == 1)
      #expect(logged.first?.kind == "decode")
      #expect(logged.first?.mode == "S")
      #expect(logged.first?.outcome == "ok")
      #expect(logged.first?.audioSeconds == 1_800)
      #expect(logged.first?.batteryBefore == 0.5)
      #expect(logged.first?.batteryAfter == 0.5)
      #expect((logged.first?.footprintMB ?? 0) > 0)
    }

    @Test("a transcription counts its windows' seconds")
    func transcriptionCountsWindows() async throws {
      let url = try temporaryDirectory().appendingPathComponent("m.jsonl")
      let transcriber = AdSkipMeasurement.MeasuredTranscriber(
        base: StubTranscriber(), recorder: recorder(logAt: url))

      _ = try await transcriber.transcript(
        ofFileAt: URL(filePath: "/dev/null"),
        windows: [TimeSpan(start: 10, end: 40), TimeSpan(start: 100, end: 160)])

      let logged = try events(at: url)
      #expect(logged.map(\.kind) == ["transcribe"])
      #expect(logged.first?.audioSeconds == 90)
    }

    @Test("a scoring pass counts its steps")
    func scoringCountsSteps() async throws {
      let url = try temporaryDirectory().appendingPathComponent("m.jsonl")
      let scorer = AdSkipMeasurement.MeasuredScorer(base: StubScorer(), recorder: recorder(logAt: url))

      _ = try await scorer.adProbabilities(forStepTexts: ["a", "b", "c"])

      #expect(try events(at: url).first?.steps == 3)
    }

    @Test("a cancelled or deferred unit is logged as such and still throws")
    func failuresAreLoggedAndRethrown() async throws {
      let url = try temporaryDirectory().appendingPathComponent("m.jsonl")
      let recorder = recorder(logAt: url)

      await #expect(throws: CancellationError.self) {
        try await AdSkipMeasurement.MeasuredTranscriber(
          base: StubTranscriber(error: CancellationError()), recorder: recorder
        ).transcript(ofFileAt: URL(filePath: "/dev/null"), windows: [])
      }
      await #expect(throws: AdSkipAnalysisDeferred.self) {
        try await AdSkipMeasurement.MeasuredTranscriber(
          base: StubTranscriber(error: AdSkipAnalysisDeferred()), recorder: recorder
        ).transcript(ofFileAt: URL(filePath: "/dev/null"), windows: [])
      }

      #expect(try events(at: url).map(\.outcome) == ["cancelled", "deferred"])
    }

    @Test("the matching benchmark matches every stored print and logs the library size")
    func matchingBenchmark() async throws {
      let directory = try temporaryDirectory()
      let store = try AdSkipTranscriptFileStore(rootURL: directory, fileAttributes: POSIXFileAttributeApplier())
      for seed in 0..<3 {
        let words = (0..<4_000).map { UInt32(truncatingIfNeeded: ($0 &* 2_654_435_761) ^ seed) }
        _ = try store.writeAudioPrint(littleEndianWords: AudioPrint(words: words).data)
      }
      let url = directory.appendingPathComponent("m.jsonl")

      await AdSkipMeasurement.runMatchBenchmark(transcripts: store, recorder: recorder(logAt: url))

      let logged = try events(at: url)
      #expect(logged.map(\.kind) == ["match"])
      #expect(logged.first?.librarySize == 3)
      #expect(abs((logged.first?.audioSeconds ?? 0) - 3 * 4_000 * AudioPrint.hopSeconds) < 0.001)
    }

    @Test("a recompute is logged with its counts, and a replan only when it ran a query or check")
    func matchingIsLogged() async throws {
      let url = try temporaryDirectory().appendingPathComponent("m.jsonl")
      let matching = AdSkipMeasurement.MeasuredMatching(recorder: recorder(logAt: url))

      await matching.willStart(.replan)
      await matching.didFinish(.replan, AdSkipMatchingDetail(queries: 0))
      await matching.willStart(.replan)
      await matching.didFinish(.replan, AdSkipMatchingDetail(queries: 9, librarySize: 11))
      await matching.willStart(.recompute)
      await matching.didFinish(
        .recompute,
        AdSkipMatchingDetail(queries: 1, librarySize: 11, episodesRead: 9, episodesSaved: 8))
      await matching.willStart(.recompute)
      await matching.didFinish(.recompute, AdSkipMatchingDetail(queries: 0, succeeded: false))
      await matching.willStart(.replan)
      await matching.didFinish(.replan, AdSkipMatchingDetail(queries: 0, pairChecks: 10))
      await matching.willStart(.replanMismatch)
      await matching.didFinish(
        .replanMismatch, AdSkipMatchingDetail(queries: 10, librarySize: 12, windowMismatches: 0))

      let logged = try events(at: url)
      #expect(logged.map(\.kind) == ["replan", "recompute", "recompute", "replan", "replanMismatch"])
      #expect(logged.map(\.outcome) == ["ok", "ok", "failed", "ok", "ok"])
      #expect(logged.map(\.queries) == [9, 1, 0, 0, 10])
      #expect(logged.first?.librarySize == 11)
      #expect(logged[1].episodesRead == 9)
      #expect(logged[1].episodesSaved == 8)
      #expect(logged[3].pairChecks == 10)
      #expect(logged[4].windowMismatches == 0)
    }

    @Test("a recompute logs how long its matched creatives went unseen, in day buckets")
    func storeMatchAgesAreLogged() async throws {
      let url = try temporaryDirectory().appendingPathComponent("m.jsonl")
      let matching = AdSkipMeasurement.MeasuredMatching(recorder: recorder(logAt: url))
      let day = 86_400.0

      await matching.willStart(.recompute)
      await matching.didFinish(
        .recompute,
        AdSkipMatchingDetail(
          queries: 0, storeMatchAges: [0, 0.5 * day, day, 6 * day, 45 * day, 75 * day, 89.5 * day]))
      await matching.willStart(.recompute)
      await matching.didFinish(.recompute, AdSkipMatchingDetail(queries: 0, storeMatchAges: []))
      await matching.willStart(.recompute)
      await matching.didFinish(.recompute, AdSkipMatchingDetail(queries: 0, succeeded: false))

      let logged = try events(at: url)
      #expect(logged.map(\.storeMatchAgeCounts) == [[2, 2, 0, 1, 0, 2], [0, 0, 0, 0, 0, 0], nil])
      #expect(logged.map(\.storeMatchMaxAgeDays) == [89.5, nil, nil])
    }

    // MARK: - Reset

    @Test("a reset removes every analysed episode, its files and the learned ads")
    func resetClearsAnalysis() async throws {
      let database = try AppDatabase.inMemory()
      let episodes = AdSkipEpisodeStore(database: database)
      let signatures = AdSignatureStore(database: database)
      let directory = try temporaryDirectory()
      let transcripts = try AdSkipTranscriptFileStore(rootURL: directory, fileAttributes: POSIXFileAttributeApplier())
      let transcript = try transcripts.write(
        StoredTranscript(words: [], silences: [], duration: 60, coverage: []))
      let print = try transcripts.writeAudioPrint(littleEndianWords: AudioPrint(words: [1, 2]).data)
      _ = try await episodes.save(
        AdSkipEpisodeRecord(
          source: .rss, accountId: nil, itemID: "rss:1", episodeID: "guid-1", fileByteSize: 1,
          fileModificationTime: 1, transcriberRevision: "t", rulesRevision: 1, state: .decoded,
          transcriptFileName: transcript, analysedAt: Date(), audioPrintFileName: print),
        ranges: [])

      try await AdSkipMeasurement.resetAnalysis(
        episodes: episodes, signatures: signatures, transcripts: transcripts)

      #expect(try await episodes.allEpisodes().isEmpty)
      #expect(try await signatures.allCreatives().isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }

  // MARK: - Stubs

  private struct StubPrinter: AudioPrinting {
    let duration: Double

    func decode(fileAt url: URL) async throws -> DecodedAudio {
      DecodedAudio(silences: [], audioPrint: AudioPrint(words: [1]), duration: duration)
    }
  }

  private struct StubTranscriber: EpisodeTranscribing {
    var error: (any Error & Sendable)?

    func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
      if let error { throw error }
      return Transcript(words: [], duration: 600)
    }
  }

  private struct StubScorer: AdStepScoring {
    func adProbabilities(forStepTexts texts: [String]) async throws -> [Double] {
      texts.map { _ in 0 }
    }
  }
#endif
