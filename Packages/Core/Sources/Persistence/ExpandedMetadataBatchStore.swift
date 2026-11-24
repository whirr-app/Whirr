import Foundation
import GRDB

/// One item's authoritative expanded-metadata mutation, including its complete chapter snapshot.
public struct ExpandedItemMetadataMutation: Sendable, Equatable {
  public let serverItemId: String
  public let seriesName: String?
  public let narratorName: String?
  public let itemDescription: String?
  public let ebookFileIno: String?
  public let ebookFileExt: String?
  public let audioDownloadExpectedBytes: Int64?
  public let ebookDownloadExpectedBytes: Int64?
  public let chapters: [StoredItemChapter]
  /// The item's complete supplement set.
  public let supplements: [StoredItemSupplement]

  public init(
    serverItemId: String,
    seriesName: String?,
    narratorName: String?,
    itemDescription: String?,
    ebookFileIno: String?,
    ebookFileExt: String?,
    audioDownloadExpectedBytes: Int64? = nil,
    ebookDownloadExpectedBytes: Int64? = nil,
    chapters: [StoredItemChapter],
    supplements: [StoredItemSupplement] = []
  ) {
    self.serverItemId = serverItemId
    self.seriesName = seriesName
    self.narratorName = narratorName
    self.itemDescription = itemDescription
    self.ebookFileIno = ebookFileIno
    self.ebookFileExt = ebookFileExt
    self.audioDownloadExpectedBytes = audioDownloadExpectedBytes
    self.ebookDownloadExpectedBytes = ebookDownloadExpectedBytes
    self.chapters = chapters
    self.supplements = supplements
  }
}

/// Persists a whole batch of authoritative expanded item responses in one transaction.
public struct ExpandedMetadataBatchStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Applies every mutation (item fields, chapter and supplement replacement) inside one
  /// `AppDatabase.writeAsync`. Either the whole batch commits or none of it does.
  public func store(
    _ mutations: [ExpandedItemMetadataMutation],
    accountId: Int64,
    fetchedAt: Date
  ) async throws {
    try await database.writeAsync { db in
      for mutation in mutations {
        let normalizedExt = ItemRecord.normalizedEbookFileExtension(mutation.ebookFileExt)
        let normalizedIno = mutation.ebookFileIno?.isEmpty == false ? mutation.ebookFileIno : nil
        try ItemRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("serverItemId") == mutation.serverItemId)
          .updateAll(
            db,
            Column("seriesName").set(to: mutation.seriesName),
            Column("narratorName").set(to: mutation.narratorName),
            Column("itemDescription").set(to: mutation.itemDescription),
            Column("ebookFileIno").set(to: normalizedIno),
            Column("ebookFileExt").set(to: normalizedExt),
            Column("audioDownloadExpectedBytes").set(to: mutation.audioDownloadExpectedBytes),
            Column("ebookDownloadExpectedBytes").set(to: mutation.ebookDownloadExpectedBytes),
            Column("expandedMetadataFetchedAt").set(to: fetchedAt))

        guard
          let itemId =
            try ItemRecord
            .filter(Column("accountId") == accountId)
            .filter(Column("serverItemId") == mutation.serverItemId)
            .select(Column("id"), as: Int64.self)
            .fetchOne(db)
        else {
          continue
        }

        try ItemChapterStore.replace(
          db, accountId: accountId, itemId: itemId, chapters: mutation.chapters)
        try ItemSupplementStore.replace(
          db, accountId: accountId, itemId: itemId, supplements: mutation.supplements)
      }
    }
  }
}
