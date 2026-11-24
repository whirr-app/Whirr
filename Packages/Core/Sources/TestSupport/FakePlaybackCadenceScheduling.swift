import Foundation
import SyncEngine
import Testing

/// `PlaybackCadenceScheduling`'s fake: a manual clock for the one pending deadline the protocol
/// allows. It never sleeps and never fires on its own; a test calls `fire()` to let the deadline
/// elapse. `reschedule` replaces the pending deadline and `cancelPending` drops it, exactly as the
/// protocol requires, and both are recorded so a test can assert how often the cadence rearmed.
///
/// A test that only needs a scheduler that does nothing passes one in and ignores it.
public final class FakePlaybackCadenceScheduling: PlaybackCadenceScheduling, @unchecked Sendable {
  /// One protocol call.
  public enum Call: Sendable, Equatable {
    case reschedule(after: TimeInterval)
    case cancelPending
  }

  private struct Deadline: Sendable {
    let interval: TimeInterval
    let action: @Sendable () async -> Void
  }

  /// Every `reschedule` and `cancelPending`, in order.
  public let recorder = CallRecorder<Call>(label: "FakePlaybackCadenceScheduling calls")

  private let state = WaitableState<Deadline?>(
    nil, label: "FakePlaybackCadenceScheduling pending deadline"
  ) { deadline in
    deadline.map { "pending in \($0.interval)s" } ?? "nothing pending"
  }

  public init() {}

  /// The interval of the pending deadline, or `nil` when none is pending.
  public var pendingInterval: TimeInterval? { state.value?.interval }

  /// How many times `reschedule` has been called.
  public var scheduleCount: Int {
    recorder.calls.filter { if case .reschedule = $0 { true } else { false } }.count
  }

  /// How many times `cancelPending` has been called.
  public var cancelCount: Int {
    recorder.calls.filter { $0 == .cancelPending }.count
  }

  public func reschedule(
    after interval: TimeInterval, action: @escaping @Sendable () async -> Void
  ) async {
    recorder.record(.reschedule(after: interval))
    state.mutate { $0 = Deadline(interval: interval, action: action) }
  }

  public func cancelPending() async {
    recorder.record(.cancelPending)
    state.mutate { $0 = nil }
  }

  /// Simulates the pending deadline elapsing: it stops being pending, like a real timer, and its
  /// action runs to completion before this returns. Returns `false`, doing nothing, when no
  /// deadline was pending.
  @discardableResult
  public func fire() async -> Bool {
    let deadline = state.mutate { state -> Deadline? in
      let current = state
      state = nil
      return current
    }
    guard let deadline else { return false }
    await deadline.action()
    return true
  }

  /// Suspends, bounded, until the pending interval satisfies `predicate` (`nil` meaning nothing is
  /// pending). It is evaluated atomically with every `reschedule` and `cancelPending`.
  @discardableResult
  public func waitForInterval(
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation,
    satisfying predicate: @escaping @Sendable (TimeInterval?) -> Bool
  ) async -> TestWaitOutcome {
    await state.waitUntil(
      "reaching a satisfying interval", timeout: timeout, sourceLocation: sourceLocation
    ) { predicate($0?.interval) }
  }

  /// Suspends, bounded, until the pending interval equals `expected` (`nil` meaning nothing is
  /// pending).
  @discardableResult
  public func waitForInterval(
    _ expected: TimeInterval?,
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> TestWaitOutcome {
    await waitForInterval(timeout: timeout, sourceLocation: sourceLocation) { $0 == expected }
  }
}
