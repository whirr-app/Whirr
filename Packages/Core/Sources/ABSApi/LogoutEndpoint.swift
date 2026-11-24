extension ABSClient {
  public func logout(for account: TokenAccount) async throws {
    var serverError: Error?
    var shouldClearTokens = true

    do {
      if let tokens = try tokenStore.load(for: account) {
        var headers: [String: String] = [:]
        if let refreshToken = tokens.refreshToken {
          headers["x-refresh-token"] = refreshToken
        }
        let request = try requestBuilder.makeRequest(
          method: .post,
          path: "/logout",
          headers: headers,
          routeTemplate: "/logout",
          isAuthenticationRoute: true
        )
        let response = try await send(request)
        try validateSuccess(response)
      } else {
        shouldClearTokens = false
      }
    } catch {
      serverError = error
    }

    var localClearError: Error?
    await invalidateAndEvictCachedClient(for: account)
    if shouldClearTokens {
      do {
        try tokenStore.clear(for: account)
      } catch {
        localClearError = error
      }
    }

    do {
      try await clearServerScopedCredentials(for: account)
    } catch {
      if localClearError == nil { localClearError = error }
    }

    if let localClearError {
      throw LogoutError.localCredentialClearFailed(underlying: localClearError)
    }
    if let serverError {
      throw serverError
    }
  }
}
