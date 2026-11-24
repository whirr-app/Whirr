import ABSApi
import Foundation
import SyncEngine

/// Hand-written fakes for every service boundary (no DI framework; see ARCHITECTURE.md).
/// Mutable ones use a lock so they stay `Sendable` under Swift 6 strict concurrency.

public final class FakeAccountLifecycle: AccountLifecycle, @unchecked Sendable {
  private let state = Locked(false)
  public var isAuthenticated: Bool {
    get { state.value }
    set { state.value = newValue }
  }

  private let validateServerResult = Locked<Result<ValidatedServer, Error>?>(nil)
  private let loginResult = Locked<Error?>(nil)
  private let logoutResult = Locked<Error?>(nil)
  private let recordedValidations = Locked<[(url: URL, customHeaders: [String: String])]>([])
  private let recordedLogins = Locked<[(server: ValidatedServer, username: String, password: String)]>([])
  public var validationCalls: [(url: URL, customHeaders: [String: String])] {
    recordedValidations.value
  }
  public var loginCalls: [(server: ValidatedServer, username: String, password: String)] {
    recordedLogins.value
  }
  public var logoutCallCount: Int { logoutCallCountBox.value }
  private let logoutCallCountBox = Locked(0)

  /// Hold one of these (`hold()`) to park `validateServer`, `login` (either overload) or `logout`
  /// in flight until the test releases it. Open by default, so calls resolve at once. Each call is
  /// recorded before it parks.
  public let validateServerGate = TestGate<Void>(label: "FakeAccountLifecycle.validateServer")
  public let loginGate = TestGate<Void>(label: "FakeAccountLifecycle.login")
  public let logoutGate = TestGate<Void>(label: "FakeAccountLifecycle.logout")

  private let logoutHook = Locked<(@Sendable () -> Void)?>(nil)
  /// Runs inside every `logout()`, after it is counted and before it parks or throws: lets a test
  /// log where the call fell relative to other collaborators.
  public func setLogoutHook(_ hook: (@Sendable () -> Void)?) {
    logoutHook.value = hook
  }

  /// The durable removal-pending signal a test seeds directly, mirroring how
  /// `AccountRemovalCoordinator.isRemovalPending()` reads its own journal.
  private let removalPendingBox = Locked(false)
  public var isRemovalPendingValue: Bool {
    get { removalPendingBox.value }
    set { removalPendingBox.value = newValue }
  }
  private let resumeRemovalErrorBox = Locked<Error?>(nil)
  public func stubResumeRemoval(throwing error: Error?) {
    resumeRemovalErrorBox.value = error
  }
  public var resumeRemovalCallCount: Int { resumeRemovalCallCountBox.value }
  private let resumeRemovalCallCountBox = Locked(0)

  public init() {}

  public func stubValidateServer(_ result: Result<ValidatedServer, Error>) {
    validateServerResult.value = result
  }

  public func stubLogin(throwing error: Error?) {
    loginResult.value = error
  }

  public func stubLogout(throwing error: Error?) {
    logoutResult.value = error
  }

  public func validateServer(url: URL, customHeaders: [String: String]) async throws -> ValidatedServer {
    recordedValidations.withValue { $0.append((url, customHeaders)) }
    await validateServerGate.pass()
    switch validateServerResult.value {
    case .success(let server):
      return server
    case .failure(let error):
      throw error
    case nil:
      return ValidatedServer(
        serverURL: url,
        serverVersion: "0.0.0",
        isPlainHTTP: url.scheme == "http",
        customHeaders: (try? CustomHeaders(customHeaders)) ?? .none)
    }
  }

  public func login(server: ValidatedServer, username: String, password: String) async throws {
    recordedLogins.withValue { $0.append((server, username, password)) }
    await loginGate.pass()
    if let error = loginResult.value { throw error }
    authenticationModeBox.value = .password
    isAuthenticated = true
  }

  public func login(server: ValidatedServer, apiToken: String) async throws {
    await loginGate.pass()
    if let error = loginResult.value { throw error }
    authenticationModeBox.value = .apiToken
    isAuthenticated = true
  }

