import Foundation
import Persistence
import Testing

@testable import SyncEngine

/// The failure classification table, and the retry cap and backoff.
@Suite struct AutomaticDownloadRetryPolicyTests {
  private let policy = AutomaticDownloadRetryPolicy.standard
  private let failedAt = Date(timeIntervalSince1970: 1_790_000_000)

  @Test(arguments: [
    NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
    NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
    NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
    NSURLErrorCancelled,
  ])
  func connectionLevelURLErrorsAreRetried(code: Int) {
    #expect(AutomaticDownloadRetryPolicy.isRetryable(.transfer(domain: NSURLErrorDomain, code: code)))
  }

  @Test(arguments: [
    NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
    NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
    NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected,
    NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorBadServerResponse, NSURLErrorUnknown,
  ])
  func urlErrorsThatWouldRecurAreNotRetried(code: Int) {
    #expect(AutomaticDownloadRetryPolicy.isRetryable(.transfer(domain: NSURLErrorDomain, code: code)) == false)
  }

  @Test(arguments: [
    "whirr.adapter.redirectDenied", "whirr.adapter.overrun", "whirr.adapter.moveFailed",
    "whirr.adapter.missingDestination", "NSPOSIXErrorDomain", "some.unknown.domain",
  ])
  func adapterAndUnknownDomainsAreNotRetried(domain: String) {
    // The adapter reports these with `NSURLErrorCancelled`'s code; the domain is what decides.
    #expect(
      AutomaticDownloadRetryPolicy.isRetryable(.transfer(domain: domain, code: NSURLErrorCancelled)) == false)
  }

  @Test func aFailureWithNoDomainOrCodeIsNotRetried() {
    #expect(AutomaticDownloadRetryPolicy.isRetryable(.transfer(domain: nil, code: nil)) == false)
    #expect(AutomaticDownloadRetryPolicy.isRetryable(.transfer(domain: NSURLErrorDomain, code: nil)) == false)
  }

  @Test func aFailedRenewalIsRetried() {
    #expect(AutomaticDownloadRetryPolicy.isRetryable(.renewal))
  }

  @Test(arguments: [500, 502, 503, 504, 599, 408, 429])
  func serverUnavailableStatusesAreRetried(status: Int) {
    #expect(AutomaticDownloadRetryPolicy.isRetryable(.httpStatus(status)))
  }

  @Test(arguments: [200, 206, 301, 400, 401, 403, 404, 410, 416, 600])
  func otherStatusesAreNotRetried(status: Int) {
    #expect(AutomaticDownloadRetryPolicy.isRetryable(.httpStatus(status)) == false)
  }

  @Test func deadlinesStepTenMinutesThirtyMinutesTwoHoursThenStop() {
    let timedOut = AutomaticDownloadFailure.transfer(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    let deadlines = (0...4).map {
      policy.nextAttempt(after: failedAt, retriesSoFar: $0, origin: .automatic, failure: timedOut)
    }
    #expect(
      deadlines == [
        failedAt.addingTimeInterval(600), failedAt.addingTimeInterval(1_800),
        failedAt.addingTimeInterval(7_200), nil, nil,
      ])
  }

  @Test func manualRowsAndPermanentFailuresGetNoDeadline() {
    let timedOut = AutomaticDownloadFailure.transfer(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    #expect(policy.nextAttempt(after: failedAt, retriesSoFar: 0, origin: .manual, failure: timedOut) == nil)
    #expect(
      policy.nextAttempt(
        after: failedAt, retriesSoFar: 0, origin: .automatic,
        failure: .transfer(domain: "whirr.adapter.redirectDenied", code: NSURLErrorCancelled)) == nil)
    #expect(policy.nextAttempt(after: failedAt, retriesSoFar: 0, origin: .automatic, failure: .httpStatus(404)) == nil)
  }
}
