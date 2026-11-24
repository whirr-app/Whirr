import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The setup/login state machine. Driven entirely through `AccountLifecycle` via
/// `FakeAccountLifecycle`, so no ABSApi/wire type appears here (ARCHITECTURE.md).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SetupFlowModelTests {

  private func makeValidatedServer(isPlainHTTP: Bool = false) -> ValidatedServer {
    ValidatedServer(
      serverURL: URL(string: "https://books.example.test")!,
      serverVersion: "2.36.0",
      isPlainHTTP: isPlainHTTP
    )
  }

  // MARK: - Happy path

  @Test func startsIdle() {
    let model = SetupFlowModel(accountLifecycle: FakeAccountLifecycle())
    #expect(model.state == .idle)
  }

  @Test func happyPathTransitionsThroughEveryState() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(
      accountLifecycle: fake, libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books")]),
      librarySelectionWriting: FakeLibrarySelectionWriter())

    await model.submitServerURL(server.serverURL)

    guard case .needsCredentials(let validated) = model.state else {
      Issue.record("expected needsCredentials, got \(model.state)")
      return
    }
    #expect(validated == server)

    model.password = "hunter2"
    await model.submitCredentials(username: "alice")

    #expect(model.state == .authenticated)
  }

  /// The state machine flips to `.validatingServer` synchronously, before the
  /// `AccountLifecycle` call resolves. A gated fake proves this, since `FakeAccountLifecycle`
  /// resolves immediately with no suspension to observe.
  @Test func submitServerURLMovesToValidatingServerBeforeTheCallResolves() async {
    let server = makeValidatedServer()
    let gated = FakeAccountLifecycle()
    gated.stubValidateServer(.success(server))
    gated.validateServerGate.hold()
    let model = SetupFlowModel(
      accountLifecycle: gated, libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books")]),
      librarySelectionWriting: FakeLibrarySelectionWriter())

    let task = Task { await model.submitServerURL(server.serverURL) }
    await waitUntil { model.state == .validatingServer }
    #expect(model.state == .validatingServer)

    gated.validateServerGate.release()
    await task.value

    #expect(model.state == .needsCredentials(server: server))
  }

  /// Same shape, one step later: `.loggingIn` appears before `login` resolves.
  @Test func submitCredentialsMovesToLoggingInBeforeTheCallResolves() async {
    let server = makeValidatedServer()
    let gated = FakeAccountLifecycle()
    gated.stubValidateServer(.success(server))
    gated.loginGate.hold()
    let model = SetupFlowModel(
      accountLifecycle: gated, libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books")]),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)

    let task = Task { await model.submitCredentials(username: "alice") }
    await waitUntil { model.state == .loggingIn(server: server, username: "alice") }
    #expect(model.state == .loggingIn(server: server, username: "alice"))

    gated.loginGate.release()
    await task.value

    #expect(model.state == .authenticated)
  }

  @Test func httpServerProceedsDirectlyToCredentials() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer(isPlainHTTP: true)
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(
      accountLifecycle: fake, libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books")]),
      librarySelectionWriting: FakeLibrarySelectionWriter())

    await model.submitServerURL(server.serverURL)

    #expect(model.state == .needsCredentials(server: server))
    #expect(model.state.copyText == "Enter your sign-in details.")
  }

  // MARK: - Sign-in methods

  /// An SSO-only server's single button depends on a server setting the user may need to ask for,
  /// so the credentials step names it.
  @Test("an SSO-only server shows the single sign-on notice at the credentials step")
  func singleSignOnOnlyServerShowsTheNotice() async {
    let fake = FakeAccountLifecycle()
    let server = ValidatedServer(
      serverURL: URL(string: "https://books.example.test")!, serverVersion: "2.37.2", isPlainHTTP: false,
      authMethods: [.openID])
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(accountLifecycle: fake)

    await model.submitServerURL(server.serverURL)

    #expect(model.state == .needsCredentials(server: server))
    #expect(model.state.credentialsNotice == SetupFlowCopy.singleSignOnOnlyNotice)
    #expect(SetupFlowCopy.singleSignOnOnlyNotice.contains("single sign-on"))
    #expect(SetupFlowCopy.singleSignOnOnlyNotice.contains("whirr://oauth"))
  }

  @Test(
    "a server that accepts passwords, or does not say, shows no notice",
    arguments: [Set<ServerAuthMethod>?.some([.local]), [.local, .openID], nil])
  func passwordCapableServerShowsNoNotice(methods: Set<ServerAuthMethod>?) async {
    let fake = FakeAccountLifecycle()
    let server = ValidatedServer(
      serverURL: URL(string: "https://books.example.test")!, serverVersion: "2.37.2", isPlainHTTP: false,
      authMethods: methods)
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(accountLifecycle: fake)

    await model.submitServerURL(server.serverURL)

    #expect(model.state.credentialsNotice == nil)
  }

  /// The notice belongs to the credentials step only: a failure shows its own recovery message.
  @Test("the notice is absent outside the credentials step")
  func noticeIsAbsentOutsideTheCredentialsStep() {
    let server = ValidatedServer(
      serverURL: URL(string: "https://books.example.test")!, serverVersion: "2.37.2", isPlainHTTP: false,
      authMethods: [.openID])

    #expect(SetupFlowModel.State.idle.credentialsNotice == nil)
    #expect(SetupFlowModel.State.loggingIn(server: server, username: "").credentialsNotice == nil)
    #expect(
      SetupFlowModel.State.loginFailed(
        server: server, message: SetupFlowCopy.recoveryMessage(for: .invalidCredentials)
      ).credentialsNotice == nil)
  }

  // MARK: - Password hygiene

  @Test func passwordIsClearedImmediatelyAfterSuccessfulLogin() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(
      accountLifecycle: fake, libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books")]),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)

    model.password = "hunter2"
    await model.submitCredentials(username: "alice")

    #expect(model.password.isEmpty)
    #expect(model.state == .authenticated)
  }

  @Test func passwordIsClearedImmediatelyAfterFailedLogin() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    fake.stubLogin(throwing: AccountLifecycleError.invalidCredentials)
    let model = SetupFlowModel(accountLifecycle: fake)
    await model.submitServerURL(server.serverURL)

    model.password = "wrong-password"
    await model.submitCredentials(username: "alice")

    #expect(model.password.isEmpty)
    guard case .loginFailed = model.state else {
      Issue.record("expected loginFailed, got \(model.state)")
      return
    }
  }

  @Test func apiTokenIsClearedImmediatelyAfterSuccessAndFailure() async {
    let server = makeValidatedServer()
    let successfulFake = FakeAccountLifecycle()
    successfulFake.stubValidateServer(.success(server))
    let successfulModel = SetupFlowModel(
      accountLifecycle: successfulFake,
      libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books")]),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await successfulModel.submitServerURL(server.serverURL)
    successfulModel.apiToken = "api-token-canary"

    await successfulModel.submitAPIToken()

    #expect(successfulModel.apiToken.isEmpty)
    #expect(successfulModel.state == .authenticated)

    let failedFake = FakeAccountLifecycle()
    failedFake.stubValidateServer(.success(server))
    failedFake.stubLogin(throwing: AccountLifecycleError.invalidCredentials)
    let failedModel = SetupFlowModel(accountLifecycle: failedFake)
    await failedModel.submitServerURL(server.serverURL)
    failedModel.apiToken = "wrong-api-token"

    await failedModel.submitAPIToken()

    #expect(failedModel.apiToken.isEmpty)
    #expect(
      failedModel.state
        == .loginFailed(
          server: server, message: SetupFlowCopy.recoveryMessage(for: .invalidCredentials)))
  }

  // MARK: - Distinct recovery copy per failure category

  @Test func everyAccountLifecycleErrorYieldsADistinctNonTechnicalMessage() async {
    let errors: [AccountLifecycleError] =
      [
        .malformedURL,
        .unreachable,
        .tlsUntrusted,
        .incompatibleServer(detectedVersion: "2.10.0"),
        .invalidCredentials,
        .deviceBoundToDifferentAccount,
        .loginRateLimited(retryAfter: 30),
        .localPersistenceFailed,
        .notAudiobookshelfServer,
        .localStateUnreadable,
        .keychainUnavailable,
        .blockedByProxy,
        .redirected(target: nil),
      ] + SingleSignOnFailure.allCases.map { .singleSignOnFailed($0) }

    var messages: [String] = []
    for error in errors {
      let fake = FakeAccountLifecycle()
      fake.stubValidateServer(.failure(error))
      let model = SetupFlowModel(accountLifecycle: fake)

      await model.submitServerURL(URL(string: "https://books.example.test")!)

      guard case .serverValidationFailed(_, _, let message) = model.state else {
        Issue.record("expected serverValidationFailed for \(error), got \(model.state)")
        continue
      }
      #expect(!message.text.isEmpty)
      // Non-technical: no raw error type name leaking into user-facing copy.
      #expect(!message.text.contains("Error"))
      messages.append(message.text)
    }

    #expect(
      Set(messages).count == messages.count, "expected every error category to have distinct copy, got \(messages)")
  }

  /// The server accepted the credentials, then a Keychain/database write threw on the way back.
  /// `genericRecoveryMessage` says nothing about a sign-in that actually succeeded, so this must
  /// not fall through to it.
  @Test("a post-authentication persistence failure gets its own recovery copy, not the generic one")
  func postAuthenticationPersistenceFailureIsNotGeneric() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    fake.stubLogin(throwing: AccountLifecycleError.localPersistenceFailed)
    let model = SetupFlowModel(accountLifecycle: fake)
    await model.submitServerURL(server.serverURL)

    model.password = "hunter2"
    await model.submitCredentials(username: "alice")

    guard case .loginFailed(_, let message) = model.state else {
      Issue.record("expected loginFailed, got \(model.state)")
      return
    }
    #expect(message.key == .localPersistenceFailed)
    #expect(message != SetupFlowCopy.genericRecoveryMessage)
  }

  @Test func localPersistenceFailureCopySaysTheSignInItselfWorked() {
    let message = SetupFlowCopy.recoveryMessage(for: .localPersistenceFailed)
    let text = message.text.lowercased()

    #expect(message.key == .localPersistenceFailed)
    #expect(text.contains("signed in"))
    #expect(text.contains("this device"))
    #expect(text.contains("try again"))
  }

  /// A non-Audiobookshelf host (e.g. a Synology DSM portal) passes setup and only fails at the
  /// login POST, where the copy would blame the credentials. The message for this category has
  /// to name the address as the problem.
  @Test func foreignServerCopyNamesTheAddressRatherThanTheCredentials() {
    let message = SetupFlowCopy.recoveryMessage(for: .notAudiobookshelfServer)
    let text = message.text.lowercased()

    #expect(message.key == .notAudiobookshelfServer)
    #expect(text.contains("doesn't look like an audiobookshelf server"))
    #expect(text.contains("url"))
    #expect(text.contains("password") == false)
    #expect(text.contains("credential") == false)
  }

  /// Audiobookshelf never refuses `/status`, so a 401 or 403 there is a proxy or access gateway.
  /// The unreachable copy's network and Tailscale advice cannot fix that; headers can.
  @Test func proxyRefusalCopyPointsAtHeadersRatherThanTheNetwork() {
    let message = SetupFlowCopy.recoveryMessage(for: .blockedByProxy)
    let text = message.text.lowercased()

    #expect(message.key == .blockedByProxy)
    #expect(text.contains("headers"))
    #expect(text.contains("advanced"))
    #expect(text.contains("tailscale") == false)
  }

  /// Whirr refuses a redirect to another scheme, host or port. The copy names the server base it
  /// pointed to, without the `/status` path that was asked for or any query or credentials.
  @Test func redirectCopyNamesTheServerBaseItPointsTo() throws {
    let target = try #require(
      URL(string: "https://who:pw@books.example.test:8443/abs/status?token=abc#frag"))
    let message = SetupFlowCopy.recoveryMessage(for: .redirected(target: target))

    #expect(message.key == .redirected)
    #expect(message.text.contains("https://books.example.test:8443/abs"))
    #expect(message.text.contains("/abs/status") == false)
    #expect(message.text.contains("token") == false)
    #expect(message.text.contains("pw@") == false)
    #expect(message.text.contains("frag") == false)
  }

  @Test func redirectCopyWithoutATargetSuggestsHTTPS() {
    let message = SetupFlowCopy.recoveryMessage(for: .redirected(target: nil))

    #expect(message.key == .redirected)
    #expect(message.text.contains("https://"))
  }

  /// -34018 is `errSecMissingEntitlement`: the build is missing its Keychain access group. The
  /// device is fine, so the `.localPersistenceFailed` advice (unlock it, free up space) sends
  /// the user hunting for a problem that isn't there.
  @Test func keychainUnavailableCopyNamesTheBuildAndNotTheDevicesStorageOrLock() {
    let message = SetupFlowCopy.recoveryMessage(for: .keychainUnavailable)
    let text = message.text.lowercased()

    #expect(message.key == .keychainUnavailable)
    #expect(text.contains("build") || text.contains("app"))
    #expect(text.contains("free space") == false)
    #expect(text.contains("unlock") == false)
    #expect(text != SetupFlowCopy.recoveryMessage(for: .localPersistenceFailed).text)
  }

  /// The mirror image of `.localPersistenceFailed`: nothing was authenticated, so the copy must
  /// not congratulate the user on a sign-in that never happened.
  @Test func localStateUnreadableCopyDoesNotClaimTheSignInSucceeded() {
    let message = SetupFlowCopy.recoveryMessage(for: .localStateUnreadable)
    let text = message.text.lowercased()

    #expect(message.key == .localStateUnreadable)
    #expect(text.contains("signed in") == false)
    #expect(text.contains("try again"))
    #expect(message != SetupFlowCopy.genericRecoveryMessage)
  }

  @Test func deviceBoundToDifferentAccountExplainsHowToRecover() {
    let message = SetupFlowCopy.recoveryMessage(for: .deviceBoundToDifferentAccount)
    let text = message.text.lowercased()

    #expect(message.key == .deviceBoundToDifferentAccount)
    #expect(text.contains("different account"))
    #expect(text.contains("remove"))
    #expect(text.contains("first"))
  }

  @Test func incompatibleServerMessageIncludesTheDetectedVersion() async {
    let fake = FakeAccountLifecycle()
    fake.stubValidateServer(.failure(AccountLifecycleError.incompatibleServer(detectedVersion: "2.10.0")))
    let model = SetupFlowModel(accountLifecycle: fake)

    await model.submitServerURL(URL(string: "https://old.example.test")!)

    guard case .serverValidationFailed(_, _, let message) = model.state else {
      Issue.record("expected serverValidationFailed, got \(model.state)")
      return
    }
    #expect(message.text.contains("2.10.0"))
  }

  @Test func incompatibleServerMessageStaysActionableWithNoDetectedVersion() async {
    let fake = FakeAccountLifecycle()
    fake.stubValidateServer(.failure(AccountLifecycleError.incompatibleServer(detectedVersion: nil)))
    let model = SetupFlowModel(accountLifecycle: fake)

    await model.submitServerURL(URL(string: "https://old.example.test")!)

    guard case .serverValidationFailed(_, _, let message) = model.state else {
      Issue.record("expected serverValidationFailed, got \(model.state)")
      return
    }
    #expect(!message.text.isEmpty)
  }

  @Test func unreachableServerMessagePointsAtAdvancedProxyHeaders() {
    let text = SetupFlowCopy.recoveryMessage(for: .unreachable).text.lowercased()

    #expect(text.contains("advanced"))
    #expect(text.contains("proxy"))
    #expect(text.contains("headers"))
  }

  @Test func invalidCredentialsDuringLoginYieldsItsOwnMessageDistinctFromServerErrors() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    fake.stubLogin(throwing: AccountLifecycleError.invalidCredentials)
    let model = SetupFlowModel(accountLifecycle: fake)
    await model.submitServerURL(server.serverURL)

    model.password = "wrong"
    await model.submitCredentials(username: "alice")

    guard case .loginFailed(_, let message) = model.state else {
      Issue.record("expected loginFailed, got \(model.state)")
      return
    }
    #expect(message.key == .invalidCredentials)
  }

  @Test func rateLimitedLoginMessageSaysAttemptWasNotSentAndGivesRetryWindow() {
    let message = SetupFlowCopy.recoveryMessage(for: .loginRateLimited(retryAfter: 30))
    let text = message.text.lowercased()

    #expect(message.key == .loginRateLimited)
    #expect(text.contains("not sent") || text.contains("wasn't sent"))
    #expect(text.contains("try again"))
    #expect(text.contains("30") && text.contains("second"))
    #expect(text.contains("wrong") == false)
    #expect(text.contains("password") == false)
    #expect(text.contains("credential") == false)
  }

  // MARK: - Invalid transitions are impossible

  @Test func submittingCredentialsWhileValidatingDoesNothing() async {
    let server = makeValidatedServer()
    let gated = FakeAccountLifecycle()
    gated.stubValidateServer(.success(server))
    gated.validateServerGate.hold()
    let model = SetupFlowModel(accountLifecycle: gated)

    let task = Task { await model.submitServerURL(server.serverURL) }
    await waitUntil { model.state == .validatingServer }
    #expect(model.state == .validatingServer)

    // Fired while still validating: must be a no-op, not a crash or a skipped state.
    model.password = "should-be-ignored"
    await model.submitCredentials(username: "alice")
    #expect(model.state == .validatingServer)
    #expect(model.password == "should-be-ignored", "a no-op transition must not touch the password either")

    gated.validateServerGate.release()
    await task.value
    #expect(model.state == .needsCredentials(server: server))
  }

  @Test func submittingServerURLWhileNotIdleDoesNothing() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(accountLifecycle: fake)
    await model.submitServerURL(server.serverURL)

    // Already at needsCredentials: re-submitting a server URL must not restart validation.
    await model.submitServerURL(URL(string: "https://other.example.test")!)

    guard case .needsCredentials(let validated) = model.state else {
      Issue.record("expected to remain at needsCredentials, got \(model.state)")
      return
    }
    #expect(validated == server)
  }

  // MARK: - Correcting a failed URL

  /// A corrected URL submitted from the failed state must re-validate as if from idle.
  /// Otherwise it is ignored and `retry()` only re-validates the stale one.
  @Test func correctedURLSubmittedFromValidationFailedStateRevalidates() async {
    let fake = FakeAccountLifecycle()
    fake.stubValidateServer(.failure(AccountLifecycleError.unreachable))
    let model = SetupFlowModel(accountLifecycle: fake)

    await model.submitServerURL(URL(string: "https://books.example.test")!)
    guard case .serverValidationFailed = model.state else {
      Issue.record("expected serverValidationFailed, got \(model.state)")
      return
    }

    let server = makeValidatedServer(isPlainHTTP: true)
    fake.stubValidateServer(.success(server))
    await model.submitServerURL(URL(string: "http://books.example.test")!)

    guard case .needsCredentials(let validated) = model.state else {
      Issue.record("expected needsCredentials after corrected URL, got \(model.state)")
      return
    }
    #expect(validated == server)
  }

  // MARK: - Cancel / retry return to a sane state

  @Test func cancelFromNeedsCredentialsReturnsToIdleAndClearsPassword() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    let model = SetupFlowModel(accountLifecycle: fake)
    await model.submitServerURL(server.serverURL)
    model.password = "typed-but-not-submitted"

    model.cancel()

    #expect(model.state == .idle)
    #expect(model.password.isEmpty)
  }

  @Test func retryFromServerValidationFailedReRunsValidationAgainstTheSameURL() async {
    let fake = FakeAccountLifecycle()
    let url = URL(string: "https://flaky.example.test")!
    fake.stubValidateServer(.failure(AccountLifecycleError.unreachable))
    let model = SetupFlowModel(accountLifecycle: fake)
    await model.submitServerURL(url)
    guard case .serverValidationFailed = model.state else {
      Issue.record("expected serverValidationFailed, got \(model.state)")
      return
    }

    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    await model.retry()

    #expect(model.state == .needsCredentials(server: server))
  }

  @Test func retryFromServerValidationFailedPreservesTheCustomHeaders() async {
    let fake = FakeAccountLifecycle()
    let url = URL(string: "https://flaky.example.test")!
    let headers = ["X-Proxy-Token": "proxy-secret"]
    fake.stubValidateServer(.failure(AccountLifecycleError.unreachable))
    let model = SetupFlowModel(accountLifecycle: fake)

    await model.submitServerURL(url, customHeaders: headers)
    fake.stubValidateServer(.success(makeValidatedServer()))
    await model.retry()

    #expect(fake.validationCalls.map { $0.url } == [url, url])
    #expect(fake.validationCalls.map { $0.customHeaders } == [headers, headers])
  }

  @Test func retryFromLoginFailedReturnsToNeedsCredentialsForTheSameServer() async {
    let fake = FakeAccountLifecycle()
    let server = makeValidatedServer()
    fake.stubValidateServer(.success(server))
    fake.stubLogin(throwing: AccountLifecycleError.invalidCredentials)
    let model = SetupFlowModel(accountLifecycle: fake)
    await model.submitServerURL(server.serverURL)
    model.password = "wrong"
    await model.submitCredentials(username: "alice")
    guard case .loginFailed = model.state else {
      Issue.record("expected loginFailed, got \(model.state)")
      return
    }

    await model.retry()

    #expect(model.state == .needsCredentials(server: server))
  }

  // MARK: - State copy for every visible state

  @Test func everyVisibleStateExposesNonEmptyCopyWithAStableKey() async {
    let idle = SetupFlowModel.State.idle
    let validating = SetupFlowModel.State.validatingServer
    let needsCredentials = SetupFlowModel.State.needsCredentials(
      server: makeValidatedServer())
    let loggingIn = SetupFlowModel.State.loggingIn(server: makeValidatedServer(), username: "alice")
    let library = Self.library("books")
    let loadingLibraries = SetupFlowModel.State.loadingLibraries
    let choosingLibraries = SetupFlowModel.State.choosingLibraries(
      libraries: [library], selectedIDs: [library.serverLibraryID])
    let savingLibrarySelection = SetupFlowModel.State.savingLibrarySelection
    let authenticated = SetupFlowModel.State.authenticated
    let serverFailed = SetupFlowModel.State.serverValidationFailed(
      url: URL(string: "https://x.test")!, customHeaders: [:],
      message: SetupFlowCopy.recoveryMessage(for: .unreachable))
    let loginFailed = SetupFlowModel.State.loginFailed(
      server: makeValidatedServer(),
      message: SetupFlowCopy.recoveryMessage(for: .invalidCredentials))

    let discoveryFailed = SetupFlowModel.State.libraryDiscoveryFailed(
      message: SetupFlowCopy.libraryDiscoveryRecoveryMessage)
    let states = [
      idle, validating, needsCredentials, loggingIn, loadingLibraries, choosingLibraries,
      savingLibrarySelection, authenticated, serverFailed, loginFailed, discoveryFailed,
    ]
    var keys: [String] = []
    for state in states {
      #expect(!state.copyText.isEmpty, "\(state) has empty copy")
      keys.append(state.copyKey)
    }
    #expect(Set(keys).count == keys.count, "expected a distinct copy key per visible state, got \(keys)")
  }

  @Test func loginTransitionsToLoadingLibrariesThenShowsEveryLibraryPreselected() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    let discovery = GatedLibraryDiscovery(libraries: [Self.library("books"), Self.library("podcasts")])
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: discovery,
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)

    let task = Task { await model.submitCredentials(username: "alice") }
    await waitUntil { model.state == .loadingLibraries }
    #expect(model.state == .loadingLibraries)
    discovery.gate.release()
    await task.value

    guard case .choosingLibraries(let libraries, let selectedIDs) = model.state else {
      Issue.record("expected choosingLibraries, got \(model.state)")
      return
    }
    #expect(selectedIDs == Set(libraries.map(\.serverLibraryID)))
  }

  @Test func oneLibraryCompletesSelectionAutomaticallyAndAuthenticates() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    let writer = FakeLibrarySelectionWriter()
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books")]),
      librarySelectionWriting: writer)
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    #expect(writer.onboardingSelections == [["books"]])
    #expect(model.state == .authenticated)
  }

  @Test func zeroSelectedDisablesContinueAndCommitRunsOnceAfterASelection() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    let writer = FakeLibrarySelectionWriter()
    let model = SetupFlowModel(
      accountLifecycle: account,
      libraryDiscovery: FakeLibraryDiscovery(libraries: [Self.library("books"), Self.library("podcasts")]),
      librarySelectionWriting: writer)
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")
    model.toggleLibrarySelection("books")
    model.toggleLibrarySelection("podcasts")
    #expect(model.canContinueLibrarySelection == false)
    await model.continueLibrarySelection()
    #expect(writer.onboardingSelections.isEmpty)

    model.toggleLibrarySelection("books")
    await model.continueLibrarySelection()
    #expect(writer.onboardingSelections == [["books"]])
    #expect(model.state == .authenticated)
  }

  @Test func discoveryFailureRetriesWithoutReplayingCredentials() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    let discovery = FakeLibraryDiscovery(libraries: [Self.library("books")])
    discovery.result = .failure(DiscoveryFailure.offline)
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: discovery,
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")
    guard case .libraryDiscoveryFailed = model.state else {
      Issue.record("expected libraryDiscoveryFailed, got \(model.state)")
      return
    }

    discovery.result = .success(())
    await model.retry()
    #expect(discovery.callCount == 2)
    #expect(account.loginCalls.count == 1)
    #expect(model.state == .authenticated)
  }

  @Test func zeroAccessibleLibrariesUsesTheExistingRetryAndSignOutRecoveryState() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: FakeLibraryDiscovery(libraries: []),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    #expect(
      model.state
        == .libraryDiscoveryFailed(
          message: SetupFlowCopy.noAccessibleLibrariesRecoveryMessage))
  }

  @Test func discoveryFailureSignOutReturnsToIdleAfterLocalRemoval() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: FakeLibraryDiscovery(libraries: []),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    let didSignOut = await model.signOut()

    #expect(didSignOut)
    #expect(model.state == .idle)
    #expect(model.isSigningOut == false)
    #expect(account.logoutCallCount == 1)
  }

  @Test func discoveryFailureSignOutDisarmsBeforeLoggingOut() async throws {
    let server = makeValidatedServer()
    let account = OrderedSignOutSpy(server: server)
    let model = SetupFlowModel(
      accountLifecycle: account,
      libraryDiscovery: FakeLibraryDiscovery(libraries: []),
      notificationLifecycle: account)
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    #expect(await model.signOut())
    #expect(account.events.value == ["disarm(nil)", "logout"])
  }

  @Test func signOutOutsideDiscoveryFailureDoesNotDisarm() async {
    let notifications = FakeRSSNotificationLifecycleHandling()
    let model = SetupFlowModel(
      accountLifecycle: FakeAccountLifecycle(), notificationLifecycle: notifications)

    #expect(await model.signOut() == false)
    #expect(await notifications.feedIDs.isEmpty)
  }

  @Test func localRemovalFailureKeepsDiscoveryRecoveryAvailable() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    account.stubLogout(throwing: AccountRemovalError.deletionFailed)
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: FakeLibraryDiscovery(libraries: []),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    let didSignOut = await model.signOut()

    #expect(didSignOut == false)
    #expect(model.state == .libraryDiscoveryFailed(message: SetupFlowCopy.noAccessibleLibrariesRecoveryMessage))
    #expect(model.isSigningOut == false)
  }

  @Test func untypedLogoutFailureKeepsDiscoveryRecoveryAvailable() async {
    let account = FakeAccountLifecycle()
    let server = makeValidatedServer()
    account.stubValidateServer(.success(server))
    account.stubLogout(throwing: DiscoveryFailure.offline)
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: FakeLibraryDiscovery(libraries: []),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    let didSignOut = await model.signOut()

    #expect(didSignOut == false)
    #expect(model.state == .libraryDiscoveryFailed(message: SetupFlowCopy.noAccessibleLibrariesRecoveryMessage))
    #expect(model.isSigningOut == false)
  }

  @Test func aSecondSignOutCannotRaceTheInFlightRemoval() async {
    let server = makeValidatedServer()
    let account = FakeAccountLifecycle()
    account.stubValidateServer(.success(server))
    account.logoutGate.hold()
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: FakeLibraryDiscovery(libraries: []),
      librarySelectionWriting: FakeLibrarySelectionWriter())
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    let firstAttempt = Task { await model.signOut() }
    // `isSigningOut` flips before the disarm hop; wait for the gated `logout()` itself, so the
    // first attempt is provably parked inside the removal and its disarm has already happened.
    await waitUntil { account.logoutCallCount == 1 }
    let secondAttempt = await model.signOut()
    await model.retry()

    #expect(secondAttempt == false)
    #expect(account.logoutCallCount == 1)
    #expect(model.state == .libraryDiscoveryFailed(message: SetupFlowCopy.noAccessibleLibrariesRecoveryMessage))
    account.logoutGate.release()
    let firstAttemptSucceeded = await firstAttempt.value
    #expect(firstAttemptSucceeded)
    #expect(model.state == .idle)
    #expect(model.isSigningOut == false)
  }

  @Test func reentrantSignOutDoesNotDisarmAgain() async {
    let server = makeValidatedServer()
    let account = FakeAccountLifecycle()
    account.stubValidateServer(.success(server))
    account.logoutGate.hold()
    let notifications = FakeRSSNotificationLifecycleHandling()
    let model = SetupFlowModel(
      accountLifecycle: account,
      libraryDiscovery: FakeLibraryDiscovery(libraries: []),
      notificationLifecycle: notifications)
    await model.submitServerURL(server.serverURL)
    await model.submitCredentials(username: "alice")

    let firstAttempt = Task { await model.signOut() }
    // `isSigningOut` flips before the disarm hop; wait for the gated `logout()` itself, so the
    // first attempt is provably parked inside the removal and its disarm has already happened.
    await waitUntil { account.logoutCallCount == 1 }
    #expect(await model.signOut() == false)
    #expect(await notifications.feedIDs == [nil])

    account.logoutGate.release()
    #expect(await firstAttempt.value)
  }

  @Test func authenticatedPendingRelaunchResumesLibraryDiscoveryWithoutCredentials() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let discovery = FakeLibraryDiscovery(libraries: [Self.library("books"), Self.library("podcasts")])
    let model = SetupFlowModel(
      accountLifecycle: account, libraryDiscovery: discovery,
      librarySelectionWriting: FakeLibrarySelectionWriter())

    await model.resumePendingLibrarySelection()

    #expect(discovery.callCount == 1)
    #expect(account.loginCalls.isEmpty)
    guard case .choosingLibraries = model.state else {
      Issue.record("expected choosingLibraries, got \(model.state)")
      return
    }
  }

  private static func library(_ id: String) -> SelectableLibrary {
    SelectableLibrary(
      serverLibraryID: id, name: id.capitalized, mediaType: "book", isAccessible: true, isIncluded: false)
  }
}

