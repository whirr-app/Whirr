import Foundation

/// Same-account reauthentication validates identity before any persistent or live-client
/// mutation, then saves the replacement pair before exposing it to a cached client.
extension ABSClient {
  public func reauthenticate(
    credentials: LoginCredentials,
    expectedAccount: TokenAccount
  ) async throws -> TokenPair {
    let exchange = try await exchangePassword(credentials: credentials)
    return try await commitReauthentication(
      exchange.tokens, for: exchange.account, expectedAccount: expectedAccount)
  }

  /// Same-account API-token recovery. `/api/me` proves the user identity before the no-refresh
  /// token replaces the stored pair.
  public func reauthenticate(
    apiToken credentials: APITokenCredentials,
    expectedAccount: TokenAccount
  ) async throws -> TokenPair {
    let exchange = try await validateAPIToken(credentials: credentials)
    return try await commitReauthentication(
      exchange.tokens, for: exchange.account, expectedAccount: expectedAccount)
  }

  /// Same-account single sign-on recovery. The callback exchange returns the same login JSON as
  /// a password, so the identity check and commit are the password variant's.
  public func reauthenticate(
    oidcAttempt attempt: OIDCAttempt,
    callbackURL: URL,
    expectedAccount: TokenAccount
  ) async throws -> TokenPair {
    let exchange = try await exchangeOIDCCallback(attempt: attempt, callbackURL: callbackURL)
    return try await commitReauthentication(
      exchange.tokens, for: exchange.account, expectedAccount: expectedAccount)
  }

  public func reauthenticate(
    apiToken: String,
    expectedAccount: TokenAccount
  ) async throws -> TokenPair {
    try await reauthenticate(
      apiToken: APITokenCredentials(token: apiToken), expectedAccount: expectedAccount)
  }

  /// Every variant's identity check and write, so they cannot drift apart.
  private func commitReauthentication(
    _ tokens: TokenPair, for account: TokenAccount, expectedAccount: TokenAccount
  ) async throws -> TokenPair {
    // The server is fixed by this client's base URL, so the exchange's URL-keyed account can only
    // differ from the stored namespace account in its user id; that is the whole identity check.
    guard account.userID == expectedAccount.userID else {
      await revokeRefusedSession(tokens)
      throw ReauthenticationError.accountMismatch
    }

    do {
      try tokenStore.save(tokens, for: expectedAccount)
    } catch {
      throw ReauthenticationError.tokenPersistenceFailed(underlying: error)
    }
    await replaceTokensInCachedClient(tokens, for: expectedAccount)
    await reportAuthEvent(.reauthenticationSucceeded(expectedAccount))
    return tokens
  }

  /// The server opened a session for the other user before the identity check could refuse it, and
  /// nothing on this device keeps the pair, so end it now rather than leave it valid until its
  /// refresh token expires. A pair without a refresh token came from an API token: that is the
  /// user's own key, not a session this attempt created, so it is left alone. Best effort: the
  /// refusal stands whatever the server answers.
  private func revokeRefusedSession(_ tokens: TokenPair) async {
    guard let refreshToken = tokens.refreshToken, refreshToken.isEmpty == false,
      let request = try? requestBuilder.makeRequest(
        method: .post,
        path: "/logout",
        headers: ["x-refresh-token": refreshToken],
        routeTemplate: "/logout",
        isAuthenticationRoute: true
      )
    else { return }
    _ = try? await send(request)
  }
}
