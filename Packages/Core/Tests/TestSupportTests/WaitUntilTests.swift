import Foundation
import Testing

@testable import TestSupport

@Suite struct WaitUntilTests {
  @Test func alreadyTrueConditionReturnsImmediately() async {
    let result = await waitUntil { true }
    #expect(result)
  }

  @Test func conditionFlippedByConcurrentWorkIsObserved() async {
    let flag = Locked(false)
    let task = Task {
      await Task.yield()
      flag.value = true
    }
    let result = await waitUntil { flag.value }
    #expect(result)
    await task.value
  }

  @MainActor
  @Test func mainActorCallerCanReadIsolatedStateInTheCondition() async {
    // Non-Sendable, MainActor-confined state: the waiter must run on the caller's isolation
    // for this closure to compile at all, so this is mainly a compile-shape check.
    var value = 0
    let result = await waitUntil {
      value += 1
      return value >= 3
    }
    #expect(result)
  }

  @Test func timeoutRecordsAnIssueAndReturnsFalse() async {
    await withKnownIssue {
      let result = await waitUntil(timeout: 0.05) { false }
      #expect(!result)
    }
  }

  // MARK: - Outcomes

  @Test func anObservedConditionCarriesNoDiagnostic() async {
    let outcome = await awaitCondition("an immediately true condition") { true }
    #expect(outcome == .observed)
    #expect(outcome.diagnostic == nil)
  }

  @Test func aTimeoutCarriesTheLabelAndTheServicedPollCount() async {
    await withKnownIssue {
      let outcome = await awaitCondition(
        "a condition that never becomes true",
        timeout: 0.05,
        observing: { "flag=false" },
        until: { false })

      guard case .timedOut(let diagnostic) = outcome else {
        Issue.record("expected a timeout, got \(outcome)")
        return
      }
      #expect(diagnostic.label == "a condition that never becomes true")
      #expect(diagnostic.servicedPolls > 0)
      #expect(diagnostic.observedState == "flag=false")
    }
  }

  /// Swallowing cancellation with `try? await Task.sleep` would let a cancelled wait spin out its
  /// remaining budget as fast as the CPU allowed. That burns the pool other tests need and defeats
  /// any `.timeLimit` backstop, because the task never unwinds.
  @Test func aCancelledWaitUnwindsInsteadOfSpinningOutItsBudget() async {
    let started = Locked(false)
    let task = Task { () -> TestWaitOutcome in
      await awaitCondition(
        "a condition that never becomes true",
        timeout: 600,
        recordingIssue: false
      ) {
        started.value = true
        return false
      }
    }

    // Cancel only once the waiter is definitely inside its loop, so this proves the loop unwinds
    // rather than that the task was cancelled before it ever ran.
    _ = await waitUntil("the waiter under test to start polling") { started.value }
    task.cancel()

    let outcome = await task.value
    guard case .cancelled(let diagnostic) = outcome else {
      Issue.record("expected a cancellation, got \(outcome)")
      return
    }
    #expect(diagnostic.label == "a condition that never becomes true")
  }

  /// The case above cancels during the yield fast path. This one waits until the waiter has spent
  /// that path and is parked in the 1ms sleep loop, where `try? await Task.sleep` would discard the
  /// cancellation. Both windows need their own case.
  @Test(.timeLimit(.minutes(1)))
  func aWaitCancelledInsideTheSleepLoopAlsoUnwinds() async {
    let polls = Locked(0)
    let task = Task { () -> TestWaitOutcome in
      await awaitCondition("never", timeout: 600, recordingIssue: false) {
        polls.value += 1
        return false
      }
    }

    // The fast path is fifty yields; wait past it so the cancellation lands in the sleep loop.
    _ = await waitUntil("the waiter under test to leave its yield fast path", timeout: 30) {
      polls.value > 60
    }
    task.cancel()

    let outcome = await task.value
    guard case .cancelled(let diagnostic) = outcome else {
      Issue.record("expected a cancellation, got \(outcome)")
      return
    }
    #expect(diagnostic.servicedPolls > 50)
  }

  /// A 600-second budget cannot be spent in the time this test takes, so finishing at all proves
  /// the wait returned on cancellation rather than running the budget down.
  @Test(.timeLimit(.minutes(1)))
  func aCancelledWaitReturnsPromptly() async {
    let started = Locked(false)
    let task = Task { () -> TestWaitOutcome in
      await awaitCondition("never", timeout: 600, recordingIssue: false) {
        started.value = true
        return false
      }
    }
    _ = await waitUntil("the waiter under test to start polling") { started.value }

    let cancelledAt = Date()
    task.cancel()
    let outcome = await task.value
    let elapsed = Date().timeIntervalSince(cancelledAt)

    #expect(outcome.isObserved == false)
    #expect(elapsed < 5, "a cancelled wait took \(elapsed)s to unwind")
  }

