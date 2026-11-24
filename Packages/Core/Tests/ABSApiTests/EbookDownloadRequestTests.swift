import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Ebook download requests", .timeLimit(.minutes(1)))
struct EbookDownloadRequestTests {

  @Test("mints the item-level EPUB request with the current token and ebook metadata")
  func mintsItemLevelRequestWithCurrentTokenAndMetadata() async throws {
    let (client, _, account) = try makeClient(
      accessToken: "current-ebook-access", refreshToken: "current-ebook-refresh")
    let request = try EbookRequest(itemID: "item-ebook")
    let ebookFile = EbookFileInfo(
      ino: "ebook-ino-987", ext: "epub", filename: "book.epub", size: 440_335)

    let authorized = try await client.makeAuthorizedEbookRequest(
      request, ebookFile: ebookFile, account: account)

    #expect(authorized.itemID == "item-ebook")
    #expect(authorized.fileID == "ebook-ino-987")
    #expect(authorized.expectedMIMEType == "application/epub+zip")
    #expect(authorized.expectedSize == 440_335)
    let urlRequest = authorized.makeURLRequest()
    #expect(urlRequest.httpMethod == "GET")
    #expect(urlRequest.url?.path == "/api/items/item-ebook/ebook")
    #expect(urlRequest.url?.query == nil)
    #expect(urlRequest.url?.path.contains("ebook-ino-987") == false)
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer current-ebook-access")
    #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "application/epub+zip")
  }

  @Test("descriptions never contain access or refresh tokens under fuzzed token input")
  func descriptionsNeverContainFuzzedTokens() async throws {
    let fuzzedPairs = [
      ("access-!@#$%^&*()-=[]{};,.<>?", "refresh-!@#$%^&*()-=[]{};,.<>?"),
      ("access-emoji-🔐-line\nbreak", "refresh-emoji-🗝️-line\nbreak"),
      ("access-very-long-" + String(repeating: "x", count: 512), "refresh-short"),
    ]

    for (accessToken, refreshToken) in fuzzedPairs {
      let (client, _, account) = try makeClient(
        accessToken: accessToken, refreshToken: refreshToken)
      let request = try EbookRequest(itemID: "item-ebook")
      let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: 10)
      let authorized = try await client.makeAuthorizedEbookRequest(
        request, ebookFile: ebookFile, account: account)

      #expect(authorized.description.contains(accessToken) == false)
      #expect(authorized.description.contains(refreshToken) == false)
      #expect(authorized.debugDescription.contains(accessToken) == false)
      #expect(authorized.debugDescription.contains(refreshToken) == false)
      #expect(String(reflecting: authorized).contains(accessToken) == false)
      #expect(String(reflecting: authorized).contains(refreshToken) == false)
    }
  }

  @Test("minting touches neither the foreground gate nor the transport")
  func mintingTakesNoGatePermitOrTransportTraffic() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)
    let http = FakeHTTPClient()
    let gate = ServerRequestGate()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store, requestGate: gate)
    let request = try EbookRequest(itemID: "item-ebook")
    let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: 10)

    _ = try await client.makeAuthorizedEbookRequest(request, ebookFile: ebookFile, account: account)

    #expect(http.requests.isEmpty)
    #expect(await gate.inFlightCount == 0)
    #expect(await gate.queuedCount == 0)
  }

  @Test("an absent ebook file is a construction failure")
  func missingEbookFileFailsConstruction() async throws {
    let (client, _, account) = try makeClient(accessToken: "access", refreshToken: "refresh")
    let request = try EbookRequest(itemID: "item-ebook")

    await #expect(throws: EbookDownloadRequestError.missingEbookFile) {
      _ = try await client.makeAuthorizedEbookRequest(
        request, ebookFile: nil, account: account)
    }
  }

  @Test("an ebook file without a size is a construction failure")
  func missingEbookSizeFailsConstruction() async throws {
    let (client, _, account) = try makeClient(accessToken: "access", refreshToken: "refresh")
    let request = try EbookRequest(itemID: "item-ebook")
    let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: nil)

    await #expect(throws: EbookDownloadRequestError.missingExpectedSize) {
      _ = try await client.makeAuthorizedEbookRequest(
        request, ebookFile: ebookFile, account: account)
    }
  }

  @Test("renewal runs one single-flight refresh and re-stamps the same item-level route")
  func renewalRunsOneRefreshAndRestampsSameRoute() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)
    let transport = FakeHTTPClient(
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")])
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let request = try EbookRequest(itemID: "item-ebook")
    let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: 440_335)

    let renewed = try await client.renewAuthorizedEbookRequest(
      request, ebookFile: ebookFile, account: account)

    let urlRequest = renewed.makeURLRequest()
    #expect(urlRequest.url?.path == "/api/items/item-ebook/ebook")
    #expect(urlRequest.url?.path.contains("ebook-ino") == false)
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    #expect(transport.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
    #expect(try store.load(for: account)?.accessToken == "new-access")
  }

  @Test("no-refresh ebook renewal fails before touching the transport")
  func renewalWithoutRefreshTokenFailsFast() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "api-access", refreshToken: nil), for: account)
    let transport = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let request = try EbookRequest(itemID: "item-ebook")
    let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: 10)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.renewAuthorizedEbookRequest(
        request, ebookFile: ebookFile, account: account)
    }

    #expect(transport.requests.isEmpty)
  }

  @Test("concurrent ebook renewals share exactly one refresh")
  func concurrentRenewalsShareOneRefresh() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)
    // Holds the one refresh open so three concurrent renewals provably attach to it.
    let refreshGate = TestGate<HTTPResponse>(label: "/auth/refresh")
    refreshGate.hold()
    let transport = FakeHTTPClient { _ in
      await refreshGate.pass(otherwise: {
        HTTPResponse(statusCode: 500, headers: [:], body: Data())
      })
    }
    let attachedWaiters = Locked(0)
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let ebookFile = EbookFileInfo(ino: "ebook-ino", ext: "epub", filename: nil, size: 10)
    let requests = try (0..<3).map { index in
      try EbookRequest(itemID: "item-ebook-\(index)")
    }

    let tasks = requests.map { request in
      Task {
        async let renewed = client.renewAuthorizedEbookRequest(
          request, ebookFile: ebookFile, account: account)
        await refreshGate.waitUntilParked()
        attachedWaiters.withValue { $0 += 1 }
        return try await renewed
      }
    }
    await refreshGate.waitUntilParked()
    #expect(await waitUntil { attachedWaiters.value == requests.count })
    refreshGate.release(
      makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"))

    for task in tasks {
      let renewed = try await task.value
      #expect(renewed.makeURLRequest().value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    }
    #expect(transport.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
  }
}

private func makeClient(
  accessToken: String,
  refreshToken: String
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  try ABSClientFixture.make(
    accessToken: accessToken, refreshToken: refreshToken, server: try makeServer())
}

private func makeServer() throws -> ABSServerConfig {
  try ABSServerConfig(url: URL(string: "https://books.example.test")!)
}

private func makeRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]])
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}
