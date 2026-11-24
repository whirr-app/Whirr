import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// A supplement PDF downloads with its audiobook, can be planned alone, and never holds the
/// audiobook's own lifecycle hostage.
@Suite("Supplement download planning")
struct SupplementDownloadPlanningTests {

  private static var pdf: [String: Any] {
    [
      "ino": "900", "metadata": ["filename": "Maps.pdf", "ext": ".pdf", "size": 40, "path": "<redacted>"],
    ]
  }

  private func requestBookWithPDF(_ harness: DownloadCoordinatorHarness) async throws {
    harness.enqueueBookItemDetail(
      audioFiles: [
        (index: 1, ino: 101, size: 50, mimeType: "audio/mp4", duration: 5),
        (index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5),
      ],
      libraryFiles: [Self.pdf])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
  }

  /// Places a row directly in a state the scheduler would otherwise have to drive it to.
  private func setState(
    _ harness: DownloadCoordinatorHarness, id: Int64, _ state: DownloadState,
    holdReason: DownloadHoldReason? = nil, errorCategory: DownloadErrorCategory? = nil
  ) async throws {
    try await harness.database.writeAsync { db in
      try DownloadRecord.filter(key: id).updateAll(
        db, Column("state").set(to: state.rawValue),
        Column("holdReason").set(to: holdReason?.rawValue),
        Column("errorCategory").set(to: errorCategory?.rawValue))
    }
  }

  @Test func theAudiobookDownloadPlansItsPDFAfterTheAudio() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await requestBookWithPDF(harness)

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId).sorted { $0.id! < $1.id! }
    #expect(rows.map(\.mediaKind) == [.audio, .audio, .supplement])
    #expect(rows.map(\.serverFileIno) == ["100", "101", "900"])
    let supplement = try #require(rows.last)
    #expect(supplement.expectedMimeType == "application/pdf")
    #expect(supplement.expectedBytes == 40)
    #expect(supplement.destinationRelativePath.hasSuffix(".pdf"))
    #expect(harness.http.requests.count == 1, "one expanded fetch plans audio and PDF together")

    let stored = try await ItemSupplementStore(
      database: harness.database, downloadRootURL: harness.downloadFileStore.rootURL
    ).supplements(itemId: DownloadCoordinatorHarness.itemID)
    #expect(stored.map(\.serverFileIno) == ["900"], "the viewer's set is stored with the plan")
  }

  @Test func aSupplementThatCannotBePlannedLeavesTheAudioPlanned() async throws {
    let harness = try await DownloadCoordinatorHarness()
    // A pre-existing row for the same file makes the supplement insert a duplicate.
    _ = try harness.downloadStore.enqueue(
      accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "900", orderIndex: 0,
      destinationRelativePath: "x.pdf", expectedBytes: 40, expectedMimeType: "application/pdf",
      fileDurationSeconds: 0, mediaKind: .supplement)

    try await requestBookWithPDF(harness)

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.filter { $0.mediaKind == .audio }.count == 2)
    #expect(rows.filter { $0.mediaKind == .supplement }.count == 1)
  }

  @Test func aPDFCanBePlannedAloneAndIdempotently() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await ExpandedMetadataBatchStore(database: harness.database).store(
      [
        ExpandedItemMetadataMutation(
          serverItemId: DownloadCoordinatorHarness.itemID, seriesName: nil, narratorName: nil,
          itemDescription: nil, ebookFileIno: nil, ebookFileExt: nil, chapters: [],
          supplements: [
            StoredItemSupplement(serverFileIno: "900", position: 0, filename: "Maps.pdf", sizeBytes: 40)
          ])
      ],
      accountId: harness.accountId, fetchedAt: Date())

    try await harness.coordinator.requestSupplementDownload(
      itemID: DownloadCoordinatorHarness.itemID, fileIno: "900")
    try await harness.coordinator.requestSupplementDownload(
      itemID: DownloadCoordinatorHarness.itemID, fileIno: "900")

    let rows = try harness.fetchDownloads(itemId: harness.itemRowId)
    #expect(rows.map(\.mediaKind) == [.supplement])
    #expect(harness.http.requests.isEmpty, "the stored description is enough; no fetch")
    // The item is still not downloaded as a book.
    #expect(try harness.downloadStore.itemStatus(itemId: harness.itemRowId) == .notDownloaded)

    await #expect(throws: DownloadPlanningError.metadataValidationFailed) {
      try await harness.coordinator.requestSupplementDownload(
        itemID: DownloadCoordinatorHarness.itemID, fileIno: "unknown")
    }
  }

  @Test func aFailedPDFIsRetriedInPlace() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await requestBookWithPDF(harness)
    let supplementID = try #require(
      try harness.fetchDownloads(itemId: harness.itemRowId).first { $0.mediaKind == .supplement }?.id)
    try await setState(harness, id: supplementID, .failed, errorCategory: .transport)

    try await harness.coordinator.requestSupplementDownload(
      itemID: DownloadCoordinatorHarness.itemID, fileIno: "900")

    let state = try harness.downloadStore.fetch(downloadId: supplementID)?.state
    #expect(state != .failed)
  }

  @Test func aManualPurgeRemovesThePDFWithTheBook() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await requestBookWithPDF(harness)
    try await harness.coordinator.purgeItemDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .itemDetail)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  @Test func anAutomaticPurgeIsNotHeldByAWaitingPDF() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await requestBookWithPDF(harness)
    for row in try harness.fetchDownloads(itemId: harness.itemRowId) {
      let id = try #require(row.id)
      if row.mediaKind == .audio {
        try harness.downloadStore.complete(downloadId: id, finalSizeBytes: 50)
      } else {
        try await setState(harness, id: id, .pending, holdReason: .waitingForWiFi)
      }
    }

    try await harness.coordinator.purgeItem(
      itemId: harness.itemRowId, source: .finishedDownloadAutoDelete)

    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  @Test func theIntegritySweepFailsAWrongSizedPDF() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try harness.downloadStore.enqueue(
      accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "900", orderIndex: 0,
      destinationRelativePath: "sweep/maps.pdf", expectedBytes: 40,
      expectedMimeType: "application/pdf", fileDurationSeconds: 0, mediaKind: .supplement)
    let id = try #require(row.id)
    _ = try harness.downloadStore.transition(downloadId: id, to: .downloading)
    _ = try harness.downloadStore.complete(downloadId: id, finalSizeBytes: 40)
    let url = harness.downloadFileStore.absoluteURL(forRelativePath: "sweep/maps.pdf")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 12).write(to: url)

    _ = try DownloadIntegritySweep(
      rootURL: harness.downloadFileStore.rootURL, downloadStore: harness.downloadStore
    ).validate(itemID: harness.itemRowId)

    #expect(try harness.downloadStore.fetch(downloadId: id)?.state == .failed)
  }
}
