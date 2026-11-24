import Foundation
import Testing

@testable import Persistence

@Suite(.timeLimit(.minutes(1))) struct PodcastFeedFingerprintProjectionTests {
  @Test func nativeAndServerShowProjectionsExposeTheSameOpaqueIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let feedURL = URL(string: "https://example.com/native.xml")!
    let expected = PodcastFeedIdentity.fingerprint(feedURL)!
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: feedURL, title: "Native", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())

    let native = try #require(
      await AsyncStreamTestSupport.first(RSSPodcastReading(database: database).observeShows())?.shows.first)
    #expect(native.serverItemId == "rss:\(feedID)")
    #expect(native.podcastFeedFingerprint == expected)

    let (accountID, libraryID) = try await database.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: "projection-client", serverBaseURL: "https://server.example",
        serverUserId: "projection-user", serverVersion: "2.36.0")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "server-podcasts", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return (account.id!, library.id!)
    }
    _ = try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: "server-show", mediaKind: "podcast",
        title: "Server", sortTitle: "server", podcastFeedFingerprint: expected))

    let server = try #require(
      await AsyncStreamTestSupport.first(
        DefaultLibraryReading(database: database).observeBrowseList(libraryId: "server-podcasts"))?.first)
    #expect(server.podcastFeedFingerprint == expected)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET podcastFeedFingerprint = ? WHERE serverItemId = ?",
        arguments: ["MALFORMED", "server-show"])
    }
    let malformed = try #require(
      await AsyncStreamTestSupport.first(
        DefaultLibraryReading(database: database).observeItemDetail(itemId: "server-show")))!
    #expect(malformed.podcastFeedFingerprint == nil)
  }
}
