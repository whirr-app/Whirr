import ABSApi
import AppModel
import CoreSupport
import Foundation
import Persistence
import SyncEngine
import WatchProtocol
import os

extension WatchPhoneSetupModel {
  private static let setupLog = CoreLogging.logger(category: "watch-setup")

  /// Revokes a session this setup signed in but will not hand to the Watch: a different user, an
  /// abandoned attempt, or a failed transfer. Best effort, but a failure is logged because that
  /// session stays live on the server until it expires.
  private static func revoke(_ client: ABSClient, _ account: TokenAccount) async {
    do {
      try await client.logout(for: account)
    } catch {
      setupLog.error("watch setup could not revoke its sign-in session")
    }
  }

  static let liveLogin: LoginProvider = { url, method, store in
    let server = try ABSServerConfig(url: url)
    let client = ABSClient.production(server: server, tokenStore: store)
    let status = try await client.fetchServerStatus()
    guard status.app?.caseInsensitiveCompare("audiobookshelf") == .orderedSame else {
      throw APIError.decoding
    }
    try ABSServerCompatibilityGate.validate(serverVersion: status.serverVersion)
    let session: LoginSession
    switch method {
    case .password(let credentials):
      session = try await client.login(credentials: credentials)
    case .singleSignOn(let browser):
      let attempt = try await client.beginOIDCLogin()
      defer { attempt.abandon() }
      // Ephemeral: the Watch's pair belongs to whoever signs in here, never to whoever Safari is
      // already signed in as.
      guard
        let callbackURL = try await browser.authenticate(
          at: attempt.authorizationURL, callbackScheme: OIDCAttempt.callbackScheme, prefersEphemeralSession: true)
      else { return nil }
      let prepared = try await client.prepareOIDCLogin(attempt: attempt, callbackURL: callbackURL)
      try await client.commitLogin(prepared)
      session = prepared
    }
    guard let tokens = try store.load(for: session.account),
      let refresh = tokens.refreshToken, !tokens.accessToken.isEmpty, !refresh.isEmpty
    else {
      await WatchPhoneSetupModel.revoke(client, session.account)
      throw SetupFailure.accountMismatch
    }
    return LoginResult(
      userID: session.userID,
      serverIdentity: session.account.serverIdentity,
      defaultLibraryID: session.defaultLibraryID,
      accessToken: tokens.accessToken,
      refreshToken: refresh,
      accessExpiry: tokens.accessExpiry,
      cleanup: { remote in
        if remote {
          await WatchPhoneSetupModel.revoke(client, session.account)
        } else {
          try? store.clear(for: session.account)
        }
      })
  }
}
