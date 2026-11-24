import Foundation
import Testing

@testable import WatchProtocol

@Suite("Watch setup handshake")
struct WatchSetupTests {
  private let account = WatchProtocolFixtures.accountStamp()
  private let otherAccount = try! WatchAccountStamp(
    accountIdentityHash: "other-account", serverIdentityHash: "other-server")
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func hello(id: UUID = UUID(), at date: Date? = nil) throws -> WatchSetupHello {
    try WatchSetupHello(id: id, accountStamp: account, issuedAt: date ?? now)
  }

  @Test func allSetupValuesRoundTripThroughBoundedCodec() throws {
    let id = UUID()
    let hello = try hello(id: id)
    let challenge = try WatchSetupChallenge(
      id: id, accountStamp: account, nonce: UUID(), expiresAt: now.addingTimeInterval(120))
    let credentials = try WatchProtocolFixtures.setupCredentials(for: challenge)
    let receipt = try WatchSetupReceipt(id: id, accountStamp: account, nonce: challenge.nonce, status: .installed)

    #expect(try WatchProtocolFixtures.roundTrip(hello) == hello)
    #expect(try WatchProtocolFixtures.roundTrip(challenge) == challenge)
    #expect(try WatchProtocolFixtures.roundTrip(credentials) == credentials)
    #expect(try WatchProtocolFixtures.roundTrip(receipt) == receipt)
    #expect(WatchTransportKey.setupHello == "whirr.watch.setup.hello.v1")
    #expect(WatchTransportKey.setupCredentials == "whirr.watch.setup.credentials.v1")
    #expect(WatchTransportKey.setupStatus == "whirr.watch.setup.status.v1")
  }

