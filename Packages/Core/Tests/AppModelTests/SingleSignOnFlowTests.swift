import ABSApi
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Single sign-on at setup and in same-account recovery, driven through
/// `FakeAccountLifecycle` and a scripted browser.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SingleSignOnFlowTests {
  private static let httpsURL = URL(string: "https://books.example.test")!

  private static func server(
    _ methods: Set<ServerAuthMethod>?, url: URL = httpsURL, customHeaders: CustomHeaders = .none
  ) -> ValidatedServer {
    ValidatedServer(
      serverURL: url, serverVersion: "2.37.2", isPlainHTTP: url.scheme == "http",
      customHeaders: customHeaders, authMethods: methods)
  }

  private static func setupModel(
    at server: ValidatedServer, fake: FakeAccountLifecycle = FakeAccountLifecycle()
  ) async -> SetupFlowModel {
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(
      accountLifecycle: fake,
      libraryDiscovery: FakeLibraryDiscovery(libraries: [
        SelectableLibrary(
          serverLibraryID: "books", name: "Books", mediaType: "book", isAccessible: true, isIncluded: false)
      ]),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)
    return model
  }

  // MARK: - Which form the server gets

  private struct FormCase: Sendable {
    let methods: Set<ServerAuthMethod>?
    let offersSingleSignOn: Bool
    let offersPassword: Bool
    let showsNotice: Bool
  }

  private static let formCases = [
    FormCase(methods: [.local], offersSingleSignOn: false, offersPassword: true, showsNotice: false),
    FormCase(methods: [.openID], offersSingleSignOn: true, offersPassword: false, showsNotice: true),
    FormCase(methods: [.local, .openID], offersSingleSignOn: true, offersPassword: true, showsNotice: false),
    // Absent or empty is a malformed response: both methods, and leg 1 reports precisely.
    FormCase(methods: nil, offersSingleSignOn: true, offersPassword: true, showsNotice: false),
    FormCase(methods: [], offersSingleSignOn: true, offersPassword: true, showsNotice: false),
  ]

  @Test("each authMethods combination decides the credentials form")
  func authMethodsDecideTheForm() async {
    for testCase in Self.formCases {
      let model = await Self.setupModel(at: Self.server(testCase.methods))
      let label = String(describing: testCase.methods)
      #expect(model.state.offersSingleSignOn == testCase.offersSingleSignOn, "\(label)")
      #expect(model.state.offersPasswordSignIn == testCase.offersPassword, "\(label)")
      #expect((model.state.credentialsNotice != nil) == testCase.showsNotice, "\(label)")
    }
  }

  /// Single sign-on is never offered over plain HTTP: an on-path attacker could replace the
  /// identity provider's page and collect a password that reaches beyond this server.
  @Test("an HTTP server never offers single sign-on")
  func plainHTTPServerNeverOffersSingleSignOn() async {
    let http = URL(string: "http://books.example.test")!
    let cases: [Set<ServerAuthMethod>?] = [[.openID], [.local, .openID], nil]
    for methods in cases {
      let fake = FakeAccountLifecycle()
      let model = await Self.setupModel(at: Self.server(methods, url: http), fake: fake)
      let browser = FakeSingleSignOnBrowser()
      let label = String(describing: methods)

      #expect(model.state.offersSingleSignOn == false, "\(label)")
      #expect(model.state.singleSignOnProxyNote == nil, "\(label)")

      await model.submitSingleSignOn(using: browser)

      #expect(browser.requests.isEmpty, "\(label)")
      #expect(fake.issuedSingleSignOnAttempts.isEmpty, "\(label)")
    }
  }

  @Test("an SSO-only HTTP server offers an API token and says why")
  func plainHTTPSingleSignOnOnlyServerOffersAnAPIToken() async {
    let model = await Self.setupModel(
      at: Self.server([.openID], url: URL(string: "http://books.example.test")!))

    #expect(model.state.offersPasswordSignIn == false)
    #expect(model.state.offersSingleSignOn == false)
    #expect(model.state.credentialsNotice == SetupFlowCopy.singleSignOnNeedsHTTPSNotice)
  }

  @Test("the proxy note appears only when the server needs custom headers")
  func proxyNoteNeedsCustomHeaders() async throws {
    let headers = try CustomHeaders(["CF-Access-Client-Id": "id"])
    let proxied = await Self.setupModel(at: Self.server([.local, .openID], customHeaders: headers))
    let plain = await Self.setupModel(at: Self.server([.local, .openID]))
    let passwordOnly = await Self.setupModel(at: Self.server([.local], customHeaders: headers))

    #expect(proxied.state.singleSignOnProxyNote == SetupFlowCopy.singleSignOnProxyHeadersNote)
    #expect(plain.state.singleSignOnProxyNote == nil)
    #expect(passwordOnly.state.singleSignOnProxyNote == nil)
  }

  @Test("outside the credentials step no sign-in method is offered")
  func noMethodsOutsideTheCredentialsStep() {
    let server = Self.server([.openID])
    for state in [
      SetupFlowModel.State.idle, .validatingServer, .loggingIn(server: server, username: ""), .authenticated,
    ] {
      #expect(state.offersSingleSignOn == false)
      #expect(state.offersPasswordSignIn == false)
      #expect(state.singleSignOnProxyNote == nil)
    }
  }

  // MARK: - Setup

  @Test("setup signs in through an ephemeral browser and completes with its callback")
  func setupSignsInThroughTheBrowser() async {
    let fake = FakeAccountLifecycle()
    let model = await Self.setupModel(at: Self.server([.local, .openID]), fake: fake)
    let callback = URL(string: "whirr://oauth?code=abc&state=xyz")!
    let browser = FakeSingleSignOnBrowser(outcome: .callback(callback))

    await model.submitSingleSignOn(using: browser)

    #expect(model.state == .authenticated)
    let attempt = fake.issuedSingleSignOnAttempts.first
    #expect(fake.issuedSingleSignOnAttempts.count == 1)
    #expect(
      browser.requests == [
        .init(
          url: attempt!.authorizationURL, callbackScheme: SingleSignOnAttempt.callbackScheme,
          prefersEphemeralSession: true)
      ])
    #expect(SingleSignOnAttempt.callbackScheme == "whirr")
    #expect(fake.singleSignOnCompletions.map { $0.attempt } == [attempt!])
    #expect(fake.singleSignOnCompletions.map { $0.callbackURL } == [callback])
  }

  @Test("closing the browser returns to the form silently and completes nothing")
  func cancelReturnsToTheFormSilently() async {
    let fake = FakeAccountLifecycle()
    let server = Self.server([.openID])
    let model = await Self.setupModel(at: server, fake: fake)

    await model.submitSingleSignOn(using: FakeSingleSignOnBrowser(outcome: .cancelled))

    #expect(model.state == .needsCredentials(server: server))
    #expect(fake.singleSignOnCompletions.isEmpty)

    // The form is usable again straight away.
    await model.submitSingleSignOn(using: FakeSingleSignOnBrowser())
    #expect(model.state == .authenticated)
    #expect(fake.issuedSingleSignOnAttempts.count == 2)
  }

  @Test("each sign-in failure shows its own message and retry returns to the form")
  func eachFailureShowsItsOwnMessage() async {
    var keys: [RecoveryMessage.Key] = []
    for failure in SingleSignOnFailure.allCases {
      let fake = FakeAccountLifecycle()
      let server = Self.server([.local, .openID])
      let model = await Self.setupModel(at: server, fake: fake)
      fake.stubLogin(throwing: AccountLifecycleError.singleSignOnFailed(failure))

      await model.submitSingleSignOn(using: FakeSingleSignOnBrowser())

      let expected = SetupFlowCopy.singleSignOnMessage(for: failure)
      #expect(model.state == .loginFailed(server: server, message: expected), "\(failure)")
      keys.append(expected.key)

      await model.retry()
      #expect(model.state == .needsCredentials(server: server), "\(failure)")
      #expect(model.state.offersSingleSignOn, "\(failure)")
    }
    #expect(Set(keys).count == SingleSignOnFailure.allCases.count)
  }

  /// Leg 1 fails before any browser opens: `400 Invalid redirect_uri` names whirr://oauth.
  @Test("a failure to start never opens the browser")
  func startFailureNeverOpensTheBrowser() async {
    let fake = FakeAccountLifecycle()
    let server = Self.server([.openID])
    let model = await Self.setupModel(at: server, fake: fake)
    fake.stubBeginSingleSignOn(throwing: AccountLifecycleError.singleSignOnFailed(.redirectURINotAllowed))
    let browser = FakeSingleSignOnBrowser()

    await model.submitSingleSignOn(using: browser)

    let message = SetupFlowCopy.singleSignOnMessage(for: .redirectURINotAllowed)
    #expect(model.state == .loginFailed(server: server, message: message))
    #expect(message.text.contains("whirr://oauth"))
    #expect(browser.requests.isEmpty)
  }

  @Test("pacing refuses the start with its own message")
  func pacedStartIsRefused() async {
    let fake = FakeAccountLifecycle()
    let server = Self.server([.openID])
    let model = await Self.setupModel(at: server, fake: fake)
    fake.stubBeginSingleSignOn(throwing: AccountLifecycleError.loginRateLimited(retryAfter: 30))

    await model.submitSingleSignOn(using: FakeSingleSignOnBrowser())

    #expect(
      model.state
        == .loginFailed(
          server: server, message: SetupFlowCopy.recoveryMessage(for: .loginRateLimited(retryAfter: 30))))
  }

  @Test("a browser that cannot open fails generically and completes nothing")
  func browserFailureIsGeneric() async {
    let fake = FakeAccountLifecycle()
    let server = Self.server([.openID])
    let model = await Self.setupModel(at: server, fake: fake)

    await model.submitSingleSignOn(using: FakeSingleSignOnBrowser(outcome: .failure(CancellationError())))

    #expect(model.state == .loginFailed(server: server, message: SetupFlowCopy.genericRecoveryMessage))
    #expect(fake.singleSignOnCompletions.isEmpty)
  }

  @Test("a server without single sign-on ignores the request")
  func passwordOnlyServerIgnoresSingleSignOn() async {
    let fake = FakeAccountLifecycle()
    let server = Self.server([.local])
    let model = await Self.setupModel(at: server, fake: fake)
    let browser = FakeSingleSignOnBrowser()

    await model.submitSingleSignOn(using: browser)

    #expect(model.state == .needsCredentials(server: server))
    #expect(fake.issuedSingleSignOnAttempts.isEmpty)
    #expect(browser.requests.isEmpty)
  }

  @Test("leaving setup while the browser is open discards its callback")
  func leavingSetupDiscardsTheCallback() async {
    let fake = FakeAccountLifecycle()
    let model = await Self.setupModel(at: Self.server([.openID]), fake: fake)
    let browser = FakeSingleSignOnBrowser()
    browser.whileOpen = { model.cancel() }

    await model.submitSingleSignOn(using: browser)

    #expect(model.state == .idle)
    #expect(fake.singleSignOnCompletions.isEmpty)
  }

  /// Leaving and re-entering the form while the first browser is still open puts the model back in
  /// `.loggingIn` for the same server; the first browser's callback must not complete that.
  @Test("a stale browser's callback never completes a newer sign-in")
  func staleBrowserCallbackIsDiscarded() async {
    let fake = FakeAccountLifecycle()
    let server = Self.server([.openID])
    let model = await Self.setupModel(at: server, fake: fake)
    // Each browser stays open until the test answers it, so the two sign-ins overlap.
    let first = FakeSingleSignOnBrowser()
    first.gate.hold()
    let second = FakeSingleSignOnBrowser()
    second.gate.hold()

    let firstSignIn = Task { await model.submitSingleSignOn(using: first) }
    await first.gate.waitUntilParked()
    model.cancel()
    await model.submitServerURL(server.serverURL)
    let secondSignIn = Task { await model.submitSingleSignOn(using: second) }
    await second.gate.waitUntilParked()

    first.gate.release(.callback(FakeSingleSignOnBrowser.defaultCallback))
    await firstSignIn.value
    #expect(fake.singleSignOnCompletions.isEmpty)
    #expect(model.state == .loggingIn(server: server, username: ""))

    second.gate.release(.callback(FakeSingleSignOnBrowser.defaultCallback))
    await secondSignIn.value
    #expect(model.state == .authenticated)
    #expect(fake.singleSignOnCompletions.map(\.attempt) == [fake.issuedSingleSignOnAttempts[1]])
  }

  // MARK: - Recovery

  @Test("recovery signs in again through a shared browser session")
  func recoveryUsesASharedSession() async {
    let fake = FakeAccountLifecycle()
    fake.authenticationMode = .openID
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let browser = FakeSingleSignOnBrowser()
    model.recoveryRequired()

    await model.submitSingleSignOn(using: browser)

    #expect(model.state == .idle)
    #expect(browser.requests.map { $0.prefersEphemeralSession } == [false])
    #expect(fake.singleSignOnCompletions.map { $0.callbackURL } == [FakeSingleSignOnBrowser.defaultCallback])
  }

  @Test("closing the browser keeps recovery required")
  func recoveryCancelStaysRequired() async {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    model.recoveryRequired()

    await model.submitSingleSignOn(using: FakeSingleSignOnBrowser(outcome: .cancelled))

    #expect(model.state == .required)
    #expect(fake.singleSignOnCompletions.isEmpty)
  }

  @Test("a different user, or a refusal, fails recovery with its own error")
  func recoveryFailuresSurface() async {
    for error in [AccountLifecycleError.accountMismatch, .singleSignOnFailed(.refused)] {
      let fake = FakeAccountLifecycle()
      fake.stubReauthenticate(throwing: error)
      let model = AuthRecoveryModel(accountLifecycle: fake)
      model.recoveryRequired()

      await model.submitSingleSignOn(using: FakeSingleSignOnBrowser())

      #expect(model.state == .failed(error), "\(error)")
      model.cancel()
      #expect(model.state == .required, "\(error)")
    }
  }

  @Test("recovery ignores a single sign-on request when it is not required")
  func recoveryIgnoresRequestsWhenIdle() async {
    let fake = FakeAccountLifecycle()
    let model = AuthRecoveryModel(accountLifecycle: fake)
    let browser = FakeSingleSignOnBrowser()

    await model.submitSingleSignOn(using: browser)

    #expect(model.state == .idle)
    #expect(browser.requests.isEmpty)
    #expect(fake.issuedSingleSignOnAttempts.isEmpty)
  }
}
