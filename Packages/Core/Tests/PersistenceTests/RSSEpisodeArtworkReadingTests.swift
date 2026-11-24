import Foundation
import GRDB
import Persistence
import Testing

@Suite("RSS episode artwork reading", .timeLimit(.minutes(1)))
struct RSSEpisodeArtworkReadingTests {
  private static let enclosure = URL(string: "https://audio.example/e.mp3")!

  private static func subscribe(_ database: AppDatabase) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://feeds.example/art.xml")!, title: "Art", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }

  @Test("emits the stored episode image")
  func emitsStoredURL() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await Self.subscribe(database)
    let image = URL(string: "https://images.example/e.jpg")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feed,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:e", enclosureURL: Self.enclosure, artworkURL: image)
      ])

    var iterator = DefaultRSSEpisodeArtworkReading(database: database)
      .observeEpisodeArtworkURL(feedId: feed, identityKey: "guid:e").makeAsyncIterator()
    #expect(await iterator.next() == .some(image))
  }

  @Test("emits nil for an episode with no image and for an unknown episode")
  func emitsNilWhenNone() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await Self.subscribe(database)
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feed,
      episodes: [RSSEpisodeUpsert(identityKey: "guid:e", enclosureURL: Self.enclosure)])
    let reading = DefaultRSSEpisodeArtworkReading(database: database)

    var plain = reading.observeEpisodeArtworkURL(feedId: feed, identityKey: "guid:e")
      .makeAsyncIterator()
    #expect(await plain.next() == .some(nil))
    var unknown = reading.observeEpisodeArtworkURL(feedId: feed, identityKey: "guid:missing")
      .makeAsyncIterator()
    #expect(await unknown.next() == .some(nil))
  }

  @Test("emits the new image after a refresh adds one")
  func emitsAfterRefreshAddsImage() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await Self.subscribe(database)
    let store = RSSEpisodeStore(database: database)
    _ = try await store.applyRefresh(
      feedId: feed,
      episodes: [RSSEpisodeUpsert(identityKey: "guid:e", enclosureURL: Self.enclosure)])
    var iterator = DefaultRSSEpisodeArtworkReading(database: database)
      .observeEpisodeArtworkURL(feedId: feed, identityKey: "guid:e").makeAsyncIterator()
    #expect(await iterator.next() == .some(nil))

    let image = URL(string: "https://images.example/new.jpg")!
    _ = try await store.applyRefresh(
      feedId: feed,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:e", enclosureURL: Self.enclosure, artworkURL: image)
      ])
    #expect(await iterator.next() == .some(image))
  }
}
