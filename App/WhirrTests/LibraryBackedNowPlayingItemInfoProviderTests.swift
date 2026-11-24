import ABSApi
import Foundation
import Persistence
import PodcastFeeds
import Testing

@testable import Whirr

/// Covers `LibraryBackedNowPlayingItemInfoProvider`: resolving Now Playing display metadata from
/// the local store the rest of the app reads. The episode cases pin the projection the expanded
/// player and the bookmark projection use: episode title in the title slot, parent show in the
/// secondary slot. The lock screen, CarPlay and Control Center then show each episode, not one
/// unchanging show title.
@Suite("LibraryBackedNowPlayingItemInfoProvider")
struct LibraryBackedNowPlayingItemInfoProviderTests {

  private struct Fixture {
    let provider: LibraryBackedNowPlayingItemInfoProvider
  }

  private static func fixture(
    itemTitle: String = "Deep Cover",
    itemAuthor: String? = "Pushkin Industries",
    mediaKind: String = "podcast",
    serverUpdatedAt: Date? = nil,
    episodes: [(id: String, title: String, softDeleted: Bool)] = []
  ) throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let accountDAO = AccountDAO(database: database)
    let account = try accountDAO.save(
      AccountRecord(
        clientUUID: "client-uuid", serverBaseURL: "https://books.example.test",
        serverUserId: "user-1", serverVersion: "2.35.1"))
    let accountId = try #require(account.id)
    let library = try LibraryDAO(database: database).upsert(
      LibraryRecord(
        accountId: accountId, serverLibraryId: "lib-1", mediaType: mediaKind, name: "Podcasts",
        lastSeenGeneration: 1))
    let item = try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: accountId, libraryId: try #require(library.id), serverItemId: "item-1",
        mediaKind: mediaKind, title: itemTitle, sortTitle: itemTitle, author: itemAuthor,
        serverUpdatedAt: serverUpdatedAt))
    let episodeDAO = PodcastEpisodeDAO(database: database)
    for episode in episodes {
      try episodeDAO.upsert(
        PodcastEpisodeRecord(
          accountId: accountId, itemId: try #require(item.id), serverEpisodeId: episode.id,
          title: episode.title, lastSeenGeneration: 1, softDeleted: episode.softDeleted))
    }
    return Fixture(
      provider: LibraryBackedNowPlayingItemInfoProvider(database: database, accountDAO: accountDAO))
  }

  @Test("an audiobook resolves the item's own title and author")
  func audiobookResolvesItemTitleAndAuthor() throws {
    let fixture = try Self.fixture(itemTitle: "Dune", itemAuthor: "Frank Herbert", mediaKind: "book")

    let info = fixture.provider.nowPlayingItemInfo(forItemID: "item-1")

    #expect(info == NowPlayingItemInfo(title: "Dune", author: "Frank Herbert"))
  }

  @Test("an item and its episodes carry the item's cover revision, so the lock screen re-fetches")
  func infoCarriesTheItemsCoverRevision() throws {
    let fixture = try Self.fixture(
      serverUpdatedAt: Date(timeIntervalSince1970: 1_790_000_000.123),
      episodes: [(id: "episode-1", title: "One", softDeleted: false)])

    let show = fixture.provider.nowPlayingItemInfo(forItemID: "item-1")
    let episode = fixture.provider.nowPlayingItemInfo(forItemID: "item-1", episodeID: "episode-1")

    #expect(show?.artworkRevision == ArtworkRevision("1790000000123"))
    #expect(episode?.artworkRevision == ArtworkRevision("1790000000123"))
  }

  @Test("a podcast episode resolves the episode title with the show as the secondary line")
  func episodeResolvesEpisodeTitleAndShow() throws {
    let fixture = try Self.fixture(
      episodes: [(id: "episode-12", title: "12. The Truth About Sam", softDeleted: false)])

    let info = fixture.provider.nowPlayingItemInfo(forItemID: "item-1", episodeID: "episode-12")

    #expect(info == NowPlayingItemInfo(title: "12. The Truth About Sam", author: "Deep Cover"))
  }

  @Test("two episodes of the same show resolve to different metadata")
  func siblingEpisodesResolveDistinctMetadata() throws {
    let fixture = try Self.fixture(episodes: [
      (id: "episode-12", title: "12. The Truth About Sam", softDeleted: false),
      (id: "episode-13", title: "13. The Last Call", softDeleted: false),
    ])

    let twelve = fixture.provider.nowPlayingItemInfo(forItemID: "item-1", episodeID: "episode-12")
    let thirteen = fixture.provider.nowPlayingItemInfo(forItemID: "item-1", episodeID: "episode-13")

    #expect(twelve?.title == "12. The Truth About Sam")
    #expect(thirteen?.title == "13. The Last Call")
    #expect(twelve != thirteen)
  }

  @Test("an unresolvable or soft-deleted episode falls back to the show's own item metadata")
  func unresolvableEpisodeFallsBackToItemMetadata() throws {
    let fixture = try Self.fixture(
      episodes: [(id: "episode-12", title: "12. The Truth About Sam", softDeleted: true)])

    let softDeleted = fixture.provider.nowPlayingItemInfo(forItemID: "item-1", episodeID: "episode-12")
    let unknown = fixture.provider.nowPlayingItemInfo(forItemID: "item-1", episodeID: "episode-99")

    let showLevel = NowPlayingItemInfo(title: "Deep Cover", author: "Pushkin Industries")
    #expect(softDeleted == showLevel)
    #expect(unknown == showLevel)
  }

  @Test("an unknown item resolves to nothing at all")
  func unknownItemResolvesToNil() throws {
    let fixture = try Self.fixture()

    #expect(fixture.provider.nowPlayingItemInfo(forItemID: "item-missing", episodeID: "episode-12") == nil)
  }
}