  @Test func unsupportedVersionIsRejectedBeforePayloadDecode() throws {
    let value = try hello()
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(value)) as? [String: Any])
    object["version"] = 99
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(99)) {
      try WatchWireCodec.decode(WatchSetupHello.self, from: data)
    }
  }

  @Test func credentialsRejectUnsafeURLsSecretsAndBounds() throws {
    let challenge = try WatchSetupChallenge(
      id: UUID(), accountStamp: account, nonce: UUID(), expiresAt: now.addingTimeInterval(120))
    #expect(throws: WatchProtocolCodingError.forbiddenMetadata) {
      _ = try WatchSetupCredentials(
        id: challenge.id, accountStamp: account, nonce: challenge.nonce, expiresAt: challenge.expiresAt,
        serverURL: "file:///tmp/library", userID: "user", accessToken: "a", refreshToken: "r")
    }
    #expect(throws: WatchProtocolCodingError.forbiddenMetadata) {
      _ = try WatchSetupCredentials(
        id: challenge.id, accountStamp: account, nonce: challenge.nonce, expiresAt: challenge.expiresAt,
        serverURL: "https://user:pass@abs.example.test", userID: "user", accessToken: "a", refreshToken: "r")
    }
    #expect(throws: WatchProtocolCodingError.oversizedMetadata) {
      _ = try WatchSetupCredentials(
        id: challenge.id, accountStamp: account, nonce: challenge.nonce, expiresAt: challenge.expiresAt,
        serverURL: "https://abs.example.test", userID: String(repeating: "u", count: 513), accessToken: "a",
        refreshToken: "r")
    }
    #expect(throws: WatchProtocolCodingError.oversizedMetadata) {
      _ = try WatchSetupCredentials(
        id: challenge.id, accountStamp: account, nonce: challenge.nonce, expiresAt: challenge.expiresAt,
        serverURL: "https://abs.example.test", userID: "user", accessToken: String(repeating: "a", count: 2_049),
        refreshToken: "r")
    }
  }

  @Test func credentialDescriptionsAndReflectionDoNotExposeSecretsOrURL() throws {
    let challenge = try WatchSetupChallenge(
      id: UUID(), accountStamp: account, nonce: UUID(), expiresAt: now.addingTimeInterval(120))
    let value = try WatchProtocolFixtures.setupCredentials(for: challenge)
    let description = String(describing: value)
    let reflection = String(reflecting: value)
    for output in [description, reflection] {
      #expect(!output.contains("access-token"))
      #expect(!output.contains("refresh-token"))
      #expect(!output.contains("abs.example.test"))
      #expect(!output.contains("https://"))
    }
  }

  @Test func freshCredentialsAreOnlyAdmittedAfterCompletionAndDuplicateIsReplay() throws {
    var admission = WatchSetupAdmission()
    let challenge = admission.begin(try hello(), existingAccount: account, now: now)
    #expect(challenge.status == .ready)
    let value = try WatchProtocolFixtures.setupCredentials(for: challenge)
    #expect(try admission.admit(value, now: now.addingTimeInterval(1)) == false)
    let receipt = try admission.complete(value, now: now.addingTimeInterval(1))
    #expect(receipt.status == .installed)
    #expect(admission.receipt == receipt)
    #expect(try admission.admit(value, now: now.addingTimeInterval(2)) == true)
  }

  @Test func retryingTheSameHelloReturnsThePendingChallenge() throws {
    var admission = WatchSetupAdmission()
    let value = try hello()
    let first = admission.begin(value, existingAccount: account, now: now)
    let retry = admission.begin(value, existingAccount: account, now: now.addingTimeInterval(1))
    #expect(retry == first)
    #expect(retry.status == .ready)
  }

  @Test func completionCanFollowAnAdmittedSaveThatCrossesTheDeadline() throws {
    var admission = WatchSetupAdmission()
    let challenge = admission.begin(try hello(), existingAccount: account, now: now)
    let value = try WatchProtocolFixtures.setupCredentials(for: challenge)
    #expect(try admission.admit(value, now: challenge.expiresAt.addingTimeInterval(-0.001)) == false)
    let receipt = try admission.complete(value, now: challenge.expiresAt.addingTimeInterval(10))
    #expect(receipt.status == .installed)
  }

  @Test func nonceAccountAndExpiryMustMatchCurrentChallenge() throws {
    var admission = WatchSetupAdmission()
    let challenge = admission.begin(try hello(), existingAccount: account, now: now)
    let wrongNonce = try WatchProtocolFixtures.setupCredentials(for: challenge, nonce: UUID())
    #expect(throws: WatchProtocolCodingError.invalidValue) { try admission.admit(wrongNonce, now: now) }
    let wrongAccount = try WatchProtocolFixtures.setupCredentials(for: challenge, account: otherAccount)
    #expect(throws: WatchProtocolCodingError.invalidValue) { try admission.admit(wrongAccount, now: now) }
    let wrongExpiry = try WatchProtocolFixtures.setupCredentials(
      for: challenge, expiry: challenge.expiresAt.addingTimeInterval(-1))
    #expect(throws: WatchProtocolCodingError.invalidValue) { try admission.admit(wrongExpiry, now: now) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try admission.admit(
        try WatchProtocolFixtures.setupCredentials(for: challenge), now: challenge.expiresAt.addingTimeInterval(0.001))
    }
  }

  @Test func setupHandshakeAndCommandAdmissionShareOneWindow() throws {
    #expect(WatchProtocolVersion.commandAdmissionWindow == WatchSetupLimits.window)
    var admission = WatchSetupAdmission()
    let challenge = admission.begin(try hello(), existingAccount: account, now: now)
    #expect(challenge.expiresAt == now.addingTimeInterval(WatchSetupLimits.window))
  }

  @Test func helloAgeIsAdmittedThroughTheWholeWindow() throws {
    for age in [119.0, 120.0] {
      var admission = WatchSetupAdmission()
      #expect(
        admission.begin(try hello(at: now.addingTimeInterval(-age)), existingAccount: account, now: now).status
          == .ready)
    }
    for age in [120.001, 121.0] {
      var admission = WatchSetupAdmission()
      #expect(
        admission.begin(try hello(at: now.addingTimeInterval(-age)), existingAccount: account, now: now).status
          == .rejected)
    }
  }

  @Test func challengeIsAdmittedThroughTheWholeLifetime() throws {
    var admission = WatchSetupAdmission()
    let challenge = admission.begin(try hello(), existingAccount: account, now: now)
    let credentials = try WatchProtocolFixtures.setupCredentials(for: challenge)
    #expect(try !admission.admit(credentials, now: challenge.expiresAt.addingTimeInterval(-1)))
    #expect(try !admission.admit(credentials, now: challenge.expiresAt))
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try admission.admit(credentials, now: challenge.expiresAt.addingTimeInterval(0.001))
    }
  }

  @Test func helloAgeFutureAndForeignAccountFailClosed() throws {
    var admission = WatchSetupAdmission()
    #expect(
      admission.begin(try hello(at: now.addingTimeInterval(-121)), existingAccount: account, now: now).status
        == .rejected)
    #expect(
      admission.begin(try hello(at: now.addingTimeInterval(31)), existingAccount: account, now: now).status == .rejected
    )
    #expect(
      admission.begin(
        try WatchSetupHello(id: UUID(), accountStamp: otherAccount, issuedAt: now), existingAccount: account, now: now
      ).status == .wrongAccount)
  }

  @Test func statusReportsProvisioningWithoutDisturbingAnOutstandingChallenge() throws {
    var admission = WatchSetupAdmission()
    let pending = admission.begin(try hello(), existingAccount: account, now: now)
    #expect(pending.status == .ready)

    let probe = try hello(id: UUID(), at: now.addingTimeInterval(1))
    let answer = WatchSetupAdmission.status(
      for: probe, existingAccount: account, isInstalled: true, now: now.addingTimeInterval(1))
    #expect(answer.status == .installed)
    #expect(answer.id == probe.id)
    #expect(answer.accountStamp == account)
    // Expired on arrival, so no caller can mistake a status answer for a challenge to complete.
    #expect(answer.expiresAt == now.addingTimeInterval(1))

    // The outstanding challenge and its credentials are untouched by having been asked.
    let value = try WatchProtocolFixtures.setupCredentials(for: pending)
    #expect(try admission.admit(value, now: now.addingTimeInterval(2)) == false)
    #expect(try admission.complete(value, now: now.addingTimeInterval(2)).status == .installed)
  }

  @Test func statusSeparatesUnprovisionedFromAnotherAccountsWatch() throws {
    #expect(
      WatchSetupAdmission.status(for: try hello(), existingAccount: nil, isInstalled: false, now: now).status == .ready)
    #expect(
      WatchSetupAdmission.status(for: try hello(), existingAccount: account, isInstalled: false, now: now).status
        == .ready)
    #expect(
      WatchSetupAdmission.status(for: try hello(), existingAccount: otherAccount, isInstalled: true, now: now).status
        == .wrongAccount)
  }

  @Test func statusSurvivesANonFiniteClock() throws {
    let probe = try hello()
    let answer = WatchSetupAdmission.status(
      for: probe, existingAccount: account, isInstalled: true, now: Date(timeIntervalSinceReferenceDate: .infinity))
    #expect(answer.status == .installed)
    #expect(answer.expiresAt == probe.issuedAt)
  }

  @Test func challengeRoundTripsWithAndWithoutHealth() throws {
    let plain = try WatchSetupChallenge(
      id: UUID(), accountStamp: account, nonce: UUID(), expiresAt: now, status: .installed)
    let reporting = try WatchSetupChallenge(
      id: UUID(), accountStamp: account, nonce: UUID(), expiresAt: now, status: .installed, health: .signInRejected)
    #expect(plain.health == nil)
    #expect(try WatchProtocolFixtures.roundTrip(plain) == plain)
    #expect(try WatchProtocolFixtures.roundTrip(reporting).health == .signInRejected)
  }

  @Test(arguments: [#""revoked""#, "7", #"["healthy"]"#])
  func unreadableHealthDecodesAsUnknownWithoutLosingTheAnswer(_ healthJSON: String) throws {
    let value = try WatchSetupChallenge(
      id: UUID(), accountStamp: account, nonce: UUID(), expiresAt: now, status: .installed, health: .healthy)
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(value)) as? [String: Any])
    object["health"] = try JSONSerialization.jsonObject(with: Data(healthJSON.utf8), options: .fragmentsAllowed)
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try WatchWireCodec.decode(WatchSetupChallenge.self, from: data)
    #expect(decoded.status == .installed)
    #expect(decoded.health == nil)
  }

  @Test func statusAttachesHealthOnlyToAnInstalledWatch() throws {
    func answer(existing: WatchAccountStamp?, installed: Bool) throws -> WatchSetupChallenge {
      WatchSetupAdmission.status(
        for: try hello(), existingAccount: existing, isInstalled: installed, now: now, health: .signInRejected)
    }
    #expect(try answer(existing: account, installed: true).health == .signInRejected)
    #expect(try answer(existing: account, installed: false).health == nil)
    #expect(try answer(existing: nil, installed: false).health == nil)
    #expect(try answer(existing: otherAccount, installed: true).health == nil)
  }

  @Test func oldReceiptCannotReplayAfterAnewSetupBegins() throws {
    var admission = WatchSetupAdmission()
    let first = admission.begin(try hello(), existingAccount: account, now: now)
    let oldCredentials = try WatchProtocolFixtures.setupCredentials(for: first)
    _ = try admission.complete(oldCredentials, now: now)
    let second = admission.begin(
      try hello(at: now.addingTimeInterval(1)), existingAccount: account, now: now.addingTimeInterval(1))
    #expect(second.status == .ready)
    #expect(admission.receipt == nil)
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try admission.admit(oldCredentials, now: now.addingTimeInterval(1))
    }
  }
}
