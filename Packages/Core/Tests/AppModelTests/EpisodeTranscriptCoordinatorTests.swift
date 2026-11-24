import AdSkip
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `EpisodeTranscriptCoordinator` against a fake session: requests, holds, checkpoints and
/// resumes, the cleanup pass, deferral and failure.
@Suite struct EpisodeTranscriptCoordinatorTests {

  // MARK: - Fakes

  /// A session the test drives: each call waits until the test emits its events and ends it.
  final class FakeSession: EpisodeTranscriptSessionRunning {
    struct Call: Sendable {
      let url: URL
      let start: Double
      let hold: EpisodeTranscriptHold
      let events: @Sendable (EpisodeTranscriptSessionEvent) async -> Void
    }

    private typealias EndingGate = TestGate<Result<Void, any Error>>

    private struct State {
      var calls: [Call] = []
      var endings: [Int: EndingGate] = [:]
      var cancelled: Set<Int> = []
      var startError: (any Error)?
    }

    private let state = Mutex(State())

    var callCount: Int { state.withLock { $0.calls.count } }
    func wasCancelled(_ index: Int) -> Bool { state.withLock { $0.cancelled.contains(index) } }

    /// The next call throws this before it starts.
    func failNextStart(with error: any Error) { state.withLock { $0.startError = error } }

    func transcribe(
      fileAt url: URL, from start: Double, hold: EpisodeTranscriptHold,
      events: @escaping @Sendable (EpisodeTranscriptSessionEvent) async -> Void
    ) async throws {
      let call = Call(url: url, start: start, hold: hold, events: events)
      let (index, error) = state.withLock { state -> (Int, (any Error)?) in
        state.calls.append(call)
        let error = state.startError
        state.startError = nil
        return (state.calls.count - 1, error)
      }
      if let error { throw error }
      let gate = endingGate(index)
      let ending = await withTaskCancellationHandler {
        await gate.pass(otherwise: { .failure(CancellationError()) })
      } onCancel: {
        _ = state.withLock { $0.cancelled.insert(index) }
      }
      try ending.get()
    }

    /// The gate a call parks on until `end`; created held, by whichever side reaches it first.
    private func endingGate(_ index: Int) -> EndingGate {
      state.withLock { state in
        if let gate = state.endings[index] { return gate }
        let gate = EndingGate(label: "FakeSession call \(index) ending")
        gate.hold()
        state.endings[index] = gate
        return gate
      }
    }

    var cancelledCount: Int { state.withLock { $0.cancelled.count } }

    func call(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Call {
      _ = await awaitCondition("session call \(index)", sourceLocation: sourceLocation) {
        callCount > index
      }
      return try #require(
        state.withLock { $0.calls.count > index ? $0.calls[index] : nil },
        sourceLocation: sourceLocation)
    }

    func emit(_ event: EpisodeTranscriptSessionEvent, call index: Int) async throws {
      try await call(index).events(event)
    }

    /// Ends the call normally, or with `error`, once it is waiting.
    func end(_ index: Int, throwing error: (any Error)? = nil) async {
      let gate = endingGate(index)
      await gate.waitUntilParked()
      gate.releaseNext(error.map { .failure($0) } ?? .success(()))
    }
  }

  final class FakeFingerprinting: AdSkipFileFingerprinting {
    private let prints = Mutex<[URL: AdSkipFileFingerprint]>([:])

    func set(_ url: URL, _ fingerprint: AdSkipFileFingerprint?) {
      prints.withLock { $0[url] = fingerprint }
    }

    func fingerprint(ofFileAt url: URL) -> AdSkipFileFingerprint? {
      prints.withLock { $0[url] }
    }
  }

  /// Sleeps until the test fires them.
  final class ManualSleeper: Sendable {
    // Always held: every sleep parks until `fireAll`.
    private let gate = TestGate<Void>(label: "ManualSleeper sleep")

    init() { gate.hold() }

    var pending: Int { gate.parkedCount }

    func sleep(_ duration: Duration) async throws {
      await gate.pass()
      try Task.checkCancellation()
    }