@Suite("RSS Now Playing item info provider")
struct RSSNowPlayingItemInfoProviderTests {

  @Test("routes RSS show and episode identities to device-owned metadata")
  func resolvesShowAndEpisodeMetadata() throws {
    let database = try AppDatabase.inMemory()
    let feedID = try database.write { db in
      var feed = RSSFeedRecord(
        feedURL: "https://feeds.example.test/show.xml", title: "Native Show",
        author: "Native Host", subscribedAt: Date())
      try feed.insert(db)
      let id = try #require(feed.id)
      var episode = RSSEpisodeRecord(
        feedId: id, identityKey: "episode-1", title: "Episode One",
        enclosureURL: "https://cdn.example.test/episode.mp3", lastSeenGeneration: 1)
      try episode.insert(db)
      return id
    }

    let provider = RSSBackedNowPlayingItemInfoProvider(database: database)
    let show = provider.nowPlayingItemInfo(
      forItemID: try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId, episodeID: nil)
    let episode = provider.nowPlayingItemInfo(
      forItemID: try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId, episodeID: "episode-1")

    #expect(show == NowPlayingItemInfo(title: "Native Show", author: "Native Host"))
    #expect(episode == NowPlayingItemInfo(title: "Episode One", author: "Native Show"))
  }

  private static func feedWithEpisode(
    showArtworkURL: String?, episodeArtworkURL: String?
  ) throws -> (database: AppDatabase, itemID: String) {
    let database = try AppDatabase.inMemory()
    let feedID = try database.write { db in
      var feed = RSSFeedRecord(
        feedURL: "https://feeds.example.test/show.xml", title: "Native Show",
        author: "Native Host", artworkURL: showArtworkURL, subscribedAt: Date())
      try feed.insert(db)
      let id = try #require(feed.id)
      var episode = RSSEpisodeRecord(
        feedId: id, identityKey: "episode-1", title: "Episode One",
        enclosureURL: "https://cdn.example.test/episode.mp3", lastSeenGeneration: 1,
        artworkURL: episodeArtworkURL)
      try episode.insert(db)
      return id
    }
    return (database, try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId)
  }

