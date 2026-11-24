import ABSApi
import CoreSupport
import Foundation
import Persistence

/// Production `AccountLifecycle` conformance: wraps `ABSClient` for the pre-sync
/// setup/login/logout lifecycle, and Persistence's `AccountDAO`/`AccountRemoving` for the DB
/// half of it. This is the lowest module that can see both `ABSApi` and `Persistence`
/// (ARCHITECTURE.md §1 table forbids AppModel from importing `ABSApi`).
///
/// Every stored property is an immutable, `Sendable` handle (existential, value type, actor or
/// `@Sendable` closure), so no lock or isolation is needed. `isAuthenticated` re-reads the token
/// store and account row on every access, so a fresh construction on relaunch reports correctly.
public final class AccountLifecycleService: AccountLifecycle, Sendable {
  /// Builds the composed `ABSClient` for a validated server config plus the shared token store.
  /// Production always uses `ABSClient.production`, the one public factory (ARCHITECTURE.md §2).
  /// Tests substitute a fake transport underneath the same decorator composition via
  /// `@testable import ABSApi`; that raw initializer stays non-public, so no other production code
  /// gains the seam.
  public typealias ClientFactory = @Sendable (ABSServerConfig, any TokenStoring) -> ABSClient
  public typealias AccountRecordSaver = @Sendable (AccountRecord) throws -> AccountRecord

  /// `CoreLogging` owns the subsystem every Core logger shares. Read with:
  ///
  ///     log stream --predicate 'subsystem == "com.remoteconcern.whirr" AND category == "account"'
  static let logger = CoreLogging.logger(category: "account")

  /// The writes that happen after the server has accepted the credentials: the four in
  /// `finishLogin`, plus the rotated-pair write inside `ABSClient.reauthenticate`. They all surface
  /// the same `.localPersistenceFailed` to the user, so the step name in the failure log is what
  /// tells a Keychain denial from a full disk.
  enum PostAuthenticationStep: String, Sendable {
    case loadCustomHeaders = "load-custom-headers"
    case saveCustomHeaders = "save-custom-headers"
    case saveAccountRecord = "save-account-record"
    case commitLogin = "commit-login"
    case saveRotatedTokens = "save-rotated-tokens"
  }

  /// The credential a login or re-authentication presents. It names the boundary step in failure
  /// logs; the shared paths in `+Login` and `+Reauthentication` are otherwise identical.
  enum CredentialMethod: Sendable {
    case password
    case apiToken
    case openID

    var logLabel: String {
      switch self {
      case .password: "password"
      case .apiToken: "API-token"
      case .openID: "OpenID"
      }
    }

    var loginStep: StaticString {
      switch self {
      case .password: "password-login"
      case .apiToken: "api-token-login"
      case .openID: "openid-login"
      }
    }

    var reauthenticationStep: StaticString {
      switch self {
      case .password: "password-reauthentication"
      case .apiToken: "api-token-reauthentication"
      case .openID: "openid-reauthentication"
      }
    }
  }

  let tokenStore: any TokenStoring
  let customHeaderStore: any CustomHeaderStoring
  let serverConfigFactory: ABSServerConfigFactory
  let accountDAO: AccountDAO
  let accountEndpointDAO: AccountEndpointDAO
  let accountRemover: any AccountRemoving
  let accountRecordSaver: AccountRecordSaver
  let makeClient: ClientFactory
  let generateClientUUID: @Sendable () -> String
  let loginBackoffGate: LoginBackoffGate
  let clearCachedArtwork: @Sendable () async -> Void
  /// When supplied, `logout()` routes entirely through the confirmed-removal sequence. When nil,
  /// `logout()` runs its own inline DB-removal-only path.
  let removalCoordinator: AccountRemovalCoordinator?

