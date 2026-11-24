import Foundation
import GRDB
import Testing

@testable import Persistence

/// v93: a downloaded RSS episode's own measured length, on its download row.
@Suite struct RSSDownloadDurationStoreTests {
  struct Seed {
    let database: AppDatabase
    let downloads: RSSDownloadStore
    let store: RSSDownloadDurationStore
    let feedID: Int64
    let episodeID: Int64
    let downloadID: Int64

    /// Measures the completed download as the resolver would: read, then a conditional write.
    func record(_ seconds: Double) async throws {
      let observed = try #require(try await store.measuredDuration(episodeId: episodeID))
      #expect(
        try await store.recordMeasuredDuration(
          episodeId: episodeID, observed: observed, seconds: seconds))
    }
  }

  /// A feed with one episode declaring `declared` seconds, and a download of it.
  static func seed(declared: Double? = 1_800, complete: Bool = true) async throws -> Seed {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed-\(UUID().uuidString).xml")!, title: "Show",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", title: "Episode",
          enclosureURL: URL(string: "https://example.com/a.mp3")!, enclosureType: "audio/mpeg",
          declaredBytes: 10, durationSeconds: declared)
      ])
    let episodeID = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(
          db, sql: "SELECT id FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
      })
    let downloads = try RSSDownloadStore(database: database)
    let downloadID = try #require(try await downloads.claimOrCreateAsync(episodeId: episodeID).id)
    if complete {
      _ = try await downloads.transitionAsync(downloadId: downloadID, to: .downloading)
      _ = try await downloads.completeAsync(downloadId: downloadID, actualBytes: 10)
    }
    return Seed(
      database: database, downloads: downloads, store: RSSDownloadDurationStore(database: database),
      feedID: feedID, episodeID: episodeID, downloadID: downloadID)
  }

  /// Completes a download of `episodeID` and stores `seconds` as its measured length, for the
  /// reader suites. Returns the download row id.
  @discardableResult
  static func downloadAndMeasure(
    _ database: AppDatabase, episodeID: Int64, seconds: Double
  ) async throws -> Int64 {
    let downloads = try RSSDownloadStore(database: database)
    let downloadID = try #require(
      try await downloads.claimOrCreateAsync(
        episodeId: episodeID, relativePath: "rss/\(episodeID).mp3", expectedBytes: 10
      ).id)
    _ = try await downloads.transitionAsync(downloadId: downloadID, to: .downloading)
    _ = try await downloads.completeAsync(downloadId: downloadID, actualBytes: 10)
    let store = RSSDownloadDurationStore(database: database)
    let observed = try #require(try await store.measuredDuration(episodeId: episodeID))
    #expect(
      try await store.recordMeasuredDuration(
        episodeId: episodeID, observed: observed, seconds: seconds))
    return downloadID
  }

  /// Removes a completed download the way the user does, through to the row's deletion.
  static func deleteDownload(_ database: AppDatabase, downloadID: Int64) async throws {
    let downloads = try RSSDownloadStore(database: database)
    _ = try await downloads.transitionAsync(downloadId: downloadID, to: .deleting)
    try await downloads.finalizeDeletionAsync(downloadId: downloadID)
  }

  private static func storedColumn(_ seed: Seed) async throws -> Double? {
    try await seed.database.readAsync { db in
      try Double.fetchOne(
        db, sql: "SELECT measuredDurationSeconds FROM rssDownload WHERE id = ?",
        arguments: [seed.downloadID])
    }
  }

  @Test func v93AddsANullableColumnToTheDownloadRow() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let column = try #require(
        try db.columns(in: "rssDownload").first { $0.name == "measuredDurationSeconds" })
      #expect(column.type == "DOUBLE")
      #expect(column.isNotNull == false)
    }
  }

  @Test func aCompletedDownloadStartsUnmeasured() async throws {
    let seed = try await Self.seed()

    let read = try await seed.store.measuredDuration(episodeId: seed.episodeID)

    #expect(read?.downloadId == seed.downloadID)
    #expect(read?.seconds == nil)
  }

  @Test func onlyACompletedDownloadAnswers() async throws {
    let seed = try await Self.seed(complete: false)

    #expect(try await seed.store.measuredDuration(episodeId: seed.episodeID) == nil)
  }

  @Test func aMeasurementIsStoredWithoutTouchingUpdatedAt() async throws {
    let seed = try await Self.seed()
    let before = try #require(try await seed.downloads.fetchAsync(downloadId: seed.downloadID))

    try await seed.record(2_080)

    #expect(try await seed.store.measuredDuration(episodeId: seed.episodeID)?.seconds == 2_080)
    // The chapter cache's conditional write compares `updatedAt` too; bumping it would drop a
    // chapter parse that raced this measurement.
    #expect(try await seed.downloads.fetchAsync(downloadId: seed.downloadID)?.updatedAt == before.updatedAt)
  }

  @Test func anUnusableMeasurementIsNeverStored() async throws {
    let seed = try await Self.seed()
    let observed = try #require(try await seed.store.measuredDuration(episodeId: seed.episodeID))

    for seconds in [0, -1, Double.infinity, Double.nan] {
      #expect(
        try await seed.store.recordMeasuredDuration(
          episodeId: seed.episodeID, observed: observed, seconds: seconds) == false)
    }
    #expect(try await Self.storedColumn(seed) == nil)
  }

  @Test func aMeasurementThatRacedAReDownloadIsDropped() async throws {
    let seed = try await Self.seed()
    let observed = try #require(try await seed.store.measuredDuration(episodeId: seed.episodeID))
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .failed)
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .pending)
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .downloading)
    _ = try await seed.downloads.completeAsync(
      downloadId: seed.downloadID, actualBytes: 20, now: observed.observedAt.addingTimeInterval(1))

    let kept = try await seed.store.recordMeasuredDuration(
      episodeId: seed.episodeID, observed: observed, seconds: 2_080)

    #expect(kept == false)
    #expect(try await Self.storedColumn(seed) == nil)
  }

  @Test func aMeasurementOfADownloadNoLongerCompletedIsDropped() async throws {
    let seed = try await Self.seed()
    let observed = try #require(try await seed.store.measuredDuration(episodeId: seed.episodeID))
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .deleting)

    #expect(
      try await seed.store.recordMeasuredDuration(
        episodeId: seed.episodeID, observed: observed, seconds: 2_080) == false)
  }

  @Test func reCompletingTheDownloadForgetsTheLength() async throws {
    let seed = try await Self.seed()
    try await seed.record(2_080)
    // Force the stale value through to `complete`, which must clear it on its own.
    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .failed)
    try await seed.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET measuredDurationSeconds = 2080, state = 'downloading' WHERE id = ?",
        arguments: [seed.downloadID])
    }

    _ = try await seed.downloads.completeAsync(downloadId: seed.downloadID, actualBytes: 20)

    #expect(try await Self.storedColumn(seed) == nil)
  }

  @Test func leavingCompletedForgetsTheLength() async throws {
    let seed = try await Self.seed()
    try await seed.record(2_080)

    _ = try await seed.downloads.transitionAsync(downloadId: seed.downloadID, to: .deleting)

    #expect(try await Self.storedColumn(seed) == nil)
  }

  /// The device purge marks rows `deleting` with a raw UPDATE that keeps the column; readers must
  /// still ignore it.
  @Test func aPurgeMarkedDownloadKeepsTheColumnButNoLongerAnswers() async throws {
    let seed = try await Self.seed()
    try await seed.record(2_080)

    _ = try await seed.downloads.markAllDeletingAsync()

    #expect(try await Self.storedColumn(seed) == 2_080)
    #expect(try await seed.store.measuredDuration(episodeId: seed.episodeID) == nil)
  }

  /// Backup describes the episode for another device, which will not have this file.
  @Test func backupKeepsTheFeedLength() async throws {
    let seed = try await Self.seed(declared: 2_184)
    try await seed.record(2_080)
    _ = try await RSSEpisodeStateStore(database: seed.database).recordTick(
      episodeId: seed.episodeID, position: 600, finished: false, capturedSequence: 0, now: Date())

    let contents = try await NativePodcastBackupReader(database: seed.database).contents()

    #expect(contents.episodes.map(\.duration) == [2_184])
  }
}
