import Foundation
import Testing

typealias WaiterResumer = @Sendable (TestWaitOutcome) -> Void

/// Progress-bounded watchdog for the continuation-backed fake waiters below. A waiter whose
/// predicate never holds would suspend forever, and a suite `.timeLimit` cannot rescue it because
/// cancellation never resumes a parked `withCheckedContinuation`. This polls with the same
/// serviced-budget discipline as `waitUntil` (no wall-clock deadline), then atomically claims the
/// waiter. Claiming and normal resumption are mutually exclusive under the fake's lock, so a
/// satisfied wait never also records a timeout.
func expireContinuationWaiter(
  label: String,
  timeout: TimeInterval,
  sourceLocation: SourceLocation,
  isRegistered: @escaping @Sendable () -> Bool,
  removeAndClaim: @escaping @Sendable () -> WaiterResumer?,
  observedState: @escaping @Sendable () -> String
) async {
  let startedAt = Date()
  var servicedPolls = 0

  func diagnostic() -> TestWaitDiagnostic {
    TestWaitDiagnostic(
      label: label,
      servicedPolls: servicedPolls,
      elapsedSeconds: Date().timeIntervalSince(startedAt),
      observedState: observedState())
  }

  func finish(_ outcome: TestWaitOutcome, issuePrefix: String?) {
    guard let resume = removeAndClaim() else { return }
    let diagnostic = outcome.diagnostic ?? diagnostic()
    if let issuePrefix {
      Issue.record("\(issuePrefix) \(diagnostic)", sourceLocation: sourceLocation)
    }
    resume(outcome)
  }

  for _ in 0..<50 {
    if isRegistered() == false { return }
    if Task.isCancelled {
      finish(.cancelled(diagnostic()), issuePrefix: nil)
      return
    }
    await Task.yield()
    servicedPolls += 1
  }
  var budgetMilliseconds = Int(timeout * 1000)
  while budgetMilliseconds > 0 {
    if isRegistered() == false { return }
    do {
      try await Task.sleep(for: .milliseconds(1))
    } catch {
      // `Task.sleep` throws only on cancellation. A cancelled watchdog claims its waiter and
      // unwinds it rather than leaving it parked.
      finish(.cancelled(diagnostic()), issuePrefix: nil)
      return
    }
    servicedPolls += 1
    budgetMilliseconds -= 1
  }
  finish(.timedOut(diagnostic()), issuePrefix: "timed out while")
}

func cancelContinuationWaiter(
  label: String,
  sourceLocation: SourceLocation,
  startedAt: Date,
  observedState: @escaping @Sendable () -> String,
  removeAndClaim: @escaping @Sendable () -> WaiterResumer?
) {
  guard let resume = removeAndClaim() else { return }
  let diagnostic = TestWaitDiagnostic(
    label: label,
    servicedPolls: 0,
    elapsedSeconds: Date().timeIntervalSince(startedAt),
    observedState: observedState())
  // Caller cancellation is expected teardown for these non-throwing fakes. The `.cancelled`
  // outcome carries the diagnostic without turning task cleanup into a test failure; only expiry
  // records an Issue.
  resume(.cancelled(diagnostic))
}