  public func logout() async throws {
    logoutCallCountBox.withValue { $0 += 1 }
    logoutHook.value?()
    isAuthenticated = false
    await logoutGate.pass()
    if let error = logoutResult.value { throw error }
  }

  public func isRemovalPending() async throws -> Bool {
    removalPendingBox.value
  }

  /// Mirrors `AccountRemovalCoordinator.resumeIfNeeded()`'s real contract: a thrown error leaves
  /// the journal (here, `isRemovalPendingValue`) untouched so a retry can re-attempt; success
  /// clears it.
  public func resumeRemovalIfNeeded() async throws {
    resumeRemovalCallCountBox.withValue { $0 += 1 }
    if let error = resumeRemovalErrorBox.value { throw error }
    removalPendingBox.value = false
  }

  // MARK: - Same-account recovery

  private let reauthenticateResult = Locked<Error?>(nil)
  private let recordedReauthentications = Locked<[(username: String, password: String)]>([])
  public var reauthenticateCallCount: Int { recordedReauthentications.value.count }
  public var lastReauthentication: (username: String, password: String)? {
    recordedReauthentications.value.last
  }
  private let storedServerDisplayStringBox = Locked<String?>(nil)
  public var storedServerDisplayString: String? {
    get { storedServerDisplayStringBox.value }
    set { storedServerDisplayStringBox.value = newValue }
  }

  private let authenticationModeBox = Locked<AccountAuthenticationMode>(.password)
  public var authenticationMode: AccountAuthenticationMode {
    get { authenticationModeBox.value }
    set { authenticationModeBox.value = newValue }
  }

  public func stubReauthenticate(throwing error: Error?) {
    reauthenticateResult.value = error
  }

  public func reauthenticate(username: String, password: String) async throws {
    recordedReauthentications.withValue { $0.append((username, password)) }
    if let error = reauthenticateResult.value { throw error }
    authenticationModeBox.value = .password
    isAuthenticated = true
  }

  public func reauthenticate(apiToken: String) async throws {
    if let error = reauthenticateResult.value { throw error }
    authenticationModeBox.value = .apiToken
    isAuthenticated = true
  }

  // MARK: - Single sign-on

  private let beginSingleSignOnResult = Locked<Error?>(nil)
  private let issuedAttempts = Locked<[SingleSignOnAttempt]>([])
  private let recordedSingleSignOnCompletions = Locked<[(attempt: SingleSignOnAttempt, callbackURL: URL)]>([])

  /// Every attempt this fake handed out, in order. Each is a stand-in that a real service would
  /// refuse to complete.
  public var issuedSingleSignOnAttempts: [SingleSignOnAttempt] { issuedAttempts.value }
  /// Completions of either kind (setup login or recovery), in order.
  public var singleSignOnCompletions: [(attempt: SingleSignOnAttempt, callbackURL: URL)] {
    recordedSingleSignOnCompletions.value
  }

  /// Makes the next `begin…` calls throw `error` (nil restores success).
  public func stubBeginSingleSignOn(throwing error: Error?) {
    beginSingleSignOnResult.value = error
  }

  public func beginSingleSignOn(server: ValidatedServer) async throws -> SingleSignOnAttempt {
    try issueAttempt()
  }

  public func login(
    server: ValidatedServer, singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL
  ) async throws {
    recordedSingleSignOnCompletions.withValue { $0.append((attempt, callbackURL)) }
    if let error = loginResult.value { throw error }
    authenticationModeBox.value = .openID
    isAuthenticated = true
  }

  public func beginSingleSignOnReauthentication() async throws -> SingleSignOnAttempt {
    try issueAttempt()
  }

  public func reauthenticate(singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL) async throws {
    recordedSingleSignOnCompletions.withValue { $0.append((attempt, callbackURL)) }
    if let error = reauthenticateResult.value { throw error }
    authenticationModeBox.value = .openID
    isAuthenticated = true
  }

  private func issueAttempt() throws -> SingleSignOnAttempt {
    if let error = beginSingleSignOnResult.value { throw error }
    let attempt = SingleSignOnAttempt(
      authorizationURL: URL(string: "https://idp.example.test/authorize?attempt=\(issuedAttempts.value.count)")!)
    issuedAttempts.withValue { $0.append(attempt) }
    return attempt
  }
}