  public init(
    tokenStore: any TokenStoring,
    accountDAO: AccountDAO,
    accountEndpointDAO: AccountEndpointDAO,
    accountRemover: any AccountRemoving,
    customHeaderStore: any CustomHeaderStoring = InMemoryCustomHeaderStore(),
    clientFactory: ClientFactory? = nil,
    clientUUIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
    loginBackoffGate: LoginBackoffGate = LoginBackoffGate(),
    removalCoordinator: AccountRemovalCoordinator? = nil,
    accountRecordSaver: AccountRecordSaver? = nil,
    clearCachedArtwork: @escaping @Sendable () async -> Void = {}
  ) {
    self.tokenStore = tokenStore
    self.customHeaderStore = customHeaderStore
    serverConfigFactory = ABSServerConfigFactory(customHeaderStore: customHeaderStore)
    self.accountDAO = accountDAO
    self.accountEndpointDAO = accountEndpointDAO
    self.accountRemover = accountRemover
    self.accountRecordSaver = accountRecordSaver ?? { record in try accountDAO.save(record) }
    self.makeClient =
      clientFactory ?? {
        server, tokenStore in
        ABSClient.production(
          server: server,
          tokenStore: tokenStore,
          customHeaderStore: customHeaderStore,
          clearCachedArtwork: clearCachedArtwork)
      }
    self.generateClientUUID = clientUUIDGenerator
    self.loginBackoffGate = loginBackoffGate
    self.removalCoordinator = removalCoordinator
    self.clearCachedArtwork = clearCachedArtwork
  }

  public var isAuthenticated: Bool {
    guard let account = try? accountDAO.fetch(),
      let tokenAccount = try? account.credentialTokenAccount
    else { return false }
    return (try? tokenStore.load(for: tokenAccount)) != nil
  }

  public var authenticationMode: AccountAuthenticationMode {
    guard let account = try? accountDAO.fetch(),
      let tokenAccount = try? account.credentialTokenAccount,
      let tokens = try? tokenStore.load(for: tokenAccount)
    else { return .password }
    if tokens.refreshToken == nil { return .apiToken }
    return account.signsInWithOpenID ? .openID : .password
  }

  public func validateServer(url: URL, customHeaders: [String: String]) async throws -> ValidatedServer {
    let server: ABSServerConfig
    do {
      server = try serverConfigFactory.make(for: url, customHeaderFields: customHeaders)
    } catch {
      throw AccountLifecycleError.malformedURL
    }

    let status: ServerStatus
    do {
      status = try await makeClient(server, tokenStore).fetchServerStatus()
    } catch APIError.decoding {
      // Something answered 200 with a body `/status` could not be read as (a NAS or router
      // landing page serving HTML). That is "the wrong thing is here", not "nothing is here", so
      // it must not borrow the unreachable copy, which sends the user to check a working network.
      Self.logger.error("server-status returned a body that is not an Audiobookshelf /status")
      throw AccountLifecycleError.notAudiobookshelfServer
    } catch {
      throw Self.classifyStatusFailure(error)
    }

    // Checked before the version gate: a "version" read off something that is not Audiobookshelf
    // would send the user to their server admin for an irrelevant upgrade.
    guard Self.isAudiobookshelf(status) else {
      Self.logger.error(
        "server-status identified a different app: app=\(status.app ?? "<absent>", privacy: .private)")
      throw AccountLifecycleError.notAudiobookshelfServer
    }

    do {
      let version = try ABSServerCompatibilityGate.validate(serverVersion: status.serverVersion)
      return ValidatedServer(
        serverURL: server.baseURL,
        serverVersion: version.description,
        isPlainHTTP: server.baseURL.scheme?.lowercased() == "http",
        customHeaders: server.customHeaders,
        authMethods: status.authMethods
      )
    } catch let apiError as APIError {
      if case .incompatibleServer(_, let detected) = apiError {
        throw AccountLifecycleError.incompatibleServer(detectedVersion: detected?.description)
      }
      throw Self.classifyTransportFailure(apiError, step: "server-compatibility")
    }
  }

  /// Read synchronously from the same account row `isAuthenticated` re-reads on every access,
  /// never cached, so it cannot drift from the stored account.
  public var storedServerDisplayString: String? {
    (try? accountDAO.fetch())?.serverBaseURL
  }

