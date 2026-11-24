import Foundation
import GRDB

/// One decoded member of a library's complete `/filterdata` response.
public struct AuthorSeriesSnapshotEntry: Sendable, Equatable {
  public let kind: SearchResultKind
  public let entityID: String
  public let name: String
  public let bookCount: Int?

  public init(kind: SearchResultKind, entityID: String, name: String, bookCount: Int? = nil) {
    self.kind = kind
    self.entityID = entityID
    self.name = name
    self.bookCount = bookCount
  }
}

/// Durable ownership of the complete author/series index. Successful replacements are atomic;
/// callers simply do not call `replaceSnapshot` after transport or decode failure, so the last
/// complete snapshot remains intact.
public struct AuthorSeriesEntityStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func hasSnapshot(accountID: Int64, libraryID: String) async -> Bool {
    (try? await database.readAsync { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM libraryFilterDataSnapshot AS snapshot
            JOIN library ON library.id = snapshot.libraryId
            WHERE library.accountId = ? AND library.serverLibraryId = ?
              AND library.softDeleted = 0 AND library.isIncluded = 1
          )
          """,
        arguments: [accountID, libraryID]) ?? false
    }) ?? false
  }

  public func replaceSnapshot(
    accountID: Int64,
    libraryID: String,
    entries: [AuthorSeriesSnapshotEntry],
    fetchedAt: Date = Date()
  ) async throws {
    try await database.writeAsync { db in
      guard
        let libraryRowID = try Int64.fetchOne(
          db,
          sql: """
            SELECT id FROM library
            WHERE accountId = ? AND serverLibraryId = ?
              AND softDeleted = 0 AND isIncluded = 1
            """,
          arguments: [accountID, libraryID])
      else { return }

      try db.execute(
        sql: "DELETE FROM libraryEntityIndex WHERE libraryId = ?", arguments: [libraryRowID])
      for entry in entries {
        try db.execute(
          sql: """
            INSERT INTO libraryEntityIndex
              (libraryId, kind, serverEntityId, name, normalizedName, bookCount)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            libraryRowID, entry.kind.rawValue, entry.entityID, entry.name,
            AuthorSeriesEntity.normalizedName(entry.name), entry.bookCount,
          ])
      }
      try db.execute(
        sql: """
          INSERT INTO libraryFilterDataSnapshot (libraryId, fetchedAt) VALUES (?, ?)
          ON CONFLICT(libraryId) DO UPDATE SET fetchedAt = excluded.fetchedAt
          """,
        arguments: [libraryRowID, fetchedAt])
    }
  }

  /// Merges spelling variants and cross-library identities in the caller's library order.
  public func entities(
    accountID: Int64, kind: SearchResultKind, libraryIDs: [String]
  ) async -> [AuthorSeriesEntity] {
    guard kind == .author || kind == .series, libraryIDs.isEmpty == false else { return [] }
    return
      (try? await database.readAsync { db in
        try Self.entities(db: db, accountID: accountID, kind: kind, libraryIDs: libraryIDs)
      }) ?? []
  }

  public func observeEntities(
    accountID: Int64, kind: SearchResultKind, libraryIDs: [String]
  ) -> AsyncStream<[AuthorSeriesEntity]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.entities(db: db, accountID: accountID, kind: kind, libraryIDs: libraryIDs)
    }
  }

  private static func entities(
    db: Database, accountID: Int64, kind: SearchResultKind, libraryIDs: [String]
  ) throws -> [AuthorSeriesEntity] {
    guard kind == .author || kind == .series, libraryIDs.isEmpty == false else { return [] }
    var order: [String] = []
    var merged: [String: Merged] = [:]
    for libraryID in libraryIDs {
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT entity.serverEntityId, entity.name, entity.normalizedName, entity.bookCount
          FROM libraryEntityIndex AS entity
          JOIN library ON library.id = entity.libraryId
          WHERE library.accountId = ? AND library.serverLibraryId = ?
            AND library.softDeleted = 0 AND library.isIncluded = 1 AND entity.kind = ?
          ORDER BY entity.id
          """,
        arguments: [accountID, libraryID, kind.rawValue])
      for row in rows {
        let entityID: String = row["serverEntityId"]
        let name: String = row["name"]
        let key: String = row["normalizedName"]
        let bookCount: Int? = row["bookCount"]
        let identity = AuthorSeriesEntity.Identity(entityID: entityID, libraryID: libraryID)
        if merged[key] == nil {
          order.append(key)
          merged[key] = Merged(name: name, identities: [identity], bookCount: bookCount)
        } else {
          merged[key]?.append(identity: identity, bookCount: bookCount)
        }
      }
    }
    return order.compactMap { key in
      guard let value = merged[key] else { return nil }
      return AuthorSeriesEntity(
        kind: kind, name: value.name, identities: value.identities,
        bookCount: value.bookCount)
    }
  }

  private struct Merged: Sendable {
    var name: String
    var identities: [AuthorSeriesEntity.Identity]
    var bookCount: Int?

    mutating func append(identity: AuthorSeriesEntity.Identity, bookCount: Int?) {
      identities.append(identity)
      guard let bookCount else { return }
      self.bookCount = (self.bookCount ?? 0) + bookCount
    }
  }
}
