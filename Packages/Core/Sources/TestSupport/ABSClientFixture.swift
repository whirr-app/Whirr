import Foundation

@testable import ABSApi

/// An `ABSClient` wired to a `FakeHTTPClient` and an account carrying the sentinel credentials the
/// privacy tests assert never leak (`user_fixture`, `canary-access`, `canary-refresh`).
public enum ABSClientFixture {
  public static let serverURL = URL(string: "https://books.example.test")!

  public static func make(
    responses: [HTTPResponse] = [],
    transportFailure: (any Error)? = nil,
    serverURL: URL = ABSClientFixture.serverURL,
    userID: String = "user_fixture",
    accessToken: String = "canary-access",
    refreshToken: String? = "canary-refresh",
    server: ABSServerConfig? = nil,
    logger: RedactingHTTPLogger = RedactingHTTPLogger()
  ) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
    let resolvedServer: ABSServerConfig
    if let server {
      resolvedServer = server
    } else {
      resolvedServer = try ABSServerConfig(url: serverURL)
    }
    let account = try TokenAccount(server: resolvedServer, userID: userID)
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: accessToken, refreshToken: refreshToken), for: account)
    let http: FakeHTTPClient
    if let transportFailure {
      http = FakeHTTPClient(responses: responses, transportFailure: transportFailure)
    } else {
      http = FakeHTTPClient(responses: responses)
    }
    let client = ABSClient(
      server: resolvedServer, httpClient: http, tokenStore: store, logger: logger)
    return (client, http, account)
  }
}
