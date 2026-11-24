import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// The authenticated pipeline's `ServerDateObserving` hook. Every scenario sends through
/// `AuthenticatedHTTPClient` directly (like the `RefreshTests.swift` harness) so the observation
/// point under test is the one production traffic uses.
@Suite("Server date observation")
struct ServerDateObservationTests {
  @Test("a 2xx authenticated response reports its Date header, account, and receipt time")
  func successfulResponseReportsServerDate() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)

    let transport = FakeHTTPClient(responses: [
      HTTPResponse(
        statusCode: 200, headers: ["Date": "Tue, 15 Nov 1994 08:12:31 GMT"], body: Data())
    ])

    let observer = RecordingServerDateObserver()
    let receiptTime = Date(timeIntervalSince1970: 1_700_000_000)
    let client = AuthenticatedHTTPClient(
      transport: transport, requestBuilder: RequestBuilder(server: server), tokenStore: store,
      account: account, initialTokens: TokenPair(accessToken: "access", refreshToken: "refresh"),
      serverDateObserving: observer, now: { receiptTime })

    _ = try await client.send(try makeItemsRequest(server: server))

    let observations = await observer.observations
    #expect(observations.count == 1)
    #expect(observations.first?.account == account)
    #expect(observations.first?.receivedAt == receiptTime)
    #expect(observations.first?.serverDate == Date(timeIntervalSince1970: 784_887_151))
  }

  @Test("4xx and 5xx authenticated responses still report their Date header, case-insensitively")
  func nonSuccessResponsesStillReportDate() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)

    let transport = FakeHTTPClient(responses: [
      HTTPResponse(statusCode: 404, headers: ["date": "Tue, 15 Nov 1994 08:12:31 GMT"], body: Data())
    ])

    let observer = RecordingServerDateObserver()
    let client = AuthenticatedHTTPClient(
      transport: transport, requestBuilder: RequestBuilder(server: server), tokenStore: store,
      account: account, initialTokens: TokenPair(accessToken: "access", refreshToken: "refresh"),
      serverDateObserving: observer)

    _ = try await client.send(try makeItemsRequest(server: server))

    let observations = await observer.observations
    #expect(observations.count == 1, "a lowercase 'date' header key must still be recognized")
  }

  @Test("a malformed Date header emits no observation")
  func malformedDateEmitsNothing() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)

    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: ["Date": "not-a-date"], body: Data())])

    let observer = RecordingServerDateObserver()
    let client = AuthenticatedHTTPClient(
      transport: transport, requestBuilder: RequestBuilder(server: server), tokenStore: store,
      account: account, initialTokens: TokenPair(accessToken: "access", refreshToken: "refresh"),
      serverDateObserving: observer)

    _ = try await client.send(try makeItemsRequest(server: server))

    #expect(await observer.observations.isEmpty)
  }

  @Test("a response with no Date header emits no observation")
  func missingDateEmitsNothing() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)

    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    let observer = RecordingServerDateObserver()
    let client = AuthenticatedHTTPClient(
      transport: transport, requestBuilder: RequestBuilder(server: server), tokenStore: store,
      account: account, initialTokens: TokenPair(accessToken: "access", refreshToken: "refresh"),
      serverDateObserving: observer)

    _ = try await client.send(try makeItemsRequest(server: server))

    #expect(await observer.observations.isEmpty)
  }

  @Test("pre-auth traffic (login/logout via the plain transport) never reports a server date")
  func preAuthTrafficEmitsNothing() async throws {
    let server = try makeServer()
    let transport = FakeHTTPClient(responses: [
      HTTPResponse(
        statusCode: 200, headers: ["Date": "Tue, 15 Nov 1994 08:12:31 GMT"],
        body: try JSONSerialization.data(
          withJSONObject: ["user": ["id": "u1", "accessToken": "a", "refreshToken": "r"]]))
    ])
    let observer = RecordingServerDateObserver()
    let tokenStore = InMemoryTokenStore()
    let client = ABSClient(
      server: server, httpClient: transport, tokenStore: tokenStore, serverDateObserving: observer)

    _ = try await client.login(credentials: LoginCredentials(username: "u", password: "p"))

    #expect(await observer.observations.isEmpty)
  }

  @Test("observing never exposes headers/tokens and never alters gate or refresh behavior")
  func observingIsSideEffectFreeOnTransportBehavior() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)

    // One sequential flow, so the queue order is the request order: the 401, the refresh, the retry.
    let transport = FakeHTTPClient(responses: [
      HTTPResponse(statusCode: 401, headers: ["Date": "Tue, 15 Nov 1994 08:12:31 GMT"], body: Data()),
      HTTPResponse(
        statusCode: 200, headers: [:],
        body: try JSONSerialization.data(
          withJSONObject: ["user": ["accessToken": "new-access", "refreshToken": "new-refresh"]])),
      HTTPResponse(statusCode: 200, headers: ["Date": "Tue, 15 Nov 1994 08:13:31 GMT"], body: Data()),
    ])

    let observer = RecordingServerDateObserver()
    let client = AuthenticatedHTTPClient(
      transport: transport, requestBuilder: RequestBuilder(server: server), tokenStore: store,
      account: account, initialTokens: TokenPair(accessToken: "old-access", refreshToken: "old-refresh"),
      serverDateObserving: observer)

    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200, "the ordinary 401-refresh-retry flow is unaffected")
    #expect(try store.load(for: account)?.accessToken == "new-access")
    // Two authenticated responses were seen (401 then 200). The bare /auth/refresh response
    // carries no Date header, so it never reports.
    #expect(await observer.observations.count == 2)
  }
}

private func makeServer() throws -> ABSServerConfig {
  try ABSServerConfig(url: URL(string: "https://books.example.test")!)
}

private func makeItemsRequest(server: ABSServerConfig) throws -> HTTPRequest {
  try RequestBuilder(server: server).makeRequest(method: .get, path: "/items", routeTemplate: "/items")
}

private actor RecordingServerDateObserver: ServerDateObserving {
  struct Observation: Equatable {
    let serverDate: Date
    let receivedAt: Date
    let account: TokenAccount
  }

  private(set) var observations: [Observation] = []

  func observeServerDate(_ serverDate: Date, receivedAt: Date, account: TokenAccount) async {
    observations.append(Observation(serverDate: serverDate, receivedAt: receivedAt, account: account))
  }
}
