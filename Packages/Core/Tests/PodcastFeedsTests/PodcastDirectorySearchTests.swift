import ABSApi
import Foundation
import PodcastFeeds
import TestSupport
import Testing

@Suite("Podcast directory search")
struct PodcastDirectorySearchTests {
  @Test("builds a bounded keyless request and redacts the search term from its route")
  func requestShape() async throws {
    let transport = FakeRedirectCustomizingHTTPClienting(fallback: .success(Self.response()))
    let client = PodcastDirectorySearchClient(httpClient: transport)

    _ = try await client.search(term: "private listening interest")

    let request = try #require(transport.requests.first)
    #expect(request.method == .get)
    #expect(request.url.host == "itunes.apple.com")
    #expect(request.url.path == "/search")
    #expect(
      URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
        $0.name == "term" && $0.value == "private listening interest"
      } == true)
    #expect(request.headers == ["Accept": "application/json"])
    #expect(request.headers["Authorization"] == nil)
    #expect(request.routeTemplate.contains("private listening interest") == false)
    #expect(request.maximumResponseBytes == PodcastDirectorySearchClient.maximumResponseBytes)
  }

  @Test("maps valid results, drops unusable feeds, and deduplicates by feed URL")
  func mapping() async throws {
    let body = Data(
      """
      {"results":[
        {"feedUrl":"https://feeds.example/one.xml","collectionName":"One","artistName":"Host","artworkUrl100":"https://images.example/one.jpg","trackCount":12},
        {"feedUrl":"https://feeds.example/one.xml","collectionName":"Duplicate"},
        {"feedUrl":"file:///tmp/feed.xml","collectionName":"Local"},
        {"feedUrl":"https://feeds.example/untitled.xml","collectionName":"   "},
        {"feedUrl":"http://feeds.example/two.xml","collectionName":"Two","artistName":"","artworkUrl100":"javascript:bad","trackCount":-2}
      ]}
      """.utf8)
    let client = PodcastDirectorySearchClient(
      httpClient: FakeRedirectCustomizingHTTPClienting(
        fallback: .success(HTTPResponse(statusCode: 200, headers: [:], body: body))))

    let results = try await client.search(term: "shows")

    #expect(results.count == 2)
    #expect(results[0].title == "One")
    #expect(results[0].author == "Host")
    #expect(results[0].episodeCount == 12)
    #expect(results[1].title == "Two")
    #expect(results[1].author == nil)
    #expect(results[1].artworkURL == nil)
    #expect(results[1].episodeCount == 0)
  }

  @Test("keeps the large directory artwork when it is a bounded HTTP(S) URL")
  func largeArtwork() async throws {
    let oversized =
      "https://images.example/"
      + String(
        repeating: "a", count: PodcastDirectorySearchClient.maximumResultStringBytes)
    let body = Data(
      """
      {"results":[
        {"feedUrl":"https://feeds.example/one.xml","collectionName":"One","artworkUrl100":"https://images.example/one-100.jpg","artworkUrl600":"https://images.example/one-600.jpg"},
        {"feedUrl":"https://feeds.example/two.xml","collectionName":"Two","artworkUrl100":"https://images.example/two-100.jpg","artworkUrl600":"javascript:bad"},
        {"feedUrl":"https://feeds.example/three.xml","collectionName":"Three","artworkUrl600":"\(oversized)"},
        {"feedUrl":"https://feeds.example/four.xml","collectionName":"Four","artworkUrl100":"https://images.example/four-100.jpg"}
      ]}
      """.utf8)
    let client = PodcastDirectorySearchClient(
      httpClient: FakeRedirectCustomizingHTTPClienting(
        fallback: .success(HTTPResponse(statusCode: 200, headers: [:], body: body))))

    let results = try await client.search(term: "shows")

    #expect(results.map(\.title) == ["One", "Two", "Three", "Four"])
    #expect(results[0].largeArtworkURL == URL(string: "https://images.example/one-600.jpg"))
    #expect(results[1].largeArtworkURL == nil)
    #expect(results[1].artworkURL == URL(string: "https://images.example/two-100.jpg"))
    #expect(results[2].largeArtworkURL == nil)
    #expect(results[3].largeArtworkURL == nil)
  }

  @Test("asks the directory's image host for the hero size of the image it returned")
  func heroArtworkURL() {
    func result(large: String?) -> PodcastDirectoryResult {
      PodcastDirectoryResult(
        feedURL: URL(string: "https://feeds.example/one.xml")!, title: "One", author: nil,
        artworkURL: nil, largeArtworkURL: large.flatMap(URL.init(string:)), episodeCount: nil)
    }
    let image = "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/f4/09/a7/id/mza_1.jpg"

    #expect(
      result(large: "\(image)/600x600bb.jpg").heroArtworkURL
        == URL(string: "\(image)/1200x1200bb.jpg"))
    #expect(
      result(large: "\(image)/600x600bb.png").heroArtworkURL
        == URL(string: "\(image)/1200x1200bb.png"))
    // Only the directory's own image host, only its size segment, and never a guessed URL.
    #expect(result(large: "https://images.example/600x600bb.jpg").heroArtworkURL == nil)
    #expect(result(large: "https://mzstatic.com.example/a/600x600bb.jpg").heroArtworkURL == nil)
    #expect(result(large: "\(image)/100x100bb.jpg").heroArtworkURL == nil)
    #expect(result(large: "\(image)/600x600bb.jpg?x=1").heroArtworkURL == nil)
    #expect(result(large: nil).heroArtworkURL == nil)
  }

  @Test("coalesces simultaneous identical searches")
  func coalescing() async throws {
    let transport = FakeRedirectCustomizingHTTPClienting(fallback: .success(Self.response()))
    transport.gate.hold()
    let client = PodcastDirectorySearchClient(httpClient: transport)
    let first = Task { try await client.search(term: "swift") }
    let second = Task { try await client.search(term: "swift") }

    #expect(
      await waitUntil("the coalesced search request to arrive") {
        transport.requests.count == 1
      })
    transport.gate.release(nil)
    _ = try await first.value
    _ = try await second.value
    #expect(transport.requests.count == 1)
  }

  @Test("caps even an overlarge successful result list")
  func resultCap() async throws {
    let rows: [[String: Any]] = (0..<40).map { index in
      [
        "feedUrl": "https://feeds.example/\(index).xml",
        "collectionName": "Show \(index)",
      ]
    }
    let body = try JSONSerialization.data(withJSONObject: ["results": rows])
    let client = PodcastDirectorySearchClient(
      httpClient: FakeRedirectCustomizingHTTPClienting(
        fallback: .success(HTTPResponse(statusCode: 200, headers: [:], body: body))))

    let results = try await client.search(term: "shows")

    #expect(results.count == PodcastDirectorySearchClient.maximumResults)
  }

  @Test("rejects empty terms and malformed JSON")
  func errors() async throws {
    let malformed = FakeRedirectCustomizingHTTPClienting(
      fallback: .success(
        HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))))
    let client = PodcastDirectorySearchClient(httpClient: malformed)
    await #expect(throws: PodcastDirectorySearchError.emptyQuery) {
      try await client.search(term: "  ")
    }
    await #expect(throws: PodcastDirectorySearchError.queryTooLong) {
      try await client.search(
        term: String(repeating: "x", count: PodcastDirectorySearchClient.maximumQueryCharacters + 1))
    }
    await #expect(throws: PodcastDirectorySearchError.invalidResponse) {
      try await client.search(term: "valid")
    }
    #expect(malformed.requests.count == 1)
  }

  private static func response() -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"results\":[]}".utf8))
  }
}
