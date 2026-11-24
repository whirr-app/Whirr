import ABSApi
import Foundation
import Persistence

/// The SyncEngine-owned fields that an authoritative expanded item response contributes to the
/// local projection. A batch/get result can build this value without depending on
/// `ItemDetailExtrasService`'s cache or fetch task.
struct PersistableExpandedItem: Sendable {
  let seriesName: String?
  let narratorName: String?
  let itemDescription: String?
  let chapters: [StoredItemChapter]
  let ebookFileIno: String?
  let ebookFileExt: String?
  let audioDownloadExpectedBytes: Int64?
  let ebookDownloadExpectedBytes: Int64?
  var supplements: [StoredItemSupplement] = []
}

struct ExpandedItemBatchEntry: Sendable {
  let serverItemId: String
  let extras: PersistableExpandedItem
}

protocol ExpandedItemBatchPersisting: Sendable {
  func persist(
    _ entries: [ExpandedItemBatchEntry], accountId: Int64, fetchedAt: Date
  ) async throws
}

/// Owns persistence of authoritative expanded item responses.
struct ExpandedItemPersistor: ExpandedItemBatchPersisting, Sendable {
  private let batchStore: ExpandedMetadataBatchStore

  init(database: AppDatabase) {
    batchStore = ExpandedMetadataBatchStore(database: database)
  }

  /// Builds the same persistence payload for both on-demand detail loads and background batch
  /// backfills. Podcasts produce the empty payload used by `ItemDetailExtrasService`;
  /// the item-id query normally excludes them, but a defensive response must keep that media-kind
  /// boundary rather than treating a podcast as a book.
  static func persistable(from detail: ItemDetail) -> PersistableExpandedItem {
    guard let media = detail.media else {
      return PersistableExpandedItem(
        seriesName: nil,
        narratorName: nil,
        itemDescription: nil,
        chapters: [],
        ebookFileIno: nil,
        ebookFileExt: nil,
        audioDownloadExpectedBytes: nil,
        ebookDownloadExpectedBytes: nil)
    }

    switch media {
    case .podcast:
      return PersistableExpandedItem(
        seriesName: nil,
        narratorName: nil,
        itemDescription: nil,
        chapters: [],
        ebookFileIno: nil,
        ebookFileExt: nil,
        audioDownloadExpectedBytes: nil,
        ebookDownloadExpectedBytes: nil)
    case .book(let book):
      return PersistableExpandedItem(
        seriesName: book.seriesName,
        narratorName: book.narratorName,
        itemDescription: book.description,
        chapters: storedItemChapters(from: book.chapters, duration: book.duration),
        ebookFileIno: book.ebookFile?.ino,
        ebookFileExt: book.ebookFile?.ext,
        audioDownloadExpectedBytes: expectedAudioDownloadBytes(from: book.audioFiles),
        ebookDownloadExpectedBytes: positiveByteCount(book.ebookFile?.size),
        supplements: storedSupplements(from: book.supplements))
    }
  }

  private static func expectedAudioDownloadBytes(from catalog: AudioFileCatalog) -> Int64? {
    guard catalog.invalidEntryCount == 0, catalog.files.isEmpty == false else { return nil }
    var total: Int64 = 0
    for file in catalog.files {
      guard let bytes = Int64(exactly: file.expectedSize), bytes > 0 else { return nil }
      let result = total.addingReportingOverflow(bytes)
      guard result.overflow == false else { return nil }
      total = result.partialValue
    }
    return total
  }

  static func storedSupplements(from files: [SupplementFileInfo]) -> [StoredItemSupplement] {
    files.enumerated().map { position, file in
      StoredItemSupplement(
        serverFileIno: file.ino, position: position, filename: file.filename,
        sizeBytes: Int64(file.size))
    }
  }

  private static func positiveByteCount(_ value: Int?) -> Int64? {
    guard let value, value > 0 else { return nil }
    return Int64(exactly: value)
  }

  func persist(
    _ extras: PersistableExpandedItem,
    accountId: Int64,
    serverItemId: String,
    fetchedAt: Date
  ) async {
    try? await persist(
      [ExpandedItemBatchEntry(serverItemId: serverItemId, extras: extras)],
      accountId: accountId,
      fetchedAt: fetchedAt)
  }

  func persist(
    _ entries: [ExpandedItemBatchEntry], accountId: Int64, fetchedAt: Date
  ) async throws {
    try await batchStore.store(
      entries.map { entry in
        ExpandedItemMetadataMutation(
          serverItemId: entry.serverItemId,
          seriesName: entry.extras.seriesName,
          narratorName: entry.extras.narratorName,
          itemDescription: entry.extras.itemDescription,
          ebookFileIno: entry.extras.ebookFileIno,
          ebookFileExt: entry.extras.ebookFileExt,
          audioDownloadExpectedBytes: entry.extras.audioDownloadExpectedBytes,
          ebookDownloadExpectedBytes: entry.extras.ebookDownloadExpectedBytes,
          chapters: entry.extras.chapters,
          supplements: entry.extras.supplements)
      },
      accountId: accountId,
      fetchedAt: fetchedAt)
  }
}
