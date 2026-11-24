import Foundation

/// The foreground API façade; endpoint extensions compose authenticated operations onto it.
///
/// The only production HTTP client (ARCHITECTURE.md §2). Every transport decorator is composed
/// once, here, and all are `internal`, so no module can build an `ABSClient` around an undecorated
/// transport. The two `production` factories are the only public way in; the raw-transport `init`
/// lets tests (via `@testable import`) supply a fake underneath the same decorators.
///
/// A client is fixed to one server, and an account-bound client to one account: proxy headers come
/// from `server` at construction, so authenticating as another account would hand that account's
/// bearer and refresh token to this server. A bound client refuses every other account with
/// `APIError.cancelled` before reading the token store. Server status, login, login commit,
/// re-authentication, logout, and requests carrying a caller-supplied bearer skip the binding.
public actor ABSClient {
  // `server`/`requestBuilder`/`tokenStore`/`decoder` are internal so sibling endpoint extensions
  // can reuse the composed state. They stay unreachable from outside ABSApi.
  let server: ABSServerConfig
  let requestBuilder: RequestBuilder
  /// Gate → Logger → transport (ARCHITECTURE.md §2). Login/logout use it directly (no access token
  /// yet); `AuthenticatedHTTPClient` wraps it per account.
  private let plainTransport: any HTTPClienting
  let tokenStore: any TokenStoring
  /// The only account this client authenticates as, or `nil` for a client that serves whichever
  /// account a caller names: pre-authentication work, endpoint probes, and the Watch's own service.
  public nonisolated let boundAccount: TokenAccount?
  private let customHeaderStore: (any CustomHeaderStoring)?
  private let clearCachedArtwork: @Sendable () async -> Void
  private let logger: RedactingHTTPLogger
  private let requestGate: ServerRequestGate
  let decoder: BoundedDecoder
  /// `ServerDateObserving` hook for the authenticated pipeline.
  private let serverDateObserving: any ServerDateObserving
  /// Credential-free `AuthEventObserving` hook.
  private let authEventObserving: any AuthEventObserving
  /// One `AuthenticatedHTTPClient` per account, reused across calls so single-flight refresh
  /// coalescing (API-CONVENTIONS.md rule 4) actually coalesces instead of resetting per request.
  private var authenticatedClients: [TokenAccount: AuthenticatedHTTPClient] = [:]

  /// The account-lifetime factory: a client that authenticates only as `account`. A composition
  /// that outlives one signed-in account must use this, so a retained old client cannot serve
  /// the next one. `nil` composes an unbound client for a graph that has no account.
  public static func production(
    server: ABSServerConfig,
    account: TokenAccount?,
    tokenStore: any TokenStoring,
    customHeaderStore: (any CustomHeaderStoring)? = nil,
    clearCachedArtwork: @escaping @Sendable () async -> Void = {},
    logger: RedactingHTTPLogger = RedactingHTTPLogger(),
    decoder: BoundedDecoder = BoundedDecoder(),
    serverDateObserving: any ServerDateObserving = NoOpServerDateObserving(),
    authEventObserving: any AuthEventObserving = NoOpAuthEventObserving(),
    serverReachabilityObserving: any ServerReachabilityObserving = NoOpServerReachabilityObserving()
  ) -> ABSClient {
    ABSClient(
      server: server,
      httpClient: URLSessionHTTPClient(),
      tokenStore: tokenStore,
      boundAccount: account,
      customHeaderStore: customHeaderStore,
      logger: logger,
      decoder: decoder,
      serverDateObserving: serverDateObserving,
      authEventObserving: authEventObserving,
      serverReachabilityObserving: serverReachabilityObserving,
      clearCachedArtwork: clearCachedArtwork
    )
  }

  /// An unbound production client, for work that is not tied to one signed-in account's
  /// lifetime: setup and login, endpoint probes and candidates, removal-only defaults, and the
  /// Watch. The only place real code constructs `URLSessionHTTPClient` is the factory above.
  public static func production(
    server: ABSServerConfig,
    tokenStore: any TokenStoring,
    customHeaderStore: (any CustomHeaderStoring)? = nil,
    clearCachedArtwork: @escaping @Sendable () async -> Void = {},
    logger: RedactingHTTPLogger = RedactingHTTPLogger(),
    decoder: BoundedDecoder = BoundedDecoder(),
    serverDateObserving: any ServerDateObserving = NoOpServerDateObserving(),
    authEventObserving: any AuthEventObserving = NoOpAuthEventObserving(),
    serverReachabilityObserving: any ServerReachabilityObserving = NoOpServerReachabilityObserving()
  ) -> ABSClient {
    production(
      server: server,
      account: nil,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      clearCachedArtwork: clearCachedArtwork,
      logger: logger,
      decoder: decoder,
      serverDateObserving: serverDateObserving,
      authEventObserving: authEventObserving,
      serverReachabilityObserving: serverReachabilityObserving
    )
  }

  /// Composes Gate → Logger around whatever raw transport is supplied. Internal: an external
  /// module cannot call this, so it cannot substitute its own raw transport for
  /// `URLSessionHTTPClient`. Tests reach it via `@testable import` to substitute a fake underneath
  /// the identical decorator composition `production(...)` uses.
  init(
    server: ABSServerConfig,
    httpClient: any HTTPClienting,
    tokenStore: any TokenStoring,
    boundAccount: TokenAccount? = nil,
    customHeaderStore: (any CustomHeaderStoring)? = nil,
    logger: RedactingHTTPLogger = RedactingHTTPLogger(),
    decoder: BoundedDecoder = BoundedDecoder(),
    requestGate: ServerRequestGate = ServerRequestGate(),
    serverDateObserving: any ServerDateObserving = NoOpServerDateObserving(),
    authEventObserving: any AuthEventObserving = NoOpAuthEventObserving(),
    serverReachabilityObserving: any ServerReachabilityObserving = NoOpServerReachabilityObserving(),
    clearCachedArtwork: @escaping @Sendable () async -> Void = {}
  ) {
    self.server = server
    requestBuilder = RequestBuilder(server: server)
    self.tokenStore = tokenStore
    self.boundAccount = boundAccount
    self.customHeaderStore = customHeaderStore
    self.clearCachedArtwork = clearCachedArtwork
    self.logger = logger
    self.requestGate = requestGate
    self.decoder = decoder
    self.serverDateObserving = serverDateObserving
    self.authEventObserving = authEventObserving
    plainTransport = GatedHTTPClient(
      transport: LoggingHTTPClient(
        transport: ReachabilityObservingHTTPClient(
          transport: httpClient, observer: serverReachabilityObserving),
        logger: logger),
      gate: requestGate
    )
  }

  /// Internal seam for authenticated endpoint methods: sends `request` through the full
  /// production pipeline: `AuthenticatedHTTPClient` → `ServerRequestGate` →
  /// `RedactingHTTPLogger` → reachability observer → transport.
  func authenticatedSend(
    _ request: HTTPRequest,
    account: TokenAccount,
    initialTokens: TokenPair
  ) async throws -> HTTPResponse {
    try await authenticatedTransport(for: account, initialTokens: initialTokens).send(request)
  }

  /// Checked before any token read and before an authenticated transport is minted or reused.
  /// `.cancelled` is what a client already invalidated by logout throws, so callers treat it the
  /// same way: the outbox requeues without dead-lettering, and nothing retries it.
  func refuseOtherAccount(_ account: TokenAccount) throws {
    guard let boundAccount, boundAccount != account else { return }
    throw APIError.cancelled
  }

  /// Internal so download minting and sibling endpoints share the same single-flight state.
  func authenticatedTransport(
    for account: TokenAccount,
    initialTokens: TokenPair
  ) throws -> AuthenticatedHTTPClient {
    try refuseOtherAccount(account)
    if let existing = authenticatedClients[account] {
      return existing
    }
    let client = AuthenticatedHTTPClient(
      transport: plainTransport,
      requestBuilder: requestBuilder,
      tokenStore: tokenStore,
      account: account,
      initialTokens: initialTokens,
      decoder: decoder,
      serverDateObserving: serverDateObserving,
      authEventObserving: authEventObserving
    )
    authenticatedClients[account] = client
    return client
  }

  /// Applies an already-persisted replacement pair to a live client without creating a new cache
  /// entry solely for lifecycle bookkeeping.
  func replaceTokensInCachedClient(_ tokens: TokenPair, for account: TokenAccount) async {
    guard let client = authenticatedClients[account] else { return }
    await client.replaceTokens(tokens)
  }

  /// Logout invalidation is terminal. Always evict that generation, even when persistent storage
  /// was already empty, so a later login can create a fresh authenticated client.
  func invalidateAndEvictCachedClient(for account: TokenAccount) async {
    if let client = authenticatedClients[account] {
      await client.invalidateForLogout()
      authenticatedClients.removeValue(forKey: account)
    }
  }

  /// Credential-free observer seam kept beside the private observer dependency.
  func reportAuthEvent(_ event: AuthEvent) async {
    await authEventObserving.authEvent(event)
  }

  /// Clears server-scoped proxy credentials independently of account-token presence. A namespace
  /// account is not keyed by a server, so it owns no header item here; its endpoints' headers are
  /// cleared by URL in the account lifecycle.
  func clearServerScopedCredentials(for account: TokenAccount) async throws {
    guard let customHeaderStore, let serverURL = account.serverURL else { return }
    let previous = try customHeaderStore.load(for: serverURL)
    try customHeaderStore.clear(for: serverURL)
    if let previous, previous.fingerprint != CustomHeaders.none.fingerprint {
      await clearCachedArtwork()
    }
  }

  /// Login/logout run pre-auth, so they use the gated+logged floor directly rather than
  /// `authenticatedSend`. This is also the sibling-endpoint seam for API-token validation.
  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await plainTransport.send(request)
  }

  /// Sibling endpoint methods reuse the shared status-code policy.
  func validateSuccess(_ response: HTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw APIError.fromHTTPStatus(response.statusCode)
    }
  }
}
