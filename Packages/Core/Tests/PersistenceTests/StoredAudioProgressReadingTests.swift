import Foundation
import GRDB
import Testing

@testable import Persistence

/// The phone's stored audio position for one title with the time it last changed, which the
/// Watch's pending-progress report is weighed against at start.
@Suite struct StoredAudioProgressReadingTests {
  private let localTime = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let serverTime = Date(timeIntervalSinceReferenceDate: 700_000_000)

  @Test func aLocalWriteIsDatedByItsOwnTime() async throws {
    let (reading, database) = try await fixture(origin: .local)
    _ = database
    let stored = try #require(reading.currentAudioProgress(itemId: "book", episodeId: nil))
    #expect(stored == StoredAudioProgress(position: 120, isFinished: false, changedAt: localTime))
  }

  @Test func aPulledValueIsDatedByTheServer() async throws {
    let (reading, database) = try await fixture(origin: .server)
    _ = database
    #expect(reading.currentAudioProgress(itemId: "book", episodeId: nil)?.changedAt == serverTime)
  }

  @Test func anEpisodeReadsItsOwnRowNotItsShow() async throws {
    let (reading, database) = try await fixture(origin: .local, episode: "episode-1")
    _ = database
    #expect(reading.currentAudioProgress(itemId: "book", episodeId: nil) == nil)
    #expect(reading.currentAudioProgress(itemId: "book", episodeId: "episode-1")?.position == 120)
    #expect(reading.currentAudioProgress(itemId: "book", episodeId: "other") == nil)
  }

  @Test func anUnknownTitleHasNoProgress() async throws {
    let (reading, database) = try await fixture(origin: .local)
    _ = database
    #expect(reading.currentAudioProgress(itemId: "missing", episodeId: nil) == nil)
  }

  private func fixture(
    origin: ProgressOrigin, episode: String? = nil
  ) async throws -> (DefaultLibraryReading, AppDatabase) {
    let database = try AppDatabase.inMemory()
    let localTime = localTime
    let serverTime = serverTime
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "book", mediaKind: "book",
        title: "Book", sortTitle: "book")
      try item.insert(db)
      var episodeRowID: Int64?
      if let episode {
        var record = PodcastEpisodeRecord(
          accountId: account.id!, itemId: item.id!, serverEpisodeId: episode, title: "Episode",
          lastSeenGeneration: 1)
        try record.insert(db)
        episodeRowID = record.id
      }
      var progress = MediaProgressRecord(
        accountId: account.id!, itemId: item.id!, podcastEpisodeId: episodeRowID, currentTime: 120,
        isFinished: false, serverUpdatedAt: serverTime, localSequence: 1, origin: origin,
        originKey: origin == .server ? ProgressOrigin.serverOriginKey : "client", lastActivityAt: localTime)
      try progress.insert(db)
    }
    return (DefaultLibraryReading(database: database), database)
  }
}
