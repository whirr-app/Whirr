import AdSkip
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `PauseTrimCoordinator`: what it queues, in what order, under which conditions, and what it
/// answers the player.
@Suite(.timeLimit(.minutes(1)))
struct PauseTrimCoordinatorTests {
  static let runs = PauseRuns(
    revision: PauseDetector.revision, duration: 60,
    runsBelow40: [PauseRun(start: 10, end: 11)], runsBelow46: [PauseRun(start: 10, end: 10.75)])

  final class FakeAnalyser: PauseAnalysing {
    enum Outcome { case aligned, misaligned, failure }
    let analysed = Mutex<[URL]>([])
    let outcomes = Mutex<[URL: Outcome]>([:])
    /// When set, analysis of that URL waits until `release()`.
    let heldURL = Mutex<URL?>(nil)
    /// A held analysis runs to completion regardless of cancellation.
    let gate = TestGate<Void>(label: "FakeAnalyser analyse", ignoresCancellation: true)

    func hold(_ url: URL) {
      heldURL.withLock { $0 = url }
      gate.hold()
    }

    func release() {
      heldURL.withLock { $0 = nil }
      gate.release()
    }

    var holding: Bool { gate.parkedCount > 0 }

    func analyse(fileAt url: URL) async throws -> PauseAnalysis {
      analysed.withLock { $0.append(url) }
      if heldURL.withLock({ $0 == url }) {
        await gate.pass()
        try Task.checkCancellation()
      }
      switch outcomes.withLock({ $0[url] }) ?? .aligned {
      case .aligned: return PauseAnalysis(runs: PauseTrimCoordinatorTests.runs, isAligned: true)
      case .misaligned: return PauseAnalysis(runs: PauseTrimCoordinatorTests.runs, isAligned: false)
      case .failure: throw CocoaError(.fileReadCorruptFile)
      }
    }
  }

  final class FakeFingerprints: AdSkipFileFingerprinting {
    let sizes = Mutex<[URL: Int64]>([:])
    func fingerprint(ofFileAt url: URL) -> AdSkipFileFingerprint? {
      sizes.withLock { $0[url] }.map { AdSkipFileFingerprint(byteSize: $0, modificationTime: 1) }
    }
  }

  struct Harness {
    let store: PauseTrimEpisodeStore
    let analyser = FakeAnalyser()
    let fingerprints = FakeFingerprints()
    let coordinator: PauseTrimCoordinator

    init() throws {
      store = PauseTrimEpisodeStore(database: try AppDatabase.inMemory())
      coordinator = PauseTrimCoordinator(
        dependencies: .init(
          store: store, analyser: analyser, fingerprinting: fingerprints,
          now: { Date(timeIntervalSince1970: 1_700_000_000) }))
    }

    func episode(_ id: String, show: String = "rss:1") -> AdSkipLocalEpisode {
      let url = URL(fileURLWithPath: "/downloads/\(show)/\(id).mp3")
      fingerprints.sizes.withLock { $0[url] = 1_000 }
      return AdSkipLocalEpisode(
        identity: AdSkipEpisodeIdentity(source: .rss, accountId: nil, itemID: show, episodeID: id),
        fileURL: url, languageTag: nil, showTitle: nil, linkedIdentities: [])
    }

    func request(_ episode: AdSkipLocalEpisode) -> PlaybackSkipRangeRequest {
      PlaybackSkipRangeRequest(
        itemID: episode.identity.itemID, episodeID: episode.identity.episodeID,
        fileURL: episode.fileURL)
    }

    var analysedIDs: [String] {
      analyser.analysed.withLock { $0 }.map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Every input set, with analysis allowed, then drained.
    func run(
      _ episodes: [AdSkipLocalEpisode], default value: TrimSilencesDefault = .moderateOn,
      overrides: [String: TrimSilencesShowOverride] = [:], allowed: Bool = true
    ) async {
      await coordinator.setDefault(value)
      await coordinator.setOverrides(overrides)
      await coordinator.setLocalEpisodes(episodes)
      await coordinator.setAllowed(allowed)
      await coordinator.waitUntilIdle()
    }
  }

  // MARK: - What is queued

  @Test func analysesEveryDownloadWhileTheDefaultIsOn() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a"), harness.episode("b")])

    #expect(harness.analysedIDs == ["a", "b"])
  }

  @Test func aShowSetToOffIsNotAnalysedWithTheDefaultOn() async throws {
    let harness = try Harness()
    await harness.run(
      [harness.episode("a"), harness.episode("b", show: "rss:2")], overrides: ["rss:1": .off])

    #expect(harness.analysedIDs == ["b"])
  }

  @Test func aShowWithItsOwnStrengthIsAnalysedWithTheDefaultOff() async throws {
    let harness = try Harness()
    await harness.run(
      [harness.episode("a"), harness.episode("b", show: "rss:2")], default: .off,
      overrides: ["rss:2": .maximum])

    #expect(harness.analysedIDs == ["b"])
  }

  @Test func turningAShowOnLaterQueuesItsDownloads() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    await harness.run([episode], default: .off)
    #expect(harness.analysedIDs.isEmpty)

    await harness.coordinator.setOverrides(["rss:1": .moderate])
    await harness.coordinator.waitUntilIdle()

