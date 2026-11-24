import Foundation
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch setup attempt retry values")
struct WatchSetupAttemptTests {
  private let now = Date(timeIntervalSinceReferenceDate: 100)

  private func hello() throws -> WatchSetupHello {
    try WatchSetupHello(
      id: UUID(),
      accountStamp: WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server"),
      issuedAt: now)
  }

  @Test func helloHasBoundedRetryWindow() throws {
    let attempt = WatchSetupAttempt(hello: try hello())
    #expect(attempt.isUsable(now: now))
    #expect(attempt.isUsable(now: now.addingTimeInterval(119)))
    #expect(!attempt.isUsable(now: now.addingTimeInterval(120)))
    #expect(!attempt.isUsable(now: now.addingTimeInterval(-1)))
    #expect(!attempt.preservesPayload(after: nil))
  }

  @Test func challengeExpiryAndIdentityFencePayload() throws {
    let hello = try hello()
    let challenge = try WatchSetupChallenge(
      id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
      expiresAt: now.addingTimeInterval(90))
    let attempt = WatchSetupAttempt(hello: hello, challenge: challenge, payload: Data([1, 2, 3]))
    #expect(attempt.isUsable(now: now))
    #expect(attempt.isUsable(now: now.addingTimeInterval(90)))
    #expect(!attempt.isUsable(now: now.addingTimeInterval(91)))
    #expect(!attempt.isUsable(now: now.addingTimeInterval(-31)))
    let otherHello = try self.hello()
    #expect(!WatchSetupAttempt(hello: otherHello, challenge: challenge).isUsable(now: now))
    #expect(!WatchSetupAttempt(hello: hello, retryEligible: false).isUsable(now: now))
  }

  @Test func helloWindowIsHalfOpenAtTheLimit() throws {
    let attempt = WatchSetupAttempt(hello: try hello())
    #expect(attempt.isUsable(now: now.addingTimeInterval(119)))
    #expect(!attempt.isUsable(now: now.addingTimeInterval(120)))
    #expect(!attempt.isUsable(now: now.addingTimeInterval(121)))
  }

  @Test func challengeWindowIsClosedAtTheLimitAndAgreesWithTheProtocol() throws {
    let hello = try hello()
    var admission = WatchSetupAdmission()
    let minted = admission.begin(hello, existingAccount: hello.accountStamp, now: now)
    #expect(minted.expiresAt == now.addingTimeInterval(WatchSetupLimits.window))
    #expect(WatchProtocolVersion.commandAdmissionWindow == WatchSetupLimits.window)

    let attempt = WatchSetupAttempt(hello: hello, challenge: minted)
    #expect(attempt.isUsable(now: now.addingTimeInterval(1)))
    #expect(attempt.isUsable(now: now))
    #expect(!attempt.isUsable(now: now.addingTimeInterval(-1)))
  }

  @Test func ambiguousAndBusyReceiptsPreserveExactBytes() throws {
    let bytes = Data([0, 255, 42])
    let attempt = WatchSetupAttempt(hello: try hello(), payload: bytes)
    #expect(attempt.preservesPayload(after: nil))
    #expect(attempt.preservesPayload(after: .busy))
    #expect(!attempt.preservesPayload(after: .installed))
    #expect(!attempt.preservesPayload(after: .rejected))
    #expect(!attempt.preservesPayload(after: .wrongAccount))
    #expect(attempt.payload == bytes)
  }

  @Test func clearingDropsCredentialsAndKeepsHelloForFreshLogin() throws {
    let hello = try hello()
    let challenge = try WatchSetupChallenge(
      id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
      expiresAt: now.addingTimeInterval(90))
    let original = WatchSetupAttempt(hello: hello, challenge: challenge, payload: Data([7]))
    let cleared = original.cleared()
    #expect(cleared.hello == hello)
    #expect(cleared.accountStamp == original.accountStamp)
    #expect(cleared.challenge == nil)
    #expect(cleared.payload == nil)
    #expect(!cleared.preservesPayload(after: .busy))
    #expect(cleared.isUsable(now: now))
    #expect(original.payload == Data([7]))
  }
}
