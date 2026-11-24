import AdSkip
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `LookBackCoordinator`: one hold of the gate for a whole window, join repair, and a clean
/// release however the run ends.
@Suite struct LookBackCoordinatorTests {
  /// Answers each call from `handler`, recording the windows it was asked for.
  final class ScriptedTranscriber: EpisodeTranscribing {
    private let handler: @Sendable (URL, TimeSpan) async throws -> [TranscriptWord]
    private let calls = Mutex<[TimeSpan]>([])

    init(_ handler: @escaping @Sendable (URL, TimeSpan) async throws -> [TranscriptWord]) {
      self.handler = handler
    }

    var windows: [TimeSpan] { calls.withLock { $0 } }

    func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
      let window = try #require(windows.first)
      calls.withLock { $0.append(window) }
      return Transcript(words: try await handler(url, window), duration: 10_000)
    }
  }

  private final class Log: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
  }

  private let url = URL(fileURLWithPath: "/book/a.mp3")

  private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end)
  }

  private func chunk(_ start: Double, _ end: Double, offset: Double = 0) -> LookBackSegment {
    LookBackSegment(fileURL: url, localWindow: TimeSpan(start: start, end: end), startOffset: offset)
  }

  private func coordinator(
    _ gate: TranscriberGate, _ transcriber: any EpisodeTranscribing, log: Log = Log(),
    isTooHot: @escaping @Sendable () -> Bool = { false }
  ) -> LookBackCoordinator {
    LookBackCoordinator(
      dependencies: .init(
        gate: gate, transcriber: transcriber,
        yieldTranscripts: { log.append("yield") }, resumeTranscripts: { log.append("resume") },
        isTooHot: isTooHot))
  }

  @Test func noAdSkipCallRunsBetweenChunks() async throws {
    let gate = TranscriberGate()
    let log = Log()
    let adSkip = Mutex<Task<Void, any Error>?>(nil)
    let transcriber = ScriptedTranscriber { _, window in
      log.append("chunk \(Int(window.start))")
      if window.start == 150 {
        let task = Task {
          try await gate.acquire(for: .adSkip)
          log.append("adSkip")
          await gate.release()
        }
        adSkip.withLock { $0 = task }
        _ = await awaitCondition(
          "ad skip queued", observing: { "\(await gate.waitingCount) waiting" },
          until: { await gate.waitingCount == 1 })
      }
      return []
    }

    _ = try await coordinator(gate, transcriber, log: log).run(
      [chunk(150, 300), chunk(0, 150)], before: []
    ) { _ in }
    try await adSkip.withLock { $0 }?.value
    #expect(log.all == ["yield", "chunk 150", "chunk 0", "resume", "adSkip"])
    #expect(await gate.isHeldForTesting == false)
  }

  @Test func wordsMoveToTheBookClockAndARepeatAtAJoinIsDropped() async throws {
    let gate = TranscriberGate()
    let transcriber = ScriptedTranscriber { _, window in
      window.start == 150
        ? [word("and", 149.8, 150.3), word("then", 151, 152)]
        : [word("was", 148, 149), word("and", 149.7, 150.2)]
    }
    let reported = Mutex<[[String]]>([])

    let words = try await coordinator(gate, transcriber).run(
      [chunk(150, 300, offset: 1_000), chunk(0, 150, offset: 1_000)], before: []
    ) { event in
      if case .chunk(_, let words) = event { reported.withLock { $0.append(words.map(\.text)) } }
    }

    #expect(words.map(\.text) == ["was", "and", "then"])
    #expect(words.map(\.start) == [1_148, 1_149.8, 1_151])
    #expect(reported.withLock { $0 } == [["and", "then"], ["was", "and", "then"]])
  }

  @Test func anExtensionJoinsBeforeTheWordsAlreadyThere() async throws {
    let gate = TranscriberGate()
    let transcriber = ScriptedTranscriber { _, _ in [word("Earlier", 10, 11), word("on.", 149, 150.2)] }
    let existing = [word("on.", 149.9, 150.4), word("Later.", 160, 161)]

    let words = try await coordinator(gate, transcriber).run(
      [chunk(0, 150)], before: existing
    ) { _ in }

    #expect(words.map(\.text) == ["Earlier", "on.", "Later."])
  }

  @Test func cancellingMidChunkReleasesTheGateAndResumesTranscripts() async throws {
    let gate = TranscriberGate()
    let log = Log()
    let started = Mutex(false)
    let transcriber = ScriptedTranscriber { _, _ in
      started.withLock { $0 = true }
      // Hangs until cancelled, then throws as the real recogniser does.
      do { try await Task.sleep(for: .seconds(600)) } catch {}
      throw CancellationError()
    }
    let lookBack = coordinator(gate, transcriber, log: log)
    let run = Task { try await lookBack.run([chunk(150, 300), chunk(0, 150)], before: []) { _ in } }
    _ = await awaitCondition("chunk started") { started.withLock { $0 } }

    run.cancel()
    await #expect(throws: CancellationError.self) { _ = try await run.value }
    #expect(await gate.isHeldForTesting == false)
    #expect(log.all == ["yield", "resume"])
  }

  @Test func cancellingWhileWaitingAtTheGateResumesTranscriptsWithoutHoldingIt() async throws {
    let gate = TranscriberGate()
    try await gate.acquire(for: .adSkip)
    let log = Log()
    let transcriber = ScriptedTranscriber { _, _ in [] }
    let lookBack = coordinator(gate, transcriber, log: log)
    let events = Mutex<[LookBackEvent]>([])
    let run = Task {
      try await lookBack.run([chunk(0, 150)], before: []) { event in events.withLock { $0.append(event) } }
    }
    _ = await awaitCondition(
      "look back queued", observing: { "\(await gate.waitingCount) waiting" },
      until: { await gate.waitingCount == 1 })
    #expect(events.withLock { $0 } == [.waiting])

    run.cancel()
    await #expect(throws: CancellationError.self) { _ = try await run.value }
    #expect(log.all == ["yield", "resume"])
    #expect(transcriber.windows.isEmpty)
    await gate.release()
    #expect(await gate.isHeldForTesting == false)
  }

  @Test func criticalHeatStopsBeforeTheNextChunk() async throws {
    let gate = TranscriberGate()
    let hot = Mutex(false)
    let transcriber = ScriptedTranscriber { _, _ in
      hot.withLock { $0 = true }
      return [word("One.", 200, 201)]
    }

    await #expect(throws: LookBackTooHot.self) {
      _ = try await coordinator(gate, transcriber, isTooHot: { hot.withLock { $0 } }).run(
        [chunk(150, 300), chunk(0, 150)], before: []
      ) { _ in }
    }
    #expect(transcriber.windows == [TimeSpan(start: 150, end: 300)])
    #expect(await gate.isHeldForTesting == false)
  }

  @Test func noChunksTouchesNothing() async throws {
    let gate = TranscriberGate()
    let log = Log()
    let words = try await coordinator(gate, ScriptedTranscriber { _, _ in [] }, log: log).run(
      [], before: [word("Kept.", 1, 2)]
    ) { _ in }
    #expect(words.map(\.text) == ["Kept."])
    #expect(log.all.isEmpty)
  }
}
