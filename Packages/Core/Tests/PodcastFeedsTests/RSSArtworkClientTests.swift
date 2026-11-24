import ABSApi
import Foundation
import TestSupport
import Testing

@testable import PodcastFeeds

@Suite("RSS artwork client")
struct RSSArtworkClientTests {
  @Test("uses a two-request pool independent of other RSS transports")
  func twoRequestGate() async throws {
    let transport = artworkTransport(responses: [imageResponse(Data([2]))])
    transport.gate.hold()
    let client = RSSArtworkClient(
      httpClient: transport, cache: isolatedCache(), authorization: NoRSSArtworkAuthorization())
    let keys = try (0..<3).map { try artworkKey(feedID: "rss:\($0)", image: "\($0).png") }
    let tasks = keys.map { key in Task { try await client.fetch(key) } }

    #expect(
      await waitUntil("the artwork gate to admit two requests") {
        transport.requests.count == 2
      })
    #expect(transport.maxInFlight == 2)
    transport.gate.release(imageResponse(Data([1])))
    #expect(
      await waitUntil("the third artwork request to be admitted") {
        transport.requests.count == 3
      })
    for task in tasks { _ = try await task.value }
  }

  @Test("credentials are admitted only for exact-origin followed-feed artwork")
  func exactOriginCredentials() async throws {
    let credentials = RecordingArtworkCredentials(value: "Bearer feed-secret")
    let transport = artworkTransport(responses: [
      imageResponse(Data([1])), imageResponse(Data([2])), imageResponse(Data([3])),
    ])
    let client = RSSArtworkClient(
      httpClient: transport, cache: isolatedCache(), authorization: credentials)

    _ = try await client.fetch(
      artworkKey(
        feedID: "rss:1", imageURL: "https://feeds.example.test/image.png",
        feedURL: "https://feeds.example.test/show.xml"))
    _ = try await client.fetch(
      artworkKey(
        feedID: "rss:2", imageURL: "https://cdn.example.test/image.png",
        feedURL: "https://feeds.example.test/show.xml"))
    _ = try await client.fetch(
      artworkKey(feedID: "directory:https://example.test/feed", imageURL: "https://cdn.example.test/directory.png"))

    let requests = transport.requests
    #expect(requests[0].headers["Authorization"] == "Bearer feed-secret")
    #expect(requests[1].headers["Authorization"] == nil)
    #expect(requests[2].headers["Authorization"] == nil)
    #expect(await credentials.requestedFeedIDs == ["rss:1"])
  }

  @Test("credential-backed artwork authorization is feed-scoped")
  func credentialBackedAuthorizationIsFeedScoped() async throws {
    let transport = artworkTransport(responses: [
      imageResponse(Data([1])), imageResponse(Data([2])), imageResponse(Data([3])),
      imageResponse(Data([4])),
    ])
    let credentialStore = InMemoryFeedCredentialStore()
    let secret = "Bearer feed-one-secret"
    try credentialStore.save(FeedCredential(authorization: secret), forFeedID: 1)
    let client = RSSArtworkClient(
      httpClient: transport,
      cache: isolatedCache(),
      authorization: RSSArtworkAuthorization(credentialStore: credentialStore))

    _ = try await client.fetch(
      artworkKey(
        feedID: "rss:1", imageURL: "https://feeds.example.test/one.png",
        feedURL: "https://feeds.example.test/show.xml"))
    _ = try await client.fetch(
      artworkKey(
        feedID: "rss:2", imageURL: "https://feeds.example.test/two.png",
        feedURL: "https://feeds.example.test/show.xml"))
    _ = try await client.fetch(
      artworkKey(
        feedID: "rss:1", imageURL: "https://cdn.example.test/one.png",
        feedURL: "https://feeds.example.test/show.xml"))
    _ = try await client.fetch(
      artworkKey(feedID: "rss:1", imageURL: "https://feeds.example.test/directory.png"))

    let requests = transport.requests
    #expect(requests.count == 4)
    #expect(requests[0].headers["Authorization"] == secret)
    #expect(requests[1].headers["Authorization"] == nil)
    #expect(requests[2].headers["Authorization"] == nil)
    #expect(requests[3].headers["Authorization"] == nil)
  }

  @Test("artwork authorization descriptions never reveal credentials")
  func artworkAuthorizationDescriptionsAreRedacted() throws {
    let credentialStore = InMemoryFeedCredentialStore()
    // Kept under the release audit's 24-character `Bearer` literal threshold
    // (`ReleaseAuditTests.literalTokenMatch`): a canary long enough to look like a real pasted
    // token would trip the repository's own secret scan, which is working as intended.
    let secret = "Bearer artwork-canary"
    try credentialStore.save(FeedCredential(authorization: secret), forFeedID: 1)
    let authorization = RSSArtworkAuthorization(credentialStore: credentialStore)

    #expect(String(describing: authorization).contains(secret) == false)
    #expect(String(reflecting: authorization).contains(secret) == false)
  }

  @Test("validator change refreshes bytes under the same cache identity")
  func validatorRefreshKeepsIdentity() async throws {
    let clock = ArtworkClock(Date(timeIntervalSince1970: 100))
    let transport = artworkTransport(responses: [
      imageResponse(Data([1]), headers: ["ETag": "\"one\""]),
      imageResponse(Data([2]), headers: ["ETag": "\"two\""]),
    ])
    let client = RSSArtworkClient(
      httpClient: transport, cache: isolatedCache(), authorization: NoRSSArtworkAuthorization(),
      now: { clock.now() },
      revalidationInterval: 60)
    let key = try artworkKey(feedID: "rss:1", image: "show.png")

    #expect(try await client.fetch(key).data == Data([1]))
    #expect(await client.needsRefresh(key) == false)
    clock.advance(61)
    #expect(await client.needsRefresh(key))
    #expect(try await client.fetch(key).data == Data([2]))

    let requests = transport.requests
    #expect(requests[1].headers["If-None-Match"] == "\"one\"")
    #expect(key == key)
  }

  @Test("validator state rehydrates for a second client sharing a URLCache")
  func validationRehydratesAcrossClientInstances() async throws {
    let cache = isolatedCache()
    let transport = artworkTransport(responses: [
      imageResponse(Data([1]), headers: ["ETag": "\"one\"", "Last-Modified": "yesterday"])
    ])
    let key = try artworkKey(feedID: "rss:1", image: "show.png")
    let firstClient = RSSArtworkClient(
      httpClient: transport, cache: cache, authorization: NoRSSArtworkAuthorization())

    _ = try await firstClient.fetch(key)

    let secondTransport = artworkTransport()
    let secondClient = RSSArtworkClient(
      httpClient: secondTransport, cache: cache, authorization: NoRSSArtworkAuthorization())
    #expect(await secondClient.needsRefresh(key) == false)
    #expect(try await secondClient.fetch(key).data == Data([1]))
    #expect(secondTransport.requests.isEmpty)
  }

  @Test("validator state survives a second URLCache instance on disk")
  func validationRehydratesAcrossDiskCacheInstances() async throws {
    let (directory, firstCache) = try makeDiskBackedCache()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try artworkKey(feedID: "rss:1", image: "show.png")
    let artworkURL = try artworkURL(for: key)
    let request = URLRequest(url: artworkURL)
    let firstTransport = artworkTransport(responses: [
      imageResponse(Data([1]), headers: ["ETag": "\"one\""])
    ])
    let firstClient = RSSArtworkClient(
      httpClient: firstTransport, cache: firstCache, authorization: NoRSSArtworkAuthorization())

    _ = try await firstClient.fetch(key)

    let secondCache = diskBackedCache(directory: directory)
    #expect(
      await waitUntil("the RSS artwork entry to reach disk") {
        secondCache.cachedResponse(for: request)?.data == Data([1])
      })
    let secondTransport = artworkTransport()
    let secondClient = RSSArtworkClient(
      httpClient: secondTransport, cache: secondCache, authorization: NoRSSArtworkAuthorization())

    #expect(await secondClient.needsRefresh(key) == false)
    #expect(try await secondClient.fetch(key).data == Data([1]))
    #expect(secondTransport.requests.isEmpty)
  }

  @Test("persisted validators drive conditional revalidation and re-stamp a 304")
  func persistedValidatorsRevalidateConditionally() async throws {
    let clock = ArtworkClock(Date(timeIntervalSince1970: 100))
    let cache = isolatedCache()
    let key = try artworkKey(feedID: "rss:1", image: "show.png")
    let firstClient = RSSArtworkClient(
      httpClient: artworkTransport(responses: [
        imageResponse(
          Data([1]),
          headers: ["ETag": "\"quoted-etag\"", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"])
      ]),
      cache: cache,
      authorization: NoRSSArtworkAuthorization(),
      now: { clock.now() })
    _ = try await firstClient.fetch(key)

    clock.advance(RSSArtworkClient.defaultRevalidationInterval + 1)
    let secondTransport = artworkTransport(responses: [
      HTTPResponse(statusCode: 304, headers: [:], body: Data())
    ])
    let secondClient = RSSArtworkClient(
      httpClient: secondTransport, cache: cache, authorization: NoRSSArtworkAuthorization(),
      now: { clock.now() })

    #expect(await secondClient.needsRefresh(key))
    #expect(try await secondClient.fetch(key).data == Data([1]))
    let requestHeaders = try #require(secondTransport.requests.first?.headers)
    #expect(requestHeaders["If-None-Match"] == "\"quoted-etag\"")
    #expect(requestHeaders["If-Modified-Since"] == "Wed, 21 Oct 2015 07:28:00 GMT")

    let thirdClient = RSSArtworkClient(
      httpClient: artworkTransport(), cache: cache, authorization: NoRSSArtworkAuthorization(),
      now: { clock.now() })
    #expect(await thirdClient.needsRefresh(key) == false)
  }

  @Test("a bare URLResponse entry revalidates unconditionally and is rewritten")
  func oldBuildEntryRevalidatesWithoutValidators() async throws {
    let cache = isolatedCache()
    let key = try artworkKey(feedID: "rss:1", image: "show.png")
    let artworkURL = try artworkURL(for: key)
    let body = Data([7])
    cache.storeCachedResponse(
      CachedURLResponse(
        response: URLResponse(
          url: artworkURL, mimeType: "image/png", expectedContentLength: body.count,
          textEncodingName: nil),
        data: body),
      for: URLRequest(url: artworkURL))
    let transport = artworkTransport(responses: [
      imageResponse(Data([8]), headers: ["ETag": "\"new\""])
    ])
    let client = RSSArtworkClient(
      httpClient: transport, cache: cache, authorization: NoRSSArtworkAuthorization())

    #expect(await client.needsRefresh(key))
    #expect(try await client.fetch(key).data == Data([8]))
    let requestHeaders = try #require(transport.requests.first?.headers)
    #expect(requestHeaders["If-None-Match"] == nil)
    #expect(requestHeaders["If-Modified-Since"] == nil)
    let rewritten = try #require(cache.cachedResponse(for: URLRequest(url: artworkURL)))
    #expect(rewritten.response is HTTPURLResponse)
    #expect(rewritten.userInfo?.values.contains { $0 is Date } == true)
  }

  @Test("304 reuses admitted cached bytes")
  func notModifiedUsesCachedBytes() async throws {
    let clock = ArtworkClock(Date(timeIntervalSince1970: 100))
    let transport = artworkTransport(responses: [
      imageResponse(Data([9]), headers: ["Last-Modified": "yesterday"]),
      HTTPResponse(statusCode: 304, headers: [:], body: Data()),
    ])
    let client = RSSArtworkClient(
      httpClient: transport, cache: isolatedCache(), authorization: NoRSSArtworkAuthorization(),
      now: { clock.now() },
      revalidationInterval: 10)
    let key = try artworkKey(feedID: "rss:1", image: "show.png")

    _ = try await client.fetch(key)
    clock.advance(11)
    #expect(try await client.fetch(key).data == Data([9]))
    #expect(transport.requests[1].headers["If-Modified-Since"] == "yesterday")
  }

  @Test("validator-less entries periodically revalidate without minting a new identity")
  func validatorlessEntryRevalidatesInPlace() async throws {
    let clock = ArtworkClock(Date(timeIntervalSince1970: 100))
    let transport = artworkTransport(responses: [
      imageResponse(Data([1])), imageResponse(Data([2])),
    ])
    let client = RSSArtworkClient(
      httpClient: transport, cache: isolatedCache(), authorization: NoRSSArtworkAuthorization(),
      now: { clock.now() },
      revalidationInterval: 10)
    let key = try artworkKey(feedID: "rss:1", image: "show.png")

    #expect(try await client.fetch(key).data == Data([1]))
    clock.advance(11)
    #expect(await client.needsRefresh(key))
    #expect(try await client.fetch(key).data == Data([2]))
    let requests = transport.requests
    #expect(requests[1].headers["If-None-Match"] == nil)
    #expect(requests[1].headers["If-Modified-Since"] == nil)
  }

  @Test("existing cover byte and MIME admission applies unchanged")
  func admission() async throws {
    let wrongMIME = RSSArtworkClient(
      httpClient: artworkTransport(responses: [
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html"], body: Data([1]))
      ]),
      cache: isolatedCache(), authorization: NoRSSArtworkAuthorization())
    await #expect(throws: APIError.decoding) {
      try await wrongMIME.fetch(artworkKey(feedID: "rss:1", image: "bad.png"))
    }

    let oversized = RSSArtworkClient(
      httpClient: artworkTransport(responses: [
        imageResponse(Data(repeating: 1, count: CoverImageAdmission.maximumResponseBytes + 1))
      ]),
      cache: isolatedCache(), authorization: NoRSSArtworkAuthorization())
    await #expect(throws: APIError.payloadTooLarge) {
      try await oversized.fetch(artworkKey(feedID: "rss:2", image: "large.png"))
    }
  }

  private func artworkKey(feedID: String, image: String) throws -> ArtworkKey {
    try artworkKey(
      feedID: feedID, imageURL: "https://images.example.test/\(image)",
      feedURL: "https://feeds.example.test/show.xml")
  }

  private func artworkURL(for key: ArtworkKey) throws -> URL {
    guard case .rss(let source) = key.source else { throw APIError.decoding }
    return source.artworkURL
  }

  private func artworkKey(
    feedID: String, imageURL: String, feedURL: String? = nil
  ) throws -> ArtworkKey {
    let imageURL = try #require(URL(string: imageURL))
    let feedURL = try feedURL.map { value in try #require(URL(string: value)) }
    let source = try #require(
      RSSArtworkSource(
        feedIdentity: feedID,
        artworkURL: imageURL,
        feedURL: feedURL))
    return ArtworkKey(
      source: .rss(source), itemID: feedID,
      variant: .libraryThumbnail(pixelWidth: 88), revision: .unversioned)
  }

  private func isolatedCache() -> URLCache {
    URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0, diskPath: nil)
  }

  private func makeDiskBackedCache() throws -> (directory: URL, cache: URLCache) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RSSArtworkClientTests-disk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, diskBackedCache(directory: directory))
  }

  private func diskBackedCache(directory: URL) -> URLCache {
    URLCache(
      memoryCapacity: 20 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, directory: directory)
  }

  private func imageResponse(
    _ data: Data, headers: [String: String] = [:]
  ) -> HTTPResponse {
    var headers = headers
    headers["Content-Type"] = "image/png"
    return HTTPResponse(statusCode: 200, headers: headers, body: data)
  }
}

/// A transport that answers from `responses`, then fails the way an unreachable network does.
private func artworkTransport(
  responses: [HTTPResponse] = []
) -> FakeRedirectCustomizingHTTPClienting {
  FakeRedirectCustomizingHTTPClienting(
    responses: responses.map { Result<HTTPResponse, any Error>.success($0) },
    fallback: .failure(APIError.transport))
}

private actor RecordingArtworkCredentials: RSSArtworkAuthorizationProviding {
  let value: String?
  private(set) var requestedFeedIDs: [String] = []

  init(value: String?) { self.value = value }

  func authorizationHeader(for feedIdentity: String) -> String? {
    requestedFeedIDs.append(feedIdentity)
    return value
  }
}

private final class ArtworkClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) { self.value = value }

  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
