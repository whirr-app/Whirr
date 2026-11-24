import ABSApi
import Foundation
import GRDB
import Persistence
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite("RSS podcast refreshing")
struct RSSPodcastRefreshingTests {
  private let feedURL = URL(string: "https://feeds.example.test/show.xml")!

  @Test func refreshPersistsMetadataEpisodesTimestampAndValidators() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(feedResponse(headers: validators))
    ])
    let refreshedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: refreshedAt)

    #expect(try await service.refresh(itemID: "rss:\(feedID)") == .complete)

    let feed = try #require(try await feedStore.fetchFeed(feedId: feedID))
    #expect(feed.title == "Parsed show")
    #expect(feed.author == "Parsed author")
    #expect(feed.language == "en-GB")
    #expect(feed.lastRefreshedAt == refreshedAt)
    #expect(feed.refreshGeneration == 1)
    #expect(feed.etag == "\"v1\"")
    let episode = try #require(try await episodeRows(database, feedID: feedID).first)
    #expect(episode.guid == "episode-one")
    #expect(episode.durationSeconds == 3_723)
    #expect(episode.seasonNumber == 1)
    #expect(episode.episodeNumber == 2)
  }

  @Test("cloud sync hears of a refresh only once its episodes have committed")
  func cloudSyncHearsOfARefreshOnlyOnceItsEpisodesHaveCommitted() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(feedResponse(headers: validators)),
      .success(HTTPResponse(statusCode: 304, headers: [:], body: Data())),
    ])
    let observer = RecordingRefreshCommitObserver(database: database)
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date(),
      cloudRefreshObserver: observer)

    _ = try await service.refresh(itemID: "rss:\(feedID)")
    #expect(await observer.calls == [RecordingRefreshCommitObserver.Call(feedId: feedID, episodeCount: 1)])

    // Not modified: nothing new committed, so there is nothing new to resolve against.
    _ = try await service.refresh(itemID: "rss:\(feedID)")
    #expect(await observer.calls.count == 1)
  }

  @Test func recoveryMarkerSuppressesTargetedRefreshUntilCleared() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await feedStore.subscribe(
      feedURL: feedURL, title: "Private", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date(), recoveryReason: .credentialStorageFailed)
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(feedResponse(headers: [:]))
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date(),
      recoveryReading: feedStore)

    #expect(try await service.refresh(itemID: "rss:\(feedID)") == .complete)
    #expect(transport.requests.isEmpty)

    try await feedStore.clearRecovery(feedId: feedID)
    #expect(try await service.refresh(itemID: "rss:\(feedID)") == .complete)
    #expect(transport.requests.count == 1)
  }

  @Test("a refresh stores the description's plain line beside the description")
  func aRefreshStoresThePlainLineBesideTheDescription() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let body = feedXML(items: [
      Self.episodeXML(
        guid: "html", title: "HTML",
        description: "<![CDATA[<p>Hello &amp; <b>world</b></p>]]>")
    ])
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())

    _ = try await service.refresh(itemID: "rss:\(feedID)")

    let stored = try #require(try await episodeRows(database, feedID: feedID).first)
    #expect(stored.synopsis == "<p>Hello &amp; <b>world</b></p>")
    #expect(stored.synopsisLine == "Hello & world")
  }

  @Test("an item image that differs from the show's art is stored as episode artwork")
  func anItemImageDifferingFromTheShowIsStored() async throws {
    let stored = try await storedEpisodeArtwork(itemArtwork: "https://feeds.example.test/ep.png")
    #expect(stored == "https://feeds.example.test/ep.png")
  }

  @Test("an item image equal to the show's art is not stored as episode artwork")
  func anItemImageEqualToTheShowIsNotStored() async throws {
    let stored = try await storedEpisodeArtwork(itemArtwork: "https://feeds.example.test/art.png")
    #expect(stored == nil)
  }

  @Test("an item image equal to the show's art except for host case is not stored")
  func anItemImageEqualExceptHostCaseIsNotStored() async throws {
    let stored = try await storedEpisodeArtwork(itemArtwork: "HTTPS://Feeds.Example.Test/art.png")
    #expect(stored == nil)
  }

  @Test("an item image equal to the show's art except for a default port is not stored")
  func anItemImageEqualExceptDefaultPortIsNotStored() async throws {
    let stored = try await storedEpisodeArtwork(
      itemArtwork: "https://feeds.example.test:443/art.png")
    #expect(stored == nil)
  }

  @Test("an item without an image stores no episode artwork")
  func anItemWithoutAnImageStoresNoEpisodeArtwork() async throws {
    let stored = try await storedEpisodeArtwork(itemArtwork: nil)
    #expect(stored == nil)
  }

  @Test func aRefreshStoresContentEncodedForTheCardAndKeepsTheLineFromTheDescription() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let body = feedXML(items: [
      Self.episodeXML(
        guid: "both", title: "Both", description: "Short teaser",
        content: "<![CDATA[<h2>Heading</h2><p>Full notes</p>]]>"),
      Self.episodeXML(
        guid: "content-only", title: "Content only", description: nil,
        content: "<![CDATA[<p>Only notes</p>]]>"),
    ])
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())

    _ = try await service.refresh(itemID: "rss:\(feedID)")

    let rows = try await episodeRows(database, feedID: feedID)
    let both = try #require(rows.first { $0.guid == "both" })
    #expect(both.synopsis == "<h2>Heading</h2><p>Full notes</p>")
    #expect(both.synopsisLine == "Short teaser")
    let contentOnly = try #require(rows.first { $0.guid == "content-only" })
    #expect(contentOnly.synopsis == "<p>Only notes</p>")
    #expect(contentOnly.synopsisLine == "Only notes")
  }

  @Test func notModifiedReplaysValidatorsAndPreservesGeneration() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(feedResponse(headers: validators)),
      .success(HTTPResponse(statusCode: 304, headers: [:], body: Data())),
    ])
    let first = makeService(
      feedStore: feedStore, database: database, transport: transport,
      now: Date(timeIntervalSince1970: 100))
    _ = try await first.refresh(itemID: "rss:\(feedID)")
    let second = makeService(
      feedStore: feedStore, database: database, transport: transport,
      now: Date(timeIntervalSince1970: 200))

    #expect(try await second.refresh(itemID: "rss:\(feedID)") == .complete)

    let requests = transport.requests
    #expect(requests[1].headers["If-None-Match"] == "\"v1\"")
    #expect(requests[1].headers["If-Modified-Since"] == validators["Last-Modified"])
    #expect(try await feedStore.fetchFeed(feedId: feedID)?.refreshGeneration == 1)
    #expect(try await feedStore.fetchFeed(feedId: feedID)?.language == "en-GB")
  }

  @Test func aRecentlyRefreshedShowAnswersFromTheCacheOnAppear() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let itemID = "rss:\(feedID)"
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(feedResponse(headers: validators)),
      .success(HTTPResponse(statusCode: 304, headers: [:], body: Data())),
      .success(HTTPResponse(statusCode: 304, headers: [:], body: Data())),
      .success(HTTPResponse(statusCode: 304, headers: [:], body: Data())),
    ])
    func service(now: TimeInterval) -> RSSPodcastRefreshing {
      makeService(
        feedStore: feedStore, database: database, transport: transport,
        now: Date(timeIntervalSince1970: now))
    }

    // Never refreshed: there is no cache to answer from.
    #expect(try await service(now: 100).refreshIfStale(itemID: itemID, maximumAge: 300) == .complete)
    #expect(transport.requests.count == 1)
    // Younger than the maximum age: no request at all.
    #expect(try await service(now: 200).refreshIfStale(itemID: itemID, maximumAge: 300) == .complete)
    #expect(transport.requests.count == 1)
    // Older than the maximum age: refreshes, and records the new time.
    #expect(try await service(now: 500).refreshIfStale(itemID: itemID, maximumAge: 300) == .complete)
    #expect(transport.requests.count == 2)
    #expect(try await feedStore.fetchFeed(feedId: feedID)?.lastRefreshedAt == Date(timeIntervalSince1970: 500))
    // A recorded time in the future is not a fresh cache.
    #expect(try await service(now: 400).refreshIfStale(itemID: itemID, maximumAge: 300) == .complete)
    #expect(transport.requests.count == 3)
    // The ungated refresh never consults the age.
    #expect(try await service(now: 401).refresh(itemID: itemID) == .complete)
    #expect(transport.requests.count == 4)
  }

  @Test func malformedResponseDoesNotReplaceAcceptedValidators() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    try await feedStore.storeValidators(
      etag: "\"accepted\"", lastModified: "accepted-date", feedURL: feedURL)
    let malformed = HTTPResponse(
      statusCode: 200, headers: ["ETag": "\"poison\"", "Last-Modified": "poison-date"],
      body: Data("<rss><channel><title>Broken</title>".utf8))
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [.success(malformed)])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())

    await #expect(throws: FeedParseError.self) {
      try await service.refresh(itemID: "rss:\(feedID)")
    }

    let feed = try #require(try await feedStore.fetchFeed(feedId: feedID))
    #expect(feed.etag == "\"accepted\"")
    #expect(feed.lastModified == "accepted-date")
  }

  @Test func missingEnclosureProducesPartialOutcomeWithoutDroppingValidItem() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let body = feedXML(items: [
      Self.episodeXML(guid: "valid", title: "Valid"),
      "<item><title>Broken</title></item>",
    ])
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())

    #expect(try await service.refresh(itemID: "rss:\(feedID)") == .partial)
    #expect(try await episodeRows(database, feedID: feedID).map(\.guid) == ["valid"])
  }

  @Test func canonicalFallbackRekeysLegacyRowAndPreservesListeningState() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let episodeStore = RSSEpisodeStore(database: database)
    let enclosure = try #require(URL(string: "https://feeds.example.test/no-guid.mp3"))
    let rawDate = "Mon, 01 Jan 2024 00:00:00 GMT"
    let identity = try #require(
      EpisodeIdentityPolicy.identities(
        for: [
          ParsedFeedItem(
            guid: nil, title: "No GUID", enclosure: .init(url: enclosure, type: "audio/mpeg", lengthBytes: 123),
            pubDate: rawDate, durationText: nil)
        ])[0])
    let legacyKey = try #require(identity.alternateKey)
    _ = try await episodeStore.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: legacyKey, title: "Before upgrade", enclosureURL: enclosure)
      ])
    let originalID = try #require(try await episodeRows(database, feedID: feedID).first?.id)
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt) VALUES (?, ?, ?, ?)",
        arguments: [originalID, 42.5, 1, Date()])
    }

    let body = feedXML(items: [Self.episodeWithoutGUIDXML(pubDate: rawDate)])
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())

    #expect(try await service.refresh(itemID: "rss:\(feedID)") == .complete)

    let rows = try await episodeRows(database, feedID: feedID)
    #expect(rows.count == 1)
    #expect(rows[0].id == originalID)
    #expect(rows[0].identityKey == identity.key)
    #expect(rows[0].alternateIdentityKey == legacyKey)
    #expect(
      try await database.readAsync { db in
        try Double.fetchOne(
          db, sql: "SELECT position FROM rssEpisodeState WHERE episodeId = ?", arguments: [originalID])
      } == 42.5)
  }

  @Test func changedGUIDReconcilesAnOldRawDateAlternateOnFirstUpgradeRefresh() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let episodeStore = RSSEpisodeStore(database: database)
    let enclosure = try #require(URL(string: "https://feeds.example.test/no-guid.mp3"))
    let rawDate = "Mon, 01 Jan 2024 00:00:00 GMT"
    let fallback = try #require(
      EpisodeIdentityPolicy.identities(
        for: [
          ParsedFeedItem(
            guid: nil, title: nil, enclosure: .init(url: enclosure, type: "audio/mpeg", lengthBytes: 123),
            pubDate: rawDate, durationText: nil)
        ])[0])
    let legacyKey = try #require(fallback.alternateKey)
    _ = try await episodeStore.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:old", alternateIdentityKey: legacyKey, guid: "old",
          title: "Before upgrade", enclosureURL: enclosure)
      ])
    let originalID = try #require(try await episodeRows(database, feedID: feedID).first?.id)
    let body = feedXML(items: [Self.episodeWithGUIDXML(guid: "new", pubDate: rawDate)])
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())

    #expect(try await service.refresh(itemID: "rss:\(feedID)") == .complete)

    let rows = try await episodeRows(database, feedID: feedID)
    #expect(rows.count == 1)
    #expect(rows[0].id == originalID)
    #expect(rows[0].identityKey == "guid:new")
    #expect(rows[0].alternateIdentityKey == legacyKey)
  }

  @Test func unknownFeedCompletesWithoutNetworkAndFailuresPropagate() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())
    #expect(try await service.refresh(itemID: "rss:999") == .complete)
    #expect(transport.requests.isEmpty)

    let feedID = try await subscribe(feedStore)
    let failing = FakeRedirectCustomizingHTTPClienting(responses: [.failure(TestTransportError())])
    let failingService = makeService(
      feedStore: feedStore, database: database, transport: failing, now: Date())
    await #expect(throws: TestTransportError.self) {
      try await failingService.refresh(itemID: "rss:\(feedID)")
    }
  }

  @Test func refreshUsesTheCredentialStoredForThatFeedIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let credentials = InMemoryFeedCredentialStore()
    let credential = try FeedCredential.basic(username: "refresh-user", password: "refresh-pass")
    try credentials.save(credential, forFeedID: feedID)
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [.success(feedResponse(headers: [:]))])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date(),
      credentialStore: credentials)

    _ = try await service.refresh(itemID: "rss:\(feedID)")

    #expect(transport.requests.first?.headers["Authorization"] == credential.authorization)
  }

  @Test func refreshDoesNotBorrowCredentialFromAnotherFeedIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let firstFeedID = try await subscribe(feedStore)
    let secondFeedID = try await subscribe(
      feedStore, url: URL(string: "https://feeds.example.test/other-show.xml")!)
    let credentials = InMemoryFeedCredentialStore()
    let secondCredential = try FeedCredential.basic(
      username: "second-feed-user", password: "second-feed-password")
    try credentials.save(secondCredential, forFeedID: secondFeedID)
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(feedResponse(headers: [:])), .success(feedResponse(headers: [:])),
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date(),
      credentialStore: credentials)

    _ = try await service.refresh(itemID: "rss:\(firstFeedID)")
    _ = try await service.refresh(itemID: "rss:\(secondFeedID)")

    let requests = transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].headers["Authorization"] == nil)
    #expect(requests[1].headers["Authorization"] == secondCredential.authorization)
  }

  @Test func coalescedBackgroundWaiterSuppliesTheCurrentDiscoveryClassification() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let baselineTransport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(
        HTTPResponse(
          statusCode: 200, headers: [:],
          body: Data(feedXML(items: [Self.episodeXML(guid: "old", title: "Old")]).utf8)))
    ])
    let discoveredAt = Date(timeIntervalSince1970: 1_800_000_000)
    let baseline = makeService(
      feedStore: feedStore, database: database, transport: baselineTransport,
      now: discoveredAt.addingTimeInterval(-60))
    _ = try await baseline.refresh(itemID: "rss:\(feedID)")

    let coalescedTransport = FakeRedirectCustomizingHTTPClienting(
      responses: [
        .success(
          HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(
              feedXML(items: [
                Self.episodeXML(guid: "old", title: "Old"),
                Self.episodeXML(guid: "new", title: "New"),
              ]).utf8)))
      ])
    coalescedTransport.gate.hold()
    let service = makeService(
      feedStore: feedStore, database: database, transport: coalescedTransport, now: discoveredAt)
    let foreground = Task {
      try await RSSNotificationDiscoveryScope.$context.withValue(
        .foreground(discoveredAt: discoveredAt)
      ) {
        try await service.refresh(itemID: "rss:\(feedID)")
      }
    }
    await coalescedTransport.recorder.waitUntil(count: 1)
    let background = Task {
      try await RSSNotificationDiscoveryScope.$context.withValue(
        .background(globalEnabled: true, discoveredAt: discoveredAt)
      ) {
        try await service.refresh(itemID: "rss:\(feedID)")
      }
    }
    _ = await awaitCondition("the background caller joins the foreground feed flight") {
      await service.joinedFlightCount == 1
    }

    coalescedTransport.gate.release(nil)
    _ = try await foreground.value
    _ = try await background.value

    let disposition: RSSNotificationDisposition? = try await database.readAsync { db in
      try RSSNotificationDisposition.fetchOne(
        db,
        sql: "SELECT disposition FROM rssEpisodeNotificationLedger WHERE feedId = ? AND identityKey = ?",
        arguments: [feedID, "guid:new"])
    }
    #expect(disposition == .pending)
  }

  private func storedEpisodeArtwork(itemArtwork: String?) async throws -> String? {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await subscribe(feedStore)
    let body = feedXML(items: [Self.episodeXML(guid: "art", title: "Art", artwork: itemArtwork)])
    let transport = FakeRedirectCustomizingHTTPClienting(responses: [
      .success(HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))
    ])
    let service = makeService(
      feedStore: feedStore, database: database, transport: transport, now: Date())

    _ = try await service.refresh(itemID: "rss:\(feedID)")

    return try #require(try await episodeRows(database, feedID: feedID).first).artworkURL
  }

  private func subscribe(_ store: RSSFeedStore, url: URL? = nil) async throws -> Int64 {
    try await store.subscribe(
      feedURL: url ?? feedURL, title: "Subscribed", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())
  }

  private func makeService(
    feedStore: RSSFeedStore,
    database: AppDatabase,
    transport: FakeRedirectCustomizingHTTPClienting,
    now: Date,
    credentialStore: (any FeedCredentialStoring)? = nil,
    recoveryReading: any NativeFeedRecoveryReading = NoOpNativeFeedRecoveryReading(),
    cloudRefreshObserver: (any PodcastRefreshCommitObserving)? = nil
  ) -> RSSPodcastRefreshing {
    RSSPodcastRefreshing(
      feedStore: feedStore,
      episodeStore: RSSEpisodeStore(database: database),
      fetchClient: FeedFetchClient(
        httpClient: transport, validatorStore: RSSFeedValidatorStore(store: feedStore),
        credentialStore: credentialStore),
      recoveryReading: recoveryReading,
      cloudRefreshObserver: cloudRefreshObserver,
      now: { now })
  }

  private func episodeRows(_ database: AppDatabase, feedID: Int64) async throws
    -> [RSSEpisodeRecord]
  {
    try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY id", arguments: [feedID])
    }
  }

  private var validators: [String: String] {
    ["ETag": "\"v1\"", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"]
  }

  private func feedResponse(headers: [String: String]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: headers, body: Data(feedXML().utf8))
  }

  private func feedXML(
    items: [String] = [Self.episodeXML(guid: "episode-one", title: "Episode one")]
  ) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
      <channel>
        <title>Parsed show</title>
        <itunes:author>Parsed author</itunes:author>
        <itunes:summary>Parsed synopsis</itunes:summary>
        <language>en-GB</language>
        <image><url>https://feeds.example.test/art.png</url></image>
        \(items.joined())
      </channel>
    </rss>
    """
  }

  private static func episodeXML(
    guid: String, title: String, description: String? = "Episode synopsis", content: String? = nil,
    artwork: String? = nil
  ) -> String {
    """
    <item>
      <guid>\(guid)</guid><title>\(title)</title>
      \(description.map { "<description>\($0)</description>" } ?? "")
      \(content.map { "<content:encoded>\($0)</content:encoded>" } ?? "")
      \(artwork.map { "<itunes:image href=\"\($0)\"/>" } ?? "")
      <enclosure url="https://feeds.example.test/\(guid).mp3" type="audio/mpeg" length="123"/>
      <pubDate>Wed, 21 Oct 2015 07:28:00 GMT</pubDate>
      <itunes:duration>1:02:03</itunes:duration><itunes:season>1</itunes:season><itunes:episode>2</itunes:episode>
    </item>
    """
  }

  private static func episodeWithoutGUIDXML(pubDate: String) -> String {
    """
    <item>
      <title>No GUID</title>
      <enclosure url="https://feeds.example.test/no-guid.mp3" type="audio/mpeg" length="123"/>
      <pubDate>\(pubDate)</pubDate>
    </item>
    """
  }

  private static func episodeWithGUIDXML(guid: String, pubDate: String) -> String {
    """
    <item>
      <guid>\(guid)</guid><title>Changed GUID</title>
      <enclosure url="https://feeds.example.test/no-guid.mp3" type="audio/mpeg" length="123"/>
      <pubDate>\(pubDate)</pubDate>
    </item>
    """
  }
}

private struct TestTransportError: Error, Sendable, Equatable {}

private actor RecordingRefreshCommitObserver: PodcastRefreshCommitObserving {
  struct Call: Equatable {
    let feedId: Int64
    let episodeCount: Int
  }

  let database: AppDatabase
  private(set) var calls: [Call] = []

  init(database: AppDatabase) {
    self.database = database
  }

  func feedRefreshCommitted(feedId: Int64) async {
    let count =
      (try? await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
      }) ?? nil
    calls.append(Call(feedId: feedId, episodeCount: count ?? -1))
  }
}