  public func logout() async throws {
    if let removalCoordinator {
      try await removalCoordinator.confirmRemoval()
      return
    }

    guard let account = try accountDAO.fetch(), let accountId = account.id else { return }

    let storedURL: URL
    do { storedURL = try account.activeServerURL } catch { throw AccountLifecycleError.malformedURL }
    let serverConfig: ABSServerConfig
    do {
      serverConfig = try serverConfigFactory.make(for: storedURL)
    } catch {
      throw AccountLifecycleError.malformedURL
    }
    let tokenAccount = try account.credentialTokenAccount
    let legacyTokenAccount = try TokenAccount(serverURL: storedURL, userID: account.serverUserId)
    let client = makeClient(serverConfig, tokenStore)

    // `ABSClient.logout` already wipes tokens even when the server call fails; catching here
    // defers handling a remote-confirmation failure until after the DB removal below has also run.
    // AppModel must not infer that an arbitrary error reached this point: fetch/configuration,
    // custom-header clearing, and DB deletion can all throw before local removal completes.
    var serverLogoutFailed = false
    do {
      try await client.logout(for: tokenAccount)
    } catch is LogoutError {
      throw AccountRemovalError.credentialClearFailed
    } catch {
      serverLogoutFailed = true
    }

    do {
      try tokenStore.clear(for: legacyTokenAccount)
    } catch {
      throw AccountRemovalError.credentialClearFailed
    }

    do {
      try await clearCustomHeaders(for: storedURL)
    } catch {
      throw AccountRemovalError.credentialClearFailed
    }

    try accountRemover.removeAccount(accountId: accountId)

    if serverLogoutFailed {
      Self.logger.error("Server logout was not confirmed after local account removal completed")
    }
  }

  public func isRemovalPending() async throws -> Bool {
    guard let removalCoordinator else { return false }
    return try await removalCoordinator.isRemovalPending()
  }

  public func resumeRemovalIfNeeded() async throws {
    guard let removalCoordinator else { return }
    try await removalCoordinator.resumeIfNeeded()
  }

  private func clearCustomHeaders(for serverURL: URL) async throws {
    let previous = try customHeaderStore.load(for: serverURL)
    try customHeaderStore.clear(for: serverURL)
    if let previous, previous.fingerprint != CustomHeaders.none.fingerprint {
      await clearCachedArtwork()
    }
  }

  /// Backoff bookkeeping and classification for a failed credential exchange, shared by every
  /// login and re-authentication path. `operation` and `step` only name the failure in logs.
  func credentialFailure(
    _ error: Error, method: CredentialMethod, operation: String, step: StaticString
  ) async -> AccountLifecycleError {
    if let singleSignOnError = error as? OIDCLoginError {
      let (failure, countsAgainstPacing) = Self.singleSignOnFailure(singleSignOnError)
      if countsAgainstPacing {
        await loginBackoffGate.recordFailure()
      } else {
        await loginBackoffGate.releaseReservation()
      }
      // The case name is all that is logged: no attempt secret is ever part of the error.
      Self.logger.error(
        "single sign-on \(operation, privacy: .public) failed: \(String(describing: singleSignOnError), privacy: .public)"
      )
      return .singleSignOnFailed(failure)
    }
    await loginBackoffGate.recordFailure()
    if let apiError = error as? APIError, apiError.isUnauthorized {
      Self.logger.error(
        "\(method.logLabel, privacy: .public) \(operation, privacy: .public) rejected by the server")
      return .invalidCredentials
    }
    return Self.classifyTransportFailure(error, step: step)
  }

  /// The server and expected identity of the stored account, which re-authentication targets.
  /// The server and user id are never caller-supplied.
  func storedAccountServer() throws -> (server: ABSServerConfig, expectedAccount: TokenAccount) {
    guard let account = try accountDAO.fetch() else {
      throw AccountLifecycleError.unreachable
    }
    let storedURL: URL
    do { storedURL = try account.activeServerURL } catch { throw AccountLifecycleError.malformedURL }
    let serverConfig: ABSServerConfig
    do {
      serverConfig = try serverConfigFactory.make(for: storedURL)
    } catch {
      throw AccountLifecycleError.malformedURL
    }
    let expectedAccount = try account.credentialTokenAccount
    return (serverConfig, expectedAccount)
  }

