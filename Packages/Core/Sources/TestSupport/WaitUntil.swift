import Foundation
import Testing

// MARK: - Outcome

/// What a bounded wait actually did.
///
/// A timeout means the product never reached the state; a cancellation means the test was torn
/// down and proves nothing either way.
public enum TestWaitOutcome: Sendable, Equatable, CustomStringConvertible {
  /// The condition became true within the serviced-polling budget.
  case observed
  /// The budget was spent without the condition ever becoming true.
  case timedOut(TestWaitDiagnostic)
  /// The waiting task was cancelled (by a suite `.timeLimit` or its parent) before the condition
  /// was observed. The wait unwinds instead of spinning out the rest of its budget.
  case cancelled(TestWaitDiagnostic)

  public var isObserved: Bool {
    if case .observed = self { return true }
    return false
  }

  public var diagnostic: TestWaitDiagnostic? {
    switch self {
    case .observed: nil
    case .timedOut(let diagnostic), .cancelled(let diagnostic): diagnostic
    }
  }

  public var description: String {
    switch self {
    case .observed: "observed"
    case .timedOut(let diagnostic): "timed out - \(diagnostic)"
    case .cancelled(let diagnostic): "cancelled - \(diagnostic)"
    }
  }
}

/// Why a wait ended without observing its condition. The log names the awaited event, how much
/// serviced waiting it got, and what the fixture looked like at the end.
public struct TestWaitDiagnostic: Sendable, Equatable, CustomStringConvertible {
  /// What the caller was waiting for, in the caller's own words.
  public var label: String
  /// Polls that were actually serviced. Under pool starvation this is far lower than the elapsed
  /// milliseconds, which is the distinction the progress-bounded budget exists to preserve.
  public var servicedPolls: Int
  /// Wall-clock time the wait took. Reported only, never the bound.
  public var elapsedSeconds: Double
  /// Fixture state at the moment the wait gave up, if the caller supplied a way to describe it.
  public var observedState: String

  public init(label: String, servicedPolls: Int, elapsedSeconds: Double, observedState: String) {
    self.label = label
    self.servicedPolls = servicedPolls
    self.elapsedSeconds = elapsedSeconds
    self.observedState = observedState
  }

  public var description: String {
    let elapsed = String(format: "%.3f", elapsedSeconds)
    let base = "waiting for \(label): \(servicedPolls) serviced polls over \(elapsed)s"
    return observedState.isEmpty ? base : "\(base); observed state: \(observedState)"
  }
}

// MARK: - The primitive

/// The one polling waiter for every test target.
///
/// Progress-bounded, not wall-clock bounded: after a short yield fast-path it waits in 1ms slices
/// and decrements the budget once per serviced resume. A wall-clock budget keeps ticking while the
/// cooperative pool is saturated (e.g. synchronous GRDB writes in a full parallel run) and would
/// expire before the condition ran; here each resume takes far longer than 1ms under starvation,
/// so the wait stretches with the stall. `timeout` is a floor on serviced waiting, and a
/// wall-clock ceiling must not be added. The outer bound is the suite's `.timeLimit`, which works
/// because this function unwinds on cancellation.
///
/// Runs on the caller's isolation, so `@MainActor` tests can pass non-Sendable closures that
/// read model state directly.
public func awaitCondition(
  _ label: String,
  timeout: TimeInterval = 5,
  recordingIssue: Bool = true,
  isolation: isolated (any Actor)? = #isolation,
  sourceLocation: SourceLocation = #_sourceLocation,
  observing state: () async -> String = { "" },
  until condition: () async -> Bool
) async -> TestWaitOutcome {
  let startedAt = Date()
  var servicedPolls = 0

  func diagnose() async -> TestWaitDiagnostic {
    TestWaitDiagnostic(
      label: label,
      servicedPolls: servicedPolls,
      elapsedSeconds: Date().timeIntervalSince(startedAt),
      observedState: await state())
  }

  // Fast path: most conditions flip within a few scheduler turns of the stimulus.
  for _ in 0..<50 {
    if await condition() { return .observed }
    await Task.yield()
    servicedPolls += 1
    if Task.isCancelled {
      let diagnostic = await diagnose()
      if recordingIssue { Issue.record("cancelled while \(diagnostic)", sourceLocation: sourceLocation) }
      return .cancelled(diagnostic)
    }
  }

  var budgetMilliseconds = Int(timeout * 1000)
  while budgetMilliseconds > 0 {
    if await condition() { return .observed }
    do {
      try await Task.sleep(for: .milliseconds(1))
    } catch {
      // Cancellation, not a spurious failure: `Task.sleep` throws only when the task is cancelled.
      // Swallowing it with `try?` would turn the remaining budget into a tight spin and defeat the
      // suite `.timeLimit`.
      let diagnostic = await diagnose()
      if recordingIssue { Issue.record("cancelled while \(diagnostic)", sourceLocation: sourceLocation) }
      return .cancelled(diagnostic)
    }
    servicedPolls += 1
    budgetMilliseconds -= 1
  }

  if await condition() { return .observed }
  let diagnostic = await diagnose()
  if recordingIssue { Issue.record("timed out \(diagnostic)", sourceLocation: sourceLocation) }
  return .timedOut(diagnostic)
}

