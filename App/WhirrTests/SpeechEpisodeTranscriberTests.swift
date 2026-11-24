import AdSkip
import CoreMedia
import Foundation
import Speech
import Testing

@testable import Whirr

/// The recogniser itself is not run here: whether the simulator has the speech asset is outside the
/// test's control. These pin what the adapter does with a result's attributed text and with the
/// asset inventory's answers.
@Suite("Speech episode transcriber")
struct SpeechEpisodeTranscriberTests {

  private func run(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
    var run = AttributedString(text)
    run.audioTimeRange = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 1_000),
      end: CMTime(seconds: end, preferredTimescale: 1_000))
    return run
  }

  @Test("each timed run keeps its text and range")
  func timedRunsKeepTextAndRange() {
    let text = run("Hello", 1, 1.5) + run(" there friend", 1.5, 2.25)

    let runs = SpeechEpisodeTranscriber.timedRuns(in: text)

    #expect(
      runs == [
        TimedRun(text: "Hello", start: 1, end: 1.5),
        TimedRun(text: " there friend", start: 1.5, end: 2.25),
      ])
  }

  @Test("text without a time range is dropped")
  func untimedTextIsDropped() {
    let text = run("one", 0, 0.5) + AttributedString(" ") + run("two", 0.5, 1)

    let runs = SpeechEpisodeTranscriber.timedRuns(in: text)

    #expect(runs.map(\.text) == ["one", "two"])
  }

  @Test("a range with an invalid time is dropped")
  func invalidTimeIsDropped() {
    var text = AttributedString("lost")
    text.audioTimeRange = CMTimeRange(start: .invalid, end: .invalid)

    #expect(SpeechEpisodeTranscriber.timedRuns(in: text).isEmpty)
  }

  @Test("the locale is pinned to the harness's")
  func localeIsPinned() {
    #expect(AdSkipSpeech.localeIdentifier == "en-US")
  }

  /// The simulator's speech asset is outside the test's control, so either answer pins the mapping:
  /// ready answers for the pinned locale, and every other outcome is a deferral or a missing format.
  @Test("readiness answers for the pinned locale or defers")
  func readiness() async {
    do {
      let ready = try await AdSkipSpeech.readiness()
      #expect(ready.locale.identifier == AdSkipSpeech.localeIdentifier)
      #expect(ready.target.channelCount > 0)
    } catch {
      #expect(error is AdSkipAnalysisDeferred || error is SpeechEpisodeTranscriber.Failure)
    }
  }

  /// One test over the pairs: `AssetInventory.Status` is not `Sendable`, so it cannot be a test argument.
  @Test("asset inventory answers map to installer states")
  func assetStates() {
    let expected: [(AssetInventory.Status, SpeechAssetState)] = [
      (.unsupported, .unavailable),
      (.supported, .notInstalled),
      (.downloading, .downloading),
      (.installed, .installed),
    ]
    for (status, state) in expected {
      #expect(SpeechAssetInstaller.state(for: status) == state)
    }
  }
}

/// The analyser's finalize ignores task cancellation, so these stand it in with work that ends only
/// when stopped: a cancel must stop it at once, not when the work next checks.
@Suite("Speech analysis cancellation")
struct SpeechAnalysisCancellationTests {

  /// Work that ignores cancellation and ends only when opened.
  private actor Gate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var stops = 0

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiter = $0 }
    }

    func stop() {
      stops += 1
      isOpen = true
      waiter?.resume()
      waiter = nil
    }
  }

  @Test("a cancel stops work that ignores cancellation, and the call throws")
  func cancelStopsWork() async {
    let gate = Gate()
    let task = Task {
      try await SpeechAnalysisCancellation.run {
        await gate.wait()
        return 1
      } stop: {
        await gate.stop()
      }
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await gate.stops == 1)
  }

  @Test("a throw from the work propagates and never stops it")
  func throwingWorkPropagates() async {
    struct Boom: Error, Equatable {}
    let gate = Gate()

    await #expect(throws: Boom.self) {
      try await SpeechAnalysisCancellation.run {
        throw Boom()
      } stop: {
        await gate.stop()
      }
    }
    #expect(await gate.stops == 0)
  }

  @Test("work that is not cancelled returns its value and is never stopped")
  func uncancelledWorkReturns() async throws {
    let gate = Gate()

    let value = try await SpeechAnalysisCancellation.run {
      42
    } stop: {
      await gate.stop()
    }

    #expect(value == 42)
    #expect(await gate.stops == 0)
  }
}
