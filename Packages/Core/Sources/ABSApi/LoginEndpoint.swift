import Foundation

/// Credentials are one-shot. The password is consumed to build the login body and
/// released on every exit path; it is never part of a stored session value.
public final class LoginCredentials: @unchecked Sendable {
  public let username: String

  private let lock = NSLock()
  private var passwordStorage: String?

  public init(username: String, password: String) {
    self.username = username
    passwordStorage = password
  }

  public var isPasswordReleased: Bool {
    lock.lock()
    defer { lock.unlock() }
    return passwordStorage == nil
  }

  fileprivate func consumePassword() -> String? {
    lock.lock()
    defer { lock.unlock() }
    let password = passwordStorage
    passwordStorage = nil
    return password
  }

  /// Releases a credential that was not used because login was cancelled or failed early.
  public func releasePassword() {
    lock.lock()
    passwordStorage = nil
    lock.unlock()
  }
}

/// API-token credentials follow the same one-shot lifecycle as `LoginCredentials`.
public final class APITokenCredentials: @unchecked Sendable {
  private let lock = NSLock()
  private var tokenStorage: String?

  public init(token: String) {
    tokenStorage = token
  }

  public var isTokenReleased: Bool {
    lock.lock()
    defer { lock.unlock() }
    return tokenStorage == nil
  }

  fileprivate func consumeToken() -> String? {
    lock.lock()
    defer { lock.unlock() }
    let token = tokenStorage
    tokenStorage = nil
    return token
  }

  /// Releases a credential that was not used because login was cancelled or failed early.
  public func releaseToken() {
    lock.lock()
    tokenStorage = nil
    lock.unlock()
  }
}

public struct LoginSession: Sendable, Equatable {
  public let account: TokenAccount
  public let userID: String
  public let defaultLibraryID: String?
  public let accessExpiry: Date?
  fileprivate let pendingCommit: PendingLoginCommitBox?

  public init(
    account: TokenAccount,
    userID: String,
    defaultLibraryID: String?,
    accessExpiry: Date?
  ) {
    self.account = account
    self.userID = userID
    self.defaultLibraryID = defaultLibraryID
    self.accessExpiry = accessExpiry
    pendingCommit = nil
  }

  fileprivate init(
    account: TokenAccount,
    userID: String,
    defaultLibraryID: String?,
    accessExpiry: Date?,
    pendingCommit: PendingLoginCommitBox
  ) {
    self.account = account
    self.userID = userID
    self.defaultLibraryID = defaultLibraryID
    self.accessExpiry = accessExpiry
    self.pendingCommit = pendingCommit
  }

  /// The one way another ABSApi file builds a committable session (the OIDC exchange): the
  /// committable initialiser and the commit box stay private to this file.
  static func prepared(from exchange: PasswordExchange) -> LoginSession {
    LoginSession(
      account: exchange.account,
      userID: exchange.userID,
      defaultLibraryID: exchange.defaultLibraryID,
      accessExpiry: exchange.tokens.accessExpiry,
      pendingCommit: PendingLoginCommitBox(account: exchange.account, tokens: exchange.tokens)
    )
  }

  public static func == (lhs: LoginSession, rhs: LoginSession) -> Bool {
    lhs.account == rhs.account
      && lhs.userID == rhs.userID
      && lhs.defaultLibraryID == rhs.defaultLibraryID
      && lhs.accessExpiry == rhs.accessExpiry
  }
}

/// Shared by password login, password reauthentication and the OIDC callback, all of which answer
/// with the same login JSON, so decoding and validation cannot drift between them.
struct PasswordExchange: Sendable {
  let account: TokenAccount
  let userID: String
  let defaultLibraryID: String?
  let tokens: TokenPair
}

struct APITokenExchange: Sendable {
  let token: String
  let profile: UserProfile
  let account: TokenAccount
  let tokens: TokenPair
}

extension ABSClient {
  public func prepareLogin(credentials: LoginCredentials) async throws -> LoginSession {
    LoginSession.prepared(from: try await exchangePassword(credentials: credentials))
  }

  public func login(credentials: LoginCredentials) async throws -> LoginSession {
    let session = try await prepareLogin(credentials: credentials)
    try await commitLogin(session)
    return session
  }

  /// API-token login validates the pasted token against `/api/me` and resolves the fallback
  /// library with the same explicit Bearer before anything is stored.
  public func prepareLogin(apiToken credentials: APITokenCredentials) async throws -> LoginSession {
    let exchange = try await validateAPIToken(credentials: credentials)
    return LoginSession(
      account: exchange.account,
      userID: exchange.profile.id,
      defaultLibraryID: try await defaultLibraryID(
        for: exchange.profile, apiToken: exchange.token),
      accessExpiry: exchange.tokens.accessExpiry,
      pendingCommit: PendingLoginCommitBox(
        account: exchange.account, tokens: exchange.tokens)
    )
  }

  public func login(apiToken credentials: APITokenCredentials) async throws -> LoginSession {
    let session = try await prepareLogin(apiToken: credentials)
    try await commitLogin(session)
    return session
  }

