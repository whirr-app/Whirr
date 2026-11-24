import Foundation
import Testing

@testable import ABSApi

@Suite("Server configuration")
struct ServerConfigTests {
  @Test("defaults custom headers to an empty value and preserves configured headers")
  func customHeadersDefaultAndRoundTrip() throws {
    let plain = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let configured = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")), customHeaders: customHeaders)

    #expect(plain.customHeaders == .none)
    #expect(configured.customHeaders == customHeaders)
  }

  @Test("normalizes trailing slashes while preserving a path prefix")
  func normalizesURL() throws {
    let config = try ABSServerConfig(url: #require(URL(string: "https://books.example.test/audiobookshelf///")))

    #expect(config.baseURL.absoluteString == "https://books.example.test/audiobookshelf")
    #expect(config.pathPrefix == "/audiobookshelf")
  }

  @Test("accepts plain-HTTP private servers")
  func acceptsHTTP() throws {
    let config = try ABSServerConfig(url: #require(URL(string: "http://nas.example.test:13378/abs/")))

    #expect(config.baseURL.absoluteString == "http://nas.example.test:13378/abs")
    #expect(config.pathPrefix == "/abs")
  }

  @Test("rejects non-HTTP(S) schemes")
  func rejectsOtherSchemes() throws {
    for rawURL in ["ftp://books.example.test", "ws://books.example.test", "abs://books.example.test"] {
      #expect(throws: APIError.self) {
        try ABSServerConfig(url: #require(URL(string: rawURL)))
      }
    }
  }

  @Test("rejects credentials, query strings, fragments, and traversal")
  func rejectsHostileURLComponents() throws {
    let hostileURLs = [
      "https://user:password@books.example.test",
      "https://books.example.test?token=secret",
      "https://books.example.test/#fragment",
      "https://books.example.test/../private",
      "https://books.example.test/%2e%2e/private",
    ]

    for rawURL in hostileURLs {
      #expect(throws: APIError.self) {
        try ABSServerConfig(url: #require(URL(string: rawURL)))
      }
    }
  }

  @Test("rejects URLs without a host")
  func requiresHost() throws {
    #expect(throws: APIError.self) {
      try ABSServerConfig(url: #require(URL(string: "https:///missing-host")))
    }
  }
}
