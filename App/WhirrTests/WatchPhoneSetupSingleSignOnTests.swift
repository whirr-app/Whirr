import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

/// An `.openID` account connects the Watch through a second, ephemeral single sign-on on the
/// phone, minting the Watch's own pair through the same `LoginProvider` seam.
@MainActor
@Suite("Phone Watch setup with single sign-on")
struct WatchPhoneSetupSingleSignOnTests {
  private let openIDAccount = AccountRecord(
    clientUUID: "phone-client", serverBaseURL: "https://books.example.test", serverUserId: "user-1",
    serverVersion: "2.37.2", signsInWithOpenID: true)

  @Test func onlyAnOpenIDAccountUsesSingleSignOn() {
    let model = makeModel(recorder: SingleSignOnRecorder()) { _ in nil }
    model.bind(account: openIDAccount, reading: WatchSetupReading())
    #expect(model.usesSingleSignOn)

    var passwordAccount = openIDAccount
    passwordAccount.signsInWithOpenID = false
    model.bind(account: passwordAccount, reading: WatchSetupReading())
    #expect(model.usesSingleSignOn == false)
  }

  /// The identity provider can outlast the Watch's 120-second challenge, so the sign-in runs
  /// before the hello is sent.
  @Test func signsInAtTheIdentityProviderBeforeTheWatchHandshake() async {
    let recorder = SingleSignOnRecorder()
    let model = makeModel(recorder: recorder) { method in
      guard case .singleSignOn = method else { return nil }
      return Self.loginResult(recorder: recorder)
    }
    model.bind(account: openIDAccount, reading: WatchSetupReading())
    await model.loadProfile()

    await model.connect(.singleSignOn(FakeSingleSignOnBrowser()))

    #expect(model.connected)
    #expect(model.state == .connected)
    #expect(recorder.events == ["login:sso", "hello", "credentials"])
    #expect(recorder.remoteCleanups == 0)
  }

  @Test func closingTheBrowserReturnsToReadySilently() async {
    let recorder = SingleSignOnRecorder()
    let model = makeModel(recorder: recorder) { _ in nil }
    model.bind(account: openIDAccount, reading: WatchSetupReading())
    await model.loadProfile()

    await model.connect(.singleSignOn(FakeSingleSignOnBrowser()))

    #expect(model.state == .ready)
    #expect(model.error == nil)
    #expect(model.connected == false)
    #expect(recorder.events == ["login:sso"])
  }

  /// A pair minted for a Watch that then cannot take it is logged out, not left live on the server.
  @Test func aFailedHandshakeLogsTheNewSessionOut() async {
    let recorder = SingleSignOnRecorder()
    let model = makeModel(recorder: recorder, watchAnswersHello: false) { _ in
      Self.loginResult(recorder: recorder)
    }
    model.bind(account: openIDAccount, reading: WatchSetupReading())
    await model.loadProfile()

    await model.connect(.singleSignOn(FakeSingleSignOnBrowser()))

    #expect(model.state == .failed)
    #expect(recorder.events == ["login:sso", "hello"])
    #expect(recorder.remoteCleanups == 1)
  }

  @Test func aRefusedSignInShowsTheSingleSignOnMessage() async {
    let recorder = SingleSignOnRecorder()
    let model = makeModel(recorder: recorder) { _ in throw OIDCLoginError.refused }
    model.bind(account: openIDAccount, reading: WatchSetupReading())
    await model.loadProfile()

    await model.connect(.singleSignOn(FakeSingleSignOnBrowser()))

    #expect(model.state == .failed)
    #expect(model.error == SetupFlowCopy.singleSignOnMessage(for: .refused).text)
    #expect(recorder.events == ["login:sso"])
  }

  private static func loginResult(recorder: SingleSignOnRecorder) -> WatchPhoneSetupModel.LoginResult {
    .init(
      userID: "user-1",
      serverIdentity: try! TokenAccount.normalizedServerIdentity(from: URL(string: "https://books.example.test")!),
      defaultLibraryID: nil,
      accessToken: "access", refreshToken: "refresh", accessExpiry: nil,
      cleanup: { remote in if remote { recorder.remoteCleanups += 1 } })
  }

  private func makeModel(
    recorder: SingleSignOnRecorder,
    watchAnswersHello: Bool = true,
    login: @escaping @MainActor (WatchPhoneSetupModel.LoginMethod) async throws -> WatchPhoneSetupModel.LoginResult?
  ) -> WatchPhoneSetupModel {
    WatchPhoneSetupModel(
      sender: { data, key in
        if key == WatchTransportKey.setupHello {
          recorder.events.append("hello")
          guard watchAnswersHello else { return nil }
          let hello = try! WatchWireCodec.decode(WatchSetupHello.self, from: data)
          return try? WatchWireCodec.encode(
            WatchSetupChallenge(
              id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
              expiresAt: Date().addingTimeInterval(90)))
        }
        guard key == WatchTransportKey.setupCredentials else { return nil }
        recorder.events.append("credentials")
        let credentials = try! WatchWireCodec.decode(WatchSetupCredentials.self, from: data)
        return try? WatchWireCodec.encode(
          WatchSetupReceipt(
            id: credentials.id, accountStamp: credentials.accountStamp, nonce: credentials.nonce,
            status: .installed))
      },
      loginProvider: { _, method, _ in
        method.releasePassword()
        if case .singleSignOn = method { recorder.events.append("login:sso") }
        return try await login(method)
      },
      defaults: UserDefaults(suiteName: "WatchPhoneSetupSingleSignOnTests.\(UUID().uuidString)")!)
  }
}

@MainActor
private final class SingleSignOnRecorder {
  var events: [String] = []
  var remoteCleanups = 0
}
