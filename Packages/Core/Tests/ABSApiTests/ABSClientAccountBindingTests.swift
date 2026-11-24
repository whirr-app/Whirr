import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// A client bound to one account never authenticates as another. The refusal comes before the
/// token store is read, so another account's bearer and refresh token never reach this client's
/// server or its proxy headers, and nothing is persisted under that account.
@Suite("ABSClient account binding")
struct ABSClientAccountBindingTests {

  @Test("a bound client never sends another account's credentials")
  func aBoundClientNeverSendsAnotherAccountsCredentials() async throws {
    let fixture = try BindingFixture()
    let other = fixture.otherAccount

    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.listLibraries(account: other)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.fetchItemDetail(account: other, itemID: "item-1")
    }
    // The internal seam every authenticated send and renewal goes through refuses on its own, so
    // a caller that already holds another account's pair still cannot use it here.
    let request = try RequestBuilder(server: fixture.server).makeRequest(
      method: .get, path: "/api/libraries", routeTemplate: "/api/libraries")
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.authenticatedSend(
        request, account: other, initialTokens: fixture.otherTokens)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.authenticatedTransport(for: other, initialTokens: fixture.otherTokens)
    }

    #expect(fixture.transport.requests.isEmpty)
    #expect(fixture.store.loadedAccounts.contains(other) == false)
  }

  @Test("a bound client never mints a download, ebook, or stream authorization for another account")
  func aBoundClientNeverMintsForAnotherAccount() async throws {
    let fixture = try BindingFixture()
    let other = fixture.otherAccount
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10)
    let ebook = try EbookRequest(itemID: "item-ebook")
    let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: 10)

    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.makeAuthorizedDownloadRequest(download, account: other)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.renewAuthorizedDownloadRequest(download, account: other)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.makeAuthorizedEbookRequest(ebook, ebookFile: ebookFile, account: other)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.renewAuthorizedEbookRequest(ebook, ebookFile: ebookFile, account: other)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.makePlaybackStreamAuthorization(account: other)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.renewPlaybackStreamAuthorization(account: other)
    }

    #expect(fixture.transport.requests.isEmpty)
    #expect(fixture.store.loadedAccounts.contains(other) == false)
  }

  @Test("a bound client never refreshes another account, and leaves its stored pair untouched")
  func aBoundClientNeverRefreshesAnotherAccount() async throws {
    let fixture = try BindingFixture()
    let other = fixture.otherAccount

    await #expect(throws: APIError.cancelled) {
      _ = try await fixture.client.refreshTokens(for: other)
    }

    #expect(fixture.transport.requests.isEmpty, "no /auth/refresh carrying the other account's token")
    #expect(fixture.store.loadedAccounts.contains(other) == false)
    #expect(fixture.store.savedAccounts.isEmpty)
    #expect(try fixture.store.load(for: other) == fixture.otherTokens)
  }

  @Test("a bound client still serves its own account")
  func aBoundClientStillServesItsOwnAccount() async throws {
    let fixture = try BindingFixture()
    fixture.transport.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: Data(#"{"libraries":[{"id":"lib1","name":"Library One","mediaType":"book"}]}"#.utf8)))
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10)

    #expect(fixture.client.boundAccount == fixture.boundAccount)
    _ = try await fixture.client.listLibraries(account: fixture.boundAccount)
    let authorized = try await fixture.client.makeAuthorizedDownloadRequest(
      download, account: fixture.boundAccount)

    #expect(fixture.transport.requests.count == 1)
    #expect(fixture.transport.requests.first?.headers["Authorization"] == "Bearer access-a")
    #expect(authorized.makeURLRequest().value(forHTTPHeaderField: "Authorization") == "Bearer access-a")
  }

  @Test("server status and logout for the bound account behave as before")
  func preAuthenticationRoutesIgnoreTheBinding() async throws {
    let fixture = try BindingFixture()
    fixture.transport.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: Data(#"{"app":"audiobookshelf","serverVersion":"2.36.0"}"#.utf8)))
    fixture.transport.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))

    let status = try await fixture.client.fetchServerStatus()
    try await fixture.client.logout(for: fixture.boundAccount)

    #expect(status.serverVersion == "2.36.0")
    #expect(fixture.transport.requests.map(\.url.path) == ["/status", "/logout"])
    #expect(fixture.transport.requests.last?.headers["x-refresh-token"] == "refresh-a")
    #expect(try fixture.store.load(for: fixture.boundAccount) == nil)
    #expect(try fixture.store.load(for: fixture.otherAccount) == fixture.otherTokens)
  }

  @Test("the account factory binds its client and the server factory does not")
  func theProductionFactoriesCarryTheBindingTheyWereGiven() throws {
    let fixture = try BindingFixture()

    let bound = ABSClient.production(
      server: fixture.server, account: fixture.boundAccount, tokenStore: fixture.store)
    let unbound = ABSClient.production(server: fixture.server, tokenStore: fixture.store)

    #expect(bound.boundAccount == fixture.boundAccount)
    #expect(unbound.boundAccount == nil)
  }
}

/// Two accounts with stored pairs, and a client bound to the first. Both use the credential
/// namespace, as every phone account does, so the binding is tested where it matters: two
/// accounts that share no server URL in their identity.
private struct BindingFixture {
  let server: ABSServerConfig
  let boundAccount: TokenAccount
  let otherAccount: TokenAccount
  let otherTokens = TokenPair(accessToken: "access-b", refreshToken: "refresh-b")
  /// Records which accounts the client reads and writes, so a test can prove a refusal came before
  /// the token store was touched rather than only before the network.
  let store = FakeTokenStoring()
  let transport = FakeHTTPClient()
  let client: ABSClient

  init() throws {
    server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    boundAccount = try TokenAccount(credentialNamespace: "account:client-a", userID: "user-a")
    otherAccount = try TokenAccount(credentialNamespace: "account:client-b", userID: "user-b")
    store.seed(TokenPair(accessToken: "access-a", refreshToken: "refresh-a"), for: boundAccount)
    store.seed(otherTokens, for: otherAccount)
    client = ABSClient(
      server: server, httpClient: transport, tokenStore: store, boundAccount: boundAccount)
  }
}
