import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// EPUB planning enters the download machinery as one media-kind-tagged row.
@Suite struct EbookDownloadPlanningTests {

  @Test
  func epubBearingItemPlansExactlyOneEbookRowWithPersistedIdentityAndLiteralEpubPath()
    async throws
  {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 4_096)

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.serverFileIno == "ebook-ino")
    #expect(row.expectedBytes == 4_096)
    #expect(row.expectedMimeType == "application/epub+zip")
    #expect(row.mediaKind == .ebook)
    #expect(
      row.destinationRelativePath
        == DownloadFileStore.destinationRelativePath(
          accountId: harness.accountId,
          itemId: harness.itemRowId,
          podcastEpisodeId: nil,
          orderIndex: 0,
          serverFileIno: "ebook-ino",
          mimeType: "application/epub+zip"))
    #expect(row.podcastEpisodeId == nil)
    #expect(row.origin == .manual)
  }

  @Test
  func normalizedLeadingDotExtensionIsAcceptedByTheEpubGate() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 10)

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).count == 1)
  }

  @Test
  func advertisedEpubWithoutPersistedEbookIdentityRefusesAsDecision9aUnavailable() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: nil, ext: nil)

    await #expect(throws: EbookDownloadPlanningError.ebookFileUnavailable) {
      try await harness.coordinator.requestEbookDownload(
        itemID: DownloadCoordinatorHarness.itemID)
    }

    #expect(harness.http.requests.isEmpty)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  /// A file replaced on the server keeps the item but gets a new inode and size, which the next
  /// library scan publishes. The expanded detail fetched here is that authoritative record, so a
  /// disagreement with the persisted identity means the local copy is stale, not that the file is
  /// gone. Refusing would strand the item permanently: nothing else rewrites `ebookFileIno`.
  @Test
  func aReplacedServerFileIsAdoptedRatherThanRefusedAsUnavailable() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "pre-repack-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "post-repack-ino", ext: ".epub", size: 8_192)

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)

    let row = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    #expect(row.serverFileIno == "post-repack-ino")
    #expect(row.expectedBytes == 8_192)

    let item = try await harness.database.readAsync { db in
      try ItemRecord.fetchOne(db, key: harness.itemRowId)
    }
    #expect(item?.ebookFileIno == "post-repack-ino")
    #expect(item?.expandedMetadataFetchedAt != nil)
  }

  /// The other side of adopting a changed identity: an expanded response with no ebook file at all
  /// still refuses, because there is nothing authoritative to adopt.
  @Test
  func anExpandedResponseWithNoEbookFileStillRefuses() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    harness.http.enqueue(
      DownloadCoordinatorHarness.jsonResponse(
        object: [
          "id": DownloadCoordinatorHarness.itemID,
          "libraryId": "lib-1",
          "mediaType": "book",
          "media": [
            "metadata": ["title": "Ebook"],
            "duration": 0.0,
            "audioFiles": [[String: Any]](),
            "tracks": [[String: Any]](),
            "chapters": [[String: Any]](),
          ] as [String: Any],
        ]))

    await #expect(throws: EbookDownloadPlanningError.ebookFileUnavailable) {
      try await harness.coordinator.requestEbookDownload(
        itemID: DownloadCoordinatorHarness.itemID)
    }

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  @Test
  func nonEpubPersistedExtensionRefusesWithoutCreatingARow() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".pdf")

    await #expect(throws: EbookDownloadPlanningError.unsupportedEbookFormat) {
      try await harness.coordinator.requestEbookDownload(
        itemID: DownloadCoordinatorHarness.itemID)
    }

    #expect(harness.http.requests.isEmpty)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  @Test
  func ebookFileWithoutSizeRefusesPerT65a() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: nil)

    await #expect(throws: EbookDownloadPlanningError.missingExpectedSize) {
      try await harness.coordinator.requestEbookDownload(
        itemID: DownloadCoordinatorHarness.itemID)
    }

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  @Test
  func duplicateEbookRequestsCoalesceAndDoNotFetchDetailTwice() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 10)

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)
    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)

    #expect(harness.http.requests.count == 1)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).count == 1)
  }

  @Test
  func audioAndEbookRowsForOneItemCoexistAndAudioRowIsNotDisturbed() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    let audio = try harness.downloadStore.enqueue(
      accountId: harness.accountId,
      itemId: harness.itemRowId,
      serverFileIno: "audio-ino",
      orderIndex: 0,
      destinationRelativePath: "audio/audio-ino.mp3",
      expectedBytes: 20,
      expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    _ = try harness.downloadStore.transition(downloadId: try #require(audio.id), to: .downloading)
    _ = try harness.downloadStore.transition(downloadId: try #require(audio.id), to: .paused)
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 10)

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.count == 2)
    let audioAfter = try #require(rows.first { $0.mediaKind == .audio })
    #expect(audioAfter.id == audio.id)
    #expect(audioAfter.state == .paused)
    #expect(audioAfter.serverFileIno == "audio-ino")
    #expect(rows.contains { $0.mediaKind == .ebook && $0.serverFileIno == "ebook-ino" })
  }

  @Test
  func ebookPlanningUsesTheExistingCellularGateAndStartsWhenWiFiReturns() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 10)
    harness.networkConditions.isConstrainedOrCellular = true

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)

    let held = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    let downloadID = try #require(held.id)
    #expect(held.state == .pending)
    #expect(held.holdReason == .waitingForWiFi)

    harness.networkConditions.simulateChange(isConstrainedOrCellular: false)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadID))?.state == .downloading
    }
    #expect(try harness.downloadStore.fetch(downloadId: downloadID)?.state == .downloading)
  }

  @Test
  func ebookRowsReusePauseAndResumeIntentsThroughThePhase4Scheduler() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 10)

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)
    let downloadID = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    try await harness.coordinator.pauseDownload(downloadId: downloadID)
    #expect(try harness.downloadStore.fetch(downloadId: downloadID)?.state == .paused)
    #expect(harness.backgroundTransferring.calls.contains(.pause(identity: .abs(rowID: downloadID))))

    try await harness.coordinator.resumeDownload(downloadId: downloadID)
    #expect(try harness.downloadStore.fetch(downloadId: downloadID)?.state == .downloading)
    #expect(harness.backgroundTransferring.calls.contains(.resume(identity: .abs(rowID: downloadID))))
  }

  @Test
  func ebookRowsReuseTheSingleRenewedAuthChallengePath() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 10)

    try await harness.coordinator.requestEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID)
    let downloadID = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    harness.enqueueRefreshResponse(accessToken: "renewed-access", refreshToken: "renewed-refresh")
    harness.backgroundTransferring.pushEvent(.authChallenge(identity: .abs(rowID: downloadID)))

    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.filter {
        if case .enqueue = $0 { return true }
        return false
      }.count == 2
    }
    #expect(try harness.downloadStore.fetch(downloadId: downloadID)?.state == .downloading)
    #expect(harness.http.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
    #expect(
      harness.backgroundTransferring.calls.filter {
        if case .enqueue(_, _, let fileID, _) = $0 { return fileID == "ebook-ino" }
        return false
      }.count == 2)
  }

  private func configureEbook(
    _ harness: DownloadCoordinatorHarness,
    ino: String?,
    ext: String?
  ) async throws {
    try await harness.database.writeAsync { db in
      try ItemRecord
        .filter(key: harness.itemRowId)
        .updateAll(
          db,
          Column("numAudioFiles").set(to: 0),
          Column("ebookFormat").set(to: "epub"),
          Column("ebookFileIno").set(to: ino),
          Column("ebookFileExt").set(to: ext))
    }
  }

  private func enqueueEbookDetail(
    _ harness: DownloadCoordinatorHarness,
    ino: String,
    ext: String,
    size: Int?
  ) {
    var metadata: [String: Any] = [
      "filename": "fixture.epub", "ext": ext, "path": "<redacted>",
    ]
    if let size { metadata["size"] = size }
    let object: [String: Any] =
      [
        "id": DownloadCoordinatorHarness.itemID,
        "libraryId": "lib-1",
        "mediaType": "book",
        "media": [
          "metadata": ["title": "Ebook"],
          "duration": 0.0,
          "audioFiles": [[String: Any]](),
          "tracks": [[String: Any]](),
          "chapters": [[String: Any]](),
          "ebookFile": ["ino": ino, "metadata": metadata],
        ] as [String: Any],
      ] as [String: Any]
    harness.http.enqueue(DownloadCoordinatorHarness.jsonResponse(object: object))
  }
}
