import Foundation
import GRDB

/// One flattened entry of an EPUB's navigation document, as stored beside its item.
///
/// `startProgression` is where the entry begins in the publication (0 to 1), resolved from the
/// positions list at parse time so the Contents tab can mark entries read against
/// `mediaProgress.ebookProgress`. Optional: an entry whose resource the positions list does not
/// resolve stays listed.
public struct StoredEbookTOCEntry: Sendable, Equatable {
  /// Zero-based index into the flattened navigation document, which is also its display order.
  public let position: Int
  public let title: String
  public let href: String?
  /// Nesting depth in the original tree; 0 is a top-level entry.
  public let depth: Int
  public let startProgression: Double?

  public init(
    position: Int, title: String, href: String?, depth: Int, startProgression: Double?
  ) {
    self.position = position
    self.title = title
    self.href = href
    self.depth = depth
    self.startProgression = startProgression
  }
}

/// Read/write seam for an item's durable ebook table of contents, keyed by server item id so the
/// caller needs no local row identity. Both sides are total: an item with nothing stored, and an
/// item that does not exist at all, are the same empty answer.
public protocol EbookTableOfContentsAccess: Sendable {
  func fetchTableOfContents(itemId: String) async throws -> [StoredEbookTOCEntry]
  func storeTableOfContents(_ entries: [StoredEbookTOCEntry], itemId: String) async throws
}

/// Database-backed contents snapshot. The item row is resolved inside each transaction (as in
/// `DefaultReaderStateReading`), so a store issued before the first sync lands is dropped rather
/// than written against a guessed row.
public struct DefaultEbookTableOfContentsAccess: EbookTableOfContentsAccess, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func fetchTableOfContents(itemId: String) async throws -> [StoredEbookTOCEntry] {
    try await database.readAsync { db in
      guard let item = try Self.item(db, serverItemId: itemId), let localId = item.id else {
        return []
      }
      return
        try EbookTOCEntryRecord
        .filter(Column("accountId") == item.accountId)
        .filter(Column("itemId") == localId)
        .order(Column("position"))
        .fetchAll(db)
        .map {
          StoredEbookTOCEntry(
            position: $0.position,
            title: $0.title,
            href: $0.href,
            depth: $0.depth,
            startProgression: $0.startProgression)
        }
    }
  }

  /// Replaces the item's complete snapshot atomically. An empty list clears it, so a re-parse that
  /// finds no navigation document cannot leave a stale one on screen.
  public func storeTableOfContents(_ entries: [StoredEbookTOCEntry], itemId: String) async throws {
    try await database.writeAsync { db in
      guard let item = try Self.item(db, serverItemId: itemId), let localId = item.id else {
        return
      }
      try EbookTOCEntryRecord
        .filter(Column("accountId") == item.accountId)
        .filter(Column("itemId") == localId)
        .deleteAll(db)

      for entry in entries {
        var record = EbookTOCEntryRecord(
          accountId: item.accountId,
          itemId: localId,
          position: entry.position,
          title: entry.title,
          href: entry.href,
          depth: entry.depth,
          startProgression: entry.startProgression)
        try record.insert(db)
      }
    }
  }

  private static func item(_ db: Database, serverItemId: String) throws -> ItemRecord? {
    try ItemRecord
      .filter(Column("serverItemId") == serverItemId)
      .filter(Column("softDeleted") == false)
      .fetchOne(db)
  }
}

/// Incremental-composition default for consumers without a database environment.
public struct NoOpEbookTableOfContentsAccess: EbookTableOfContentsAccess, Sendable {
  public init() {}

  public func fetchTableOfContents(itemId: String) async throws -> [StoredEbookTOCEntry] { [] }
  public func storeTableOfContents(_ entries: [StoredEbookTOCEntry], itemId: String) async throws {}
}