// Kept: one event log shared by logout and disarm is what proves their relative order.
private final class OrderedSignOutSpy: AccountLifecycle, RSSNotificationLifecycleHandling,
  @unchecked Sendable
{
  let events = Locked<[String]>([])
  private let server: ValidatedServer

  init(server: ValidatedServer) {
    self.server = server
  }

  var isAuthenticated: Bool { false }

  func validateServer(url: URL, customHeaders: [String: String]) async throws -> ValidatedServer {
    server
  }

  func login(server: ValidatedServer, username: String, password: String) async throws {}

  func login(server: ValidatedServer, apiToken: String) async throws {}

  func logout() async throws {
    events.withValue { $0.append("logout") }
  }

  func disarm(feedID: Int64?) async {
    events.withValue { $0.append(feedID.map { "disarm(\($0))" } ?? "disarm(nil)") }
  }
}

private enum DiscoveryFailure: Error {
  case offline
}

final class FakeLibraryDiscovery: LibrarySelectionDiscovering, @unchecked Sendable {
  private let libraries: [SelectableLibrary]
  var result: Result<Void, Error> = .success(())
  private(set) var callCount = 0

  init(libraries: [SelectableLibrary]) {
    self.libraries = libraries
  }

  func discoverAccessibleLibraries() async throws -> [SelectableLibrary] {
    callCount += 1
    try result.get()
    return libraries
  }
}

private final class GatedLibraryDiscovery: LibrarySelectionDiscovering, @unchecked Sendable {
  /// Holds discovery until a test has observed the model's intermediate state, then lets it
  /// proceed. A held call stays parked through task cancellation until released.
  let gate = TestGate<Void>(label: "GatedLibraryDiscovery discovery", ignoresCancellation: true)
  private let libraries: [SelectableLibrary]

  init(libraries: [SelectableLibrary]) {
    self.libraries = libraries
    gate.hold()
  }

  func discoverAccessibleLibraries() async throws -> [SelectableLibrary] {
    await gate.pass()
    return libraries
  }
}

final class FakeLibrarySelectionWriter: LibrarySelectionWriting, @unchecked Sendable {
  private(set) var onboardingSelections: [Set<String>] = []

  func completeOnboarding(includedIDs: Set<String>) async throws {
    onboardingSelections.append(includedIDs)
  }

  func setIncluded(_ included: Bool, libraryID: String) async throws {}
}