    #expect(harness.analysedIDs == ["a"])
  }

  @Test func nothingIsAnalysedUntilConditionsAllow() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a")], allowed: false)
    #expect(harness.analysedIDs.isEmpty)

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()

    #expect(harness.analysedIDs == ["a"])
  }

  @Test func theEpisodeThePlayerAsksAboutGoesFirst() async throws {
    let harness = try Harness()
    let episodes = ["a", "b", "c"].map { harness.episode($0) }
    await harness.run(episodes, allowed: false)

    _ = await harness.coordinator.trimAnswer(for: harness.request(episodes[2]))
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()

    #expect(harness.analysedIDs == ["c", "a", "b"])
  }

  @Test func anAnalysedEpisodeIsNotAnalysedAgain() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    await harness.run([episode])

    await harness.coordinator.setLocalEpisodes([episode, harness.episode("b")])
    await harness.coordinator.waitUntilIdle()

    #expect(harness.analysedIDs == ["a", "b"])
  }

  // MARK: - Answers

  @Test func answersTheRunsOfAnAnalysedFile() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    await harness.run([episode])

    #expect(
      await harness.coordinator.trimAnswer(for: harness.request(episode))
        == .runs(Self.runs, timing: .estimated))
  }

  @Test func answersNotAnalysedBeforeTheAnalysis() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    await harness.run([episode], allowed: false)

    #expect(await harness.coordinator.trimAnswer(for: harness.request(episode)) == .notAnalysed)
  }

  /// A file whose estimated timeline drifts keeps its runs, and is trimmed through a
  /// precise-timing composition.
  @Test func aMisalignedFileIsTrimmedWithPreciseTiming() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    harness.analyser.outcomes.withLock { $0[episode.fileURL] = .misaligned }
    await harness.run([episode])

    #expect(
      await harness.coordinator.trimAnswer(for: harness.request(episode))
        == .runs(Self.runs, timing: .precise))
    let row = try await harness.store.episode(for: episode.identity)
    #expect(row?.state == .misaligned)
    #expect(row?.runs == Self.runs.encoded())
  }

  @Test func aFileThatCannotBeDecodedIsUnavailableAndNotRetried() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    harness.analyser.outcomes.withLock { $0[episode.fileURL] = .failure }
    await harness.run([episode])
    await harness.coordinator.setAllowed(false)
    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()

    #expect(
      await harness.coordinator.trimAnswer(for: harness.request(episode))
        == .unavailable(.unreadable))
    #expect(harness.analysedIDs == ["a"])
  }

  @Test func aChangedFileIsAnalysedAgain() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    await harness.run([episode])

    harness.fingerprints.sizes.withLock { $0[episode.fileURL] = 2_000 }
    // Asking about a file that is not analysed wakes the queue.
    #expect(await harness.coordinator.trimAnswer(for: harness.request(episode)) == .notAnalysed)
    await harness.coordinator.waitUntilIdle()

    #expect(harness.analysedIDs == ["a", "a"])
    #expect(try await harness.store.episode(for: episode.identity)?.fileByteSize == 2_000)
  }

  @Test func anOlderDetectorRevisionIsAnalysedAgain() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    try await harness.store.save(
      PauseTrimEpisodeRecord(
        source: .rss, accountId: nil, itemID: "rss:1", episodeID: "a", fileByteSize: 1_000,
        fileModificationTime: 1, detectorRevision: PauseDetector.revision - 1, state: .analysed,
        runs: Self.runs.encoded(), analysedAt: Date()))

    #expect(await harness.coordinator.trimAnswer(for: harness.request(episode)) == .notAnalysed)
    await harness.run([episode])

    #expect(harness.analysedIDs == ["a"])
    #expect(
      try await harness.store.episode(for: episode.identity)?.detectorRevision
        == PauseDetector.revision)
  }

  @Test func aRemovedDownloadLosesItsAnalysis() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    await harness.run([episode])

    await harness.coordinator.setLocalEpisodes([])
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.store.allSummaries().isEmpty)
  }

  @Test func switchingAShowOffKeepsItsAnalysis() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    await harness.run([episode])

    await harness.coordinator.setOverrides(["rss:1": .off])
    await harness.coordinator.waitUntilIdle()

    #expect(try await harness.store.allSummaries().count == 1)
  }

  /// A show switched off mid-decode cancels it. The cancelled pass is not retried: the episode
  /// waits until an input wakes the queue, here the show coming back on.
  @Test func switchingAShowOffCancelsItsDecodeAndItWaitsForTheShowToComeBack() async throws {
    let harness = try Harness()
    let episode = harness.episode("a")
    harness.analyser.hold(episode.fileURL)
    await harness.coordinator.setDefault(.moderateOn)
    await harness.coordinator.setLocalEpisodes([episode])
    await harness.coordinator.setAllowed(true)
    #expect(await waitUntil("the decode is held") { harness.analyser.holding })

    await harness.coordinator.setOverrides(["rss:1": .off])
    harness.analyser.release()
    await harness.coordinator.waitUntilIdle()

    #expect(harness.analysedIDs == ["a"])
    #expect(try await harness.store.allSummaries().isEmpty)

    await harness.coordinator.setOverrides(["rss:1": .moderate])
    await harness.coordinator.waitUntilIdle()

    #expect(harness.analysedIDs == ["a", "a"])
    #expect(try await harness.store.allSummaries().count == 1)
  }

  @Test func aStoredAnalysisIsAnnounced() async throws {
    let harness = try Harness()
    await harness.run([harness.episode("a")], allowed: false)
    let changes = harness.coordinator.trimChanges()

    await harness.coordinator.setAllowed(true)
    await harness.coordinator.waitUntilIdle()

    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() != nil)
  }
}

extension TrimSilencesDefault {
  static let moderateOn = TrimSilencesDefault(isEnabled: true, strength: .moderate)
}
