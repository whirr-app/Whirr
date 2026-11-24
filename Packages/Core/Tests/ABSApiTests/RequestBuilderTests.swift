import Foundation
import Testing

@testable import ABSApi

@Suite("Request builder")
struct RequestBuilderTests {
  private struct Payload: Encodable {
    let title: String
    let count: Int
  }

  @Test("composes a path prefix safely, encodes JSON and query values, and adds Bearer auth")
  func buildsJSONRequest() throws {
    let config = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test/abs///"))
    )
    let request = try RequestBuilder(server: config).makeJSONRequest(
      method: .post,
      path: "/api/items",
      queryItems: [URLQueryItem(name: "filter", value: "a space & a symbol")],
      body: Payload(title: "A title", count: 2),
      bearerToken: "access-token"
    )

    #expect(request.method == .post)
    #expect(
      request.url.absoluteString == "https://books.example.test/abs/api/items?filter=a%20space%20%26%20a%20symbol")
    #expect(request.headers["Authorization"] == "Bearer access-token")
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(request.headers["Accept"] == "application/json")

    let json = try #require(request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
    #expect(json["title"] as? String == "A title")
    #expect(json["count"] as? Int == 2)
  }

  @Test("preserves the accepted MIME types in the Accept header")
  func setsAcceptedMIMETypes() throws {
    let config = try ABSServerConfig(url: #require(URL(string: "http://nas.example.test")))
    let request = try RequestBuilder(server: config).makeRequest(
      method: .get,
      path: "/status",
      acceptedMIMETypes: ["application/json", "application/problem+json"]
    )

    #expect(request.headers["Accept"] == "application/json, application/problem+json")
    #expect(request.headers["Content-Type"] == nil)
    #expect(request.body == nil)
  }

  @Test("merges server custom headers before the standard stamps and Bearer wins collisions")
  func mergesCustomHeadersBeforeStandardStamps() throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let config = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")), customHeaders: customHeaders)
    let request = try RequestBuilder(server: config).makeRequest(
      method: .get,
      path: "/api/items",
      headers: ["authorization": "caller-value"],
      bearerToken: "abs-access"
    )

    #expect(request.headers["X-Proxy-Token"] == "proxy-secret")
    #expect(request.headers["Authorization"] == "Bearer abs-access")
    #expect(
      request.headers.keys.filter {
        $0.caseInsensitiveCompare("Authorization") == .orderedSame
      }.count == 1)
  }

  @Test("disables cookie storage only when server custom headers contain Cookie")
  func setsCookieHandlingFlagFromCustomHeaders() throws {
    let plainConfig = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let cookieConfig = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")),
      customHeaders: try CustomHeaders(["cookie": "session=abc"])
    )

    let plainRequest = try RequestBuilder(server: plainConfig).makeRequest(
      method: .get, path: "/status")
    let cookieRequest = try RequestBuilder(server: cookieConfig).makeRequest(
      method: .get, path: "/status")

    #expect(plainRequest.httpShouldHandleCookies)
    #expect(cookieRequest.httpShouldHandleCookies == false)
  }

  @Test("rejects absolute and traversal paths")
  func rejectsUnsafePaths() throws {
    let config = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let builder = RequestBuilder(server: config)

    #expect(throws: RequestBuilderError.self) {
      try builder.makeRequest(method: .get, path: "https://other.example.test/secret")
    }
    #expect(throws: RequestBuilderError.self) {
      try builder.makeRequest(method: .get, path: "/api/../secret")
    }
  }

  /// An unreachable host would otherwise spin the setup screen for the platform-default 60s+.
  /// Every built request must carry the client-wide bounded timeout so transport failures
  /// classify within a tolerable window.
  @Test func builtRequestsCarryTheBoundedTimeout() throws {
    let config = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let request = try RequestBuilder(server: config).makeRequest(method: .get, path: "/status")
    #expect(request.timeout == HTTPRequest.defaultTimeout)
  }
}
