import Foundation
import Persistence
import Testing

@Suite("RSS notification route resolution")
struct RSSNotificationRouteResolverTests {
  @Test("single episode falls back through show to Podcasts root")
  func singleFallbacks() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await RSSFeedStore(database: database).subscribe(
      feedURL: #require(URL(string: "https://example.com/feed.xml")), title: "Show",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: .now)
    let resolver = RSSNotificationRouteResolver(database: database)
    #expect(
      try await resolver.resolve(.episode(feedID: feed, identityKey: "missing"))
        == .show(feedID: feed))
    try await RSSFeedStore(database: database).unsubscribe(feedId: feed)
    #expect(
      try await resolver.resolve(.episode(feedID: feed, identityKey: "missing")) == .podcastsRoot)
  }

  @Test("multi-show Latest requires at least one included live feed")
  func latestFallback() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await RSSFeedStore(database: database).subscribe(
      feedURL: #require(URL(string: "https://example.com/feed.xml")), title: "Show",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: .now)
    let resolver = RSSNotificationRouteResolver(database: database)
    #expect(try await resolver.resolve(.latest(feedIDs: [feed, 999])) == .latest)
    try await RSSFeedSettingsStore(database: database).setIncludeInLatest(
      feedId: feed, enabled: false)
    #expect(try await resolver.resolve(.latest(feedIDs: [feed])) == .podcastsRoot)
  }
}
