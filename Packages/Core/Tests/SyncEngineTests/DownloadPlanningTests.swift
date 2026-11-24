import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `DownloadCoordinator.requestDownload` planning: one expanded detail fetch per request, never
/// per file (API-CONVENTIONS.md rule 15).
@Suite struct DownloadPlanningTests {

  @Test func invalidAccountServerURLProducesMissingHostConfigurationError() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await harness.database.writeAsync { db in
      var record = try AccountRecord.fetchOne(db)!
      record.serverBaseURL = "http://[invalid"
      try record.update(db)
    }

    await #expect(throws: APIError.invalidServerConfiguration(.missingHost)) {
      try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    }
  }

  @Test func fetchesDetailOnceAndCreatesARowPerCatalogFileWithIdentityOrderExpectedSizeMimeAndDuration()
    async throws
  {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 1000, mimeType: "audio/mp4", duration: 60),
      (index: 1, ino: 101, size: 2000, mimeType: "audio/mp4", duration: 120),
    ])

    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)

    #expect(harness.http.requests.count == 1)
    #expect(harness.http.requests[0].url.host == "downloads.example.test")
    #expect(harness.http.requests[0].url.path == "/api/items/\(DownloadCoordinatorHarness.itemID)")
    #expect(harness.http.requests[0].routeTemplate == "/api/items/:id")

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.count == 2)
    #expect(rows[0].orderIndex == 0)
    #expect(rows[0].serverFileIno == "100")
    #expect(rows[0].expectedBytes == 1000)
    #expect(rows[0].expectedMimeType == "audio/mp4")
    #expect(rows[0].fileDurationSeconds == 60)
    #expect(
      rows[0].destinationRelativePath
        == DownloadFileStore.destinationRelativePath(
          accountId: harness.accountId,
          itemId: harness.itemRowId,
          podcastEpisodeId: nil,
          orderIndex: 0,
          serverFileIno: "100",
          mimeType: "audio/mp4"))
    #expect(rows[0].mediaKind == .audio)
    #expect(rows[0].podcastEpisodeId == nil)
    #expect(rows[0].origin == .manual)
    #expect(rows[1].orderIndex == 1)
    #expect(rows[1].serverFileIno == "101")
    #expect(rows[1].expectedBytes == 2000)
  }

  @Test func emptyCatalogRejectsTheWholePlanWithAMetadataValidationCategoryAndCreatesNoRows() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [])

    await #expect(throws: DownloadPlanningError.metadataValidationFailed) {
      try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    }

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.isEmpty)
    #expect(harness.diagnostics.recorded.contains { $0.category == .download && $0.statusClass == .clientError })
  }

  @Test func nonzeroInvalidEntryCountRejectsTheWholePlanAndCreatesNoRows() async throws {
    let harness = try await DownloadCoordinatorHarness()
    // One valid entry plus one malformed (missing "ino") -> invalidEntryCount == 1.
    let object: [String: Any] = [
      "id": DownloadCoordinatorHarness.itemID, "libraryId": "lib-1", "mediaType": "book",
      "media": [
        "metadata": ["title": "Test Book"], "duration": 60.0,
        "audioFiles": [
          ["index": 0, "ino": 100, "duration": 60.0, "mimeType": "audio/mp4", "metadata": ["size": 1000]],
          ["index": 1, "duration": 60.0, "mimeType": "audio/mp4", "metadata": ["size": 1000]],
        ],
        "tracks": [[String: Any]](), "chapters": [[String: Any]](),
      ] as [String: Any],
    ]
    harness.http.enqueue(DownloadCoordinatorHarness.jsonResponse(object: object))

    await #expect(throws: DownloadPlanningError.metadataValidationFailed) {
      try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    }

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.isEmpty, "an invalid entry rejects the whole plan, never a partial set of rows")
  }

  @Test func repeatRequestsAreIdempotentAndFetchDetailOnlyOnce() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 1000, mimeType: "audio/mp4", duration: 60)
    ])

    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)

    #expect(harness.http.requests.count == 1)
    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.count == 1)
  }

  /// An item-level request against a podcast show can never succeed (episodes are planned one at a
  /// time by `requestEpisodeDownload`), so it is rejected from the locally cached media kind
  /// without spending an expanded item-detail fetch (API-CONVENTIONS.md rule 15).
  @Test func podcastRequestIsRejectedFromLocalStateWithoutEverFetchingDetail() async throws {
    let harness = try await DownloadCoordinatorHarness()

    await #expect(throws: DownloadPlanningError.podcastEpisodesUnsupported) {
      try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.podcastItemID)
    }

    #expect(harness.http.requests.isEmpty)
    let rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    #expect(rows.isEmpty)
  }

  /// Whole-item ("book") downloads have no automatic planning path, since `requestDownload` takes
  /// no origin argument. Every row it creates stays `.manual`.
  @Test func bookDownloadsRemainManual() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 1000, mimeType: "audio/mp4", duration: 60),
      (index: 1, ino: 101, size: 2000, mimeType: "audio/mp4", duration: 120),
    ])

    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.isEmpty == false)
    #expect(rows.allSatisfy { $0.origin == .manual })
  }

  @Test func anUnknownItemThrowsBeforeEverFetchingDetail() async throws {
    let harness = try await DownloadCoordinatorHarness()

    await #expect(throws: DownloadPlanningError.unknownItem("never-synced-item")) {
      try await harness.coordinator.requestDownload(itemID: "never-synced-item")
    }
    #expect(harness.http.requests.isEmpty)
  }

  /// `AccountRemovalCoordinator` calls `beginAccountRemoval()` at its `.intentsStopped` boundary,
  /// before the purge. A request admitted after that point would enqueue a background transfer
  /// still authorised for the account being removed, and the purge would never see its row. So
  /// planning refuses from local state, without spending a detail fetch.
  @Test func planningIsRefusedOnceAccountRemovalHasBegun() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [
      (index: 0, ino: 100, size: 1000, mimeType: "audio/mp4", duration: 60)
    ])

    await harness.coordinator.beginAccountRemoval()

    await #expect(throws: DownloadPlanningError.accountRemovalInProgress) {
      try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    }
    await #expect(throws: DownloadPlanningError.accountRemovalInProgress) {
      try await harness.coordinator.requestEbookDownload(itemID: DownloadCoordinatorHarness.itemID)
    }

    #expect(harness.http.requests.isEmpty)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  // MARK: - Reclaiming a tombstoned episode's stranded download

  /// The show screen only lists episodes with `softDeleted = 0`, so a download whose episode the
  /// publisher pulled from the feed loses its per-episode remove affordance. The bytes stay
  /// reported (`DownloadStore.tombstonedEpisodeDownloads`) and this explicit intent reclaims only
  /// them, leaving every still-listed episode's download alone.
  @Test func purgeTombstonedEpisodeDownloadsReclaimsOnlyRowsBehindASoftDeletedEpisode() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let live = try await harness.seedPodcastEpisode(episodeID: "episode-live", storedAudioIno: "ino-live")
    let gone = try await harness.seedPodcastEpisode(episodeID: "episode-gone", storedAudioIno: "ino-gone")

    for episodeID in ["episode-live", "episode-gone"] {
      try await harness.coordinator.requestEpisodeDownload(
        itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: episodeID)
    }
    let rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    let liveRowId = try #require(rows.first { $0.podcastEpisodeId == live.id }?.id)
    let goneRowId = try #require(rows.first { $0.podcastEpisodeId == gone.id }?.id)

    // The next structurally-complete refresh no longer sees the episode and tombstones it.
    try await harness.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [gone.id])
    }
    #expect(try harness.downloadStore.tombstonedEpisodeDownloads().compactMap(\.id) == [goneRowId])

    try await harness.coordinator.purgeTombstonedEpisodeDownloads(source: .storage)

    #expect(try harness.downloadStore.fetch(downloadId: goneRowId) == nil)
    #expect(try harness.downloadStore.fetch(downloadId: liveRowId) != nil)
    #expect(try harness.downloadStore.tombstonedEpisodeDownloads().isEmpty)
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: goneRowId))))
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: liveRowId))) == false)
  }
}
