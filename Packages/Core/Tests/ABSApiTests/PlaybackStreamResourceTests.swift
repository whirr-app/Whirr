import Foundation
import Testing

@testable import ABSApi

/// `PlaybackStreamResource.resolve` is the sole path to a restricted, resolved stream URL
/// (ARCHITECTURE.md §2 transport exception 5; API-CONVENTIONS.md rule 6a). No live playback
/// starts here. It accepts the live-confirmed relative shapes and a same-origin absolute echo,
/// applies the configured path prefix, and fails closed (returns `nil`, never throws) on every
/// hostile input.
@Suite("Playback stream resource resolution")
struct PlaybackStreamResourceTests {

  // MARK: - Accepted shapes

  @Test("resolves a relative /api direct-play content URL against the server's own origin")
  func resolvesRelativeDirectPlayURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "/api/items/item_book_fixture/file/101",
      server: server
    )

    let url = try #require(resource?.url)
    #expect(url.scheme == "https")
    #expect(url.host == "books.example.test")
    #expect(url.path == "/api/items/item_book_fixture/file/101")
  }

  @Test("resolves a relative /hls transcode playlist URL")
  func resolvesRelativeHLSURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "/hls/session_fixture/output.m3u8",
      server: server
    )

    #expect(resource?.url.path == "/hls/session_fixture/output.m3u8")
  }

  @Test("resolves a relative /public URL on the same terms as /api and /hls")
  func resolvesRelativePublicURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "/public/session/session_fixture/track/0",
      server: server
    )

    #expect(resource?.url.path == "/public/session/session_fixture/track/0")
  }

  @Test("applies the configured path prefix to a relative content URL")
  func appliesConfiguredPathPrefix() throws {
    let server = try makeServer("https://books.example.test/abs")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "/hls/session_fixture/output.m3u8",
      server: server
    )

    #expect(resource?.url.path == "/abs/hls/session_fixture/output.m3u8")
  }

  @Test("resolves a same-origin absolute content URL, matching scheme/host/port")
  func resolvesSameOriginAbsoluteURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "https://books.example.test/api/items/item_book_fixture/file/101",
      server: server
    )

    #expect(resource?.url.absoluteString == "https://books.example.test/api/items/item_book_fixture/file/101")
  }

  @Test("rejects a same-origin HTTP absolute URL when the server uses HTTPS")
  func rejectsHTTPAbsoluteURLOnHTTPSServer() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "http://books.example.test/api/items/item_book_fixture/file/101",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("no resolved resource ever carries a query or fragment")
  func resolvedResourceNeverCarriesQueryOrCredential() throws {
    let server = try makeServer("https://books.example.test")

    let resource = try #require(
      PlaybackStreamResource.resolve(
        rawContentUrl: "/api/items/item_book_fixture/file/101",
        server: server
      )
    )

    #expect(resource.url.query == nil)
    #expect(resource.url.fragment == nil)
    #expect(resource.url.user == nil)
    #expect(resource.url.password == nil)
  }

  // MARK: - Hostile / rejected shapes (fail closed: nil, never a thrown error)

  @Test("rejects a foreign-origin absolute URL")
  func rejectsForeignOriginAbsoluteURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "https://evil.example.test/api/items/item_book_fixture/file/101",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects a same-host URL on a mismatched port")
  func rejectsMismatchedPort() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "https://books.example.test:8443/api/items/item_book_fixture/file/101",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects a non-http(s) scheme")
  func rejectsNonHTTPScheme() throws {
    let server = try makeServer("https://books.example.test")

    #expect(
      PlaybackStreamResource.resolve(rawContentUrl: "file:///etc/passwd", server: server) == nil
    )
    #expect(
      PlaybackStreamResource.resolve(
        rawContentUrl: "javascript:alert(1)",
        server: server
      ) == nil
    )
  }

  @Test("rejects a protocol-relative URL as host confusion, not a same-origin relative path")
  func rejectsProtocolRelativeURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "//evil.example.test/api/items/item_book_fixture/file/101",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects a content URL carrying embedded user-info")
  func rejectsUserInfoInURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "https://attacker@books.example.test/api/items/item_book_fixture/file/101",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects a content URL carrying a fragment")
  func rejectsFragmentInURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "/api/items/item_book_fixture/file/101#evil",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects a content URL carrying a query - proof no token/query credential can be produced")
  func rejectsQueryInURL() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "/api/items/item_book_fixture/file/101?token=abc123",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects literal path traversal segments")
  func rejectsPathTraversal() throws {
    let server = try makeServer("https://books.example.test")

    #expect(
      PlaybackStreamResource.resolve(
        rawContentUrl: "/api/items/../../../etc/passwd",
        server: server
      ) == nil
    )
    #expect(
      PlaybackStreamResource.resolve(rawContentUrl: "/../secret", server: server) == nil
    )
  }

  @Test("rejects percent-encoded path traversal segments")
  func rejectsPercentEncodedPathTraversal() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "/api/items/%2e%2e/%2e%2e/etc/passwd",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects a relative content URL with no leading slash")
  func rejectsRelativePathWithoutLeadingSlash() throws {
    let server = try makeServer("https://books.example.test")

    let resource = PlaybackStreamResource.resolve(
      rawContentUrl: "api/items/item_book_fixture/file/101",
      server: server
    )

    #expect(resource == nil)
  }

  @Test("rejects an empty content URL")
  func rejectsEmptyURL() throws {
    let server = try makeServer("https://books.example.test")

    #expect(PlaybackStreamResource.resolve(rawContentUrl: "", server: server) == nil)
  }
}

private func makeServer(_ urlString: String) throws -> ABSServerConfig {
  try ABSServerConfig(url: #require(URL(string: urlString)))
}