    func fireAll() { gate.releaseParked() }
  }

  struct Failure: Error {}

  // MARK: - Fixture

  private struct Fixture {
    let coordinator: EpisodeTranscriptCoordinator
    let store: EpisodeTranscriptStore
    let files: AdSkipTranscriptFileStore
    let session: FakeSession
    let gate: TranscriberGate
    let fingerprints: FakeFingerprinting
    let sleeper: ManualSleeper
    let root: URL

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func fileNames() throws -> Set<String> {
      Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }
  }

  private static let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func fixture(saveInterval: TimeInterval = 1_000) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EpisodeTranscriptCoordinator-\(UUID().uuidString)", isDirectory: true)
    let files = try AdSkipTranscriptFileStore(rootURL: root, fileAttributes: InertFileAttributes())
    let store = EpisodeTranscriptStore(database: try AppDatabase.inMemory(), files: files)
    let session = FakeSession()
    let gate = TranscriberGate()
    let fingerprints = FakeFingerprinting()
    let sleeper = ManualSleeper()
    let coordinator = EpisodeTranscriptCoordinator(
      dependencies: .init(
        store: store, session: session, gate: gate, fingerprinting: fingerprints,
        transcriberRevision: "r", saveInterval: saveInterval, pauseLimit: .seconds(300),
        now: { Self.start.addingTimeInterval(60) }, sleep: { try await sleeper.sleep($0) }))
    return Fixture(
      coordinator: coordinator, store: store, files: files, session: session, gate: gate,
      fingerprints: fingerprints, sleeper: sleeper, root: root)
  }

  private let print = AdSkipFileFingerprint(byteSize: 1_000, modificationTime: 1_600_000_000)

  private func episode(
    _ id: String, language: String? = "en", in fixture: Fixture
  ) -> AdSkipLocalEpisode {
    let url = URL(fileURLWithPath: "/downloads/\(id).mp3")
    fixture.fingerprints.set(url, print)
    return AdSkipLocalEpisode(
      identity: AdSkipEpisodeIdentity(source: .rss, accountId: nil, itemID: "rss:\(id)", episodeID: id),
      fileURL: url, languageTag: language, showTitle: nil, linkedIdentities: [])
  }

  private var transcriptFingerprint: EpisodeTranscriptFingerprint {
    EpisodeTranscriptFingerprint(
      fileByteSize: print.byteSize, fileModificationTime: print.modificationTime)
  }

  private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end)
  }

  /// A coordinator with `episodes` local, conditions allowing and the app in the foreground.
  private func ready(_ fixture: Fixture, _ episodes: [AdSkipLocalEpisode]) async {
    await fixture.coordinator.setAllowed(true)
    await fixture.coordinator.setForeground(true)
    await fixture.coordinator.setLocalEpisodes(episodes)
    await eventually { await fixture.coordinator.hasCompletedFirstCleanup }
  }

  private func eventually(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool
  ) async {
    _ = await awaitCondition("condition", sourceLocation: sourceLocation, until: condition)
  }

  /// A barrier before asserting that nothing more happens: waits for the session and the
  /// coordinator's counts to stop changing.
  private func settle(_ fixture: Fixture) async {
    await awaitQuiescence("the coordinator settling") {
      let counts = await fixture.coordinator.currentCounts()
      return "\(fixture.session.callCount) \(fixture.session.cancelledCount) "
        + "\(fixture.sleeper.pending) \(counts.sessions) \(counts.checkpoints) \(counts.holds)"
    }
  }

  private func storedWords(_ fixture: Fixture, _ identity: AdSkipEpisodeIdentity) async throws -> [String] {
    try await fixture.store.transcript(for: identity)?.transcript.words.map(\.text) ?? []
  }

  // MARK: - Tests

  @Test func aRequestTranscribesTheWholeFileAndSavesItComplete() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    #expect(await fixture.coordinator.status(for: one.identity) == .notStarted)

    await fixture.coordinator.request(one.identity)
    let call = try await fixture.session.call(0)
    #expect(call.start == 0)
    #expect(call.url == one.fileURL)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(
      .finalized(words: [word("Hello", 1, 2), word("there.", 2, 3)], through: 50), call: 0)
    #expect(await fixture.coordinator.status(for: one.identity) == .generating(covered: 0.5))
    #expect(try await fixture.coordinator.transcript(for: one.identity)?.words.count == 2)
    try await fixture.session.emit(.finalized(words: [word("Bye.", 90, 91)], through: 100), call: 0)
    await fixture.session.end(0)

    await eventually { await fixture.coordinator.status(for: one.identity) == .complete }
    #expect(await fixture.coordinator.status(for: one.identity) == .complete)
    let entry = try #require(try await fixture.store.transcript(for: one.identity))
    #expect(entry.record.state == .complete)
    #expect(entry.transcript.words.map(\.text) == ["Hello", "there.", "Bye."])
    #expect(entry.transcript.coverage == [StoredTimeSpan(start: 0, end: 100)])
    await fixture.coordinator.request(one.identity)
    await settle(fixture)
    #expect(fixture.session.callCount == 1)
  }

  @Test func aHoldPausesTheSessionAndAReleaseResumesItWithoutAJoin() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    let call = try await fixture.session.call(0)
    try await fixture.session.emit(.started(duration: 100), call: 0)

    await fixture.coordinator.setAllowed(false)
    #expect(call.hold.isHeld)
    #expect(await fixture.coordinator.status(for: one.identity) == .waiting(.held, covered: 0))
    await fixture.coordinator.setAllowed(true)
    #expect(call.hold.isHeld == false)
    #expect(await fixture.coordinator.status(for: one.identity) == .generating(covered: 0))

    await fixture.session.end(0)
    await eventually { await fixture.coordinator.status(for: one.identity) == .complete }
    #expect(fixture.session.callCount == 1)
    #expect(fixture.session.wasCancelled(0) == false)
    #expect(await fixture.coordinator.currentCounts().holds == 1)
  }

  @Test func aHoldPastTheLimitCheckpointsAndTheNextSessionResumesAPadBeforeTheGap() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(0)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(
      .finalized(words: [word("One", 10, 11), word("two", 58, 60)], through: 60), call: 0)

    await fixture.coordinator.setAllowed(false)
    await eventually { fixture.sleeper.pending == 1 }
    fixture.sleeper.fireAll()
    await eventually { fixture.session.wasCancelled(0) }
    await eventually { await fixture.coordinator.currentCounts().checkpoints == 1 }
    #expect(await fixture.coordinator.status(for: one.identity) == .waiting(.held, covered: 0.6))
    let saved = try #require(try await fixture.store.transcript(for: one.identity))
    #expect(saved.record.state == .partial)
    #expect(saved.transcript.coverage == [StoredTimeSpan(start: 0, end: 60)])

    await fixture.coordinator.setAllowed(true)
    let resumed = try await fixture.session.call(1)
    #expect(resumed.start == 55)
    try await fixture.session.emit(.started(duration: 100), call: 1)
    try await fixture.session.emit(
      .finalized(
        words: [word("before", 56, 57), word("Two", 59.5, 61), word("three", 61, 62)], through: 100),
      call: 1)
    await fixture.session.end(1)

    await eventually { await fixture.coordinator.status(for: one.identity) == .complete }
    // "before" is the earlier session's audio; "Two" repeats the word cut by the join.
    #expect(try await storedWords(fixture, one.identity) == ["One", "two", "three"])
    #expect(await fixture.coordinator.currentCounts().joinRepeatsDropped == 1)
  }

  @Test func leavingTheForegroundCheckpointsUnlessAudioPlays() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(0)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(.finalized(words: [word("One", 1, 2)], through: 20), call: 0)

    await fixture.coordinator.setPlaying(true)
    await fixture.coordinator.setForeground(false)
    await settle(fixture)
    #expect(fixture.session.wasCancelled(0) == false)

    await fixture.coordinator.setPlaying(false)
    await eventually { fixture.session.wasCancelled(0) }
    await eventually {
      await fixture.coordinator.status(for: one.identity) == .waiting(.queued, covered: 0.2)
    }
    #expect(try await storedWords(fixture, one.identity) == ["One"])
    await settle(fixture)
    #expect(fixture.session.callCount == 1)

    await fixture.coordinator.setForeground(true)
    #expect(try await fixture.session.call(1).start == 15)
  }

  @Test func aSessionThatFailsInTheBackgroundWaitsForTheForegroundInsteadOfFailing() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(0)
    await fixture.coordinator.setPlaying(true)
    await fixture.coordinator.setForeground(false)

    await fixture.session.end(0, throwing: Failure())

    await eventually {
      await fixture.coordinator.status(for: one.identity) == .waiting(.queued, covered: 0)
    }
    #expect(try await fixture.store.record(for: one.identity) == nil)
    await fixture.coordinator.setForeground(true)
    _ = try await fixture.session.call(1)
  }

  @Test func aSessionThatFailsAfterAHoldCheckpointsInsteadOfFailing() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(0)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(.finalized(words: [word("One", 1, 2)], through: 20), call: 0)
    await fixture.coordinator.setAllowed(false)
    await fixture.coordinator.setAllowed(true)

    // An analyser left idle by a hold may be gone when the feed starts again.
    await fixture.session.end(0, throwing: Failure())

    await eventually { await fixture.coordinator.currentCounts().checkpoints == 1 }
    #expect(try await storedWords(fixture, one.identity) == ["One"])
    #expect(try await fixture.session.call(1).start == 15)
  }

  @Test func cancellingARequestCheckpointsAndStops() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(0)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(.finalized(words: [word("One", 1, 2)], through: 30), call: 0)

    await fixture.coordinator.cancel(one.identity)

    await eventually { await fixture.coordinator.status(for: one.identity) == .stopped(covered: 0.3) }
    #expect(try await storedWords(fixture, one.identity) == ["One"])
    await settle(fixture)
    #expect(fixture.session.callCount == 1)
  }

  @Test func yieldingForLookBackCheckpointsSavesAndReleasesTheGateBeforeItReturns() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(0)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(
      .finalized(words: [word("One", 1, 2), word("two", 38, 40)], through: 40), call: 0)

    await fixture.coordinator.yieldForLookBack()

    #expect(fixture.session.wasCancelled(0))
    #expect(await fixture.gate.isHeldForTesting == false)
    #expect(try await storedWords(fixture, one.identity) == ["One", "two"])
    #expect(await fixture.coordinator.status(for: one.identity) == .waiting(.queued, covered: 0.4))
    await settle(fixture)
    #expect(fixture.session.callCount == 1)

    await fixture.coordinator.resumeAfterLookBack()
    let resumed = try await fixture.session.call(1)
    #expect(resumed.start == 35)
    try await fixture.session.emit(.started(duration: 100), call: 1)
    try await fixture.session.emit(
      .finalized(words: [word("two", 39, 40.5), word("three", 41, 42)], through: 100), call: 1)
    await fixture.session.end(1)
    await eventually { await fixture.coordinator.status(for: one.identity) == .complete }
    #expect(try await storedWords(fixture, one.identity) == ["One", "two", "three"])
  }

  @Test func noSessionStartsWhileYieldedWhicheverInputAsks() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.yieldForLookBack()

    await fixture.coordinator.request(one.identity)
    await fixture.coordinator.setAllowed(true)
    await fixture.coordinator.setForeground(true)
    await fixture.coordinator.retry()
    await fixture.coordinator.setLocalEpisodes([one])
    await settle(fixture)
    #expect(fixture.session.callCount == 0)
    #expect(await fixture.coordinator.status(for: one.identity) == .waiting(.queued, covered: 0))

    await fixture.coordinator.resumeAfterLookBack()
    #expect(try await fixture.session.call(0).start == 0)
  }

  @Test func aSessionWaitingAtTheGateYieldsWithoutStarting() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    try await fixture.gate.acquire(for: .adSkip)
    await fixture.coordinator.request(one.identity)
    await eventually { await fixture.gate.waitingCount == 1 }

    await fixture.coordinator.yieldForLookBack()
    #expect(await fixture.gate.waitingCount == 0)
    await fixture.gate.release()
    await settle(fixture)
    #expect(fixture.session.callCount == 0)

    await fixture.coordinator.resumeAfterLookBack()
    _ = try await fixture.session.call(0)
  }

  @Test func progressIsSavedAsItArrivesOnceTheIntervalHasPassed() async throws {
    let fixture = try fixture(saveInterval: 0)
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(.finalized(words: [word("One", 1, 2)], through: 30), call: 0)

    let saved = try #require(try await fixture.store.transcript(for: one.identity))
    #expect(saved.record.state == .partial)
    #expect(saved.transcript.words.map(\.text) == ["One"])
    #expect(try fixture.fileNames().count == 1)
  }

  @Test func aDeferredSessionWaitsAndRetriesOnTheNextForeground() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    fixture.session.failNextStart(with: AdSkipAnalysisDeferred())

    await fixture.coordinator.request(one.identity)
    await eventually {
      await fixture.coordinator.status(for: one.identity) == .waiting(.deferred, covered: 0)
    }
    await settle(fixture)
    #expect(fixture.session.callCount == 1)

    await fixture.coordinator.setForeground(true)
    _ = try await fixture.session.call(1)
    #expect(await fixture.coordinator.status(for: one.identity) == .generating(covered: 0))
  }

  @Test func aFailureIsRecordedAndARequestTriesAgain() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(0)

    await fixture.session.end(0, throwing: Failure())

    await eventually { await fixture.coordinator.status(for: one.identity) == .failed }
    let record = try #require(try await fixture.store.record(for: one.identity))
    #expect(record.state == .failed)
    #expect(record.transcriberRevision == "r")
    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(1)
  }

  @Test func aSessionWaitsForAdSkipsCallInFlight() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    try await fixture.gate.acquire(for: .adSkip)

    await fixture.coordinator.request(one.identity)
    await settle(fixture)
    #expect(fixture.session.callCount == 0)
    #expect(await fixture.coordinator.status(for: one.identity) == .waiting(.queued, covered: 0))

    await fixture.gate.release()
    _ = try await fixture.session.call(0)
  }

  @Test func onlyDownloadedEpisodesOfEnglishShowsAreEligible() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let english = episode("1", in: fixture)
    let french = episode("2", language: "fr", in: fixture)
    await ready(fixture, [english, french])
    let streamed = AdSkipEpisodeIdentity(source: .rss, accountId: nil, itemID: "rss:3", episodeID: "3")

    #expect(await fixture.coordinator.status(for: french.identity) == .unavailable)
    #expect(await fixture.coordinator.status(for: streamed) == .unavailable)
    await fixture.coordinator.request(french.identity)
    await fixture.coordinator.request(streamed)
    await settle(fixture)
    #expect(fixture.session.callCount == 0)
  }

  @Test func theCleanupPassDeletesRowsForRemovedChangedAndMissingFilesAndSweepsOrphans() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let kept = episode("kept", in: fixture)
    let removed = episode("removed", in: fixture)
    let changed = episode("changed", in: fixture)
    let missing = episode("missing", in: fixture)
    let transcript = StoredTranscript(
      words: [StoredTranscriptWord(text: "Hi", start: 0, end: 1)], silences: [], duration: 10)
    for item in [kept, removed, changed, missing] {
      try await fixture.store.saveProgress(
        transcript, for: item.identity, fingerprint: transcriptFingerprint,
        transcriberRevision: "r", isComplete: true, at: Self.start)
    }
    let missingFile = try #require(try await fixture.store.record(for: missing.identity)?.transcriptFileName)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(missingFile))
    let orphan = try fixture.files.write(transcript)
    try FileManager.default.setAttributes(
      [.modificationDate: Self.start.addingTimeInterval(-60)],
      ofItemAtPath: fixture.root.appendingPathComponent(orphan).path)
    fixture.fingerprints.set(
      changed.fileURL, AdSkipFileFingerprint(byteSize: 2_000, modificationTime: 1_600_000_000))

    await fixture.coordinator.setLocalEpisodes([kept, changed, missing])
    await eventually { await fixture.coordinator.hasCompletedFirstCleanup }

    #expect(try await fixture.store.allRecords().map(\.identity) == [kept.identity])
    let keptFile = try #require(try await fixture.store.record(for: kept.identity)?.transcriptFileName)
    #expect(try fixture.fileNames() == [keptFile])
    #expect(await fixture.coordinator.status(for: kept.identity) == .complete)
    #expect(await fixture.coordinator.status(for: changed.identity) == .notStarted)
    #expect(await fixture.coordinator.status(for: missing.identity) == .notStarted)

    // A download removed later goes on the next pass.
    await fixture.coordinator.setLocalEpisodes([changed])
    await eventually { (try? await fixture.store.allRecords().isEmpty) == true }
    #expect(try await fixture.store.allRecords().isEmpty)
  }

  @Test func removingTheDownloadStopsItsSessionWithoutSaving() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    await fixture.coordinator.request(one.identity)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(.finalized(words: [word("One", 1, 2)], through: 30), call: 0)

    fixture.fingerprints.set(one.fileURL, nil)
    await fixture.coordinator.setLocalEpisodes([])

    await eventually { fixture.session.wasCancelled(0) }
    await eventually { await fixture.coordinator.status(for: one.identity) == .unavailable }
    await settle(fixture)
    #expect(try await fixture.store.record(for: one.identity) == nil)
  }

  @Test func statusChangesAreObserved() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    let changes = await fixture.coordinator.statusChanges(of: one.identity)
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == .notStarted)

    await fixture.coordinator.request(one.identity)
    var seen: [EpisodeTranscriptStatus] = []
    while let next = await iterator.next() {
      seen.append(next)
      if next == .generating(covered: 0) { break }
    }
    #expect(seen.last == .generating(covered: 0))
    #expect(seen.dropLast().allSatisfy { $0 == .waiting(.queued, covered: 0) })
  }

  // MARK: - The player's episode

  @Test func thePlayersEpisodeIsFoundByItemAndEpisodeOnceItIsLocalAndEligible() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    let changes = await fixture.coordinator.identityChanges(itemID: "rss:1", episodeID: "1")
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == .some(nil))

    await fixture.coordinator.setLocalEpisodes([one])
    #expect(await iterator.next() == one.identity)

    await fixture.coordinator.setLocalEpisodes([])
    #expect(await iterator.next() == .some(nil))
  }

  @Test func anEpisodeOfAShowInAnotherLanguageIsNotOffered() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    await fixture.coordinator.setLocalEpisodes([episode("1", language: "de", in: fixture)])

    let changes = await fixture.coordinator.identityChanges(itemID: "rss:1", episodeID: "1")
    var iterator = changes.makeAsyncIterator()

    #expect(await iterator.next() == .some(nil))
  }

  @Test func twoAccountsCopiesOfOneEpisodeAreNotGuessedBetween() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    func copy(account: Int64) -> AdSkipLocalEpisode {
      let url = URL(fileURLWithPath: "/downloads/\(account)/1.mp3")
      fixture.fingerprints.set(url, print)
      return AdSkipLocalEpisode(
        identity: AdSkipEpisodeIdentity(source: .abs, accountId: account, itemID: "li", episodeID: "1"),
        fileURL: url, languageTag: "en", showTitle: nil, linkedIdentities: [])
    }
    await fixture.coordinator.setLocalEpisodes([copy(account: 1), copy(account: 2)])

    let changes = await fixture.coordinator.identityChanges(itemID: "li", episodeID: "1")
    var iterator = changes.makeAsyncIterator()

    #expect(await iterator.next() == .some(nil))
  }

  @Test func anUnchangedAnswerIsNotRepeated() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    let two = episode("2", in: fixture)
    await fixture.coordinator.setLocalEpisodes([one])
    let changes = await fixture.coordinator.identityChanges(itemID: "rss:1", episodeID: "1")
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == one.identity)

    await fixture.coordinator.setLocalEpisodes([one, two])
    await fixture.coordinator.setLocalEpisodes([])

    #expect(await iterator.next() == .some(nil))
  }

  // MARK: - The complete-transcript reader (ad skip's host-read pass)

  /// The identities the stream has yielded so far.
  private final class Changes: Sendable {
    private let seen = Mutex<[AdSkipEpisodeIdentity]>([])
    var all: [AdSkipEpisodeIdentity] { seen.withLock { $0 } }
    func add(_ identity: AdSkipEpisodeIdentity) { seen.withLock { $0.append(identity) } }
  }

  private func observingCompleteChanges(_ fixture: Fixture) async -> (Changes, Task<Void, Never>) {
    let changes = Changes()
    let stream = await fixture.coordinator.completeTranscriptChanges()
    return (changes, Task { for await identity in stream { changes.add(identity) } })
  }

  @Test func onlyACompleteTranscriptOfTheCurrentFileIsRead() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let one = episode("1", in: fixture)
    await ready(fixture, [one])
    let (changes, task) = await observingCompleteChanges(fixture)
    defer { task.cancel() }
    #expect(await fixture.coordinator.completeTranscript(for: one.identity) == nil)

    await fixture.coordinator.request(one.identity)
    try await fixture.session.emit(.started(duration: 100), call: 0)
    try await fixture.session.emit(
      .finalized(words: [word("Hello", 1, 2), word("there.", 2, 3)], through: 50), call: 0)
    // The running session's words are not a complete transcript, in memory or once saved.
    #expect(await fixture.coordinator.completeTranscript(for: one.identity) == nil)
    await fixture.coordinator.cancel(one.identity)
    await eventually { await fixture.coordinator.status(for: one.identity) == .stopped(covered: 0.5) }
    #expect(await fixture.coordinator.completeTranscript(for: one.identity) == nil)
    #expect(changes.all.isEmpty)

    await fixture.coordinator.request(one.identity)
    _ = try await fixture.session.call(1)
    try await fixture.session.emit(.started(duration: 100), call: 1)
    try await fixture.session.emit(.finalized(words: [word("Bye.", 90, 91)], through: 100), call: 1)
    await fixture.session.end(1)
    await eventually { changes.all == [one.identity] }

    let complete = try #require(await fixture.coordinator.completeTranscript(for: one.identity))
    #expect(complete.transcript.duration == 100)
    #expect(complete.transcript.words.last == word("Bye.", 90, 91))
    #expect(complete.fileName == (try await fixture.store.record(for: one.identity)?.transcriptFileName))

    // The file changed under the stored transcript: not this file's words, even before clean-up.
    fixture.fingerprints.set(
      one.fileURL, AdSkipFileFingerprint(byteSize: 2_000, modificationTime: 1_600_000_000))
    #expect(await fixture.coordinator.completeTranscript(for: one.identity) == nil)
  }

  @Test func removingACompleteTranscriptIsReportedAndAPartialOneIsNot() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let complete = episode("complete", in: fixture)
    let partial = episode("partial", in: fixture)
    let transcript = StoredTranscript(
      words: [StoredTranscriptWord(text: "Hi", start: 0, end: 1)], silences: [], duration: 10)
    try await fixture.store.saveProgress(
      transcript, for: complete.identity, fingerprint: transcriptFingerprint,
      transcriberRevision: "r", isComplete: true, at: Self.start)
    try await fixture.store.saveProgress(
      transcript, for: partial.identity, fingerprint: transcriptFingerprint,
      transcriberRevision: "r", isComplete: false, at: Self.start)
    await ready(fixture, [complete, partial])
    let (changes, task) = await observingCompleteChanges(fixture)
    defer { task.cancel() }
    #expect(await fixture.coordinator.completeTranscript(for: complete.identity) != nil)
    #expect(await fixture.coordinator.completeTranscript(for: partial.identity) == nil)

    await fixture.coordinator.setLocalEpisodes([])
    await eventually { (try? await fixture.store.allRecords().isEmpty) == true }
    await eventually { changes.all.isEmpty == false }
    #expect(changes.all == [complete.identity])
    #expect(await fixture.coordinator.completeTranscript(for: complete.identity) == nil)
  }
}