  /// Classifies a post-authentication write failure and records which step threw. The server has
  /// accepted the credentials, so a raw rethrow would hit `SetupFlowModel`'s catch-all and render
  /// the generic "something went wrong" copy.
  ///
  /// SECURITY.md: only the step name and error type are `.public`; the description can carry a
  /// server URL, user id or GRDB statement text, so it stays `.private`.
  static func postAuthenticationFailure(
    _ error: Error, step: PostAuthenticationStep
  ) -> AccountLifecycleError {
    let classified: AccountLifecycleError =
      isMissingKeychainEntitlement(error) ? .keychainUnavailable : .localPersistenceFailed
    logger.error(
      """
      login failed after authentication: step=\(step.rawValue, privacy: .public) \
      classified=\(String(describing: classified), privacy: .public) \
      errorType=\(String(describing: type(of: error)), privacy: .public) \
      detail=\(String(describing: error), privacy: .private)
      """)
    return classified
  }

  /// `existingAccountState()` reads the account row and Keychain before a credential leaves the
  /// device. A raw rethrow would hit `SetupFlowModel`'s catch-all ("Something went wrong...") with
  /// no cause or recovery.
  ///
  /// Not `.localPersistenceFailed`: nothing is authenticated yet, so its "you're signed in, but we
  /// couldn't save it" copy would mislead.
  static func preAuthenticationReadFailure(_ error: Error) -> AccountLifecycleError {
    let classified: AccountLifecycleError =
      isMissingKeychainEntitlement(error) ? .keychainUnavailable : .localStateUnreadable
    logger.error(
      """
      login could not read local account state: \
      classified=\(String(describing: classified), privacy: .public) \
      errorType=\(String(describing: type(of: error)), privacy: .public) \
      detail=\(String(describing: error), privacy: .private)
      """)
    return classified
  }

  /// `errSecMissingEntitlement` (-34018) says this build cannot reach its Keychain access group.
  /// The device is unlocked and has free space, and retrying will never succeed, so it must not
  /// share `.localPersistenceFailed`'s copy, which asks the user to check those two things.
  static func isMissingKeychainEntitlement(_ error: Error) -> Bool {
    (error as? KeychainStoreError)?.isMissingEntitlement ?? false
  }

  /// A real Audiobookshelf `/status` names itself. Anything else answering on that host (a NAS
  /// portal, a router admin page, a reverse proxy's default vhost) must be refused here rather
  /// than at the login POST, where the failure reads as a credentials problem.
  private static func isAudiobookshelf(_ status: ServerStatus) -> Bool {
    guard let app = status.app else { return false }
    return app.caseInsensitiveCompare("audiobookshelf") == .orderedSame
  }

  /// A `GET /status` failure. Only this route reads a 401/403 as a proxy refusal: Audiobookshelf
  /// answers it without authentication, while the same status on any authenticated route means
  /// the credentials.
  static func classifyStatusFailure(_ error: Error) -> AccountLifecycleError {
    if let redirect = error as? RefusedRedirectError {
      logger.error("server-status was redirected to an address the app does not follow")
      return .redirected(target: redirect.target)
    }
    switch error as? APIError {
    case .unauthorized, .forbidden:
      logger.error("server-status was refused before reaching Audiobookshelf")
      return .blockedByProxy
    default:
      return classifyTransportFailure(error, step: "server-status")
    }
  }

  /// `step` names the boundary call that threw so a failure report is not just "unreachable".
  /// Same privacy split as `postAuthenticationFailure`: step and error type public, detail not.
  static func classifyTransportFailure(
    _ error: Error, step: StaticString = "transport"
  ) -> AccountLifecycleError {
    let classified: AccountLifecycleError
    if let urlError = error as? URLError {
      classified = isTLSFailure(urlError) ? .tlsUntrusted : .unreachable
    } else {
      classified = .unreachable
    }
    logger.error(
      """
      \(step, privacy: .public) failed: classified=\(String(describing: classified), privacy: .public) \
      errorType=\(String(describing: type(of: error)), privacy: .public) \
      detail=\(String(describing: error), privacy: .private)
      """)
    return classified
  }

  private static func isTLSFailure(_ error: URLError) -> Bool {
    switch error.code {
    case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
      .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
      return true
    default:
      return false
    }
  }
}
