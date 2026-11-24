import Foundation
import Testing

@testable import Persistence

@Suite struct PodcastEpisodeDAOTests {
  @Test func upsertRoundTripsConfirmedMetadataStoredAudioAndSyncState() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId) = try await seedPodcast(database)
    let dao = PodcastEpisodeDAO(database: database)
    let publishedAt = Date(timeIntervalSince1970: 1_751_000_000)

    let inserted = try dao.upsert(
      PodcastEpisodeRecord(
        accountId: accountId,
        itemId: itemId,
        serverEpisodeId: "episode-1",
        title: "Episode One",
        subtitle: "",
        episodeDescription: "<p>Shown offline</p>",
        seasonNumber: "2",
        episodeNumber: "7",
        episodeType: "full",
        mimeType: "audio/mpeg",
        durationSeconds: 1_234.5,
        sizeBytes: 98_765,
        publishedAt: publishedAt,
        storedAudioIno: "audio-ino-1",
        storedAudioExpectedSize: 98_765,
        storedAudioMimeType: "audio/mpeg",
        storedAudioDurationSeconds: 1_234.5,
        lastSeenGeneration: 4,
        softDeleted: true))

    let fetched = try #require(
      try dao.fetchOne(itemId: itemId, serverEpisodeId: "episode-1"))

    #expect(fetched.id == inserted.id)
    #expect(fetched.accountId == accountId)
    #expect(fetched.itemId == itemId)
    #expect(fetched.serverEpisodeId == "episode-1")
    #expect(fetched.title == "Episode One")
    #expect(fetched.subtitle == "")
    #expect(fetched.episodeDescription == "<p>Shown offline</p>")
    #expect(fetched.seasonNumber == "2")
    #expect(fetched.episodeNumber == "7")
    #expect(fetched.episodeType == "full")
    #expect(fetched.mimeType == "audio/mpeg")
    #expect(fetched.durationSeconds == 1_234.5)
    #expect(fetched.sizeBytes == 98_765)
    #expect(fetched.publishedAt == publishedAt)
    #expect(fetched.storedAudioIno == "audio-ino-1")
    #expect(fetched.storedAudioExpectedSize == 98_765)
    #expect(fetched.storedAudioMimeType == "audio/mpeg")
    #expect(fetched.storedAudioDurationSeconds == 1_234.5)
    #expect(fetched.lastSeenGeneration == 4)
    #expect(fetched.softDeleted)
  }

  @Test func repeatedUpsertKeepsIdentityAndCanClearOptionalMetadata() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId) = try await seedPodcast(database)
    let dao = PodcastEpisodeDAO(database: database)
    let original = try dao.upsert(
      PodcastEpisodeRecord(
        accountId: accountId,
        itemId: itemId,
        serverEpisodeId: "episode-1",
        title: "Old title",
        subtitle: "Old subtitle",
        episodeDescription: "Old description",
        seasonNumber: "1",
        episodeNumber: "2",
        episodeType: "trailer",
        mimeType: "audio/mp4",
        durationSeconds: 10,
        sizeBytes: 20,
        publishedAt: Date(timeIntervalSince1970: 100),
        storedAudioIno: "old-ino",
        storedAudioExpectedSize: 20,
        storedAudioMimeType: "audio/mp4",
        storedAudioDurationSeconds: 10,
        lastSeenGeneration: 1))

    let updated = try dao.upsert(
      PodcastEpisodeRecord(
        accountId: accountId,
        itemId: itemId,
        serverEpisodeId: "episode-1",
        title: "New title",
        lastSeenGeneration: 2))

    // `upsert` returns the caller's own record with `id` patched in and never re-reads the row,
    // so every assertion below reads the database. Asserting on `updated` would pass even if the
    // write skipped nil columns instead of clearing them.
    let stored = try #require(
      try dao.fetchOne(itemId: itemId, serverEpisodeId: "episode-1"))

    #expect(updated.id == original.id)
    #expect(stored.id == original.id)
    #expect(try dao.fetchAll(itemId: itemId).count == 1, "the upsert updated in place, never inserted")
    #expect(stored.title == "New title")
    #expect(stored.subtitle == nil)
    #expect(stored.episodeDescription == nil)
    #expect(stored.seasonNumber == nil)
    #expect(stored.episodeNumber == nil)
    #expect(stored.episodeType == nil)
    #expect(stored.mimeType == nil)
    #expect(stored.durationSeconds == nil)
    #expect(stored.sizeBytes == nil)
    #expect(stored.publishedAt == nil)
    #expect(stored.storedAudioIno == nil)
    #expect(stored.storedAudioExpectedSize == nil)
    #expect(stored.storedAudioMimeType == nil)
    #expect(stored.storedAudioDurationSeconds == nil)
    #expect(stored.lastSeenGeneration == 2)
    #expect(stored.softDeleted == false)
  }

  private func seedPodcast(_ database: AppDatabase) async throws -> (accountId: Int64, itemId: Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: "https://example.com",
        serverUserId: "user-1",
        serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!,
        serverLibraryId: "podcasts",
        mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)

      var item = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: "show-1",
        mediaKind: "podcast",
        title: "Show",
        sortTitle: "show")
      try item.insert(db)

      return (account.id!, item.id!)
    }
  }
}
