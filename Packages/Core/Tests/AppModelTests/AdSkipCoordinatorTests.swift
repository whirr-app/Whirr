import AdSkip
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `AdSkipCoordinator`: arrival and removal from the local-episode
/// set, the analysis queue, recompute, learning, and setting-off cleanup.
@Suite struct AdSkipCoordinatorTests {

  // MARK: - Synthetic audio

  /// Words 0.5 s apart, 0.4 s long, so a sequence is one segment and 40 words span 19.9 s.
  static func transcript(_ words: [String]) -> Transcript {
    Transcript(
      words: words.enumerated().map {
        TranscriptWord(text: $1, start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4)
      },
      duration: Double(words.count) * 0.5)
  }

  static func programme(_ tag: String, count: Int = 60) -> [String] {
    (0..<count).map { "\(tag)w\($0)" }
  }

  static let ad = (0..<40).map { "acmead\($0)" }

  /// 60 programme words, the ad from 30.0 s to 49.9 s, 60 more programme words.
  static func withAd(_ tag: String) -> Transcript {
    transcript(programme(tag) + ad + programme(tag + "x"))
  }

  // MARK: - Harness

  final class FakeTranscriber: EpisodeTranscribing {
    let results = Mutex<[URL: Result<Transcript, any Error>]>([:])
    let calls = Mutex<[URL]>([])
    /// The windows of each call, in call order.
    let windowCalls = Mutex<[[TimeSpan]]>([])
    /// When set, transcription of that URL waits until `release()`.
    let heldURL = Mutex<URL?>(nil)
    /// A held call runs to completion regardless of cancellation, as real transcription does.
    let gate = TestGate<Void>(label: "FakeTranscriber transcription", ignoresCancellation: true)
    /// What a held call throws on finding itself cancelled, as a framework that reports its own
    /// error for an interrupted run does; `CancellationError` when nil.
    let errorWhenCancelled = Mutex<(any Error)?>(nil)

    func set(_ url: URL, _ result: Result<Transcript, any Error>) {
      results.withLock { $0[url] = result }
    }

    func hold(_ url: URL) {
      heldURL.withLock { $0 = url }
      gate.hold()
    }

    func release() { release(thenHold: nil) }

    /// Releases the held call and holds the next call for `url`, in one step, so that call cannot
    /// slip through between the two.
    func release(thenHold url: URL?) {
      heldURL.withLock { $0 = url }
      if url == nil { gate.release() } else { gate.releaseParked() }
    }

    var holding: Bool { gate.parkedCount > 0 }

    func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
      calls.withLock { $0.append(url) }
      windowCalls.withLock { $0.append(windows) }
      if heldURL.withLock({ $0 == url }) {
        await gate.pass()
        if Task.isCancelled, let error = errorWhenCancelled.withLock({ $0 }) { throw error }
        try Task.checkCancellation()
      }
      guard let result = results.withLock({ $0[url] }) else { throw Unexpected() }
      let whole = try result.get()
      // The adapter's contract: each window's words by the slice rule, in time order.
      let words = windows.flatMap { TranscriptionWindows.words(whole.words, keptBy: $0) }
        .sorted { $0.start < $1.start }
      return Transcript(words: words, duration: whole.duration)
    }