  /// Commits a prepared login after the lifecycle owner completes its local identity and
  /// persistence checks. A failed synchronous save leaves the shared capability retryable.
  public func commitLogin(_ session: LoginSession) async throws {
    try await commitLogin(session, storingUnder: session.account)
  }

  /// Commits a prepared login under the account's stable credential namespace. The session's URL
  /// account remains the provisional identity used to perform the login request.
  public func commitLogin(_ session: LoginSession, storingUnder account: TokenAccount) async throws {
    guard let pendingCommit = session.pendingCommit else { throw APIError.decoding }
    let pending = try pendingCommit.commit { pending in
      try tokenStore.save(pending.tokens, for: account)
    }
    await replaceTokensInCachedClient(pending.tokens, for: account)
  }

  /// Drops a prepared login that failed before the token-store replacement boundary.
  public func discardLogin(_ session: LoginSession) {
    session.pendingCommit?.discard()
  }

  /// Convenience entry point for callers that have not crossed into a credential-owning object.
  public func login(apiToken: String) async throws -> LoginSession {
    try await login(apiToken: APITokenCredentials(token: apiToken))
  }

  func exchangePassword(credentials: LoginCredentials) async throws -> PasswordExchange {
    defer { credentials.releasePassword() }

    guard let password = credentials.consumePassword() else {
      throw APIError.decoding
    }
    let request = try requestBuilder.makeJSONRequest(
      method: .post,
      path: "/login",
      headers: ["x-return-tokens": "true"],
      body: LoginPayload(username: credentials.username, password: password),
      routeTemplate: "/login",
      isAuthenticationRoute: true
    )
    let response = try await send(request)
    try validateSuccess(response)
    return try decodeLoginResponse(response.body, endpoint: "/login")
  }

  /// The login JSON both `POST /login` and the OIDC callback answer with. Both tokens must be
  /// present: a pair without a refresh token would be mistaken for an API-token account.
  func decodeLoginResponse(_ body: Data, endpoint: String) throws -> PasswordExchange {
    let wireResponse = try decoder.decode(LoginResponseDTO.self, from: body, endpoint: endpoint)
    guard wireResponse.user.id.isEmpty == false,
      wireResponse.user.accessToken.isEmpty == false,
      wireResponse.user.refreshToken.isEmpty == false
    else {
      throw APIError.decoding
    }

    let tokens = TokenPair(
      accessToken: wireResponse.user.accessToken,
      refreshToken: wireResponse.user.refreshToken
    )
    return PasswordExchange(
      account: try TokenAccount(server: server, userID: wireResponse.user.id),
      userID: wireResponse.user.id,
      defaultLibraryID: wireResponse.defaultLibraryID,
      tokens: tokens
    )
  }

  func validateAPIToken(credentials: APITokenCredentials) async throws -> APITokenExchange {
    defer { credentials.releaseToken() }

    guard let apiToken = credentials.consumeToken(), apiToken.isEmpty == false else {
      throw APIError.unauthorized
    }
    let profile = try await fetchUserProfile(bearerToken: apiToken)
    return APITokenExchange(
      token: apiToken,
      profile: profile,
      account: try TokenAccount(server: server, userID: profile.id),
      tokens: TokenPair(accessToken: apiToken, refreshToken: nil)
    )
  }

  private func defaultLibraryID(for profile: UserProfile, apiToken: String) async throws -> String? {
    let libraries = try await listLibraries(apiToken: apiToken)
    return libraries.first(where: { profile.librariesAccessible.contains($0.id) })?.id
      ?? libraries.first?.id
  }
}

/// The pending pair is retained only by copies of the returned session. The lock makes one-shot
/// commit/discard semantics hold even if copies are passed to different client actors.
private final class PendingLoginCommitBox: @unchecked Sendable {
  struct Pending {
    let account: TokenAccount
    let tokens: TokenPair
  }

  private let lock = NSLock()
  private var state: State

  init(account: TokenAccount, tokens: TokenPair) {
    state = .pending(Pending(account: account, tokens: tokens))
  }

  func commit(_ save: (Pending) throws -> Void) throws -> Pending {
    lock.lock()
    guard case .pending(let pending) = state else {
      lock.unlock()
      throw APIError.decoding
    }
    state = .committing
    lock.unlock()

    do {
      try save(pending)
    } catch {
      lock.lock()
      if case .committing = state {
        state = .pending(pending)
      }
      lock.unlock()
      throw error
    }

    lock.lock()
    state = .consumed
    lock.unlock()
    return pending
  }

  func discard() {
    lock.lock()
    state = .consumed
    lock.unlock()
  }

  private enum State {
    case pending(Pending)
    case committing
    case consumed
  }
}

private struct LoginPayload: Encodable, Sendable {
  let username: String
  let password: String
}

private struct LoginResponseDTO: Decodable {
  let user: UserDTO
  let defaultLibraryID: String?

  private enum CodingKeys: String, CodingKey {
    case user
    case defaultLibraryID = "userDefaultLibraryId"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    user = try container.decode(UserDTO.self, forKey: .user)
    defaultLibraryID =
      try container.decode(LossyOptional<String>.self, forKey: .defaultLibraryID).wrappedValue
  }
}

private struct UserDTO: Decodable {
  let id: String
  let accessToken: String
  let refreshToken: String
}
