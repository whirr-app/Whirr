import ABSApi
import Foundation
import Persistence

/// Errors specific to adding and managing an account's alternate server addresses.
public enum AccountEndpointError: Error, Sendable, Equatable {
  case noAccount
  case duplicateAddress
  case credentialsRequired
  case differentServerOrUser
  case activeAddressUnreachable
  case lastAddress
  case activeAddress
  case endpointNotFound
  case reorderMismatch
  case localPersistenceFailed
}

/// Proves and manages server addresses without changing the account's active address.
public actor AccountEndpointService {
  public enum EndpointProofCredentials: Sendable {
    case password(username: String, password: String)
    case apiToken(String)
  }

  private let accountDAO: AccountDAO
  private let accountEndpointDAO: AccountEndpointDAO
  private let tokenStore: any TokenStoring
  private let customHeaderStore: any CustomHeaderStoring
  private let serverConfigFactory: ABSServerConfigFactory
  private let candidateClientFactory: @Sendable (ABSServerConfig, any TokenStoring) -> ABSClient
  private let refreshLiveTokens: @Sendable (TokenAccount) async throws -> TokenPair
  private let loginBackoffGate: LoginBackoffGate
  private let now: @Sendable () -> Date

  /// The candidate factory should build an `ABSClient.production` with no-op authentication and
  /// reachability observers. A probe must not latch the live client or flip its reachability
  /// monitor; the App supplies that isolated composition when it wires this service.
  public init(
    accountDAO: AccountDAO,
    accountEndpointDAO: AccountEndpointDAO,
    tokenStore: any TokenStoring,
    customHeaderStore: any CustomHeaderStoring,
    serverConfigFactory: ABSServerConfigFactory,
    candidateClientFactory: @escaping @Sendable (ABSServerConfig, any TokenStoring) -> ABSClient,
    refreshLiveTokens: @escaping @Sendable (TokenAccount) async throws -> TokenPair,
    loginBackoffGate: LoginBackoffGate = LoginBackoffGate(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.loginBackoffGate = loginBackoffGate
    self.accountDAO = accountDAO
    self.accountEndpointDAO = accountEndpointDAO
    self.tokenStore = tokenStore
    self.customHeaderStore = customHeaderStore
    self.serverConfigFactory = serverConfigFactory
    self.candidateClientFactory = candidateClientFactory
    self.refreshLiveTokens = refreshLiveTokens
    self.now = now
  }

  /// Adds an address using the account's stored access token. The candidate is unproven, so it
  /// receives exactly one bearer token: an expiring token is renewed through the injected live
  /// client first, and a candidate 401 is never answered with a fresh token.
  public func add(
    url: URL, customHeaders: [String: String]
  ) async throws -> AccountEndpointRecord {
    let context = try await prepareAdd(url: url, customHeaders: customHeaders)
    guard let tokens = try storedTokens(for: context.tokenAccount) else {
      throw AccountEndpointError.credentialsRequired
    }

    do {
      let accessToken = try await currentAccessToken(tokens, tokenAccount: context.tokenAccount)
      try await proveWithBearer(
        client: context.client,
        accessToken: accessToken,
        expectedUserID: context.account.serverUserId
      )
    } catch let error as AccountEndpointError {
      throw error
    } catch {
      throw classifyCandidateFailure(error)
    }

    return try persist(
      normalizedURL: context.config.baseURL.absoluteString,
      candidateURL: context.config.baseURL,
      headers: context.config.customHeaders,
      accountID: context.accountID
    )
  }

  /// Adds an address by logging in to the candidate only when the account has no stored tokens.
  /// The caller must rebuild the runtime composition after this succeeds: committing the newly
  /// issued pair under the namespace leaves an already-built live client's cache stale, and the
  /// App performs that rebuild in its composition layer.
  public func add(
    url: URL,
    customHeaders: [String: String],
    credentials: EndpointProofCredentials
  ) async throws -> AccountEndpointRecord {
    let context = try await prepareAdd(url: url, customHeaders: customHeaders)
    guard (try storedTokens(for: context.tokenAccount)) == nil else {
      throw AccountEndpointError.credentialsRequired
    }

    // API-CONVENTIONS rule 5a: this proof posts to the rate-limited login route like setup does.
    if let retryAfter = await loginBackoffGate.admit() {
      throw AccountLifecycleError.loginRateLimited(retryAfter: retryAfter)
    }
    let session: LoginSession
    do {
      switch credentials {
      case .password(let username, let password):
        session = try await context.client.prepareLogin(
          credentials: LoginCredentials(username: username, password: password))
      case .apiToken(let token):
        session = try await context.client.prepareLogin(
          apiToken: APITokenCredentials(token: token))
      }
    } catch {
      await loginBackoffGate.recordFailure()
      throw classifyCandidateFailure(error)
    }
    await loginBackoffGate.recordSuccess()

    guard session.userID == context.account.serverUserId else {
      await context.client.discardLogin(session)
      throw AccountEndpointError.differentServerOrUser
    }

    do {
      try await context.client.commitLogin(session, storingUnder: context.tokenAccount)
    } catch {
      await context.client.discardLogin(session)
      throw AccountEndpointError.localPersistenceFailed
    }

    return try persist(
      normalizedURL: context.config.baseURL.absoluteString,
      candidateURL: context.config.baseURL,
      headers: context.config.customHeaders,
      accountID: context.accountID
    )
  }

  public func remove(id: Int64) throws {
    let accountID: Int64
    do {
      guard let account = try accountDAO.fetch(), let id = account.id else {
        throw AccountEndpointError.noAccount
      }
      accountID = id
    } catch let error as AccountEndpointError {
      throw error
    } catch {
      throw AccountEndpointError.localPersistenceFailed
    }
    let endpoint: AccountEndpointRecord
    do {
      guard
        let found = try accountEndpointDAO.fetchAll(accountId: accountID).first(where: {
          $0.id == id
        })
      else { throw AccountEndpointError.endpointNotFound }
      endpoint = found
      try accountEndpointDAO.remove(id: id)
    } catch let error as AccountEndpointError {
      throw error
    } catch {
      throw mapDAOError(error)
    }

    guard let endpointURL = URL(string: endpoint.normalizedURL) else {
      throw AccountEndpointError.localPersistenceFailed
    }
    do {
      try customHeaderStore.clear(for: endpointURL)
    } catch {
      throw AccountEndpointError.localPersistenceFailed
    }
  }

  public func reorder(ids: [Int64]) throws {
    let accountID = try requiredAccountID()
    do {
      try accountEndpointDAO.reorder(accountId: accountID, ids: ids)
    } catch {
      throw mapDAOError(error)
    }
  }

  public func setPreferred(id: Int64) throws {
    _ = try requiredAccountID()
    do {
      try accountEndpointDAO.setPreferred(id: id)
    } catch {
      throw mapDAOError(error)
    }
  }

  public func endpoints() throws -> [AccountEndpointRecord] {
    let accountID = try requiredAccountID()
    do {
      return try accountEndpointDAO.fetchAll(accountId: accountID)
    } catch {
      throw AccountEndpointError.localPersistenceFailed
    }
  }

  private struct AddContext: Sendable {
    let account: AccountRecord
    let accountID: Int64
    let tokenAccount: TokenAccount
    let config: ABSServerConfig
    let client: ABSClient
  }

  private func prepareAdd(url: URL, customHeaders: [String: String]) async throws -> AddContext {
    let account: AccountRecord
    do {
      guard let fetched = try accountDAO.fetch(), let accountID = fetched.id else {
        throw AccountEndpointError.noAccount
      }
      account = fetched

      let config: ABSServerConfig
      do {
        config = try serverConfigFactory.make(for: url, customHeaderFields: customHeaders)
      } catch {
        throw AccountLifecycleError.malformedURL
      }

      let normalizedURL = config.baseURL.absoluteString
      let endpoints = try accountEndpointDAO.fetchAll(accountId: accountID)
      guard endpoints.contains(where: { $0.normalizedURL == normalizedURL }) == false else {
        throw AccountEndpointError.duplicateAddress
      }

      let client = candidateClientFactory(config, tokenStore)
      let status: ServerStatus
      do {
        status = try await client.fetchServerStatus()
      } catch APIError.decoding {
        throw AccountLifecycleError.notAudiobookshelfServer
      } catch {
        throw AccountLifecycleService.classifyStatusFailure(error)
      }

      guard status.app?.caseInsensitiveCompare("audiobookshelf") == .orderedSame else {
        throw AccountLifecycleError.notAudiobookshelfServer
      }
      do {
        _ = try ABSServerCompatibilityGate.validate(serverVersion: status.serverVersion)
      } catch APIError.incompatibleServer(_, let detected) {
        throw AccountLifecycleError.incompatibleServer(detectedVersion: detected?.description)
      } catch {
        throw classifyCandidateFailure(error)
      }

      return AddContext(
        account: account,
        accountID: accountID,
        tokenAccount: try account.credentialTokenAccount,
        config: config,
        client: client
      )
    } catch let error as AccountEndpointError {
      throw error
    } catch let error as AccountLifecycleError {
      throw error
    } catch {
      throw AccountEndpointError.localPersistenceFailed
    }
  }

  /// Renews through the live client, never the candidate, when the access token is near expiry.
  /// Mirrors the live client's proactive lead time so a legitimate candidate rarely answers 401.
  private func currentAccessToken(
    _ tokens: TokenPair, tokenAccount: TokenAccount
  ) async throws -> String {
    guard tokens.refreshToken != nil, let expiry = tokens.accessExpiry,
      now() >= expiry.addingTimeInterval(-Self.proactiveRefreshLeadTime)
    else { return tokens.accessToken }
    do {
      return try await refreshLiveTokens(tokenAccount).accessToken
    } catch APIError.unauthorized {
      throw AccountEndpointError.credentialsRequired
    } catch {
      throw AccountEndpointError.activeAddressUnreachable
    }
  }

  private static let proactiveRefreshLeadTime: TimeInterval = 5 * 60

  /// A 401 here is a mismatch: retrying with a renewed token would hand an impostor that
  /// answers 401 on purpose a second, fresher credential.
  private func proveWithBearer(
    client: ABSClient,
    accessToken: String,
    expectedUserID: String
  ) async throws {
    let profile: UserProfile
    do {
      profile = try await client.fetchUserProfile(bearerToken: accessToken)
    } catch APIError.unauthorized {
      throw AccountEndpointError.differentServerOrUser
    }
    guard profile.id == expectedUserID else {
      throw AccountEndpointError.differentServerOrUser
    }
  }

  private func persist(
    normalizedURL: String,
    candidateURL: URL,
    headers: CustomHeaders,
    accountID: Int64
  ) throws -> AccountEndpointRecord {
    do {
      if headers.headers.isEmpty == false {
        try customHeaderStore.save(headers, for: candidateURL)
      }
      let endpoint: AccountEndpointRecord
      do {
        endpoint = try accountEndpointDAO.insert(
          accountId: accountID, normalizedURL: normalizedURL, preferred: false)
      } catch {
        throw mapDAOError(error)
      }
      do {
        try accountEndpointDAO.markReached(id: endpoint.id ?? 0, at: now())
      } catch {
        throw AccountEndpointError.localPersistenceFailed
      }
      guard
        let inserted = try accountEndpointDAO.fetchAll(accountId: accountID).first(where: {
          $0.id == endpoint.id
        })
      else {
        throw AccountEndpointError.localPersistenceFailed
      }
      return inserted
    } catch let error as AccountEndpointError {
      throw error
    } catch {
      throw AccountEndpointError.localPersistenceFailed
    }
  }

  private func requiredAccountID() throws -> Int64 {
    do {
      guard let account = try accountDAO.fetch(), let id = account.id else {
        throw AccountEndpointError.noAccount
      }
      return id
    } catch let error as AccountEndpointError {
      throw error
    } catch {
      throw AccountEndpointError.localPersistenceFailed
    }
  }

  private func storedTokens(for account: TokenAccount) throws -> TokenPair? {
    do {
      return try tokenStore.load(for: account)
    } catch {
      throw AccountEndpointError.localPersistenceFailed
    }
  }

  private func mapDAOError(_ error: Error) -> AccountEndpointError {
    guard let error = error as? AccountEndpointDAOError else {
      return .localPersistenceFailed
    }
    switch error {
    case .accountNotFound: return .noAccount
    case .endpointNotFound: return .endpointNotFound
    case .duplicateURL: return .duplicateAddress
    case .cannotRemoveLastEndpoint: return .lastAddress
    case .cannotRemoveActiveEndpoint: return .activeAddress
    case .reorderMismatch: return .reorderMismatch
    }
  }

  private func classifyCandidateFailure(_ error: Error) -> Error {
    if let lifecycleError = error as? AccountLifecycleError { return lifecycleError }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
        .clientCertificateRejected, .clientCertificateRequired:
        return AccountLifecycleError.tlsUntrusted
      default:
        return AccountLifecycleError.unreachable
      }
    }
    return AccountLifecycleError.unreachable
  }
}
