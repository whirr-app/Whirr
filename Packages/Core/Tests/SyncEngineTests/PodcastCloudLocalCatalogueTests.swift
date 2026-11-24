import Foundation
import Persistence
import Testing

@testable import SyncEngine

/// The one episode-identity query publication, projection and Saved-intent resolution share.
/// Pinned directly so a column-list change cannot silently narrow one caller's view.
@Suite struct PodcastCloudLocalCatalogueTests {
  private static let feedURL = URL(string: "https://example.com/feed.xml")!

  private func fixture() async throws -> (AppDatabase, Int64) {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: Self.feedURL, title: "Feed", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date(timeIntervalSince1970: 1))
    return (database, feedId)
  }

  @Test func identityCarriesTheFullSuperset() async throws {
    let (database, feedId) = try await fixture()
    let published = Date(timeIntervalSince1970: 1_000)
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:one", alternateIdentityKey: "enclosure:one", guid: "one",
          title: "Episode One", enclosureURL: URL(string: "https://example.com/1.mp3")!,
          publishedAt: published, durationSeconds: 42)
      ])
    let episodeId = try await database.readAsync { db in
      try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode WHERE identityKey = ?", arguments: ["guid:one"])
    }
    let id = try #require(episodeId)

    let identity = try await database.readAsync { db in
      try PodcastCloudLocalCatalogue.episodeIdentity(episodeId: id, in: db)
    }
    let read = try #require(identity)
    #expect(read.feedURL == Self.feedURL.absoluteString)
    #expect(read.identityKey == "guid:one")
    #expect(read.alternateIdentityKey == "enclosure:one")
    #expect(read.guid == "one")
    #expect(read.enclosureURL == "https://example.com/1.mp3")
    #expect(read.title == "Episode One")
    #expect(read.publishedAt == published)
    #expect(read.duration == 42)
    #expect(read.fields.alternateIdentityKey == "enclosure:one")
  }

  @Test func identityFallsBackToTheMeasuredDuration() async throws {
    let (database, feedId) = try await fixture()
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:one", enclosureURL: URL(string: "https://example.com/1.mp3")!)
      ])
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisode SET durationSeconds = NULL, measuredDurationSeconds = 12.5 WHERE identityKey = ?",
        arguments: ["guid:one"])
    }

    let identity = try await database.readAsync { db -> PodcastCloudLocalCatalogue.EpisodeIdentity? in
      guard
        let id = try Int64.fetchOne(
          db, sql: "SELECT id FROM rssEpisode WHERE identityKey = ?", arguments: ["guid:one"])
      else { return nil }
      return try PodcastCloudLocalCatalogue.episodeIdentity(episodeId: id, in: db)
    }
    #expect(try #require(identity).duration == 12.5)
  }

  @Test func identityIsNilForAnUnknownEpisode() async throws {
    let (database, _) = try await fixture()
    let identity = try await database.readAsync { db in
      try PodcastCloudLocalCatalogue.episodeIdentity(episodeId: 999, in: db)
    }
    #expect(identity == nil)
  }
}