/// Boolean shorthand over `awaitCondition`. Prefer `awaitCondition` in new code: its outcome
/// distinguishes a timeout from a cancellation.
@discardableResult
public func waitUntil(
  _ label: String = "condition",
  timeout: TimeInterval = 5,
  isolation: isolated (any Actor)? = #isolation,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: () async -> Bool
) async -> Bool {
  await awaitCondition(
    label,
    timeout: timeout,
    isolation: isolation,
    sourceLocation: sourceLocation,
    until: condition
  ).isObserved
}

/// Waits until a signal stops changing, for negative assertions `awaitCondition` cannot express.
///
/// `#expect(nothing.happened)` needs a barrier: run immediately, it passes before the work it
/// denies could have started. This polls `signal()` on the progress-bounded schedule and returns
/// `.observed` once it reports the same value for `stableFor` consecutive serviced 1ms polls.
///
/// Serviced polls, not yields: yields cost nothing, so several elapse between two steps of the
/// awaited work and a yield-counted floor would call that settled. Under a saturated cooperative
/// pool each serviced poll stretches with the stall. Unlike `awaitCondition` there is no yield
/// fast path, because settling early is the failure mode.
///
/// A bound with a diagnostic, not a proof of causality. Where one can be built, a fake that
/// acknowledges its work (such as "the drain task ran and found the queue empty") is better.
@discardableResult
public func awaitQuiescence(
  _ label: String,
  stableFor: Int = 50,
  timeout: TimeInterval = 5,
  recordingIssue: Bool = true,
  isolation: isolated (any Actor)? = #isolation,
  sourceLocation: SourceLocation = #_sourceLocation,
  of signal: () async -> String
) async -> TestWaitOutcome {
  let startedAt = Date()
  var servicedPolls = 0
  var lastValue: String?
  var consecutiveStablePolls = 0

  func diagnose() -> TestWaitDiagnostic {
    TestWaitDiagnostic(
      label: label,
      servicedPolls: servicedPolls,
      elapsedSeconds: Date().timeIntervalSince(startedAt),
      observedState:
        "last \(lastValue ?? "nothing"), stable for \(consecutiveStablePolls) of \(stableFor) polls")
  }

  var budgetMilliseconds = Int(timeout * 1000)
  while budgetMilliseconds > 0 {
    let value = await signal()
    if value == lastValue {
      consecutiveStablePolls += 1
      if consecutiveStablePolls >= stableFor { return .observed }
    } else {
      lastValue = value
      consecutiveStablePolls = 1
    }

    do {
      try await Task.sleep(for: .milliseconds(1))
    } catch {
      // Cancellation, not a spurious failure: `Task.sleep` throws only on cancel.
      let diagnostic = diagnose()
      if recordingIssue {
        Issue.record("cancelled while awaiting quiescence, \(diagnostic)", sourceLocation: sourceLocation)
      }
      return .cancelled(diagnostic)
    }
    servicedPolls += 1
    budgetMilliseconds -= 1
  }

  let diagnostic = diagnose()
  if recordingIssue {
    Issue.record("never settled while \(diagnostic)", sourceLocation: sourceLocation)
  }
  return .timedOut(diagnostic)
}
