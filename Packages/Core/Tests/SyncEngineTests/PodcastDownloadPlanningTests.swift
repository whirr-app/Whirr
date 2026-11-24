import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite struct PodcastDownloadPlanningTests {
  @Test func storedEpisodePlansOneEpisodeScopedAuthorizedTransferWithoutRefetchingDetail() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let episode = try await harness.seedPodcastEpisode(
      episodeID: "episode-a",
      storedAudioIno: "stored-audio-ino",
      expectedSize: 4_096,
      mimeType: "audio/mpeg",
      duration: 180)
    let episodeRowID = try #require(episode.id)

    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID,
      episodeID: "episode-a")

    #expect(harness.http.requests.isEmpty)
    let row = try #require(
      harness.fetchDownloads(itemId: harness.podcastItemRowId).first)
    #expect(row.podcastEpisodeId == episodeRowID)
    #expect(row.serverFileIno == "stored-audio-ino")
    #expect(row.orderIndex == 0)
    #expect(row.expectedBytes == 4_096)
    #expect(row.expectedMimeType == "audio/mpeg")
    #expect(row.fileDurationSeconds == 180)
    #expect(
      row.destinationRelativePath
        == DownloadFileStore.destinationRelativePath(
          accountId: harness.accountId,
          itemId: harness.podcastItemRowId,
          podcastEpisodeId: episodeRowID,
          orderIndex: 0,
          serverFileIno: "stored-audio-ino",
          mimeType: "audio/mpeg"))
    #expect(row.mediaKind == .audio)
    #expect(row.origin == .manual)
    #expect(
      harness.backgroundTransferring.calls
        == [
          .enqueue(
            identity: .abs(rowID: try #require(row.id)),
            itemID: DownloadCoordinatorHarness.podcastItemID,
            fileID: "stored-audio-ino",
            destinationURL: harness.downloadFileStore.absoluteURL(
              forRelativePath: row.destinationRelativePath))
        ])
  }

  @Test func unavailableEpisodeCreatesNoRowAndDuplicateTapCoalesces() async throws {
    let harness = try await DownloadCoordinatorHarness()
    _ = try await harness.seedPodcastEpisode(
      episodeID: "unavailable",
      storedAudioIno: nil,
      expectedSize: nil,
      mimeType: nil,
      duration: nil)

    await #expect(throws: DownloadPlanningError.episodeUnavailable) {
      try await harness.coordinator.requestEpisodeDownload(
        itemID: DownloadCoordinatorHarness.podcastItemID,
        episodeID: "unavailable")
    }
    #expect(try harness.fetchDownloads(itemId: harness.podcastItemRowId).isEmpty)

    _ = try await harness.seedPodcastEpisode(episodeID: "available")
    async let first: Void = harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID,
      episodeID: "available")
    async let second: Void = harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID,
      episodeID: "available")
    _ = try await (first, second)

    #expect(try harness.fetchDownloads(itemId: harness.podcastItemRowId).count == 1)
    #expect(harness.backgroundTransferring.calls.count == 1)
  }

  @Test func unknownEpisodeUnderAKnownShowCreatesNoRowOrTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()

    await #expect(
      throws: DownloadPlanningError.unknownPodcastEpisode(
        itemID: DownloadCoordinatorHarness.podcastItemID,
        episodeID: "missing")
    ) {
      try await harness.coordinator.requestEpisodeDownload(
        itemID: DownloadCoordinatorHarness.podcastItemID,
        episodeID: "missing")
    }

    #expect(try harness.fetchDownloads(itemId: harness.podcastItemRowId).isEmpty)
    #expect(harness.backgroundTransferring.calls.isEmpty)
    #expect(harness.http.requests.isEmpty)
  }

  @Test func everyPartialOrInvalidStoredAudioTupleIsUnavailable() async throws {
    let cases:
      [(
        id: String, ino: String?, size: Int?, mime: String?, duration: Double?
      )] = [
        ("missing", nil, nil, nil, nil),
        ("empty-ino", "", 100, "audio/mpeg", 10),
        ("zero-size", "ino", 0, "audio/mpeg", 10),
        ("empty-mime", "ino", 100, "", 10),
        ("zero-duration", "ino", 100, "audio/mpeg", 0),
        ("nonfinite-duration", "ino", 100, "audio/mpeg", .infinity),
      ]

    for value in cases {
      let harness = try await DownloadCoordinatorHarness()
      _ = try await harness.seedPodcastEpisode(
        episodeID: value.id,
        storedAudioIno: value.ino,
        expectedSize: value.size,
        mimeType: value.mime,
        duration: value.duration)

      await #expect(throws: DownloadPlanningError.episodeUnavailable) {
        try await harness.coordinator.requestEpisodeDownload(
          itemID: DownloadCoordinatorHarness.podcastItemID,
          episodeID: value.id)
      }
      #expect(try harness.fetchDownloads(itemId: harness.podcastItemRowId).isEmpty)
      #expect(harness.backgroundTransferring.calls.isEmpty)
    }
  }

  @Test func siblingLifecycleActionsRemainEpisodeScopedAndPurgedEpisodeCanBeDownloadedAgain() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let episodeA = try await harness.seedPodcastEpisode(
      episodeID: "episode-a", storedAudioIno: "shared-ino")
    let episodeB = try await harness.seedPodcastEpisode(
      episodeID: "episode-b", storedAudioIno: "shared-ino")
    let episodeARowID = try #require(episodeA.id)
    let episodeBRowID = try #require(episodeB.id)

    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-b")
    var rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    let rowA = try #require(rows.first { $0.podcastEpisodeId == episodeARowID })
    let rowB = try #require(rows.first { $0.podcastEpisodeId == episodeBRowID })
    #expect(rowA.destinationRelativePath != rowB.destinationRelativePath)

    try await harness.coordinator.pauseEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    #expect(rows.first { $0.podcastEpisodeId == episodeARowID }?.state == .paused)
    #expect(rows.first { $0.podcastEpisodeId == episodeBRowID }?.state == .downloading)

    try await harness.coordinator.resumeEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    try await harness.coordinator.purgeEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a",
      source: .podcastEpisodeRemoval)
    rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    #expect(rows.contains { $0.podcastEpisodeId == episodeARowID } == false)
    #expect(rows.first { $0.podcastEpisodeId == episodeBRowID }?.state == .downloading)

    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    #expect(rows.count == 2)
  }

  // MARK: - Origin

  @Test func manualEpisodeRequestWritesManualOrigin() async throws {
    let harness = try await DownloadCoordinatorHarness()
    _ = try await harness.seedPodcastEpisode(episodeID: "episode-a")

    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")

    let row = try #require(harness.fetchDownloads(itemId: harness.podcastItemRowId).first)
    #expect(row.origin == .manual)
  }

  @Test func automaticEpisodeRequestWritesAutomaticOrigin() async throws {
    let harness = try await DownloadCoordinatorHarness()
    _ = try await harness.seedPodcastEpisode(episodeID: "episode-a")

    try await harness.coordinator.requestAutomaticEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")

    let row = try #require(harness.fetchDownloads(itemId: harness.podcastItemRowId).first)
    #expect(row.origin == .automatic)
  }

  @Test func repeatAutomaticRequestIsIdempotent() async throws {
    let harness = try await DownloadCoordinatorHarness()
    _ = try await harness.seedPodcastEpisode(episodeID: "episode-a")

    try await harness.coordinator.requestAutomaticEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    try await harness.coordinator.requestAutomaticEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")

    let rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    #expect(rows.count == 1, "a repeat automatic request finds the existing row, never a duplicate")
    #expect(rows.first?.origin == .automatic)
  }

  @Test func automaticRequestDoesNotRelabelExistingManualRow() async throws {
    let harness = try await DownloadCoordinatorHarness()
    _ = try await harness.seedPodcastEpisode(episodeID: "episode-a")

    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    try await harness.coordinator.requestAutomaticEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")

    let rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    #expect(rows.count == 1)
    #expect(rows.first?.origin == .manual, "an automatic request never relabels a manual row")
  }

  @Test func aManualRequestForAnAutomaticRowPromotesItToManual() async throws {
    let harness = try await DownloadCoordinatorHarness()
    _ = try await harness.seedPodcastEpisode(episodeID: "episode-a")

    try await harness.coordinator.requestAutomaticEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")

    let rows = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    #expect(rows.count == 1, "the row is promoted in place, never duplicated")
    #expect(
      rows.first?.origin == .manual,
      "the only permitted direction: a manual request promotes an automatic row to manual")
  }

  @Test func integritySweepFinishesEpisodeDeletionWithoutTouchingSiblingFileOrRow() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let episodeA = try await harness.seedPodcastEpisode(episodeID: "episode-a")
    let episodeB = try await harness.seedPodcastEpisode(episodeID: "episode-b")
    let episodeARowID = try #require(episodeA.id)
    let episodeBRowID = try #require(episodeB.id)
    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-a")
    try await harness.coordinator.requestEpisodeDownload(
      itemID: DownloadCoordinatorHarness.podcastItemID, episodeID: "episode-b")
    let planned = try harness.fetchDownloads(itemId: harness.podcastItemRowId)
    let rowA = try #require(planned.first { $0.podcastEpisodeId == episodeARowID })
    let rowB = try #require(planned.first { $0.podcastEpisodeId == episodeBRowID })
    let rowAID = try #require(rowA.id)
    let rowBID = try #require(rowB.id)
    for row in [rowA, rowB] {
      harness.backgroundTransferring.pushEvent(
        .finished(
          identity: .abs(rowID: try #require(row.id)),
          temporaryFileURL: try harness.makeTempFile(bytes: 1_024),
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 1_024)))
    }
    let completed = await TestSupport.waitUntil {
      let states =
        (try? [rowAID, rowBID].compactMap {
          try harness.downloadStore.fetch(downloadId: $0)?.state
        }) ?? []
      return states == [.completed, .completed]
    }
    #expect(completed)
    #expect(try harness.downloadStore.fetch(downloadId: rowAID)?.state == .completed)
    #expect(try harness.downloadStore.fetch(downloadId: rowBID)?.state == .completed)
    let rowBURL = harness.downloadFileStore.absoluteURL(
      forRelativePath: rowB.destinationRelativePath)

    _ = try harness.downloadStore.markDeleting(
      itemId: harness.podcastItemRowId, podcastEpisodeId: episodeARowID)
    let result = try DownloadIntegritySweep(
      rootURL: harness.downloadFileStore.rootURL,
      downloadStore: harness.downloadStore
    ).run()

    #expect(result.finishedDeletionDownloadIds == [rowAID])
    #expect(try harness.downloadStore.fetch(downloadId: rowAID) == nil)
    #expect(try harness.downloadStore.fetch(downloadId: rowBID)?.state == .completed)
    #expect(FileManager.default.fileExists(atPath: rowBURL.path))
  }
}
