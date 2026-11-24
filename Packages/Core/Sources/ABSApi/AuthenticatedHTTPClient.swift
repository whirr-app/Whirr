import Foundation

/// The single production auth decorator (ARCHITECTURE.md §2): Bearer injection plus
/// proactive/reactive refresh, coalesced into one in-flight refresh (API-CONVENTIONS.md
/// rules 3-4). Composed into the public `ABSClient` pipeline; itself internal.
actor AuthenticatedHTTPClient: HTTPClienting {
  private let transport: any HTTPClienting
  private let requestBuilder: RequestBuilder
  private let tokenStore: any TokenStoring
  private let account: TokenAccount
  private let decoder: BoundedDecoder
  private let proactiveRefreshLeadTime: TimeInterval
  private let now: @Sendable () -> Date
  private let randomUnit: @Sendable () -> Double
  private let sleep: @Sendable (Duration) async throws -> Void
  /// Reports every authenticated response's `Date` header.
  private let serverDateObserving: any ServerDateObserving
  /// Reports a `.reauthenticationRequired` event once per latch transition.
  private let authEventObserving: any AuthEventObserving

  private var currentTokens: TokenPair
  private var refreshTask: Task<TokenPair, Error>?
  private var credentialEpoch: UInt64 = 0
  private var refreshBackoffPolicy = BackoffPolicy()
  private var refreshBackoff: RefreshBackoffState?
  /// API-CONVENTIONS.md rule 3c: the bounded retry scheduled after a refresh whose outcome is
  /// unknown. Nil when none is pending; cancelled by any credential change.
  private var unknownOutcomeRecovery: Task<Void, Never>?
  /// API-CONVENTIONS.md rule 4a: set only on a definitive rejection (a refresh 401, or a retried
  /// resource request still 401). While set, `send`/`forceRefresh` fail locally as `.unauthorized`
  /// with no `/auth/refresh` traffic. In-memory only: a relaunch gets one fresh attempt.
  private var reauthenticationRequired = false
  /// Terminal: set by `invalidateForLogout()`, never cleared. The epoch fence revokes the in-flight
  /// refresh, but a `send` still holding this actor could start a new one at the post-logout epoch
  /// and re-save rotated credentials into the cleared store. A fresh login builds a fresh client.
  private var isInvalidatedForLogout = false

  init(
    transport: any HTTPClienting,
    requestBuilder: RequestBuilder,
    tokenStore: any TokenStoring,
    account: TokenAccount,
    initialTokens: TokenPair,
    decoder: BoundedDecoder = BoundedDecoder(),
    proactiveRefreshLeadTime: TimeInterval = 5 * 60,
    serverDateObserving: any ServerDateObserving = NoOpServerDateObserving(),
    authEventObserving: any AuthEventObserving = NoOpAuthEventObserving(),
    now: @escaping @Sendable () -> Date = Date.init,
    randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.transport = transport
    self.requestBuilder = requestBuilder
    self.tokenStore = tokenStore
    self.account = account
    currentTokens = initialTokens
    self.decoder = decoder
    self.proactiveRefreshLeadTime = proactiveRefreshLeadTime
    self.serverDateObserving = serverDateObserving
    self.authEventObserving = authEventObserving
    self.now = now
    self.randomUnit = randomUnit
    self.sleep = sleep
  }

  /// A refresh that the server is still answering must not be abandoned: ABS saves the rotated
  /// pair before it writes the response, so giving up early leaves only the old refresh token,
  /// which the server accepts for just its grace period (ten minutes by default).
  static let refreshRequestTimeout: TimeInterval = 60

  /// Delays before each unknown-outcome retry. Their sum must stay inside ABS's default
  /// ten-minute grace period, during which the old refresh token still returns the current pair.
  static let unknownOutcomeRetryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(300)]

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard isInvalidatedForLogout == false else { throw APIError.cancelled }
    // API-CONVENTIONS.md rule 4a: a definitive rejection latches locally; no further server
    // traffic (including refresh) is attempted for this account until a successful
    // reauthentication calls `replaceTokens(_:)`.
    guard reauthenticationRequired == false else { throw APIError.unauthorized }

    var tokens = currentTokens
    if shouldRefreshProactively() {
      // Use the tokens `refreshTokens()` actually returns, not `currentTokens` read again
      // afterwards: a waiter that coalesced onto someone else's refresh task can resume before
      // the owner's continuation assigns `currentTokens`, so re-reading it here would race.
      tokens = try await refreshTokens(proactive: true)
    }

    let response = try await transport.send(authorized(request, accessToken: tokens.accessToken))
    await reportServerDate(from: response)
    guard response.statusCode == 401 else { return response }

    guard currentTokens.refreshToken != nil else {
      // API-CONVENTIONS.md rule 4a: a no-refresh account has no alternate credential to try after
      // a resource rejection, so it latches locally without making an /auth/refresh request.
      reauthenticationRequired = true
      await authEventObserving.authEvent(.reauthenticationRequired(account))
      throw APIError.unauthorized
    }

    // Reactive path (API-CONVENTIONS.md rule 3/4): exactly one refresh, one retry, never a loop.
    let refreshedTokens = try await refreshTokens()
    let retryResponse = try await transport.send(authorized(request, accessToken: refreshedTokens.accessToken))
    await reportServerDate(from: retryResponse)
    guard retryResponse.statusCode != 401 else {
      // A retried resource request that is still 401 is itself a definitive rejection (rule 4a).
      reauthenticationRequired = true
      await authEventObserving.authEvent(.reauthenticationRequired(account))
      throw APIError.unauthorized
    }
    return retryResponse
  }

  /// Called after a successful same-account reauthentication has saved the rotated pair to the
  /// token store. Updates the in-memory tokens and clears the rejection latch atomically (plain
  /// actor-isolated assignments, no suspension point between them), so the next
  /// `send`/`forceRefresh` uses the replacement pair. Not `private`: `ABSClient`'s
  /// reauthentication operation, in a sibling file, is the only other caller.
  func replaceTokens(_ tokens: TokenPair) {
    credentialEpoch &+= 1
    currentTokens = tokens
    reauthenticationRequired = false
    resetRefreshBackoff()
    cancelUnknownOutcomeRecovery()
  }

  /// Invalidates work belonging to the previous credential generation. The transport operation is
  /// cancelled, while the epoch check remains the correctness boundary for transports that do not
  /// promptly honor cancellation.
  func invalidateForLogout() {
    isInvalidatedForLogout = true
    credentialEpoch &+= 1
    refreshTask?.cancel()
    refreshTask = nil
    cancelUnknownOutcomeRecovery()
  }

  /// Reports `response`'s `Date` header (case-insensitive, RFC 7231) with this client's account
  /// and the local receipt time, for every authenticated response, 2xx or not. A missing or
  /// malformed header reports nothing: observation is best-effort and must never influence
  /// request/response handling.
  private func reportServerDate(from response: HTTPResponse) async {
    guard let raw = response.headerValue(caseInsensitive: "Date"), let serverDate = HTTPDateParsing.parse(raw)
    else { return }
    await serverDateObserving.observeServerDate(serverDate, receivedAt: now(), account: account)
  }

  /// The JWT `exp` claim is decoded only to schedule this proactive check, never as signature or
  /// trust validation. A missing or invalid `exp` (nil `accessExpiry`) or a missing refresh token
  /// falls back to the reactive 401 path.
  private func shouldRefreshProactively() -> Bool {
    guard currentTokens.refreshToken != nil, let expiry = currentTokens.accessExpiry else { return false }
    return now() >= expiry.addingTimeInterval(-proactiveRefreshLeadTime)
  }

  private func authorized(_ request: HTTPRequest, accessToken: String) -> HTTPRequest {
    var headers = request.headers
    let authorizationNames = headers.keys.filter {
      $0.caseInsensitiveCompare("Authorization") == .orderedSame
    }
    for name in authorizationNames {
      headers.removeValue(forKey: name)
    }
    headers["Authorization"] = "Bearer \(accessToken)"
    return HTTPRequest(
      method: request.method,
      url: request.url,
      headers: headers,
      body: request.body,
      routeTemplate: request.routeTemplate,
      timeout: request.timeout,
      transportClass: request.transportClass,
      maximumResponseBytes: request.maximumResponseBytes,
      isAuthenticationRoute: request.isAuthenticationRoute,
      httpShouldHandleCookies: request.httpShouldHandleCookies
    )
  }

  /// Forces one run of the same single-flight refresh `send(_:)` uses reactively, without probing
  /// an authenticated endpoint first. The download adapter's one-renewed-retry path
  /// (`ABSClient.renewAuthorizedDownloadRequest`, ARCHITECTURE.md §2) needs the same coalescing.
  /// Not `private`: `ABSClient`'s download-minting extension, in a sibling file, is the only
  /// other caller.
  func forceRefresh() async throws -> TokenPair {
    guard reauthenticationRequired == false else { throw APIError.unauthorized }

    // Every caller reaches this only after a resource already answered 401. For an account with no
    // refresh token there is no alternate credential to try, so that 401 is definitive and latches
    // here as a rejected refresh does for a password account (rule 4a). Without this, a stream
    // or download rejection on a no-refresh account would fail the transfer without raising the
    // re-authentication state, leaving the listener with no prompt.
    guard currentTokens.refreshToken != nil else {
      reauthenticationRequired = true
      await authEventObserving.authEvent(.reauthenticationRequired(account))
      throw APIError.unauthorized
    }
    return try await refreshTokens()
  }

  /// Coalesces concurrent refreshes into a single unstructured task. Cancelling one waiter's
  /// request can never cancel the shared refresh; logout uses the actor's epoch fence to revoke
  /// the result for every waiter.
  private func refreshTokens(proactive: Bool = false, isRecoveryAttempt: Bool = false) async throws -> TokenPair {
    // A send that passed its own guard before logout began must still not start a fresh refresh
    // afterwards; the epoch fence would only revoke the persistence, not the request itself.
    guard isInvalidatedForLogout == false else { throw APIError.cancelled }
    guard let refreshToken = currentTokens.refreshToken else { throw APIError.unauthorized }

    if let existing = refreshTask {
      return try await existing.value
    }

    if isRecoveryAttempt == false, let backoffCategory = refreshBackoffCategoryIfClosed() {
      if proactive { return currentTokens }
      throw backoffCategory
    }

    let transport = self.transport
    let requestBuilder = self.requestBuilder
    let decoder = self.decoder
    let account = self.account
    let launchEpoch = credentialEpoch

    let task = Task<TokenPair, Error> { [transport, requestBuilder, decoder, refreshToken, launchEpoch] in
      let request = try requestBuilder.makeRequest(
        method: .post,
        // Auth is mounted outside /api. Keep this path unprefixed.
        path: "/auth/refresh",
        headers: ["x-refresh-token": refreshToken],
        routeTemplate: "/auth/refresh",
        timeout: Self.refreshRequestTimeout,
        isAuthenticationRoute: true
      )

      let response: HTTPResponse
      do {
        response = try await transport.send(request)
      } catch {
        // API-CONVENTIONS.md rule 3a: a refresh that cannot be completed is not a refresh that
        // was rejected. Tokens are retained and the transport/cancellation category surfaces
        // unchanged instead of collapsing to `.unauthorized`.
        throw Self.classifyTransportFailure(error)
      }
      guard (200..<300).contains(response.statusCode) else {
        // Status-mapped outcomes (429/5xx/401/etc.) use the shared mapping (rule 3a's outcome
        // table). Tokens are never cleared here.
        throw APIError.fromHTTPStatus(response.statusCode)
      }

      // `BoundedDecoder.decode` classifies its own failures (`.payloadTooLarge` for an oversized
      // body, `.decoding` for anything else). Tokens are never cleared here: a malformed or
      // empty-token 2xx body is a diagnostic-only decoding failure.
      let wire = try decoder.decode(
        RefreshResponseDTO.self,
        from: response.body,
        endpoint: "/auth/refresh"
      )
      guard wire.user.accessToken.isEmpty == false, wire.user.refreshToken.isEmpty == false else {
        throw APIError.decoding
      }
      let rotated = TokenPair(accessToken: wire.user.accessToken, refreshToken: wire.user.refreshToken)

      // The actor owns the epoch check and persistence ordering. The shared task does not expose
      // its pair to any waiter until this actor operation has saved it and applied it in memory.
      return try self.persistAndApply(rotated, epoch: launchEpoch)
    }

    refreshTask = task
    do {
      let tokens = try await task.value
      currentTokens = tokens
      resetRefreshBackoff()
      refreshTask = nil
      cancelUnknownOutcomeRecovery()
      return tokens
    } catch {
      refreshTask = nil
      armRefreshBackoff(for: error)
      // API-CONVENTIONS.md rule 4a: only a definitive rejection (refresh 401) latches. Every
      // other retained category above (.transport/.cancelled/.rateLimited/.serverFailure/
      // .decoding/etc.) leaves the latch untouched so the next admitted call retries normally.
      if let apiError = error as? APIError {
        switch apiError {
        case .transport:
          if isRecoveryAttempt == false { startUnknownOutcomeRecovery() }
          await authEventObserving.authEvent(.refreshTransport(account))
        case .rateLimited:
          await authEventObserving.authEvent(.refreshRateLimited(account))
        case .serverFailure:
          await authEventObserving.authEvent(.refreshServerFailure(account))
        case .decoding, .payloadTooLarge:
          await authEventObserving.authEvent(.refreshDecoding(account))
        case .unauthorized:
          reauthenticationRequired = true
          await authEventObserving.authEvent(.reauthenticationRequired(account))
        default:
          break
        }
      }
      throw error
    }
  }

  /// API-CONVENTIONS.md rule 3c: a transport failure may hide a rotation the server completed, so
  /// the same refresh token is retried on a fixed schedule without waiting for another request.
  /// Retries bypass the admission gate and never start a second schedule; any refresh success, a
  /// definitive rejection, replacement tokens or logout ends it.
  private func startUnknownOutcomeRecovery() {
    guard unknownOutcomeRecovery == nil else { return }
    unknownOutcomeRecovery = Task { await self.runUnknownOutcomeRecovery() }
  }

  private func runUnknownOutcomeRecovery() async {
    for delay in Self.unknownOutcomeRetryDelays {
      do { try await sleep(delay) } catch { return }
      guard Task.isCancelled == false, isInvalidatedForLogout == false, reauthenticationRequired == false
      else { break }
      do {
        _ = try await refreshTokens(isRecoveryAttempt: true)
        return
      } catch {
        guard BackoffPolicy.isRetryable(error) else { break }
      }
    }
    // A cancelled schedule was already detached by whoever cancelled it, and a newer one may hold
    // the slot by now.
    if Task.isCancelled == false { unknownOutcomeRecovery = nil }
  }

  private func cancelUnknownOutcomeRecovery() {
    unknownOutcomeRecovery?.cancel()
    unknownOutcomeRecovery = nil
  }

  /// API-CONVENTIONS.md rule 3: persistence precedes the in-memory replacement and every awaiter's
  /// observation. No suspension point between the epoch check, save and assignment, so
  /// replacement/logout cannot interleave.
  ///
  /// A refresh only rotates a pair that is still stored (login and re-authentication save through
  /// their own paths). A missing pair means it was cleared mid-refresh, possibly by account removal
  /// through another client, and saving would recreate it. The read and save are not atomic with
  /// the store, so removal's post-read verification remains the final check.
  private func persistAndApply(_ tokens: TokenPair, epoch: UInt64) throws -> TokenPair {
    guard credentialEpoch == epoch else { throw APIError.cancelled }
    guard try tokenStore.load(for: account) != nil else { throw APIError.cancelled }
    try tokenStore.save(tokens, for: account)
    guard credentialEpoch == epoch else { throw APIError.cancelled }
    currentTokens = tokens
    return tokens
  }

  private func refreshBackoffCategoryIfClosed() -> APIError? {
    guard let refreshBackoff, now() < refreshBackoff.nextAllowed else { return nil }
    return refreshBackoff.category
  }

  private func armRefreshBackoff(for error: any Error) {
    guard let category = error as? APIError, BackoffPolicy.isRetryable(error) else { return }

    let currentDate = now()
    let delay = refreshBackoffPolicy.nextDelay(now: currentDate, randomUnit: randomUnit())
    refreshBackoff = RefreshBackoffState(
      nextAllowed: currentDate.addingTimeInterval(delay),
      category: category
    )
  }

  private func resetRefreshBackoff() {
    refreshBackoffPolicy.reset()
    refreshBackoff = nil
  }

  /// Follows the same thrown-error classification convention used elsewhere in this package
  /// (e.g. `PodcastRefreshCoordinator.statusClass`): `CancellationError` maps to `.cancelled`, an
  /// already-typed `APIError` passes through unchanged, and any other raw transport error (a
  /// `URLError`, or a fake transport's own error type in tests) maps to `.transport`.
  private static func classifyTransportFailure(_ error: any Error) -> APIError {
    if error is CancellationError { return .cancelled }
    if let apiError = error as? APIError { return apiError }
    return .transport
  }
}

/// The gate only arms on a retryable `APIError`, so the category is the raw thrown value. Nothing
/// is flattened, and a gated reactive refresh rethrows what armed it.
private struct RefreshBackoffState {
  let nextAllowed: Date
  let category: APIError
}

/// Refresh returns the same shape as `/login`; only the rotated tokens matter.
private struct RefreshResponseDTO: Decodable {
  let user: RefreshUserDTO
}

private struct RefreshUserDTO: Decodable {
  let accessToken: String
  let refreshToken: String
}
