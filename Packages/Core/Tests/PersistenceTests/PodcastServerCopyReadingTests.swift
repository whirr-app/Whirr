import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The local read that finds the server shows which are the same feed as a followed one.
@Suite struct PodcastServerCopyReadingTests {
  private static let feedFingerprint = PodcastFeedIdentity.fingerprint("https://example.com/feed")!
  private static let otherFingerprint = PodcastFeedIdentity.fingerprint("https://example.com/other")!

  private struct Seed {
    let accountId: Int64
    let libraryId: Int64
  }

  private static func seed(_ database: AppDatabase) async throws -> Seed {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-a", serverBaseURL: "server-a", serverUserId: "user-a",
        serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-a", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return Seed(accountId: account.id!, libraryId: library.id!)
    }
  }

  @discardableResult
  private static func insertItem(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, serverItemId: String,
    fingerprint: String?, softDeleted: Bool = false, mediaKind: String = "podcast"
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        mediaKind: mediaKind, title: serverItemId, sortTitle: serverItemId,
        podcastFeedFingerprint: fingerprint, softDeleted: softDeleted)
      try item.insert(db)
      return item.id!
    }
  }

  private static func ids(
    _ reading: DefaultPodcastReading, _ fingerprint: String = feedFingerprint
  ) async -> [String]? {
    var iterator = reading.observeServerCopyItemIDs(podcastFeedFingerprint: fingerprint)
      .makeAsyncIterator()
    return await iterator.next()
  }

  @Test("no, one and several matches")
  func zeroOneSeveral() async throws {
    let database = try AppDatabase.inMemory()
    let seed = try await Self.seed(database)
    let reading = DefaultPodcastReading(database: database)
    try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "unrelated",
      fingerprint: Self.otherFingerprint)
    #expect(await Self.ids(reading) == [])

    try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "b-copy",
      fingerprint: Self.feedFingerprint)
    #expect(await Self.ids(reading) == ["b-copy"])

    try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "a-copy",
      fingerprint: Self.feedFingerprint)
    #expect(await Self.ids(reading) == ["a-copy", "b-copy"])
  }

  @Test("a soft-deleted item, an excluded library and a soft-deleted library are ignored")
  func hiddenCopiesAreIgnored() async throws {
    let database = try AppDatabase.inMemory()
    let seed = try await Self.seed(database)
    let reading = DefaultPodcastReading(database: database)
    try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "deleted",
      fingerprint: Self.feedFingerprint, softDeleted: true)
    let hiddenLibraries = try await database.writeAsync { db -> [Int64] in
      var excluded = LibraryRecord(
        accountId: seed.accountId, serverLibraryId: "excluded", mediaType: "podcast",
        name: "Excluded", isIncluded: false)
      try excluded.insert(db)
      var gone = LibraryRecord(
        accountId: seed.accountId, serverLibraryId: "gone", mediaType: "podcast", name: "Gone")
      try gone.insert(db)
      try db.execute(sql: "UPDATE library SET softDeleted = 1 WHERE id = ?", arguments: [gone.id!])
      return [excluded.id!, gone.id!]
    }
    for (index, libraryId) in hiddenLibraries.enumerated() {
      try await Self.insertItem(
        database, accountId: seed.accountId, libraryId: libraryId, serverItemId: "hidden-\(index)",
        fingerprint: Self.feedFingerprint)
    }

    #expect(await Self.ids(reading) == [])
  }

  @Test("another account's item is ignored")
  func otherAccountIsIgnored() async throws {
    let database = try AppDatabase.inMemory()
    let seed = try await Self.seed(database)
    let reading = DefaultPodcastReading(database: database)
    let other = try await database.writeAsync { db -> Seed in
      var account = AccountRecord(
        clientUUID: "client-b", serverBaseURL: "server-b", serverUserId: "user-b",
        serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-b", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return Seed(accountId: account.id!, libraryId: library.id!)
    }
    try await Self.insertItem(
      database, accountId: other.accountId, libraryId: other.libraryId, serverItemId: "theirs",
      fingerprint: Self.feedFingerprint)
    try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "mine",
      fingerprint: Self.feedFingerprint)

    #expect(await Self.ids(reading) == ["mine"])
  }

  @Test("equality is on the normalized fingerprint, and a malformed one matches nothing")
  func normalizedEquality() async throws {
    let database = try AppDatabase.inMemory()
    let seed = try await Self.seed(database)
    let reading = DefaultPodcastReading(database: database)
    let serverSide = try #require(PodcastFeedIdentity.fingerprint("HTTPS://Example.com:443/feed/"))
    try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "norm",
      fingerprint: serverSide)

    #expect(await Self.ids(reading) == ["norm"])
    #expect(await Self.ids(reading, "NOT-A-FINGERPRINT") == [])
    #expect(await Self.ids(reading, "") == [])
  }

  @Test("a copy that appears later is emitted without reopening, and a hidden one withdraws")
  func observationReemits() async throws {
    let database = try AppDatabase.inMemory()
    let seed = try await Self.seed(database)
    let reading = DefaultPodcastReading(database: database)
    let observations = PersistenceObservationCollector(
      reading.observeServerCopyItemIDs(podcastFeedFingerprint: Self.feedFingerprint))
    #expect(await TestSupport.waitUntil { observations.contains { $0.isEmpty } })

    let rowID = try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "late",
      fingerprint: Self.feedFingerprint)
    #expect(await TestSupport.waitUntil { observations.contains { $0 == ["late"] } })

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [rowID])
    }
    #expect(await TestSupport.waitUntil { observations.values.last == [] })
  }

  @Test("the default reader and the routing reader answer")
  func routingForwards() async throws {
    let database = try AppDatabase.inMemory()
    let seed = try await Self.seed(database)
    try await Self.insertItem(
      database, accountId: seed.accountId, libraryId: seed.libraryId, serverItemId: "routed",
      fingerprint: Self.feedFingerprint)
    let routing = RoutingPodcastReading(
      abs: DefaultPodcastReading(database: database), rss: RSSPodcastReading(database: database))
    var iterator = routing.observeServerCopyItemIDs(podcastFeedFingerprint: Self.feedFingerprint)
      .makeAsyncIterator()
    #expect(await iterator.next() == ["routed"])
  }
}
