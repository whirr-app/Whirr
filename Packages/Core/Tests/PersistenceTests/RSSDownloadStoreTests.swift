import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct RSSDownloadStoreTests {
  @Test func claimIsIdempotentAndLaunchRecoversDownloadingRows() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: "Feed", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", enclosureURL: URL(string: "https://example.com/a.mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: 10)
      ])
    let episode = try #require(
      try await database.readAsync { db in
        try RSSEpisodeRecord.fetchOne(db, sql: "SELECT * FROM rssEpisode LIMIT 1")
      })
    let store = try RSSDownloadStore(database: database)
    let first = try await store.claimOrCreateAsync(episodeId: episode.id!)
    let second = try await store.claimOrCreateAsync(episodeId: episode.id!)
    #expect(first.id == second.id)
    _ = try await store.transitionAsync(downloadId: first.id!, to: .downloading)
    let reopened = try RSSDownloadStore(database: database)
    #expect(try await reopened.fetchAsync(downloadId: first.id!)?.state == .interrupted)
  }

  @Test("episode presence is keyed by the native identity and summarised by the ABS rule")
  func episodePresenceIsKeyedByTheNativeIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let done = try await seedDownload(database: database, suffix: "done")
    let going = try await seedDownload(database: database, suffix: "going")
    let gone = try await seedDownload(database: database, suffix: "gone")
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET state = 'completed' WHERE id = ?", arguments: [done.downloadID])
      try db.execute(
        sql: "UPDATE rssDownload SET state = 'downloading' WHERE id = ?",
        arguments: [going.downloadID])
      try db.execute(
        sql: "UPDATE rssDownload SET state = 'deleting' WHERE id = ?", arguments: [gone.downloadID])
    }

    let presence = try await database.readAsync { db in try RSSDownloadStore.episodePresence(db) }

    #expect(presence[Self.key(feedID: done.feedID, episode: "done")] == .completed)
    #expect(presence[Self.key(feedID: going.feedID, episode: "going")] == .partial)
    #expect(presence[Self.key(feedID: gone.feedID, episode: "gone")] == .deleting)
    #expect(presence.count == 3)
  }

  @Test("the shared episode presence projection carries native rows beside account ones")
  func theSharedEpisodePresenceProjectionCarriesNativeRows() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await seedDownload(database: database, suffix: "episode")
    let reading = DefaultDownloadReading(database: database)
    let key = Self.key(feedID: seeded.feedID, episode: "episode")

    let observations = PersistenceObservationCollector(reading.observeEpisodeDownloadPresence())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(observations.values.first?[key] == .partial, "a claimed row is pending, so partial")

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET state = 'completed' WHERE id = ?",
        arguments: [seeded.downloadID])
    }
    #expect(
      await TestSupport.waitUntil { observations.values.last?[key] == .completed },
      "completion re-emits through the projection the player's overflow menu reads")
  }

  private static func key(feedID: Int64, episode: String) -> EpisodeDownloadKey {
    EpisodeDownloadKey(
      itemID: PodcastSourceIdentity.rss(feedId: feedID)!.itemId, episodeID: episode)
  }

  @Test func exactPathAndSizePolicyAreStable() {
    let url = URL(string: "https://cdn.example.com/audio.mp3?token=unsafe")!
    #expect(
      RSSFileStore.destinationRelativePath(
        feedId: 4, episodeRowId: 9, enclosureURL: url, enclosureMimeType: "audio/mpeg; charset=utf-8")
        == "RSS/4/9.mp3")
    #expect(RSSFileStore.sizeCapBytes == 1_073_741_824)
  }

  @Test func credentialUpdateReleasesOnlyMatchingFeedCredentialHolds() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await seedDownload(database: database, suffix: "one")
    let second = try await seedDownload(database: database, suffix: "two")
    let store = try RSSDownloadStore(database: database)
    for row in [first, second] {
      _ = try await store.transitionAsync(downloadId: row.downloadID, to: .downloading)
      _ = try await store.transitionAsync(
        downloadId: row.downloadID, to: .pausedAuth, holdReason: .feedCredentials,
        errorCode: .auth)
    }

    #expect(try await store.releaseFeedCredentialHolds(feedId: first.feedID) == 1)

    let released = try #require(try await store.fetchAsync(downloadId: first.downloadID))
    let untouched = try #require(try await store.fetchAsync(downloadId: second.downloadID))
    #expect(released.state == .pending)
    #expect(released.holdReason == nil)
    #expect(released.errorCode == nil)
    #expect(untouched.state == .pausedAuth)
    #expect(untouched.holdReason == .feedCredentials)
  }

  @Test("a transfer's reported size backfills a feed that declared none")
  func transferSizeBackfillsAnUndeclaredRow() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await seedDownload(database: database, suffix: "sizeless", declaredBytes: nil)
    let store = try RSSDownloadStore(database: database)
    _ = try await store.transitionAsync(downloadId: seeded.downloadID, to: .downloading)

    let updated = try await store.updateProgressAsync(
      downloadId: seeded.downloadID, actualBytes: 512, expectedBytes: 4096)

    #expect(updated.actualBytes == 512)
    #expect(
      updated.expectedBytes == 4096,
      "Content-Length is the only size such a feed will ever offer, so it has to be kept")
    #expect(try await store.fetchAsync(downloadId: seeded.downloadID)?.expectedBytes == 4096)
  }

  @Test("a declared size outranks the transfer's, and an absent transfer size erases nothing")
  func transferSizeNeverOverwritesADeclaredOne() async throws {
    let database = try AppDatabase.inMemory()
    let declared = try await seedDownload(database: database, suffix: "declared", declaredBytes: 10)
    let sizeless = try await seedDownload(database: database, suffix: "chunked", declaredBytes: nil)
    let store = try RSSDownloadStore(database: database)
    for row in [declared, sizeless] {
      _ = try await store.transitionAsync(downloadId: row.downloadID, to: .downloading)
    }

    // A redirect or a ranged retry can report a different total mid-flight; the feed's own
    // number is the one the size text and the ring were already drawn from.
    let kept = try await store.updateProgressAsync(
      downloadId: declared.downloadID, actualBytes: 4, expectedBytes: 4096)
    #expect(kept.expectedBytes == 10)

    // A chunked response reports no total at all. That is not a correction to nil.
    _ = try await store.updateProgressAsync(
      downloadId: sizeless.downloadID, actualBytes: 8, expectedBytes: 4096)
    let unchanged = try await store.updateProgressAsync(
      downloadId: sizeless.downloadID, actualBytes: 16, expectedBytes: nil)
    #expect(unchanged.expectedBytes == 4096)

    // Neither is a non-positive report, which is what a `-1` transfer size would arrive as.
    let ignored = try await store.updateProgressAsync(
      downloadId: sizeless.downloadID, actualBytes: 24, expectedBytes: 0)
    #expect(ignored.expectedBytes == 4096)
  }

  private func seedDownload(
    database: AppDatabase, suffix: String, declaredBytes: Int64? = 10
  ) async throws -> (feedID: Int64, downloadID: Int64) {
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(suffix).xml")!, title: suffix, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodes = RSSEpisodeStore(database: database)
    _ = try await episodes.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: suffix,
          enclosureURL: URL(string: "https://example.com/\(suffix).mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: declaredBytes)
      ])
    let episode = try #require(await episodes.fetchEpisode(feedId: feedID, identityKey: suffix))
    let store = try RSSDownloadStore(database: database)
    let download = try await store.claimOrCreateAsync(episodeId: try #require(episode.id))
    return (feedID, try #require(download.id))
  }

}
