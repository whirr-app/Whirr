import Foundation
import Testing

@testable import TestSupport

@Suite("Call recorder")
struct CallRecorderTests {
  enum Call: Sendable, Equatable {
    case fetch(String)
    case cancel
  }

  @Test func recordsCallsInOrder() {
    let recorder = CallRecorder<Call>(label: "test fake")
    recorder.record(.fetch("a"))
    recorder.record(.cancel)
    #expect(recorder.calls == [.fetch("a"), .cancel])
    #expect(recorder.count == 2)
    recorder.removeAll()
    #expect(recorder.calls.isEmpty)
  }

  @Test func aWaitAlreadySatisfiedReturnsAtOnce() async {
    let recorder = CallRecorder<Call>(label: "test fake")
    recorder.record(.cancel)
    #expect(await recorder.waitUntil { $0.contains(.cancel) } == .observed)
  }

  @Test func aWaitResumesWhenALaterCallSatisfiesIt() async {
    let recorder = CallRecorder<Call>(label: "test fake")
    async let outcome = recorder.waitUntil(count: 2)
    recorder.record(.fetch("a"))
    recorder.record(.fetch("b"))
    #expect(await outcome == .observed)
  }

  @Test func aWaitThatNeverHoldsTimesOutWithTheLogItSaw() async {
    let recorder = CallRecorder<Call>(label: "test fake")
    recorder.record(.fetch("a"))
    await withKnownIssue {
      let outcome = await recorder.waitUntil(timeout: 0.05) { $0.contains(.cancel) }
      guard case .timedOut(let diagnostic) = outcome else {
        Issue.record("expected a timeout, got \(outcome)")
        return
      }
      #expect(diagnostic.label == "test fake satisfying the predicate")
      #expect(diagnostic.observedState.hasPrefix("recorded 1 calls; last fetch(\"a\")"))
    }
  }

  @Test func cancellingAWaitResumesItWithoutAnIssue() async {
    let recorder = CallRecorder<Call>(label: "test fake")
    let waiting = Task { await recorder.waitUntil { $0.contains(.cancel) } }
    waiting.cancel()
    guard case .cancelled = await waiting.value else {
      Issue.record("expected cancellation")
      return
    }
  }

  @Test func theCountRecorderWaitsForItsTarget() async {
    let counter = TestCountRecorder(label: "events")
    async let outcome = counter.waitUntil(count: 3)
    for _ in 0..<3 { counter.record() }
    #expect(await outcome == .observed)
    #expect(counter.count == 3)
  }
}
