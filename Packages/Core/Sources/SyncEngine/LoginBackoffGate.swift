import ABSApi
import Foundation

/// Admission state for the rate-limited `/login` route; an actor because
/// `AccountLifecycleService` stays a synchronous-property, lock-free service. `BackoffPolicy`
/// owns the exponential/jitter math; this type records the next admission time and owns the
/// injectable clock/randomness seams.
///
/// Client-side UX politeness, not a security boundary. Admission atomically reserves one
/// in-flight attempt; until it resolves via `recordFailure()` or `recordSuccess()`, other
/// callers get a short retry delay.
public actor LoginBackoffGate {
  private let now: @Sendable () -> Date
  private let randomUnit: @Sendable () -> Double
  private var policy = ABSApi.BackoffPolicy()
  private var blockedUntil: Date?
  private var hasInFlightReservation = false
  private let inFlightRetryAfter: TimeInterval = 0.1

  public init(
    now: @escaping @Sendable () -> Date = { Date() },
    randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.now = now
    self.randomUnit = randomUnit
  }

  /// Atomically admits one attempt, returning `nil`, or returns the delay for a rejected attempt.
  /// A zero-length jitter window is open immediately after it expires; this gate is
  /// politeness for user experience, not a lockout mechanism.
  public func admit() -> TimeInterval? {
    if hasInFlightReservation { return inFlightRetryAfter }
    if let blockedUntil {
      let remaining = blockedUntil.timeIntervalSince(now())
      guard remaining > 0 else {
        self.blockedUntil = nil
        hasInFlightReservation = true
        return nil
      }
      return remaining
    }
    hasInFlightReservation = true
    return nil
  }

  /// Returns the remaining delay for a blocked user-initiated attempt, or `nil` when admission is
  /// open. An expired window is cleared here so the next attempt is admitted without a latch.
  public func retryAfter() -> TimeInterval? {
    guard let blockedUntil else { return nil }
    let remaining = blockedUntil.timeIntervalSince(now())
    guard remaining > 0 else {
      self.blockedUntil = nil
      return nil
    }
    return remaining
  }

  /// Releases the in-flight reservation without judging the attempt. For failures that happen
  /// before a request exists (local setup errors): unlike `recordSuccess`, this keeps the armed
  /// window and the policy's failure counter, so a database or config error between admission and
  /// the request cannot erase real backoff history.
  public func releaseReservation() {
    hasInFlightReservation = false
  }

  /// Arms the next window after a failed request. The first failure is counted by
  /// `BackoffPolicy.nextDelay`, whose full-jitter result may be zero.
  public func recordFailure() {
    let failureDate = now()
    let delay = policy.nextDelay(now: failureDate, randomUnit: randomUnit())
    blockedUntil = failureDate.addingTimeInterval(delay)
    hasInFlightReservation = false
  }

  /// Clears both the admission window and the policy's failure counter after a successful login.
  public func recordSuccess() {
    policy.reset()
    blockedUntil = nil
    hasInFlightReservation = false
  }
}