  @Test func recordingIssueCanBeSuppressedForWaitsThatAreAllowedToExpire() async {
    // No `withKnownIssue`: the point is that nothing is recorded at all.
    let outcome = await awaitCondition("a deliberately expiring wait", timeout: 0.02, recordingIssue: false) {
      false
    }
    #expect(outcome.isObserved == false)
  }

  @Test func theBooleanShorthandAgreesWithTheOutcome() async {
    #expect(await waitUntil("an immediately true condition") { true })
    await withKnownIssue {
      #expect(await waitUntil("never", timeout: 0.02) { false } == false)
    }
  }

  /// A producer may signal after a watchdog has already claimed a waiter. The claim removes the
  /// continuation under the same lock used by the producer, so the late signal is a no-op rather
  /// than a second resume.
  @Test func aLateSignalAfterTimeoutCannotResumeTwice() async {
    let gate = PlannerGate()
    await withKnownIssue {
      let outcome = await gate.waitUntilStarted(episodeID: "late", timeout: 0.02)
      guard case .timedOut = outcome else {
        Issue.record("expected the abandoned start waiter to time out, got \(outcome)")
        return
      }
    }

    let releaseTask = Task { await gate.waitForRelease(episodeID: "late") }
    _ = await waitUntil("the release waiter to register") {
      await gate.isWaitingForRelease(episodeID: "late")
    }
    await gate.release(episodeID: "late")
    await gate.release(episodeID: "late")

    #expect(await releaseTask.value == .observed)
  }

  // MARK: - Quiescence

  @Test func aSignalThatStopsChangingReachesQuiescence() async {
    let remaining = Locked(3)
    let outcome = await awaitQuiescence("a signal that settles", stableFor: 4) {
      remaining.withValue { value in
        if value > 0 { value -= 1 }
        return "\(value)"
      }
    }
    #expect(outcome.isObserved)
  }

  @Test func aSignalThatNeverStopsChangingNeverSettles() async {
    let ticks = Locked(0)
    let outcome = await awaitQuiescence(
      "a signal that never settles", timeout: 0.05, recordingIssue: false
    ) {
      ticks.withValue { value in
        value += 1
        return "\(value)"
      }
    }
    let diagnostic = outcome.diagnostic
    #expect(outcome.isObserved == false)
    #expect(diagnostic?.observedState.contains("stable for 1 of 50 polls") == true)
  }

  /// A settled signal is not enough on its own: the barrier has to survive the case where the value
  /// settles, moves once more, and settles again. Only the final run of `stableFor` polls counts.
  @Test func aLateChangeRestartsTheStabilityCount() async {
    let step = Locked(0)
    let outcome = await awaitQuiescence("a signal that jolts once more", stableFor: 4) {
      step.withValue { value in
        value += 1
        // Steady, then one late change, then steady again.
        return value < 4 ? "a" : (value == 4 ? "b" : "c")
      }
    }
    #expect(outcome.isObserved)
  }

  /// Delegating to `awaitCondition` would be wrong: its yield fast path polls essentially for free,
  /// so a few yields can elapse between two steps of the work being waited on and the barrier would
  /// call a still-running system settled. Quiescence is counted in serviced polls, not yields.
  @Test func quiescenceDoesNotSettleAcrossAGapThatYieldsWouldCross() async {
    let counter = Locked(0)
    let producer = Task {
      for _ in 0..<10 {
        try await Task.sleep(for: .milliseconds(5))
        counter.withValue { $0 += 1 }
      }
    }

    let outcome = await awaitQuiescence("a signal that keeps stepping", stableFor: 50) {
      "\(counter.value)"
    }
    // Sampled before joining the producer: joining first would let the counter reach 10 no matter
    // when the barrier returned, so the assertion could look green while failing.
    let atBarrier = counter.value
    _ = await producer.result

    #expect(outcome.isObserved)
    #expect(atBarrier == 10, "the barrier settled at \(atBarrier) while the producer was stepping")
  }

  @Test func aCancelledQuiescenceWaitUnwinds() async {
    let started = Locked(false)
    let task = Task {
      await awaitQuiescence("a signal nobody lets settle", timeout: 30, recordingIssue: false) {
        started.withValue { $0 = true }
        return UUID().uuidString
      }
    }
    _ = await waitUntil("the quiescence wait to start polling") { started.value }

    task.cancel()
    let outcome = await task.value

    #expect(outcome.isObserved == false)
    if case .cancelled = outcome {} else { Issue.record("expected a cancellation, got \(outcome)") }
  }
}
