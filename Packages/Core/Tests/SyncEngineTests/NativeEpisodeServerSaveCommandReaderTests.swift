import ABSApi
import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// Command assembly re-reads the persisted RSS subscription and applies the security and payload
/// bounds immediately before a later SyncEngine network operation.
@Suite(.timeLimit(.minutes(1))) struct NativeEpisodeServerSaveCommandReaderTests {

  @Test func readsOneSubscribedEpisodeIntoBoundedCommandValues() async throws {
    let database = try AppDatabase.inMemory()
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let ids = try await insertFeedAndEpisode(
      database,
      artworkURL: "https://images.example/show.png?token=opaque",
      publishedAt: publishedAt)
    let reader = PersistenceNativeEpisodeServerSaveCommandReader(
      database: database,
      feedCredentialStore: InMemoryFeedCredentialStore(),
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))

    let command = try await reader.read(feedId: ids.feedId, episodeId: ids.episodeId)

    #expect(command.feedId == ids.feedId)
    #expect(command.episodeId == ids.episodeId)
    #expect(command.episodeIdentityKey == "guid:episode-1")
    #expect(command.feedTitle == "A native show")
    #expect(command.feedAuthor == "An author")
    #expect(command.feedSynopsis == "A bounded synopsis")
    #expect(command.feedArtworkURL?.absoluteString == "https://images.example/show.png?token=opaque")
    #expect(command.episodeGUID == "episode-1")
    #expect(command.episodeTitle == "An episode")
    #expect(command.episodeSynopsis == "Episode synopsis")
    #expect(command.enclosureURL.absoluteString == "https://media.example/episode.mp3")
    #expect(command.declaredBytes == 42)
    #expect(command.durationSeconds == 12.5)
    #expect(command.seasonNumber == 2)
    #expect(command.episodeNumber == 3)
    #expect(command.publishedAt == publishedAt)

    // Public diagnostics contain only opaque ids and presence flags, never source URL or metadata.
    #expect(command.description.contains("https://") == false)
    #expect(command.description.contains("episode.mp3") == false)
    #expect(command.description.contains("An author") == false)
  }

  @Test func invalidPublicationDatesAreAbsentFromTheCommand() async throws {
    let validDate = Date(timeIntervalSince1970: 1_700_000_000)

    let validDatabase = try AppDatabase.inMemory()
    let validIDs = try await insertFeedAndEpisode(validDatabase, publishedAt: validDate)
    let validCommand = try await makeReader(validDatabase).read(
      feedId: validIDs.feedId, episodeId: validIDs.episodeId)
    #expect(validCommand.publishedAt == validDate)

    for invalidDate in [Date?](arrayLiteral: nil, Date(timeIntervalSince1970: -1)) {
      let database = try AppDatabase.inMemory()
      let ids = try await insertFeedAndEpisode(database, publishedAt: invalidDate)
      let command = try await makeReader(database).read(
        feedId: ids.feedId, episodeId: ids.episodeId)
      #expect(command.publishedAt == nil)
    }

    let nonFiniteDatabase = try AppDatabase.inMemory()
    let nonFiniteIDs = try await insertFeedAndEpisode(nonFiniteDatabase)
    try await nonFiniteDatabase.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisode SET publishedAt = ?", arguments: [Double.infinity])
    }
    let nonFiniteCommand = try await makeReader(nonFiniteDatabase).read(
      feedId: nonFiniteIDs.feedId, episodeId: nonFiniteIDs.episodeId)
    #expect(nonFiniteCommand.publishedAt == nil)
  }

  @Test func commandDiagnosticsDoNotReflectSourceURLs() async throws {
    let database = try AppDatabase.inMemory()
    let ids = try await insertFeedAndEpisode(
      database, enclosureURL: "https://private-media.example/signed-episode.mp3?token=secret")
    let command = try await makeReader(database).read(
      feedId: ids.feedId, episodeId: ids.episodeId)

    #expect(Mirror(reflecting: command).children.isEmpty)
    #expect(String(reflecting: command).contains("private-media.example") == false)
    #expect(String(describing: command).contains("private-media.example") == false)
  }

  @Test func commandDescriptionsDoNotReflectHostileSourceOrUserValues() {
    let command = NativeEpisodeServerSaveCommand(
      feedId: 1,
      episodeId: 2,
      episodeIdentityKey: "guid:episode-guid",
      feedTitle: "Show title token=not-a-secret",
      feedAuthor: "Author",
      feedSynopsis: "Synopsis",
      episodeGUID: "episode-guid",
      episodeTitle: "Episode title token=not-a-secret",
      episodeSynopsis: "Episode synopsis",
      enclosureType: "audio/mpeg",
      declaredBytes: 42,
      durationSeconds: 12.5,
      seasonNumber: 2,
      episodeNumber: 3,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      feedURL: URL(string: "https://user:fake-pass@feeds.example/hostile.xml")!,
      enclosureURL: URL(string: "https://media.example/episode.mp3?token=not-a-secret")!)
    let diagnostics = [command.description, command.debugDescription, String(reflecting: command)]

    for value in diagnostics {
      #expect(value.contains("feeds.example") == false)
      #expect(value.contains("media.example") == false)
      #expect(value.contains("episode.mp3") == false)
      #expect(value.contains("not-a-secret") == false)
      #expect(value.contains("Show title") == false)
    }
  }

  @Test func missingOrCrossFeedRowsCannotBeRead() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await insertFeedAndEpisode(database)
    let secondFeed = try await insertFeed(database, url: "https://second.example/feed.xml")
    let reader = makeReader(database)

    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.feedNotFound) {
      try await reader.read(feedId: 999, episodeId: first.episodeId)
    }
    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.episodeNotFound) {
      try await reader.read(feedId: first.feedId, episodeId: 999)
    }
    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.episodeNotInFeed) {
      try await reader.read(feedId: secondFeed, episodeId: first.episodeId)
    }
  }

  @Test(arguments: [
    ("ftp://feeds.example/feed.xml", NativeEpisodeServerSaveCommandReaderError.invalidFeedURL(.unsupportedScheme)),
    (
      "https://user:password@feeds.example/feed.xml",
      NativeEpisodeServerSaveCommandReaderError.invalidFeedURL(.credentialsNotAllowed)
    ),
  ])
  func invalidStoredFeedURLIsRejected(
    rawURL: String,
    expected: NativeEpisodeServerSaveCommandReaderError
  ) async throws {
    let database = try AppDatabase.inMemory()
    let ids = try await insertFeedAndEpisode(database, feedURL: rawURL)
    let reader = makeReader(database)

    do {
      _ = try await reader.read(feedId: ids.feedId, episodeId: ids.episodeId)
      Issue.record("invalid feed URL was accepted")
    } catch let error as NativeEpisodeServerSaveCommandReaderError {
      #expect(error == expected)
    }
  }

  @Test(arguments: [
    (
      "ftp://media.example/episode.mp3",
      NativeEpisodeServerSaveCommandReaderError.invalidEnclosureURL(.unsupportedScheme)
    ),
    (
      "https://user:password@media.example/episode.mp3",
      NativeEpisodeServerSaveCommandReaderError.invalidEnclosureURL(.credentialsNotAllowed)
    ),
    (
      "https://media.example/"
        + String(
          repeating: "e", count: PersistenceNativeEpisodeServerSaveCommandReader.maximumStringBytes)
        + ".mp3",
      NativeEpisodeServerSaveCommandReaderError.fieldTooLong(.enclosureURL)
    ),
  ])
  func invalidStoredEnclosureURLIsRejected(
    rawURL: String,
    expected: NativeEpisodeServerSaveCommandReaderError
  ) async throws {
    let database = try AppDatabase.inMemory()
    let ids = try await insertFeedAndEpisode(database, enclosureURL: rawURL)
    let reader = makeReader(database)

    do {
      _ = try await reader.read(feedId: ids.feedId, episodeId: ids.episodeId)
      Issue.record("invalid enclosure URL was accepted")
    } catch let error as NativeEpisodeServerSaveCommandReaderError {
      #expect(error == expected)
    }
  }

  @Test func keychainCredentialPresenceAndFailureFailClosedWithoutExportingSecrets() async throws {
    let database = try AppDatabase.inMemory()
    let ids = try await insertFeedAndEpisode(database)
    let credentialStore = InMemoryFeedCredentialStore()
    try credentialStore.save(
      try FeedCredential.basic(username: "user", password: "secret"), forFeedID: ids.feedId)
    let credentialedReader = PersistenceNativeEpisodeServerSaveCommandReader(
      database: database,
      feedCredentialStore: credentialStore,
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))

    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.credentialedFeed) {
      try await credentialedReader.read(feedId: ids.feedId, episodeId: ids.episodeId)
    }

    let failingReader = PersistenceNativeEpisodeServerSaveCommandReader(
      database: database,
      feedCredentialStore: FailingFeedCredentialStore(),
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.credentialStoreUnavailable) {
      try await failingReader.read(feedId: ids.feedId, episodeId: ids.episodeId)
    }
  }

  @Test func disabledNativeSubscriptionsAreRecheckedAtReadTime() async throws {
    let database = try AppDatabase.inMemory()
    let ids = try await insertFeedAndEpisode(database)
    let reader = PersistenceNativeEpisodeServerSaveCommandReader(
      database: database,
      feedCredentialStore: InMemoryFeedCredentialStore(),
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: false))

    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.nativeSubscriptionsDisabled) {
      try await reader.read(feedId: ids.feedId, episodeId: ids.episodeId)
    }
  }

  @Test func persistedMetadataIsBoundedAtTheCommandBoundary() async throws {
    let database = try AppDatabase.inMemory()
    let ids = try await insertFeedAndEpisode(
      database,
      title: String(repeating: "t", count: PersistenceNativeEpisodeServerSaveCommandReader.maximumStringBytes + 1))
    let reader = makeReader(database)

    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.fieldTooLong(.feedTitle)) {
      try await reader.read(feedId: ids.feedId, episodeId: ids.episodeId)
    }
  }

  @Test func invalidIdentityIsRejectedBeforeDatabaseAccess() async throws {
    let reader = makeReader(try AppDatabase.inMemory())

    await #expect(throws: NativeEpisodeServerSaveCommandReaderError.invalidIdentity) {
      try await reader.read(feedId: 0, episodeId: 1)
    }
  }

  @Test func invalidStoredArtworkIsOmittedWithoutBlockingTheEpisodeCommand() async throws {
    let invalidArtworkURLs = [
      "ftp://images.example/show.png",
      "https:///show.png",
      "https://user:password@images.example/show.png",
      "https://images.example/show.png#fragment",
      "https://images.example/show%00.png",
      "https://localhost/show.png",
      "https://127.0.0.1/show.png",
      "https://127.1/show.png",
      "https://2130706433/show.png",
      "https://192.168.1.7/show.png",
      "https://[::1]/show.png",
      "https://[fc00::1]/show.png",
      "https://[2001:11::1]/show.png",
      "https://[2001:20::1]/show.png",
      String(
        repeating: "a",
        count: PersistenceNativeEpisodeServerSaveCommandReader.maximumStringBytes + 1),
    ]

    for artworkURL in invalidArtworkURLs {
      let database = try AppDatabase.inMemory()
      let ids = try await insertFeedAndEpisode(database, artworkURL: artworkURL)
      let command = try await makeReader(database).read(
        feedId: ids.feedId, episodeId: ids.episodeId)
      #expect(command.feedArtworkURL == nil)
      #expect(command.episodeIdentityKey == "guid:episode-1")
    }
  }

  // MARK: - Fixtures

  private func makeReader(_ database: AppDatabase) -> PersistenceNativeEpisodeServerSaveCommandReader {
    PersistenceNativeEpisodeServerSaveCommandReader(
      database: database,
      feedCredentialStore: InMemoryFeedCredentialStore(),
      nativeSubscriptions: FakeNativePodcastSubscriptionsReading(enabled: true))
  }

  private func insertFeedAndEpisode(
    _ database: AppDatabase,
    feedURL: String = "https://feeds.example/feed.xml",
    enclosureURL: String = "https://media.example/episode.mp3",
    artworkURL: String? = nil,
    title: String? = "A native show",
    publishedAt: Date? = nil
  ) async throws -> (feedId: Int64, episodeId: Int64) {
    try await database.writeAsync { db in
      var feed = RSSFeedRecord(
        feedURL: feedURL, title: title, author: "An author", synopsis: "A bounded synopsis",
        artworkURL: artworkURL, subscribedAt: Date(), refreshGeneration: 1)
      try feed.insert(db)
      var episode = RSSEpisodeRecord(
        feedId: feed.id!, identityKey: "guid:episode-1", guid: "episode-1", title: "An episode",
        synopsis: "Episode synopsis", enclosureURL: enclosureURL, enclosureType: "audio/mpeg",
        declaredBytes: 42, publishedAt: publishedAt, durationSeconds: 12.5, seasonNumber: 2,
        episodeNumber: 3, lastSeenGeneration: 1)
      try episode.insert(db)
      return (feed.id!, episode.id!)
    }
  }

  private func insertFeed(_ database: AppDatabase, url: String) async throws -> Int64 {
    try await database.writeAsync { db in
      var feed = RSSFeedRecord(feedURL: url, title: "Second", subscribedAt: Date())
      try feed.insert(db)
      return feed.id!
    }
  }
}

// Kept: no shared fake exists for FeedCredentialStoring in TestSupport.
private struct FailingFeedCredentialStore: FeedCredentialStoring {
  struct Failure: Error {}

  func save(_: FeedCredential, forFeedID _: Int64) throws { throw Failure() }
  func load(forFeedID _: Int64) throws -> FeedCredential? { throw Failure() }
  func clear(forFeedID _: Int64) throws { throw Failure() }
}
