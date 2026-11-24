import ABSApi
import Foundation
import Persistence

/// Single sign-on through the server's mobile OIDC flow. Each operation is two calls either side
/// of a browser session the App runs: `begin…` asks the server for the identity provider's page,
/// and the matching completion exchanges the browser's callback.
///
/// The backoff gate is admitted per server request, never across the browser: the user can spend
/// minutes at the identity provider, and a reservation held that long would refuse every other
/// sign-in or leak if the screen went away. A cancelled browser session never touches the gate.
extension AccountLifecycleService {
  public func beginSingleSignOn(server: ValidatedServer) async throws -> SingleSignOnAttempt {
    let serverConfig: ABSServerConfig
    do {
      serverConfig = try serverConfigFactory.make(
        for: server.serverURL, customHeaders: server.customHeaders)
    } catch {
      throw AccountLifecycleError.malformedURL
    }
    return try await beginSingleSignOn(on: serverConfig)
  }

  public func login(
    server: ValidatedServer, singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL
  ) async throws {
    let oidcAttempt = try Self.completable(attempt)
    // Single use whatever happens below, including a failure before the exchange is sent.
    defer { oidcAttempt.abandon() }
    try await logIn(server: server, method: .openID) { client in
      try await client.prepareOIDCLogin(attempt: oidcAttempt, callbackURL: callbackURL)
    }
  }

  public func beginSingleSignOnReauthentication() async throws -> SingleSignOnAttempt {
    return try await beginSingleSignOn(on: try storedAccountServer().server)
  }

  public func reauthenticate(singleSignOn attempt: SingleSignOnAttempt, callbackURL: URL) async throws {
    let oidcAttempt = try Self.completable(attempt)
    defer { oidcAttempt.abandon() }
    try await reauthenticateStoredAccount(method: .openID) { client, expectedAccount in
      _ = try await client.reauthenticate(
        oidcAttempt: oidcAttempt, callbackURL: callbackURL, expectedAccount: expectedAccount)
    }
  }

  private func beginSingleSignOn(on serverConfig: ABSServerConfig) async throws -> SingleSignOnAttempt {
    if let retryAfter = await loginBackoffGate.admit() {
      throw AccountLifecycleError.loginRateLimited(retryAfter: retryAfter)
    }
    let attempt: OIDCAttempt
    do {
      attempt = try await makeClient(serverConfig, tokenStore).beginOIDCLogin()
    } catch {
      throw await credentialFailure(
        error, method: .openID, operation: "sign-in start", step: "openid-begin")
    }
    // Starting proves nothing about the user, so it neither clears nor arms pacing.
    await loginBackoffGate.releaseReservation()
    return SingleSignOnAttempt(attempt)
  }

  /// A stand-in attempt (fakes and previews) carries no exchange, so it can never complete.
  private static func completable(_ attempt: SingleSignOnAttempt) throws -> OIDCAttempt {
    guard let oidcAttempt = attempt.oidcAttempt else {
      throw AccountLifecycleError.singleSignOnFailed(.callbackRejected)
    }
    return oidcAttempt
  }

  /// Which `OIDCLoginError`s count against login pacing. Only a refusal is a judgement about the
  /// sign-in; the rest are configuration, a callback Whirr rejected before sending anything, or an
  /// attempt the server forgot, and arming the gate would only delay the retry the copy asks for.
  static func singleSignOnFailure(_ error: OIDCLoginError) -> (SingleSignOnFailure, countsAgainstPacing: Bool) {
    switch error {
    case .redirectURINotAllowed: (.redirectURINotAllowed, false)
    case .unavailable: (.unavailable, false)
    case .invalidCallback, .stateMismatch, .attemptAlreadyUsed, .attemptForAnotherServer:
      (.callbackRejected, false)
    case .attemptExpired: (.attemptExpired, false)
    case .refused: (.refused, true)
    case .proxyCookieConflict: (.proxyCookieConflict, false)
    case .requiresHTTPS: (.requiresHTTPS, false)
    }
  }
}
