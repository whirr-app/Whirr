import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct DownloadStatusReducerTests {
  @Test("item-level status follows the full reducer contract")
  func itemLevelStatusFollowsFullReducerContract() async throws {
    for testCase in Self.statusCases() {
      let (itemStatus, _) = try await Self.evaluate(testCase)
      #expect(itemStatus == testCase.expected, "item status: \(testCase.name)")
    }
  }

  @Test("episode-level status follows the full reducer contract")
  func episodeLevelStatusFollowsFullReducerContract() async throws {
    for testCase in Self.statusCases() {
      let (_, episodeStatus) = try await Self.evaluate(testCase)
      #expect(episodeStatus == testCase.expected, "episode status: \(testCase.name)")
    }
  }

  @Test("item-level and episode-level status agree for the same rows")
  func itemAndEpisodeProjectionsAgreeForSameRows() async throws {
    for testCase in Self.statusCases() {
      let (itemStatus, episodeStatus) = try await Self.evaluate(testCase)
      #expect(itemStatus == episodeStatus, "callers disagree: \(testCase.name)")
    }
  }

  private static func statusCases() -> [(name: String, rows: [RowSpec], expected: ItemDownloadStatus)] {
    [
      ("no rows", [], .notDownloaded),
      ("all rows deleting", [RowSpec(state: .deleting)], .deleting),
      (
        "paused auth outranks failed",
        [
          RowSpec(state: .failed, errorCategory: .lowDisk),
          RowSpec(state: .pausedAuth),
        ],
        .pausedAuth
      ),
      (
        "failed outranks paused",
        [
          RowSpec(state: .paused),
          RowSpec(state: .failed, errorCategory: .validation),
        ],
        .failed(category: .validation)
      ),
      (
        "paused outranks downloading",
        [RowSpec(state: .downloading), RowSpec(state: .paused)],
        .paused
      ),
      (
        "downloading aggregates every live row and ignores deleting rows",
        [
          RowSpec(state: .downloading, expectedBytes: 100, receivedBytes: 25),
          RowSpec(
            state: .pending, expectedBytes: 200, receivedBytes: 50,
            holdReason: .waitingForWiFi),
          RowSpec(state: .completed, expectedBytes: 100, receivedBytes: 100),
          RowSpec(state: .deleting, expectedBytes: 100, receivedBytes: 100),
        ],
        .downloading(progressFraction: 0.4375)
      ),
      (
        "waiting for Wi-Fi outranks interrupted and queued",
        [
          RowSpec(state: .pending, holdReason: .waitingForWiFi),
          RowSpec(state: .interrupted),
          RowSpec(state: .pending),
        ],
        .waitingForWiFi
      ),
      (
        "interrupted outranks queued",
        [RowSpec(state: .interrupted), RowSpec(state: .pending)],
        .interrupted
      ),
      ("pending is queued", [RowSpec(state: .pending)], .queued),
      ("all rows completed", [RowSpec(state: .completed)], .completed),
    ]
  }

  private static func evaluate(
    _ testCase: (name: String, rows: [RowSpec], expected: ItemDownloadStatus)
  ) async throws -> (item: ItemDownloadStatus, episode: ItemDownloadStatus) {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedPodcast(database)
    let rows = testCase.rows.enumerated().map { index, spec in
      DownloadRecord(
        accountId: seeded.accountId,
        itemId: seeded.itemId,
        podcastEpisodeId: seeded.episodeId,
        serverFileIno: "file-\(index)",
        orderIndex: index,
        destinationRelativePath: "episode/\(index).mp3",
        expectedBytes: spec.expectedBytes,
        expectedMimeType: "audio/mpeg",
        fileDurationSeconds: 60,
        receivedBytes: spec.receivedBytes,
        state: spec.state,
        holdReason: spec.holdReason,
        errorCategory: spec.errorCategory)
    }
    try await database.writeAsync { db in
      for var row in rows {
        try row.insert(db)
      }
    }

    let itemStatus = try database.read { db in
      try DownloadStore.itemStatus(db, itemId: seeded.itemId)
    }
    let context = try #require(
      await DefaultPodcastReading(database: database).episode(
        itemID: seeded.serverItemId, episodeID: seeded.episodeServerId))
    return (itemStatus, context.episode.downloadStatus)
  }

  private struct RowSpec: Sendable {
    let state: DownloadState
    let expectedBytes: Int64
    let receivedBytes: Int64
    let holdReason: DownloadHoldReason?
    let errorCategory: DownloadErrorCategory?

    init(
      state: DownloadState,
      expectedBytes: Int64 = 100,
      receivedBytes: Int64 = 0,
      holdReason: DownloadHoldReason? = nil,
      errorCategory: DownloadErrorCategory? = nil
    ) {
      self.state = state
      self.expectedBytes = expectedBytes
      self.receivedBytes = receivedBytes
      self.holdReason = holdReason
      self.errorCategory = errorCategory
    }
  }

  private static func seedPodcast(_ database: AppDatabase) async throws -> (
    accountId: Int64, itemId: Int64, serverItemId: String, episodeId: Int64, episodeServerId: String
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: "https://example.com",
        serverUserId: "user",
        serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)

      let serverItemId = "show-1"
      var item = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: serverItemId,
        mediaKind: "podcast",
        title: "Show",
        sortTitle: "show")
      try item.insert(db)

      let episodeServerId = "episode-1"
      var episode = PodcastEpisodeRecord(
        accountId: account.id!,
        itemId: item.id!,
        serverEpisodeId: episodeServerId,
        title: "Episode",
        durationSeconds: 60,
        lastSeenGeneration: 1)
      try episode.insert(db)

      return (
        account.id!, item.id!, serverItemId, episode.id!, episodeServerId
      )
    }
  }
}
