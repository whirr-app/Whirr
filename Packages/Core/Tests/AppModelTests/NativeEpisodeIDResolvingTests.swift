import Foundation
import Persistence
import Testing

@testable import AppModel

/// A resolver with a fixed key-to-row map, shared by the show and card model suites so a test can
/// state which identity keys have rows without touching a database.
struct StaticNativeEpisodeIDResolving: NativeEpisodeIDResolving, Sendable {
  let ids: [String: Int64]

  init(_ ids: [String: Int64]) {
    self.ids = ids
  }

  func nativeEpisodeIDs(feedId: Int64, identityKeys: [String]) async -> [String: Int64] {
    var resolved: [String: Int64] = [:]
    for key in identityKeys {
      if let id = ids[key] { resolved[key] = id }
    }
    return resolved
  }
}

@Suite("Native episode id resolution")
struct NativeEpisodeIDResolvingTests {
  @Test("NoOp resolves nothing")
  func noOpResolvesNothing() async {
    let resolver = NoOpNativeEpisodeIDResolving()
    #expect(await resolver.nativeEpisodeIDs(feedId: 1, identityKeys: ["9"]).isEmpty)
    #expect(await resolver.nativeEpisodeID(feedId: 1, identityKey: "9") == nil)
  }

  @Test("the persistence resolver maps identity keys to row ids within one feed only")
  func persistenceResolverMapsIdentityKeysWithinTheFeed() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedID = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/a.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let otherFeedID = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/b.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    let enclosureURL = URL(string: "https://example.com/episode.mp3")!
    _ = try await episodeStore.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:one", enclosureURL: enclosureURL),
        RSSEpisodeUpsert(identityKey: "guid:two", enclosureURL: enclosureURL),
      ])
    _ = try await episodeStore.applyRefresh(
      feedId: otherFeedID,
      episodes: [RSSEpisodeUpsert(identityKey: "guid:one", enclosureURL: enclosureURL)])
    let expectedOne = try #require(
      try await episodeStore.fetchEpisode(feedId: feedID, identityKey: "guid:one")?.id)
    let expectedTwo = try #require(
      try await episodeStore.fetchEpisode(feedId: feedID, identityKey: "guid:two")?.id)

    let resolver = PersistenceNativeEpisodeIDResolver(database: database)
    let resolved = await resolver.nativeEpisodeIDs(
      feedId: feedID, identityKeys: ["guid:one", "guid:two", "guid:missing", "\(expectedOne)"])

    #expect(resolved == ["guid:one": expectedOne, "guid:two": expectedTwo])
    // A row id spelled as a string is not an identity key; it must never resolve to itself.
    #expect(resolved["\(expectedOne)"] == nil)
    #expect(await resolver.nativeEpisodeID(feedId: otherFeedID, identityKey: "guid:two") == nil)
    #expect(await resolver.nativeEpisodeIDs(feedId: feedID, identityKeys: []).isEmpty)
  }
}