  private static func source(_ url: String, feedID: String) throws -> ArtworkSource {
    .rss(
      try #require(
        RSSArtworkSource(
          feedIdentity: feedID, artworkURL: URL(string: url)!,
          feedURL: URL(string: "https://feeds.example.test/show.xml")!)))
  }

  @Test("an episode with its own image names it as the artwork and the show's as the fallback")
  func episodeImageIsTheArtworkAndTheShowIsTheFallback() throws {
    let (database, itemID) = try Self.feedWithEpisode(
      showArtworkURL: "https://images.example.test/show.png",
      episodeArtworkURL: "https://images.example.test/episode.png")
    let info = try #require(
      RSSBackedNowPlayingItemInfoProvider(database: database).nowPlayingItemInfo(
        forItemID: itemID, episodeID: "episode-1"))

    #expect(info.artworkSource == (try Self.source("https://images.example.test/episode.png", feedID: itemID)))
    #expect(info.fallbackArtworkSource == (try Self.source("https://images.example.test/show.png", feedID: itemID)))
  }

  @Test("an episode with no image of its own keeps the show's artwork and has no fallback")
  func episodeWithoutAnImageKeepsTheShowArtwork() throws {
    let (database, itemID) = try Self.feedWithEpisode(
      showArtworkURL: "https://images.example.test/show.png", episodeArtworkURL: nil)
    let info = try #require(
      RSSBackedNowPlayingItemInfoProvider(database: database).nowPlayingItemInfo(
        forItemID: itemID, episodeID: "episode-1"))

    #expect(info.artworkSource == (try Self.source("https://images.example.test/show.png", feedID: itemID)))
    #expect(info.fallbackArtworkSource == nil)
  }

  @Test("the show-level lookup never names an episode image")
  func showLevelLookupHasNoEpisodeImage() throws {
    let (database, itemID) = try Self.feedWithEpisode(
      showArtworkURL: "https://images.example.test/show.png",
      episodeArtworkURL: "https://images.example.test/episode.png")
    let info = try #require(
      RSSBackedNowPlayingItemInfoProvider(database: database).nowPlayingItemInfo(
        forItemID: itemID, episodeID: nil))

    #expect(info.artworkSource == (try Self.source("https://images.example.test/show.png", feedID: itemID)))
    #expect(info.fallbackArtworkSource == nil)
  }

  @Test("numeric ABS and RSS identifiers remain distinct at the real Now Playing route")
  func numericIdentityCollisionStaysOnItsTypedSource() throws {
    let database = try AppDatabase.inMemory()
    let accountDAO = AccountDAO(database: database)
    let account = try accountDAO.save(
      AccountRecord(
        clientUUID: "client-uuid", serverBaseURL: "https://books.example.test",
        serverUserId: "user-1", serverVersion: "2.35.1"))
    let accountID = try #require(account.id)
    let library = try LibraryDAO(database: database).upsert(
      LibraryRecord(
        accountId: accountID, serverLibraryId: "lib-1", mediaType: "book", name: "Books",
        lastSeenGeneration: 1))
    _ = try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: accountID, libraryId: try #require(library.id), serverItemId: "1",
        mediaKind: "book", title: "ABS One", sortTitle: "ABS One", author: "Server Author"))
    let feedID = try database.write { db in
      var feed = RSSFeedRecord(
        feedURL: "https://feeds.example.test/one.xml", title: "RSS One",
        author: "Device Author", subscribedAt: Date())
      try feed.insert(db)
      return try #require(feed.id)
    }
    // These two rows share a key. Only the source namespace distinguishes them.
    #expect(feedID == 1)

    let provider = RoutingNowPlayingItemInfoProvider(
      abs: LibraryBackedNowPlayingItemInfoProvider(database: database, accountDAO: accountDAO),
      rss: RSSBackedNowPlayingItemInfoProvider(database: database))

    #expect(
      provider.nowPlayingItemInfo(forItemID: "1")
        == NowPlayingItemInfo(title: "ABS One", author: "Server Author"))
    #expect(
      provider.nowPlayingItemInfo(forItemID: try #require(PodcastSourceIdentity.rss(feedId: 1)).itemId)
        == NowPlayingItemInfo(title: "RSS One", author: "Device Author"))
  }

  @Test("RSS Now Playing artwork uses the canonical identity for a private feed")
  func rssArtworkIdentityAuthorizesPrivateFeed() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try database.write { db in
      var feed = RSSFeedRecord(
        feedURL: "https://feeds.example.test/show.xml",
        title: "Native Show",
        author: "Native Host",
        artworkURL: "https://images.example.test/show.png",
        subscribedAt: Date())
      try feed.insert(db)
      return try #require(feed.id)
    }
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
    let provider = RSSBackedNowPlayingItemInfoProvider(database: database)
    let info = try #require(provider.nowPlayingItemInfo(forItemID: itemID))
    let source = try #require(info.artworkSource)
    let summary = ItemSummary(
      serverItemId: itemID,
      mediaKind: "podcast",
      title: "Native Show",
      author: "Native Host",
      durationSeconds: nil,
      category: .podcast,
      artworkURL: URL(string: "https://images.example.test/show.png"),
      artworkFeedURL: URL(string: "https://feeds.example.test/show.xml"))

    #expect(source == summary.providerArtworkSource)
    guard case .rss(let artwork) = source else {
      Issue.record("expected the RSS provider to declare artwork")
      return
    }

    let credentialStore = InMemoryFeedCredentialStore()
    let credential = try FeedCredential(authorization: "Bearer artwork-canary")
    try credentialStore.save(credential, forFeedID: feedID)
    let authorization = RSSArtworkAuthorization(credentialStore: credentialStore)
    #expect(
      await authorization.authorizationHeader(for: artwork.feedIdentity) == credential.authorization)
  }

  @Test("malformed reserved identities are rejected without crossing origins")
  func malformedReservedIdentityIsRejected() throws {
    let database = try AppDatabase.inMemory()
    let abs = StubNowPlayingItemInfoProvider(
      info: NowPlayingItemInfo(title: "ABS item", author: "ABS author"))
    let rss = RSSBackedNowPlayingItemInfoProvider(database: database)
    let provider = RoutingNowPlayingItemInfoProvider(abs: abs, rss: rss)

    let info = provider.nowPlayingItemInfo(forItemID: "rss:not-a-feed", episodeID: nil)

    #expect(info == nil)
    #expect(abs.requestedItemIDs.isEmpty)
  }

  @Test("unknown RSS feeds resolve to no metadata without falling through to ABS")
  func unknownRSSFeedDoesNotCrossOrigins() throws {
    let database = try AppDatabase.inMemory()
    let abs = StubNowPlayingItemInfoProvider(
      info: NowPlayingItemInfo(title: "ABS item", author: "ABS author"))
    let provider = RoutingNowPlayingItemInfoProvider(
      abs: abs, rss: RSSBackedNowPlayingItemInfoProvider(database: database))

    let info = provider.nowPlayingItemInfo(forItemID: "rss:99", episodeID: "episode-1")

    #expect(info == nil)
    #expect(abs.requestedItemIDs.isEmpty)
  }
}

private final class StubNowPlayingItemInfoProvider: NowPlayingItemInfoProviding {
  let info: NowPlayingItemInfo
  private(set) var requestedItemIDs: [String] = []

  init(info: NowPlayingItemInfo) {
    self.info = info
  }

  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo? {
    nowPlayingItemInfo(forItemID: itemID, episodeID: nil)
  }

  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo? {
    requestedItemIDs.append(itemID)
    return info
  }
}
