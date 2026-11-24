import Foundation
import GRDB
import Testing

@testable import Persistence

/// v75: chapters read out of a downloaded native RSS episode, cached per download.
@Suite struct RSSEpisodeChapterStoreTests {
  private struct Seed {
    let database: AppDatabase
    let downloads: RSSDownloadStore
    let store: RSSEpisodeChapterStore
    let feedID: Int64
    let episodeID: Int64
    let downloadID: Int64
  }

  private static func chapters(_ count: Int) -> [RSSStoredChapter] {
    (0..<count).map {
      RSSStoredChapter(
        start: Double($0) * 60, end: Double($0 + 1) * 60, title: "Chapter \($0)")
    }
  }

  private static func seed(complete: Bool = true) async throws -> Seed {
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
    let episodeID = try #require(
      try await database.readAsync { db in
        try RSSEpisodeRecord.fetchOne(db, sql: "SELECT * FROM rssEpisode LIMIT 1")?.id
      })
    let downloads = try RSSDownloadStore(database: database)
    let row = try await downloads.claimOrCreateAsync(episodeId: episodeID)
    let downloadID = try #require(row.id)
    if complete {
      _ = try await downloads.transitionAsync(downloadId: downloadID, to: .downloading)
      _ = try await downloads.completeAsync(downloadId: downloadID, actualBytes: 10)
    }
    return Seed(
      database: database, downloads: downloads,
      store: RSSEpisodeChapterStore(database: database), feedID: feedID, episodeID: episodeID,
      downloadID: downloadID)
  }

  private static func completedAt(_ seed: Seed) async throws -> Date {
    try #require(try await seed.downloads.fetchAsync(downloadId: seed.downloadID)).updatedAt
  }

  private static func currentCache(_ seed: Seed) async throws -> RSSEpisodeChapterCache {
    try #require(try await seed.store.cache(episodeId: seed.episodeID))
  }

  private static func rowCount(_ seed: Seed) async throws -> Int {
    try await seed.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisodeChapter") ?? 0
    }
  }

  @Test func v75CreatesTheTableAndMarkerColumn() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      #expect(try db.tableExists("rssEpisodeChapter"))
      #expect(try db.columns(in: "rssDownload").contains { $0.name == "chaptersExtractedAt" })
      let uniqueIndex = try db.indexes(on: "rssEpisodeChapter").first { $0.isUnique }
      #expect(uniqueIndex?.columns == ["episodeId", "position"])
      let foreignKey = try #require(try db.foreignKeys(on: "rssEpisodeChapter").first)
      #expect(foreignKey.destinationTable == "rssEpisode")
      #expect(foreignKey.originColumns == ["episodeId"])
    }
  }

  @Test func aCompletedDownloadThatWasNeverParsedHasNoCachedChapters() async throws {
    let seed = try await Self.seed()

    let cache = try await seed.store.cache(episodeId: seed.episodeID)

    #expect(cache?.downloadId == seed.downloadID)
    #expect(cache?.chapters == nil)
  }

  @Test func anEpisodeWithoutACompletedDownloadHasNoCache() async throws {
    let seed = try await Self.seed(complete: false)

    #expect(try await seed.store.cache(episodeId: seed.episodeID) == nil)
    let kept = try await seed.store.recordExtraction(
      episodeId: seed.episodeID,
      cache: RSSEpisodeChapterCache(
        downloadId: seed.downloadID, completedAt: try await Self.completedAt(seed), chapters: nil),
      chapters: Self.chapters(2))
    #expect(kept == false)
    #expect(try await Self.rowCount(seed) == 0)
  }

  @Test func recordedChaptersComeBackInOrderAndReplaceAnEarlierSnapshot() async throws {
    let seed = try await Self.seed()

    try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: try await Self.currentCache(seed), chapters: Self.chapters(3))
    #expect(
      try await seed.store.cache(episodeId: seed.episodeID)
        == RSSEpisodeChapterCache(
          downloadId: seed.downloadID, completedAt: try await Self.completedAt(seed),
          chapters: Self.chapters(3)))

    try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: try await Self.currentCache(seed), chapters: Self.chapters(1))
    #expect(try await seed.store.cache(episodeId: seed.episodeID)?.chapters == Self.chapters(1))
    #expect(try await Self.rowCount(seed) == 1)
  }

  @Test func anEmptyExtractionIsRememberedAsDone() async throws {
    let seed = try await Self.seed()

    try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: try await Self.currentCache(seed), chapters: [])

    #expect(
      try await seed.store.cache(episodeId: seed.episodeID)
        == RSSEpisodeChapterCache(
          downloadId: seed.downloadID, completedAt: try await Self.completedAt(seed), chapters: []))
  }

  @Test func anExtractionForASupersededDownloadIsRejected() async throws {
    let seed = try await Self.seed()

    let kept = try await seed.store.recordExtraction(
      episodeId: seed.episodeID,
      cache: RSSEpisodeChapterCache(
        downloadId: seed.downloadID + 100, completedAt: try await Self.completedAt(seed),
        chapters: nil),
      chapters: Self.chapters(2))

    #expect(kept == false)
    #expect(try await seed.store.cache(episodeId: seed.episodeID)?.chapters == nil)
  }

  @Test func deletingTheEpisodeCascadesToItsChapters() async throws {
    let seed = try await Self.seed()
    try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: try await Self.currentCache(seed), chapters: Self.chapters(2))

    try await seed.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM rssEpisode WHERE id = ?", arguments: [seed.episodeID])
    }

    #expect(try await Self.rowCount(seed) == 0)
  }

  @Test func removingTheDownloadClearsTheChapters() async throws {
    let seed = try await Self.seed()
    try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: try await Self.currentCache(seed), chapters: Self.chapters(2))

    _ = try await seed.downloads.markDeletingAsync(downloadId: seed.downloadID)
    try await seed.downloads.finalizeDeletionAsync(downloadId: seed.downloadID)

    #expect(try await Self.rowCount(seed) == 0)
    #expect(try await seed.store.cache(episodeId: seed.episodeID) == nil)
  }

  @Test func demotingAMissingFileClearsTheChapters() async throws {
    let seed = try await Self.seed()
    try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: try await Self.currentCache(seed), chapters: Self.chapters(2))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    let demoted = try RSSDownloadIntegritySweep(rootURL: root, downloadStore: seed.downloads)
      .validate(episodeId: seed.episodeID)

    #expect(demoted == seed.downloadID)
    #expect(try await Self.rowCount(seed) == 0)
    let marker = try await seed.database.readAsync { db in
      try Date.fetchOne(
        db, sql: "SELECT chaptersExtractedAt FROM rssDownload WHERE id = ?",
        arguments: [seed.downloadID])
    }
    #expect(marker == nil)
  }

  @Test func aReplacementDownloadIsParsedAgain() async throws {
    let seed = try await Self.seed()
    try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: try await Self.currentCache(seed), chapters: Self.chapters(2))
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .failed)
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .pending)
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .downloading)
    _ = try await seed.downloads.completeAsync(downloadId: seed.downloadID, actualBytes: 12)

    #expect(try await seed.store.cache(episodeId: seed.episodeID)?.chapters == nil)
    #expect(try await Self.rowCount(seed) == 0)
  }

  @Test func aParseOfTheFileARedownloadReplacedIsRejected() async throws {
    let seed = try await Self.seed()
    let staleCache = try await Self.currentCache(seed)
    let completed = try #require(try await seed.downloads.fetchAsync(downloadId: seed.downloadID))
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .failed)
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .pending)
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .downloading)
    _ = try await seed.downloads.completeAsync(
      downloadId: seed.downloadID, actualBytes: 12, now: completed.updatedAt.addingTimeInterval(60))

    let kept = try await seed.store.recordExtraction(
      episodeId: seed.episodeID, cache: staleCache, chapters: Self.chapters(2))

    #expect(kept == false)
    #expect(try await seed.store.cache(episodeId: seed.episodeID)?.chapters == nil)
    #expect(try await Self.rowCount(seed) == 0)
  }
}
