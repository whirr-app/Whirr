import Foundation
import Persistence

/// What ended a transfer, in the terms the retry decision needs. Classified where the failure is
/// written, because only there is the error domain or HTTP status still in hand; the row keeps
/// its coarse `DownloadErrorCategory`.
public enum AutomaticDownloadFailure: Sendable, Equatable {
  /// A URLSession `.failed` event, including the background adapter's own `whirr.adapter.*` domains.
  case transfer(domain: String?, code: Int?)
  /// The ABS token renewal during an auth challenge failed for a reason other than `401`.
  case renewal
  /// The transfer finished with this non-2xx HTTP status.
  case httpStatus(Int)
}

/// The cap, backoff and classification for retrying failed automatic downloads, and the only place
/// those numbers live. The store receives the computed deadline and knows nothing of this policy.
public struct AutomaticDownloadRetryPolicy: Sendable, Equatable {
  /// The wait before each retry; its count is the cap. With the default, a row gets at most three
  /// retries after its first attempt. The short first steps fit the overnight task's 30-minute
  /// same-night retry; the last lets a server outage clear.
  public let backoff: [TimeInterval]

  public static let standard = AutomaticDownloadRetryPolicy(backoff: [10 * 60, 30 * 60, 2 * 60 * 60])

  public init(backoff: [TimeInterval]) {
    self.backoff = backoff
  }

  /// The earliest time to retry, or `nil` when this failure must not be retried automatically:
  /// a manual row, a failure that would recur, or a row that has spent its cap.
  public func nextAttempt(
    after failedAt: Date, retriesSoFar: Int, origin: DownloadOrigin, failure: AutomaticDownloadFailure
  ) -> Date? {
    guard origin == .automatic, Self.isRetryable(failure), backoff.indices.contains(retriesSoFar)
    else { return nil }
    return failedAt.addingTimeInterval(backoff[retriesSoFar])
  }

  /// Connection-level failures and system cancellations are transient; everything else, including
  /// any domain this table does not name, would fail the same way again.
  public static func isRetryable(_ failure: AutomaticDownloadFailure) -> Bool {
    switch failure {
    case .renewal:
      return true
    case .httpStatus(let status):
      return (500...599).contains(status) || status == 408 || status == 429
    case .transfer(let domain, let code):
      // The adapter reports an overrun or a denied redirect under its own domain, so a plain
      // `NSURLErrorCancelled` here is a system or force-quit cancellation.
      guard domain == NSURLErrorDomain, let code else { return false }
      return transientURLErrorCodes.contains(code)
    }
  }

  private static let transientURLErrorCodes: Set<Int> = [
    NSURLErrorTimedOut,
    NSURLErrorNetworkConnectionLost,
    NSURLErrorNotConnectedToInternet,
    NSURLErrorCannotConnectToHost,
    NSURLErrorCannotFindHost,
    NSURLErrorDNSLookupFailed,
    NSURLErrorDataNotAllowed,
    NSURLErrorInternationalRoamingOff,
    NSURLErrorCallIsActive,
    NSURLErrorCancelled,
  ]
}
