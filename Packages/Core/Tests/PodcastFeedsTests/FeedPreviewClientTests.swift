import ABSApi
import Foundation
import TestSupport
import Testing

@testable import PodcastFeeds

@Suite("Feed preview client")
struct FeedPreviewClientTests {
  @Test("previews a real feed")
  func previewsRealFeed() async throws {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: "compact-itunes-rss", withExtension: "xml", subdirectory: "Fixtures"))
    let fixture = try Data(contentsOf: fixtureURL)
    let transport = FakeRedirectCustomizingHTTPClienting(
      fallback: .success(HTTPResponse(statusCode: 200, headers: [:], body: fixture)))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))
    let inputURL = URL(string: "https://feeds.example.test/compact-itunes-rss.xml")!

    let preview = try await client.preview(for: inputURL)

    #expect(preview.feedURL == inputURL)
    #expect(preview.title == "Fixture Tech Talk")
    #expect(preview.episodeCount == 4)
  }

  @Test(
    "previews feeds served as application/xml with long show notes, or with a DOCTYPE prologue",
    arguments: [
      ("oversized-item-description-rss", "application/xml", "Fixture Community Radio"),
      ("doctype-legacy-compat-rss", "application/rss+xml; charset=utf-8", "Fixture Freedom Podcast"),
    ])
  func previewsAwkwardRealFeedShapes(fixtureName: String, contentType: String, title: String) async throws {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: fixtureName, withExtension: "xml", subdirectory: "Fixtures"))
    let transport = FakeRedirectCustomizingHTTPClienting(
      fallback: .success(
        HTTPResponse(
          statusCode: 200, headers: ["Content-Type": contentType], body: try Data(contentsOf: fixtureURL))))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))

    let preview = try await client.preview(for: URL(string: "https://feeds.example.test/\(fixtureName).xml")!)

    #expect(preview.title == title)
    #expect(preview.episodeCount == 2)
  }

  @Test("keeps the newest episodes, undated items last, ties in feed order")
  func recentEpisodesOrdering() async throws {
    let feed = Self.feed(items: [
      Self.item(title: "Older", pubDate: "Mon, 01 Sep 2025 10:00:00 +0000"),
      Self.item(title: "Undated"),
      Self.item(
        title: "Newest", pubDate: "Wed, 03 Sep 2025 10:00:00 +0000", duration: "1:02:03",
        description: "<p>Notes &amp; links</p>"),
      Self.item(title: "Tie A", pubDate: "Tue, 02 Sep 2025 10:00:00 +0000"),
      Self.item(title: "Tie B", pubDate: "Tue, 02 Sep 2025 10:00:00 +0000"),
      Self.item(title: "Garbled date", pubDate: "not a date"),
    ])
    let client = Self.client(serving: feed)

    let preview = try await client.preview(for: URL(string: "https://feeds.example.test/x.xml")!)

    #expect(preview.episodeCount == 6)
    #expect(
      preview.recentEpisodes.map(\.title) == [
        "Newest", "Tie A", "Tie B", "Older", "Undated", "Garbled date",
      ])
    let newest = try #require(preview.recentEpisodes.first)
    #expect(newest.duration == 3723)
    #expect(newest.publishedAt == FeedValueParsing.pubDate("Wed, 03 Sep 2025 10:00:00 +0000"))
    // Raw feed text: HTML stripping belongs to the display layer.
    #expect(newest.synopsis == "<p>Notes &amp; links</p>")
    #expect(preview.recentEpisodes.last?.publishedAt == nil)
  }

  @Test("a preview episode prefers content:encoded over the description")
  func recentEpisodesPreferContent() async throws {
    let feed = Self.feed(items: [
      Self.item(title: "Both", description: "Teaser", content: "<p>Full notes</p>"),
      Self.item(title: "Description only", description: "Teaser"),
    ])
    let preview = try await Self.client(serving: feed)
      .preview(for: URL(string: "https://feeds.example.test/x.xml")!)
    #expect(preview.recentEpisodes.map(\.synopsis) == ["<p>Full notes</p>", "Teaser"])
  }

  @Test("caps recent episodes at the preview limit")
  func recentEpisodesCap() async throws {
    let count = FeedPreview.recentEpisodeLimit + 5
    let items = (0..<count).map { day in
      Self.item(title: "Episode \(day)", pubDate: "\(String(format: "%02d", day + 1)) Jan 2025 10:00:00 +0000")
    }
    let client = Self.client(serving: Self.feed(items: items))

    let preview = try await client.preview(for: URL(string: "https://feeds.example.test/x.xml")!)

    #expect(preview.episodeCount == count)
    #expect(preview.recentEpisodes.count == FeedPreview.recentEpisodeLimit)
    #expect(preview.recentEpisodes.first?.title == "Episode \(count - 1)")
  }

  @Test("a feed without items previews with no recent episodes")
  func emptyFeed() async throws {
    let client = Self.client(serving: Self.feed(items: []))

    let preview = try await client.preview(for: URL(string: "https://feeds.example.test/x.xml")!)

    #expect(preview.episodeCount == 0)
    #expect(preview.recentEpisodes.isEmpty)
  }

  @Test("a repeat preview of the same feed is unconditional")
  func repeatPreviewIsUnconditional() async throws {
    // A preview keeps no copy of the feed, so it can do nothing with a 304. Replaying the first
    // preview's validators turned every second open of the same show into "not a feed".
    let body = Data(Self.feed(items: [Self.item(title: "One")]).utf8)
    let transport = FakeRedirectCustomizingHTTPClienting(
      fallback: .success(
        HTTPResponse(
          statusCode: 200,
          headers: ["ETag": "\"v1\"", "Last-Modified": "Wed, 03 Sep 2025 10:00:00 GMT"],
          body: body)))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))
    let url = URL(string: "https://feeds.example.test/x.xml")!

    _ = try await client.preview(for: url)
    _ = try await client.preview(for: url)

    let second = try #require(transport.requests.last)
    #expect(second.headers["If-None-Match"] == nil)
    #expect(second.headers["If-Modified-Since"] == nil)
  }

  @Test("transport failure is unreachable")
  func transportFailure() async {
    let transport = FakeRedirectCustomizingHTTPClienting(fallback: .failure(APIError.transport))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))

    await #expect(throws: FeedPreviewError.unreachable) {
      try await client.preview(for: URL(string: "https://feeds.example.test/x.xml")!)
    }
  }

  @Test("HTTP error status is not a feed")
  func httpErrorStatus() async {
    let response = HTTPResponse(statusCode: 404, headers: [:], body: Data())
    let transport = FakeRedirectCustomizingHTTPClienting(fallback: .success(response))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))

    await #expect(throws: FeedPreviewError.notAFeed) {
      try await client.preview(for: URL(string: "https://feeds.example.test/x.xml")!)
    }
  }

  @Test("unparsable response is not a feed")
  func unparsableResponse() async {
    let response = HTTPResponse(
      statusCode: 200, headers: [:], body: Data("<html><body>nope</body></html>".utf8))
    let transport = FakeRedirectCustomizingHTTPClienting(fallback: .success(response))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))

    await #expect(throws: FeedPreviewError.notAFeed) {
      try await client.preview(for: URL(string: "https://feeds.example.test/x.xml")!)
    }
  }

  @Test("non-feed scheme is invalid")
  func nonFeedScheme() async {
    let transport = FakeRedirectCustomizingHTTPClienting(fallback: .failure(APIError.transport))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))

    await #expect(throws: FeedPreviewError.invalidURL) {
      try await client.preview(for: URL(string: "ftp://feeds.example.test/x.xml")!)
    }
  }

  @Test("credentialed URL is invalid")
  func credentialedURL() async {
    let transport = FakeRedirectCustomizingHTTPClienting(fallback: .failure(APIError.transport))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))

    // Per-feed credentials are handled in a later phase.
    await #expect(throws: FeedPreviewError.invalidURL) {
      try await client.preview(for: URL(string: "https://user:pass@feeds.example.test/x.xml")!)
    }
  }

  @Test("previews a clean URL with an ephemeral credential")
  func credentialedPreview() async throws {
    let fixtureURL = try #require(
      Bundle.module.url(forResource: "compact-itunes-rss", withExtension: "xml", subdirectory: "Fixtures"))
    let transport = FakeRedirectCustomizingHTTPClienting(
      fallback: .success(
        HTTPResponse(statusCode: 200, headers: [:], body: try Data(contentsOf: fixtureURL))))
    let client = FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))
    let cleanURL = URL(string: "https://feeds.example.test/private.xml")!
    let credential = try FeedCredential.basic(username: "user", password: "pass")

    let preview = try await client.preview(for: cleanURL, credential: credential)

    #expect(preview.feedURL == cleanURL)
    #expect(transport.requests.last?.url == cleanURL)
    #expect(transport.requests.last?.headers["Authorization"] == credential.authorization)
  }
}

extension FeedPreviewClientTests {
  fileprivate static func client(serving feed: String) -> FeedPreviewClient {
    let transport = FakeRedirectCustomizingHTTPClienting(
      fallback: .success(HTTPResponse(statusCode: 200, headers: [:], body: Data(feed.utf8))))
    return FeedPreviewClient(fetchClient: FeedFetchClient(httpClient: transport))
  }

  fileprivate static func feed(items: [String]) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel><title>Show</title>\(items.joined())</channel></rss>
    """
  }

  fileprivate static func item(
    title: String, pubDate: String? = nil, duration: String? = nil, description: String? = nil,
    content: String? = nil
  ) -> String {
    var xml = "<item><title>\(title)</title>"
    if let pubDate { xml += "<pubDate>\(pubDate)</pubDate>" }
    if let duration { xml += "<itunes:duration>\(duration)</itunes:duration>" }
    if let description { xml += "<description><![CDATA[\(description)]]></description>" }
    if let content { xml += "<content:encoded><![CDATA[\(content)]]></content:encoded>" }
    return xml + "</item>"
  }
}