    func fullTranscript(_ url: URL) -> Transcript? {
      results.withLock { try? $0[url]?.get() }
    }
  }

  struct Unexpected: Error {}

  /// Decodes a file into its silences and a synthetic audio print drawn from the transcript the
  /// transcriber holds for it: a word's frames are a pure function of its text and the frame's
  /// offset into it, and frames outside any word are noise unique to the file. So audio recurs
  /// exactly where words do, as an ad's would.
  final class FakeAudioPrinter: AudioPrinting {
    let transcriber: FakeTranscriber
    let silencesByURL = Mutex<[URL: [Silence]]>([:])
    let failures = Mutex<[URL: any Error]>([:])
    /// Sound with no speech (music, say) that the print hears and the transcriber does not.
    let unspoken = Mutex<[URL: [TranscriptWord]]>([:])
    let calls = Mutex<[URL]>([])
    /// When set, decoding that URL waits until `release()`.
    let heldURL = Mutex<URL?>(nil)
    /// A held call runs to completion regardless of cancellation.
    let gate = TestGate<Void>(label: "FakeAudioPrinter decode", ignoresCancellation: true)

    init(transcriber: FakeTranscriber) {
      self.transcriber = transcriber
    }

    func set(_ url: URL, _ silences: [Silence]) { silencesByURL.withLock { $0[url] = silences } }

    func fail(_ url: URL, _ error: (any Error)?) { failures.withLock { $0[url] = error } }

    func hold(_ url: URL) {
      heldURL.withLock { $0 = url }
      gate.hold()
    }

    func release() {
      heldURL.withLock { $0 = nil }
      gate.release()
    }

    var holding: Bool { gate.parkedCount > 0 }

    func decode(fileAt url: URL) async throws -> DecodedAudio {
      calls.withLock { $0.append(url) }
      if heldURL.withLock({ $0 == url }) {
        await gate.pass()
        try Task.checkCancellation()
      }
      if let error = failures.withLock({ $0[url] }) { throw error }
      let silent = unspoken.withLock { $0[url] ?? [] }
      let spoken =
        transcriber.fullTranscript(url)
        ?? Transcript(words: [], duration: max(60, (silent.map(\.end).max() ?? 0) + 0.1))
      let transcript = Transcript(words: spoken.words + silent, duration: spoken.duration)
      return DecodedAudio(
        silences: silencesByURL.withLock { $0[url] ?? [] },
        audioPrint: Self.audioPrint(of: transcript, noise: Self.mix(UInt64(Self.fnv(url.path)))),
        duration: transcript.duration)
    }

    static func audioPrint(of transcript: Transcript, noise: UInt64) -> AudioPrint {
      let samples = Int(transcript.duration * Double(AudioPrint.sampleRate))
      let frames = max(0, (samples - AudioPrint.frameLength) / AudioPrint.hopLength - 1)
      let words = transcript.words.sorted { $0.start < $1.start }
      var next = 0
      var words32: [UInt32] = []
      words32.reserveCapacity(frames)
      for frame in 0..<frames {
        let time = AudioPrint.time(ofFrame: frame)
        while next + 1 < words.count && words[next + 1].start <= time { next += 1 }
        if let word = words.indices.contains(next) ? words[next] : nil,
          word.start <= time && time < word.end + 0.1
        {
          let offset = frame - AudioPrint.frame(atTime: word.start)
          words32.append(UInt32(truncatingIfNeeded: mix(fnv(word.text) &+ UInt64(bitPattern: Int64(offset)))))
        } else {
          words32.append(UInt32(truncatingIfNeeded: mix(noise &+ UInt64(frame))))
        }
      }
      return AudioPrint(words: words32)
    }

    static func fnv(_ text: String) -> UInt64 {
      text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    static func mix(_ value: UInt64) -> UInt64 {
      var z = value &+ 0x9E37_79B9_7F4A_7C15
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  final class FakeScorer: AdStepScoring {
    let probability = Mutex(0.9)
    /// When set, scores each step's text in place of `probability`.
    let perStep = Mutex<(@Sendable (String) -> Double)?>(nil)
    let scoredSteps = Mutex(0)
    /// Thrown by the next call, once.
    let failure = Mutex<(any Error)?>(nil)
    func adProbabilities(forStepTexts texts: [String]) async throws -> [Double] {
      if let error = failure.withLock({ state -> (any Error)? in
        defer { state = nil }
        return state
      }) {
        throw error
      }
      scoredSteps.withLock { $0 += texts.count }
      let p = probability.withLock { $0 }
      let rule = perStep.withLock { $0 }
      return texts.map { rule?($0) ?? p }
    }
  }

  final class FakeFingerprints: AdSkipFileFingerprinting {
    let values = Mutex<[URL: AdSkipFileFingerprint]>([:])
    func fingerprint(ofFileAt url: URL) -> AdSkipFileFingerprint? { values.withLock { $0[url] } }
    func set(_ url: URL, size: Int64) {
      values.withLock { $0[url] = AdSkipFileFingerprint(byteSize: size, modificationTime: 1_000) }
    }
  }

  final class Clock: Sendable {
    let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { value.withLock { $0 } }
    func advance(days: Double) { value.withLock { $0 += days * 86_400 } }
  }

  struct Harness {
    let coordinator: AdSkipCoordinator
    let database: AppDatabase
    let episodes: AdSkipEpisodeStore
    let signatures: AdSignatureStore
    let transcripts: AdSkipTranscriptFileStore
    let transcriber = FakeTranscriber()
    let audio: FakeAudioPrinter
    let scorer: FakeScorer
    let fingerprints: FakeFingerprints
    let clock: Clock
    let root: URL
    /// The listener's transcripts: none until a test sets one.
    let listener: FakeListenerTranscripts

    init(
      transcriberRevision: String = "t1", reusing other: Harness? = nil, wholeFiles: Bool = false,
      measurement: (any AdSkipMatchingMeasuring)? = nil, incremental: Bool = true,
      readsListenerTranscripts: Bool = true
    ) throws {
      listener = other?.listener ?? FakeListenerTranscripts()
      audio = FakeAudioPrinter(transcriber: transcriber)
      // A restarted coordinator reuses the first harness's stores, database and files.
      database = try other?.database ?? AppDatabase.inMemory()
      root =
        other?.root
        ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("AdSkipCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
      episodes = other?.episodes ?? AdSkipEpisodeStore(database: database)
      signatures = other?.signatures ?? AdSignatureStore(database: database)
      transcripts =
        try other?.transcripts
        ?? AdSkipTranscriptFileStore(
          rootURL: root.appendingPathComponent("AdSkip"), fileAttributes: POSIXFileAttributeApplier())
      scorer = other?.scorer ?? FakeScorer()
      fingerprints = other?.fingerprints ?? FakeFingerprints()
      clock = other?.clock ?? Clock()
      let clock = clock
      coordinator = AdSkipCoordinator(
        dependencies: .init(
          episodes: episodes, signatures: signatures, transcripts: transcripts,
          transcriber: transcriber, audioPrinter: audio, scorer: scorer,
          fingerprinting: fingerprints, transcriberRevision: transcriberRevision,
          transcribesWholeFiles: wholeFiles, matchingMeasurement: measurement,
          replansIncrementally: incremental,
          listenerTranscripts: readsListenerTranscripts ? listener : nil, now: { clock.now() }))
    }

    func episode(
      _ id: String, transcript: Transcript? = nil, size: Int64? = nil, language: String? = nil,
      source: AdSkipEpisodeSource = .rss, linked: [AdSkipEpisodeIdentity] = [],
      show: String = "rss:1", showTitle: String? = nil
    ) -> AdSkipLocalEpisode {
      let url = root.appendingPathComponent("audio/\(source)-\(id).mp3")
      if let transcript { transcriber.set(url, .success(transcript)) }
      // Distinct by default: equal fingerprints mark two files as copies of one episode.
      fingerprints.set(url, size: size ?? 1_000 + Int64(url.path.utf8.reduce(0) { $0 &* 31 &+ Int($1) } & 0xFFFF))
      return AdSkipLocalEpisode(
        identity: Self.identity(id, source: source, show: show), fileURL: url, languageTag: language,
        showTitle: showTitle, linkedIdentities: linked)
    }

    /// An RSS episode of `show`, or of the Audiobookshelf podcast "show".
    static func identity(
      _ id: String, source: AdSkipEpisodeSource = .rss, show: String = "rss:1"
    ) -> AdSkipEpisodeIdentity {
      switch source {
      case .rss: AdSkipEpisodeIdentity(source: .rss, accountId: nil, itemID: show, episodeID: id)
      case .abs: AdSkipEpisodeIdentity(source: .abs, accountId: 7, itemID: "show", episodeID: id)
      }
    }

    func run(
      _ episodes: [AdSkipLocalEpisode], enabled: Bool = true, allowed: Bool = true
    ) async {
      await coordinator.setLocalEpisodes(episodes)
      await coordinator.setAllowed(allowed)
      await coordinator.setEnabled(enabled)
      await coordinator.waitUntilIdle()
    }

    func ranges(
      _ id: String, source: AdSkipEpisodeSource = .rss, show: String = "rss:1"
    ) async throws -> [AdSkipRange] {
      guard
        let row = try await episodes.episode(for: Self.identity(id, source: source, show: show)),
        let rowId = row.id
      else { return [] }
      return try await episodes.ranges(forEpisodeId: rowId)
    }

    func transcriptFiles() -> [String] {
      files().filter { $0.hasSuffix(".words") }
    }

    func audioPrintFiles() -> [String] {
      files().filter { $0.hasSuffix(".aprint") }
    }

    func files() -> [String] {
      (try? FileManager.default.contentsOfDirectory(atPath: transcripts.rootURL.path)) ?? []
    }
  }

  // MARK: - Arrival and the setting

  @Test func nothingIsAnalysedWhileTheSettingIsOff() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: Self.withAd("a"))], enabled: false)
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
    #expect(try await harness.episodes.allEpisodes().isEmpty)
  }

  @Test func nothingIsAnalysedUntilAnalysisIsAllowed() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    await harness.run([a], allowed: false)
    #expect(try await harness.episodes.allEpisodes().isEmpty)

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed])
  }

  @Test func aSkipRunsOnToAPauseShortlyAfterTheMatchedAd() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    // Programme words continue after the ad, so only the playback edge reaches this pause.
    harness.audio.set(a.fileURL, [Silence(start: 53, end: 53.4)])
    await harness.run([a, harness.episode("b", transcript: Self.withAd("b"))])

    // The served end then takes in the whole pause.
    #expect(try await harness.ranges("a").map { abs($0.endTime - 53.4) < 1e-9 } == [true])
    #expect(try await harness.ranges("b").map { abs($0.endTime - 49.9) < 1e-9 } == [true])
    // What is learned is still the matched ad alone.
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.allSatisfy { $0.hashes.count == 33 })
  }

  @Test func aSkipBridgesTheSilencesAroundTheMatchedAd() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    // A stitch gap before the ad and one after it, each inside the 0.1 s between two words. The
    // repetition stage reaches the end of the first and the start of the second; the served range
    // covers both whole.
    harness.audio.set(a.fileURL, [Silence(start: 29.92, end: 29.98), Silence(start: 49.93, end: 49.97)])
    await harness.run([a, harness.episode("b", transcript: Self.withAd("b"))])

    let ranges = try await harness.ranges("a")
    #expect(ranges.map { abs($0.startTime - 29.92) < 1e-9 } == [true])
    #expect(ranges.map { abs($0.endTime - 49.97) < 1e-9 } == [true])
    // What is learned is still the matched ad alone.
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.allSatisfy { $0.hashes.count == 33 })
  }

  @Test func anAdHeardInTwoEpisodesIsSkippedInBothAndLearned() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.withAd("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ])

    for id in ["a", "b"] {
      let ranges = try await harness.ranges(id)
      #expect(ranges.count == 1)
      #expect(ranges.first?.startTime == 30.0)
      #expect(ranges.first.map { abs($0.endTime - 49.9) < 1e-9 } == true)
      #expect(ranges.first?.endsItem == false)
      #expect(ranges.first?.rulesRevision == AdSkipRules.revision)
    }
    // Each episode is its own group and teaches the ad; the store holds it once, taught by both.
    let creatives = try await harness.signatures.allCreatives()
    #expect(creatives.count == 1)
    #expect(creatives.first?.teachers.count == 2)
    #expect(creatives.allSatisfy { $0.kind == .learned && $0.hashes.count == 33 })
    #expect(harness.transcriptFiles().count == 2)
  }

  @Test func programmeHeardOnlyOnceIsNotSkipped() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.transcript(Self.programme("a", count: 120))),
      harness.episode("b", transcript: Self.withAd("b")),
    ])
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  @Test func theClassifierVetoesALowScoringRepeatAndNothingIsLearned() async throws {
    let harness = try Harness()
    harness.scorer.probability.withLock { $0 = 0.01 }
    await harness.run([
      harness.episode("a", transcript: Self.withAd("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ])
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
  }

  @Test func copiesOfOneEpisodeNeverMatchEachOther() async throws {
    let harness = try Harness()
    let abs = Harness.identity("a", source: .abs)
    await harness.run([
      harness.episode("a", transcript: Self.withAd("a"), linked: [abs]),
      harness.episode("a", transcript: Self.withAd("a"), size: 2_000, source: .abs),
    ])
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("a", source: .abs).isEmpty)
  }

  @Test func filesWithEqualFingerprintsAreCopiesOfOneEpisode() async throws {
    let harness = try Harness()
    await harness.run([
      harness.episode("a", transcript: Self.withAd("a"), size: 4_000),
      harness.episode("b", transcript: Self.withAd("b"), size: 4_000),
    ])
    #expect(try await harness.ranges("a").isEmpty)
    #expect(try await harness.ranges("b").isEmpty)
  }

  @Test func theLearnedAdKeepsSkippingAfterTheEpisodeThatTaughtItIsGone() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.episodes.episode(for: Harness.identity("a")) == nil)
    #expect(harness.transcriptFiles().count == 1)
    let ranges = try await harness.ranges("b")
    #expect(ranges.count == 1)
    #expect(ranges.first?.fromStore == true)
    let creatives = try await harness.signatures.allCreatives()
    #expect(ranges.first?.creativeId.map { id in creatives.contains { $0.id == id } } == true)
  }

  @Test func aNewEpisodeMatchesTheStoreAlone() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let c = harness.episode("c", transcript: Self.withAd("c"))
    await harness.coordinator.setLocalEpisodes([c])
    await harness.coordinator.waitUntilIdle()

    let ranges = try await harness.ranges("c")
    #expect(ranges.count == 1)
    #expect(ranges.first?.fromStore == true)
  }

  @Test func recomputeKeepsLearnedCreativesStable() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let before = try await harness.signatures.allCreatives().map(\.id).sorted()

    let c = harness.episode("c", transcript: Self.transcript(Self.programme("c", count: 120)))
    await harness.coordinator.setLocalEpisodes([a, b, c])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.signatures.allCreatives().map(\.id).sorted() == before)
  }

  @Test func turningTheSettingOffKeepsTranscriptsRangesAndTheStore() async throws {
    let harness = try Harness()
    let episodes = [
      harness.episode("a", transcript: Self.withAd("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ]
    await harness.run(episodes)
    let hashes = try await harness.signatures.hashCount()
    #expect(hashes > 0)

    await harness.coordinator.setEnabled(false)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed, .analysed])
    #expect(try await harness.ranges("b").count == 1)
    #expect(try await harness.signatures.hashCount() == hashes)
    #expect(harness.transcriptFiles().count == 2)
  }

  @Test func turningTheSettingBackOnServesKeptRangesWithoutTranscribingAgain() async throws {
    let harness = try Harness()
    let episodes = [
      harness.episode("a", transcript: Self.withAd("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ]
    await harness.run(episodes)
    let transcriptions = harness.transcriber.calls.withLock { $0.count }
    await harness.coordinator.setEnabled(false)
    await harness.coordinator.waitUntilIdle()

    await harness.coordinator.setEnabled(true)
    await harness.coordinator.waitUntilIdle()
    #expect(harness.transcriber.calls.withLock { $0.count } == transcriptions)
    #expect(harness.audio.calls.withLock { $0.count } == 2)
    #expect(try await harness.ranges("b").count == 1)
  }

  @Test func aLaunchWithTheSettingOffKeepsWhatWasLearned() async throws {
    let harness = try Harness()
    let episodes = [
      harness.episode("a", transcript: Self.withAd("a")),
      harness.episode("b", transcript: Self.withAd("b")),
    ]
    await harness.run(episodes)

    let restarted = try Harness(reusing: harness)
    await restarted.run(episodes, enabled: false)
    #expect(try await restarted.episodes.allEpisodes().count == 2)
    #expect(try await restarted.signatures.hashCount() > 0)
    #expect(restarted.transcriptFiles().count == 2)
  }

  @Test func aDownloadRemovedWhileTheSettingIsOffTakesItsDataWithIt() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    await harness.coordinator.setEnabled(false)
    await harness.coordinator.waitUntilIdle()

    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().map(\.identity) == [b.identity])
    #expect(harness.transcriptFiles().count == 1)
  }

  @Test func forgettingLearnedAdsWorksWhileTheSettingIsOff() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").count == 1)
    let transcriptions = harness.transcriber.calls.withLock { $0.count }
    await harness.coordinator.setEnabled(false)
    await harness.coordinator.waitUntilIdle()

    await harness.coordinator.forgetLearnedAds()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.signatures.allCreatives().isEmpty)
    #expect(harness.transcriptFiles().count == 1)

    // Ranges that came only from the store go once the setting is back on.
    await harness.coordinator.setEnabled(true)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)
    #expect(harness.transcriber.calls.withLock { $0.count } == transcriptions)
  }

  @Test func forgetLearnedAdsClearsTheStoreAndItsRanges() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").count == 1)

    await harness.coordinator.forgetLearnedAds()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)
    #expect(try await harness.signatures.allCreatives().isEmpty)
    // The transcript stays: forgetting the store is not forgetting the episode.
    #expect(harness.transcriptFiles().count == 1)
  }

  /// A backup restore writes the store behind the coordinator: told, it applies the new ads.
  @Test func learnedAdsRestoredFromABackupAreApplied() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()
    let learned = try await harness.signatures.allCreatives().filter { $0.kind == .learned }
    let prints = Dictionary(
      uniqueKeysWithValues: try await harness.signatures.learnedAudioPrints().map { ($0.id, $0.audioPrint) })
    #expect(learned.isEmpty == false)
    await harness.coordinator.forgetLearnedAds()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)

    _ = try await harness.signatures.apply(
      AdSignatureStoreChange(
        insertions: learned.map {
          NewAdSignatureCreative(
            kind: .learned, lastSeen: $0.lastSeen, startTime: $0.startTime, endTime: $0.endTime,
            teachers: $0.teachers, hashes: $0.hashes, audioPrint: prints[$0.id])
        }))
    await harness.coordinator.learnedAdsRestored()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").count == 1)
  }

  @Test func aCreativeUnseenForNinetyDaysExpires() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    harness.clock.advance(days: 91)
    await harness.coordinator.setLocalEpisodes([b])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.ranges("b").isEmpty)
  }

  // MARK: - Draining the backlog

  /// The overnight task can launch the process cold and ask before any input has arrived; it
  /// must not see an idle worker and finish with the backlog untouched.
  @Test func drainingWaitsForEveryInputThenAnalysesTheBacklog() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    let coordinator = harness.coordinator
    let drain = Task { await coordinator.drainBacklog() }

    await coordinator.setLocalEpisodes([a, b])
    await coordinator.setEnabled(true)
    await coordinator.setAllowed(true)
    await drain.value

    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed, .analysed])
    #expect(try await harness.ranges("a").count == 1)
  }

  @Test func drainingWaitsForTheFirstAllowedSignal() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.setLocalEpisodes([harness.episode("a", transcript: Self.withAd("a"))])
    await coordinator.setEnabled(true)
    let drain = Task { await coordinator.drainBacklog() }

    await coordinator.setAllowed(true)
    await drain.value

    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed])
  }

  @Test func drainingReturnsWithoutAnalysisWhileTheSettingIsOff() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: Self.withAd("a"))], enabled: false)
    await harness.coordinator.drainBacklog()
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
  }

  @Test func drainingReturnsWhenAnalysisIsNotAllowed() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: Self.withAd("a"))], allowed: false)
    await harness.coordinator.drainBacklog()
    #expect(try await harness.episodes.allEpisodes().isEmpty)
  }

  @Test func stoppingReleasesADrainStillWaitingForInputs() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    let drain = Task { await coordinator.drainBacklog() }
    await coordinator.stop()
    await drain.value
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
  }

  // MARK: - Language

  @Test func aShowTaggedAnotherLanguageIsNeverAnalysed() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: Self.withAd("a"), language: "fr")])
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
  }

  @Test func aShowRetaggedToAnotherLanguageLosesItsAnalysis() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a", transcript: Self.withAd("a"), language: "en-GB")])
    #expect(try await harness.episodes.allEpisodes().count == 1)

    await harness.coordinator.setLocalEpisodes([
      harness.episode("a", transcript: Self.withAd("a"), language: "de")
    ])
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().isEmpty)
    #expect(harness.transcriptFiles().isEmpty)
  }

  // MARK: - Failures and revisions

  @Test func aFailedFileIsRecordedAndRetriedOnlyUnderANewTranscriber() async throws {
    let harness = try Harness()
    let a = harness.episode("a")
    harness.audio.fail(a.fileURL, Unexpected())
    await harness.run([a])
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.failed])

    // Another pass with the same transcriber does not retry.
    await harness.coordinator.prioritize(a.identity)
    await harness.coordinator.waitUntilIdle()
    #expect(harness.audio.calls.withLock { $0.count } == 1)

    let upgraded = try Harness(transcriberRevision: "t2", reusing: harness)
    upgraded.transcriber.set(a.fileURL, .success(Self.withAd("a")))
    await upgraded.run([a])
    #expect(try await upgraded.episodes.allEpisodes().map(\.state) == [.analysed])
  }

  @Test func aFailedEpisodeDoesNotStallTheQueue() async throws {
    let harness = try Harness()
    let a = harness.episode("a")
    harness.audio.fail(a.fileURL, Unexpected())
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let states = try await harness.episodes.allEpisodes().map { ($0.episodeID, $0.state) }
    #expect(states.sorted { $0.0 < $1.0 }.map(\.1) == [.failed, .analysed])
  }

  @Test func aDeferralStillRunsTheRecomputeThatWasDue() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    let c = harness.episode("c")
    harness.transcriber.set(c.fileURL, .failure(AdSkipAnalysisDeferred()))
    await harness.run([a, b, c])
    #expect(try await harness.ranges("a").count == 1)
    #expect(try await harness.ranges("b").count == 1)
  }

  @Test func aFailedRecomputeIsRetriedOnTheNextPass() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    harness.scorer.failure.withLock { $0 = Unexpected() }
    await harness.run([a, b])
    #expect(harness.scorer.failure.withLock { $0 == nil })
    #expect(try await harness.ranges("a").count == 1)
  }

  @Test func anUnreadableTranscriptIsAnalysedAgain() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let name = try #require(try await harness.episodes.episode(for: a.identity)?.transcriptFileName)
    try FileManager.default.removeItem(at: harness.transcripts.rootURL.appendingPathComponent(name))

    await harness.coordinator.forgetLearnedAds()
    await harness.coordinator.waitUntilIdle()
    #expect(harness.audio.calls.withLock { $0.filter { $0 == a.fileURL }.count } == 2)
    #expect(try await harness.episodes.episode(for: a.identity)?.state == .analysed)
    #expect(try await harness.ranges("a").count == 1)
  }

  @Test func aTranscriptUnreadableTwiceWaitsForTheLocalSetToChange() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    func loseTranscript() async throws {
      let name = try #require(try await harness.episodes.episode(for: a.identity)?.transcriptFileName)
      try FileManager.default.removeItem(at: harness.transcripts.rootURL.appendingPathComponent(name))
      await harness.coordinator.forgetLearnedAds()
      await harness.coordinator.waitUntilIdle()
    }
    func analysesOfA() -> Int { harness.audio.calls.withLock { $0.filter { $0 == a.fileURL }.count } }

    try await loseTranscript()
    #expect(analysesOfA() == 2)
    try await loseTranscript()
    #expect(analysesOfA() == 2)
    #expect(try await harness.episodes.episode(for: a.identity) == nil)

    await harness.coordinator.setLocalEpisodes([a, b, harness.episode("c")])
    await harness.coordinator.waitUntilIdle()
    #expect(analysesOfA() == 3)
  }

  @Test func everyRangeFromTheStoreNamesALiveCreative() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])

    // a is replaced by a cut with the ad placed later, so what it taught is replaced.
    harness.transcriber.set(
      a.fileURL, .success(Self.transcript(Self.programme("a", count: 70) + Self.ad + Self.programme("ax"))))
    harness.fingerprints.set(a.fileURL, size: 9_999)
    await harness.coordinator.setLocalEpisodes([a, b, harness.episode("c")])
    await harness.coordinator.waitUntilIdle()

    let live = Set(try await harness.signatures.allCreatives().map(\.id))
    // b's range was matched against what a taught before, so it now names the replacement.
    #expect(try await harness.ranges("b").first?.fromStore == true)
    for id in ["a", "b"] {
      for range in try await harness.ranges(id) where range.fromStore {
        let creative = try #require(range.creativeId)
        #expect(live.contains(creative))
      }
    }
  }

  @Test func nothingRunsAfterStop() async throws {
    let harness = try Harness()
    await harness.run([])
    await harness.coordinator.stop()
    await harness.coordinator.setLocalEpisodes([harness.episode("a", transcript: Self.withAd("a"))])
    await harness.coordinator.waitUntilIdle()
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
  }

  @Test func aDeferredTranscriptionRecordsNoWordsAndResumesWhenAllowedAgain() async throws {
    let harness = try Harness(wholeFiles: true)
    let a = harness.episode("a")
    harness.transcriber.set(a.fileURL, .failure(AdSkipAnalysisDeferred()))
    await harness.run([a])
    // The decode is kept; the transcription waits.
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.decoded])
    #expect(await harness.coordinator.progress?.remaining == 1)

    harness.transcriber.set(a.fileURL, .success(Self.withAd("a")))
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed])
  }

  @Test func aChangedFileIsAnalysedAgain() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    await harness.run([a])
    let first = try #require(try await harness.episodes.allEpisodes().first?.transcriptFileName)

    harness.fingerprints.set(a.fileURL, size: 5_000)
    await harness.coordinator.setLocalEpisodes([a, harness.episode("b")])
    await harness.coordinator.waitUntilIdle()
    let row = try #require(try await harness.episodes.episode(for: a.identity))
    #expect(row.fileByteSize == 5_000)
    #expect(row.transcriptFileName != first)
    #expect(harness.audio.calls.withLock { $0.filter { $0 == a.fileURL }.count } == 2)
    #expect(harness.transcriptFiles().contains(first) == false)
  }

  @Test func aMissingFileIsSkippedWithoutBeingMarkedFailed() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    harness.fingerprints.values.withLock { $0[a.fileURL] = nil }
    await harness.run([a])
    #expect(try await harness.episodes.allEpisodes().isEmpty)
    #expect(harness.transcriber.calls.withLock { $0 }.isEmpty)
  }

  @Test func aStaleRulesRevisionIsRescoredFromTheStoredTranscript() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    for var row in try await harness.episodes.allEpisodes() {
      row.rulesRevision = AdSkipRules.revision - 1
      _ = try await harness.episodes.save(row, ranges: [])
    }

    let restarted = try Harness(reusing: harness)
    await restarted.run([a, b])
    #expect(restarted.transcriber.calls.withLock { $0 }.isEmpty)
    #expect(try await restarted.ranges("a").count == 1)
    #expect(
      try await restarted.episodes.allEpisodes().allSatisfy {
        $0.rulesRevision == AdSkipRules.revision
      })
  }

  @Test func scoresAreCachedAcrossRecomputes() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let b = harness.episode("b", transcript: Self.withAd("b"))
    await harness.run([a, b])
    let scored = harness.scorer.scoredSteps.withLock { $0 }

    await harness.coordinator.setLocalEpisodes([
      a, b, harness.episode("c", transcript: Self.transcript(Self.programme("c", count: 120))),
    ])
    await harness.coordinator.waitUntilIdle()
    #expect(harness.scorer.scoredSteps.withLock { $0 } == scored)
  }

  // MARK: - Ordering and cancellation

  @Test func theLoadedEpisodeIsAnalysedFirst() async throws {
    let harness = try Harness()
    let a = harness.episode("a", transcript: Self.withAd("a"))
    let z = harness.episode("z", transcript: Self.withAd("z"))
    await harness.coordinator.prioritize(z.identity)
    await harness.run([a, z])
    #expect(harness.audio.calls.withLock { $0 } == [z.fileURL, a.fileURL])
    #expect(harness.transcriber.calls.withLock { $0.prefix(2) } == [z.fileURL, a.fileURL])
  }

  @Test func removingTheEpisodeBeingTranscribedCancelsItAndSavesNothing() async throws {
    let harness = try Harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Self.withAd("a"))
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.setLocalEpisodes([a])
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.setEnabled(true)
    #expect(await waitUntil("transcription is held") { harness.transcriber.holding })

    await harness.coordinator.setLocalEpisodes([])
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().isEmpty)
    #expect(harness.files().isEmpty)
  }

  @Test func anErrorFromACancelledTranscriptionIsNotRecordedAsAFailure() async throws {
    let harness = try Harness(wholeFiles: true)
    let a = harness.episode("a", transcript: Self.withAd("a"))
    harness.transcriber.errorWhenCancelled.withLock { $0 = Unexpected() }
    harness.transcriber.hold(a.fileURL)
    await harness.coordinator.setLocalEpisodes([a])
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.setEnabled(true)
    #expect(await waitUntil("transcription is held") { harness.transcriber.holding })

    await harness.coordinator.setAllowed(false)
    harness.transcriber.release()
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.decoded])

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()
    #expect(try await harness.episodes.allEpisodes().map(\.state) == [.analysed])
  }

  @Test func anOrphanedTranscriptFileIsSweptOnTheFirstPass() async throws {
    let harness = try Harness()
    let orphan = try harness.transcripts.write(StoredTranscript(words: [], silences: [], duration: 1))
    await harness.run([])
    #expect(harness.transcriptFiles().contains(orphan) == false)
  }
}
