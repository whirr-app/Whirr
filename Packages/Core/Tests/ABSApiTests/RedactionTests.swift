import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("HTTP redaction")
struct RedactionTests {
  @Test("formatted log entries contain metadata only and no secrets, URLs, bodies, or errors")
  func redactsSensitiveData() async throws {
    let request = HTTPRequest(
      method: .post,
      url: try #require(URL(string: "https://books.example.test/api/items?token=url-secret")),
      headers: [
        "Authorization": "Bearer header-secret",
        "X-Secret": "header-secret-2",
        "Content-Type": "application/json",
      ],
      body: Data("body-secret".utf8),
      routeTemplate: "/api/items/:id"
    )
    let response = HTTPResponse(
      statusCode: 204,
      headers: ["X-Response-Secret": "response-secret"],
      body: Data("response-body-secret".utf8)
    )
    let logger = RedactingHTTPLogger()

    await logger.record(
      request: request,
      response: response,
      duration: 0.25,
      requestID: "request-123"
    )
    await logger.recordFailure(
      request: request,
      duration: 0.5,
      requestID: "request-456"
    )

    let formatted = (await logger.formattedEntries()).joined(separator: "\n")
    #expect(formatted.contains("POST"))
    #expect(formatted.contains("/api/items/:id"))
    #expect(formatted.contains("204"))
    #expect(formatted.contains("request-123"))
    for secret in [
      "url-secret", "header-secret", "header-secret-2", "body-secret", "response-secret",
      "response-body-secret", "error-secret", "books.example.test",
    ] {
      #expect(formatted.contains(secret) == false, "Log leaked \(secret)")
    }
  }

  @Test("an authorized download request's formatted description never contains its bearer token")
  func authorizedDownloadRequestDescriptionNeverContainsToken() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(
      TokenPair(accessToken: "header-secret-token", refreshToken: "refresh-secret-token"),
      for: account
    )
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: store)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "file-9", expectedMIMEType: "audio/mpeg", expectedSize: 10
    )

    let authorized = try await client.makeAuthorizedDownloadRequest(download, account: account)

    #expect("\(authorized)".contains("header-secret-token") == false)
    #expect(String(reflecting: authorized).contains("header-secret-token") == false)
    #expect("\(authorized)".contains("refresh-secret-token") == false)
  }

  /// `AuthorizedDownloadRequest`/`PlaybackStreamAuthorization` each hand-write a `description` to
  /// keep their private `HTTPRequest` out of reflection, but that only protects those two types.
  /// `HTTPRequest` is public and carries the `Authorization` header itself, so the
  /// guarantee has to hold at the primitive, not per wrapper.
  @Test("an HTTPRequest's own description never contains header values, the URL, or the body")
  func httpRequestDescriptionNeverContainsSecrets() throws {
    let request = HTTPRequest(
      method: .post,
      url: try #require(URL(string: "https://books.example.test/api/items?token=url-secret")),
      headers: [
        "Authorization": "Bearer header-secret",
        "X-Secret": "header-secret-2",
        "Content-Type": "application/json",
      ],
      body: Data("body-secret".utf8),
      routeTemplate: "/api/items/:id"
    )

    for rendered in ["\(request)", String(describing: request), String(reflecting: request)] {
      for secret in [
        "header-secret", "header-secret-2", "url-secret", "body-secret", "books.example.test",
      ] {
        #expect(rendered.contains(secret) == false, "HTTPRequest description leaked \(secret)")
      }
    }

    // Still useful for diagnostics: the redaction-safe route template survives.
    #expect("\(request)".contains("/api/items/:id"))
    #expect("\(request)".contains("POST"))
  }
}
