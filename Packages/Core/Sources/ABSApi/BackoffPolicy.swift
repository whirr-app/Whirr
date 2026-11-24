import Foundation

/// Stateful failure counter with injectable time and randomness for deterministic tests.
///
/// Public because SyncEngine's outbox drain reuses it for retry pacing (API-CONVENTIONS.md
/// rule 14). The drain seeds `failureCount` from the durable `OutboxOperationRecord.attempts`, so
/// a relaunch between attempts still computes the correct next delay.
public struct BackoffPolicy: Sendable {
  public static let baseDelay: TimeInterval = 1
  public static let maximumDelay: TimeInterval = 5 * 60

  public private(set) var failureCount: Int

  public init(failureCount: Int = 0) {
    self.failureCount = failureCount
  }

  public mutating func nextDelay(
    retryAfter: String? = nil,
    now: Date = Date(),
    randomUnit: Double = Double.random(in: 0...1)
  ) -> TimeInterval {
    failureCount += 1

    if let retryAfter = Self.saneRetryAfter(retryAfter, now: now) {
      return retryAfter
    }

    let exponential = min(
      Self.maximumDelay,
      Self.baseDelay * pow(2, Double(max(0, failureCount - 1)))
    )
    let boundedRandomUnit = min(1, max(0, randomUnit))
    return min(Self.maximumDelay, exponential * boundedRandomUnit)
  }

  public mutating func reset() {
    failureCount = 0
  }

  public static func isRetryable(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    guard let error = error as? APIError else { return false }
    switch error {
    case .transport, .rateLimited:
      return true
    case .serverFailure:
      return true
    case .badRequest, .unauthorized, .forbidden, .notFound, .payloadTooLarge, .unexpectedStatus,
      .decoding, .ambiguousLocalSessionResponse, .incompatibleServer, .invalidServerConfiguration, .cancelled:
      return false
    }
  }

  private static func saneRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
    guard let value, value.isEmpty == false else { return nil }

    if let seconds = TimeInterval(value), seconds >= 0, seconds <= maximumDelay {
      return seconds
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value) else { return nil }
    let delay = date.timeIntervalSince(now)
    guard delay >= 0, delay <= maximumDelay else { return nil }
    return delay
  }
}
