import AdSkip
import Foundation
import Persistence
import PlayerCore
import SyncEngine
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `PlaybackModel+Trim`: the map rides on the load when it is ready in time, follows as an
/// intent when it is not, and follows the default, the show's own setting and the analysis
/// while the episode plays.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackTrimModelTests {
  nonisolated static let file = URL(fileURLWithPath: "/downloads/show/episode-a.mp3")
  nonisolated static let runs = PauseRuns(
    revision: PauseDetector.revision, duration: 100,
    runsBelow40: [PauseRun(start: 10, end: 12)], runsBelow46: [PauseRun(start: 10, end: 13)])
  nonisolated static let moderate = PauseTrimPlanner.map(for: runs, strength: .moderate)
  nonisolated static let maximum = PauseTrimPlanner.map(for: runs, strength: .maximum)

  // MARK: - Fakes

  final class FakeSource: PlaybackTrimSource {
    let answers = Mutex<[URL: PlaybackTrimAnswer]>([:])
    let requests = Mutex<[PlaybackSkipRangeRequest]>([])
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(answer: PlaybackTrimAnswer = .runs(PlaybackTrimModelTests.runs, timing: .estimated)) {
      (changes, continuation) = AsyncStream.makeStream()
      answers.withLock {
        $0[PlaybackTrimModelTests.file] = answer
        $0[PlaybackTrimModelTests.otherFile] = answer
      }
    }

    func trimAnswer(for request: PlaybackSkipRangeRequest) async -> PlaybackTrimAnswer {
      requests.withLock { $0.append(request) }
      return answers.withLock { $0[request.fileURL] } ?? .notAnalysed
    }

    func trimChanges() -> AsyncStream<Void> { changes }

    func set(_ answer: PlaybackTrimAnswer) {
      answers.withLock { $0[PlaybackTrimModelTests.file] = answer }
      continuation.yield()
    }
  }

  /// Answers at once, or holds every request until the test releases it, oldest first.
  final class FakePreparer: PlaybackTrimPreparing {
    let isGated: Bool
    let succeeds: Bool
    let prepared = Mutex<[(PlayerTrimMap, URL)]>([])
    let timings = Mutex<[PlaybackTrimTiming]>([])
    // A parked request stays parked through task cancellation until released.
    private let gate = TestGate<Bool>(label: "FakePreparer prepare", ignoresCancellation: true)

    init(isGated: Bool = false, succeeds: Bool = true) {
      self.isGated = isGated
      self.succeeds = succeeds
      if isGated { gate.hold() }
    }

    func prepare(map: PlayerTrimMap, forFileURL url: URL, timing: PlaybackTrimTiming) async -> Bool {
      prepared.withLock { $0.append((map, url)) }
      timings.withLock { $0.append(timing) }
      guard isGated else { return succeeds }
      return await gate.pass(otherwise: { false })
    }

    var waitingCount: Int { gate.parkedCount }

    func releaseOldest(_ result: Bool = true) {
      gate.releaseNext(result)
    }
  }

  final class FakeDefaults: TrimSilencesDefaultSource {
    private let value: Mutex<TrimSilencesDefault>
    private let stream: AsyncStream<TrimSilencesDefault>
    private let continuation: AsyncStream<TrimSilencesDefault>.Continuation

    init(_ value: TrimSilencesDefault) {
      self.value = Mutex(value)
      (stream, continuation) = AsyncStream.makeStream()
    }

    var current: TrimSilencesDefault { value.withLock { $0 } }
    func observeDefault() -> AsyncStream<TrimSilencesDefault> { stream }

    func set(_ next: TrimSilencesDefault) {
      value.withLock { $0 = next }
      continuation.yield(next)
    }
  }

  final class FakeShowSettings: TrimSilencesShowSettingsReading {
    private let values: Mutex<[String: TrimSilencesShowOverride]>
    private let stream: AsyncStream<[String: TrimSilencesShowOverride]>
    private let continuation: AsyncStream<[String: TrimSilencesShowOverride]>.Continuation

    init(_ values: [String: TrimSilencesShowOverride] = [:]) {
      self.values = Mutex(values)
      (stream, continuation) = AsyncStream.makeStream()
    }

    func fetchTrimSilencesOverrides() async throws -> [String: TrimSilencesShowOverride] {
      values.withLock { $0 }
    }

    func observeTrimSilencesOverrides() -> AsyncStream<[String: TrimSilencesShowOverride]> {
      stream
    }

    func set(_ next: [String: TrimSilencesShowOverride]) {
      values.withLock { $0 = next }
      continuation.yield(next)
    }
  }

  @MainActor struct Harness {
    let model: PlaybackModel
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let source: FakeSource
    let preparer: FakePreparer
    let defaults: FakeDefaults
    let showSettings: FakeShowSettings
    let timeSaved = FakeTimeSaved()
    let downloadReading = FakeDownloadReading()

    init(
      source: FakeSource = FakeSource(), preparer: FakePreparer = FakePreparer(),
      default value: TrimSilencesDefault = .moderateOn,
      overrides: [String: TrimSilencesShowOverride] = [:], budget: Duration = .seconds(30)
    ) {
      self.source = source
      self.preparer = preparer
      defaults = FakeDefaults(value)
      showSettings = FakeShowSettings(overrides)
      let playback = PlaybackModelHarness(
        sync: sync, player: player, downloadReading: downloadReading, timeSaved: timeSaved,
        trim: PlaybackTrimDependencies(
          source: source, preparer: preparer, defaults: defaults, showSettings: showSettings,
          preparationBudget: budget))
      model = playback.model
    }

    func start(
      _ episodeID: String = "episode-a", source: PreparedPlaybackSource = .local, tracks: Int = 1
    ) async {
      sync.stubStartSession(
        .success(PlaybackTrimModelTests.prepared(source: source, episodeID: episodeID, tracks: tracks)))
      await model.start(itemID: "show", episodeID: episodeID)
    }

    var loads: [PlayerTrimMap?] {
      player.intents.compactMap {
        if case .load(_, _, _, let trim) = $0 { trim } else { nil }
      }
    }

    var loadCount: Int {
      player.intents.filter { if case .load = $0 { true } else { false } }.count
    }

    func sentMaps(_ episodeID: String = "episode-a") -> [PlayerTrimMap?] {
      player.intents.compactMap {
        if case .setTrimMap("show", episodeID, let map) = $0 { map } else { nil }
      }
    }

    func sentMapCount(_ episodeID: String = "episode-a") -> Int {
      player.intents.filter {
        if case .setTrimMap("show", episodeID, _) = $0 { true } else { false }
      }.count
    }
  }

  nonisolated static let otherFile = URL(fileURLWithPath: "/downloads/show/episode-b.mp3")

  nonisolated static func prepared(
    source: PreparedPlaybackSource, episodeID: String = "episode-a", tracks: Int = 1
  ) -> PreparedPlayback {
    let file = episodeID == "episode-a" ? file : otherFile
    let duration = 100.0 / Double(tracks)
    return PlaybackFixture.prepared(
      itemID: "show", episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: (0..<tracks).map { index in
        PlaybackFixture.track(
          index: index, startOffset: Double(index) * duration, duration: duration,
          url: source == .local
            ? (tracks == 1 ? file : file.appendingPathExtension("\(index)"))
            : URL(string: "https://example.test/episode-\(index).mp3")!,
          mimeType: "audio/mpeg", title: "episode")
      },
      chapters: [], source: source)
  }

  // MARK: - At load

  @Test func aReadyMapRidesOnTheLoad() async throws {
    let harness = Harness()
    await harness.start()

    #expect(harness.loads == [Self.moderate])
    #expect(harness.preparer.prepared.withLock { $0.map(\.1) } == [Self.file])
    #expect(harness.preparer.timings.withLock { $0 } == [.estimated])
    #expect(harness.model.trimStatus == .trimming(savedThisEpisode: 0))
    #expect(harness.sentMapCount() == 0)
  }

  @Test func theShowsOwnStrengthIsUsed() async throws {
    let harness = Harness(overrides: ["show": .maximum])
    await harness.start()

    #expect(harness.loads == [Self.maximum])
  }

  @Test func aShowSetToOffIsUntrimmedWithTheDefaultOn() async throws {
    let harness = Harness(overrides: ["show": .off])
    await harness.start()

    #expect(harness.loads == [nil])
    #expect(harness.model.trimStatus == .off)
    #expect(harness.source.requests.withLock { $0 }.isEmpty)
  }

  @Test func aShowSetToMaximumIsTrimmedWithTheDefaultOff() async throws {
    let harness = Harness(default: .off, overrides: ["show": .maximum])
    await harness.start()

    #expect(harness.loads == [Self.maximum])
  }

  @Test func aCompositionThatCannotBePreparedPlaysUntrimmed() async throws {
    let harness = Harness(preparer: FakePreparer(succeeds: false))
    await harness.start()

    #expect(harness.loads == [nil])
    #expect(harness.model.trimStatus == .unavailable)
  }

  /// A file whose estimated timeline drifts is prepared with precise timing.
  @Test func aMisalignedEpisodeIsPreparedWithPreciseTiming() async throws {
    let harness = Harness(source: FakeSource(answer: .runs(Self.runs, timing: .precise)))
    await harness.start()

    #expect(harness.loads == [Self.moderate])
    #expect(harness.preparer.timings.withLock { $0 } == [.precise])
    #expect(harness.model.trimStatus == .trimming(savedThisEpisode: 0))
  }

  @Test func aStreamIsNotApplicable() async throws {
    let harness = Harness()
    await harness.start(source: .streaming)

    #expect(harness.loads == [nil])
    #expect(harness.model.trimStatus == .notApplicable)
    #expect(harness.source.requests.withLock { $0 }.isEmpty)
  }

  @Test func aMultiFileItemIsNotApplicable() async throws {
    let harness = Harness()
    await harness.start(tracks: 2)

    #expect(harness.loads == [nil])
    #expect(harness.model.trimStatus == .notApplicable)
  }

  @Test func aPromotedEpisodeGetsItsMapOnTheSwap() async throws {
    let harness = Harness()
    await harness.start(source: .streaming)
    #expect(harness.model.trimStatus == .notApplicable)
    harness.player.isPlaybackIntended = true
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .playing, currentTime: 10,
        listenedDelta: 0))
    try #require(await waitUntil { harness.model.phase == .playing })
    harness.sync.stubPromoteStreamingSessionToLocalDownload(Self.prepared(source: .local))

    harness.downloadReading.pushEpisodePresence([
      EpisodeDownloadKey(itemID: "show", episodeID: "episode-a"): .completed
    ])

    #expect(await waitUntil { harness.loads.count == 2 })
    #expect(harness.loads.last == Self.moderate)
    #expect(harness.model.trimStatus == .trimming(savedThisEpisode: 0))
  }

  // MARK: - Late maps

  @Test func aLateMapFollowsAsAnIntent() async throws {
    let harness = Harness(preparer: FakePreparer(isGated: true), budget: .zero)
    await harness.start()
    #expect(harness.loads == [nil])
    #expect(harness.model.trimStatus == .preparing)

    try #require(await waitUntil { harness.preparer.waitingCount == 1 })
    harness.preparer.releaseOldest()

    #expect(await waitUntil { harness.sentMaps() == [Self.moderate] })
    #expect(harness.model.trimStatus == .trimming(savedThisEpisode: 0))
  }

  @Test func aLateMapForAnEpisodeNoLongerLoadedIsDropped() async throws {
    let harness = Harness(preparer: FakePreparer(isGated: true), budget: .zero)
    await harness.start()
    try #require(await waitUntil { harness.preparer.waitingCount == 1 })
    await harness.start("episode-b")
    try #require(await waitUntil { harness.preparer.waitingCount == 2 })

    harness.preparer.releaseOldest()
    harness.preparer.releaseOldest()

    #expect(await waitUntil { harness.sentMapCount("episode-b") == 1 })
    #expect(harness.sentMapCount("episode-a") == 0)
  }

  @Test func ownershipIsCheckedAgainAfterTheWait() async throws {
    let harness = Harness(preparer: FakePreparer(isGated: true))
    harness.sync.stubStartSession(.success(Self.prepared(source: .local)))
    let first = Task { await harness.model.start(itemID: "show", episodeID: "episode-a") }
    try #require(await waitUntil { harness.preparer.waitingCount == 1 })

    harness.sync.stubStartSession(.success(Self.prepared(source: .local, episodeID: "episode-b")))
    let second = Task { await harness.model.start(itemID: "show", episodeID: "episode-b") }
    harness.preparer.releaseOldest()
    await first.value
    try #require(await waitUntil { harness.preparer.waitingCount == 1 })
    harness.preparer.releaseOldest()
    await second.value

    #expect(harness.loadCount == 1)
    #expect(harness.model.loadedEpisodeID == "episode-b")
  }

  // MARK: - While playing

  @Test func turningTheDefaultOnMidPlaySendsTheMap() async throws {
    let harness = Harness(default: .off)
    await harness.start()
    #expect(harness.loads == [nil])
    #expect(harness.model.trimStatus == .off)

    harness.defaults.set(.moderateOn)
    #expect(await waitUntil { harness.sentMaps() == [Self.moderate] })

    harness.defaults.set(.off)
    #expect(await waitUntil { harness.sentMaps() == [Self.moderate, nil] })
    #expect(harness.model.trimStatus == .off)
  }

  @Test func changingTheShowsSettingMidPlayReloads() async throws {
    let harness = Harness()
    await harness.start()

    harness.showSettings.set(["show": .maximum])
    #expect(await waitUntil { harness.sentMaps() == [Self.maximum] })

    harness.showSettings.set(["show": .off])
    #expect(await waitUntil { harness.sentMaps() == [Self.maximum, nil] })
  }

  @Test func anAnalysisThatFinishesMidPlayIsApplied() async throws {
    let harness = Harness(source: FakeSource(answer: .notAnalysed))
    await harness.start()
    #expect(harness.loads == [nil])
    #expect(harness.model.trimStatus == .preparing)

    harness.source.set(.runs(Self.runs, timing: .estimated))

    #expect(await waitUntil { harness.sentMaps() == [Self.moderate] })
  }

  @Test func anUnchangedAnswerSendsNothing() async throws {
    let harness = Harness()
    await harness.start()

    harness.source.set(.runs(Self.runs, timing: .estimated))
    try await Task.sleep(for: .milliseconds(100))

    #expect(harness.sentMapCount() == 0)
    #expect(harness.preparer.prepared.withLock { $0.count } == 1)
  }

  // MARK: - Time saved

  /// The episode's figure is at the listener's rate; the device's total takes the source
  /// seconds cut, at 1×.
  @Test func savedTimeAddsUpForTheEpisodeAndTheDevice() async throws {
    let harness = Harness()
    await harness.start()

    for sequence in 1...2 {
      harness.player.pushProgress(
        PlaybackProgressEvent(
          sequence: sequence, itemId: "show", episodeID: "episode-a", phase: .playing,
          currentTime: Double(sequence) * 10, listenedDelta: 1, trimmedDelta: 1.5,
          trimmedSourceDelta: 3))
    }

    #expect(await waitUntil { harness.model.trimStatus == .trimming(savedThisEpisode: 3) })
    #expect(harness.timeSaved.total(.silence) == 6)
  }
}
