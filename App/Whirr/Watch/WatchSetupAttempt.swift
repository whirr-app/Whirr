import Foundation
import WatchProtocol

/// Retry identity and the exact encoded credentials remain together until delivery is resolved.
/// Clearing credentials retains the hello for a fresh login against that challenge.
struct WatchSetupAttempt: Sendable {
  let hello: WatchSetupHello
  let challenge: WatchSetupChallenge?
  let payload: Data?
  let accountStamp: WatchAccountStamp
  let retryEligible: Bool

  init(
    hello: WatchSetupHello,
    challenge: WatchSetupChallenge? = nil,
    payload: Data? = nil,
    retryEligible: Bool = true
  ) {
    self.hello = hello
    self.challenge = challenge
    self.payload = payload
    self.accountStamp = hello.accountStamp
    self.retryEligible = retryEligible
  }

  func isUsable(now: Date) -> Bool {
    guard retryEligible else { return false }
    if let challenge {
      return challenge.id == hello.id && challenge.accountStamp == accountStamp
        && (0...WatchSetupLimits.window).contains(challenge.expiresAt.timeIntervalSince(now))
    }
    return (0..<WatchSetupLimits.window).contains(now.timeIntervalSince(hello.issuedAt))
  }

  /// A missing, malformed or mismatched receipt is represented by nil by the caller.
  func preservesPayload(after status: WatchSetupStatus?) -> Bool {
    retryEligible && payload != nil && (status == nil || status == .busy)
  }

  func cleared() -> Self {
    Self(hello: hello)
  }
}
