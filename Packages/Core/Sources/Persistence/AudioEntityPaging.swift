import Foundation
import GRDB

/// The two ways a small screen groups audiobooks besides their titles.
public enum AudioEntityKind: String, Sendable, Hashable {
  case author
  case series
}

/// An author or a series that has at least one audiobook to play.
public struct AudioEntityPageRow: Sendable, Equatable {
  public let kind: AudioEntityKind
  public let name: String
  /// Audiobooks only, in the included libraries.
  public let bookCount: Int

  public init(kind: AudioEntityKind, name: String, bookCount: Int) {
    self.kind = kind
    self.name = name
    self.bookCount = bookCount
  }
}

/// The last author or series of a page. Opaque outside Persistence.
public struct AudioEntityCursor: Sendable, Hashable {
  let kind: AudioEntityKind
  let name: String
}

/// The last book of one author's or one series' page. It names the row itself, so a book removed
/// between pages is noticed instead of shifting the next page.
public struct AudioEntityBookCursor: Sendable, Hashable {
  let kind: AudioEntityKind
  let name: String
  let rowID: Int64
}

/// Authors and series read from the audiobooks already on the device.
///
/// The server's author and series catalogue is per library, includes ebook-only entities, and
/// lists books over the network. These reads use the names synced onto each item, so every row
/// has audio behind it and works offline. Names compare as text: two authors with one name are
/// one row.
public protocol AudioEntityPaging: Sendable {
  /// Authors or series in name order, starting after `cursor`.
  func entityPage(
    kind: AudioEntityKind, after cursor: AudioEntityCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudioEntityPageRow, AudioEntityCursor>

  /// The audiobooks of the author or series called `name`: an author's by title, a series' in
  /// sequence order with unnumbered books last.
  func entityBookPage(
    kind: AudioEntityKind, name: String, after cursor: AudioEntityBookCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudiobookPageRow, AudioEntityBookCursor>
}

extension DefaultAudioBrowsePaging: AudioEntityPaging {
  private static let listableAudiobooksSQL = """
    FROM item
    JOIN library
      ON library.id = item.libraryId
      AND library.accountId = item.accountId
    WHERE \(ItemVisibilityPredicate.sql)
      AND (\(ItemCategoryPredicate.sql(.audiobook)))
    """

  private static func column(_ kind: AudioEntityKind) -> String {
    switch kind {
    case .author: "item.author"
    case .series: "item.seriesName"
    }
  }

  /// The names one stored value holds, with a series' sequence where it has one. The server
  /// flattens several authors, and several series, into one comma-separated string.
  static func entries(_ kind: AudioEntityKind, in value: String?) -> [(name: String, sequence: String?)] {
    switch kind {
    case .author:
      (value ?? "").components(separatedBy: ", ").compactMap {
        let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (name, nil)
      }
    case .series:
      SeriesFlattenedName.entries(from: value).map { ($0.name, $0.sequence) }
    }
  }

  private static func sortKey(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
    let left = sortKey(lhs)
    let right = sortKey(rhs)
    return left == right ? lhs < rhs : left < right
  }

  public func entityPage(
    kind: AudioEntityKind, after cursor: AudioEntityCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudioEntityPageRow, AudioEntityCursor> {
    if let cursor, cursor.kind != kind { throw AudioBrowsePagingError.staleCursor }
    let limit = Self.clamped(limit)
    let column = Self.column(kind)
    return try await database.readAsync { db in
      // One row per distinct stored value, not per book: the names are split here because a
      // value can hold several, and the result is then small enough to order in memory.
      let values = try Row.fetchAll(
        db,
        sql: """
          SELECT \(column) AS value, COUNT(*) AS books
          \(Self.listableAudiobooksSQL)
            AND \(column) IS NOT NULL
          GROUP BY \(column)
          """)
      var counts: [String: Int] = [:]
      for row in values {
        let books: Int = row["books"]
        // A book counts once for a name however often its value repeats it.
        for name in Set(Self.entries(kind, in: row["value"]).map(\.name)) {
          counts[name, default: 0] += books
        }
      }
      var names = counts.keys.sorted(by: Self.precedes)
      if let cursor { names.removeAll { Self.precedes(cursor.name, $0) == false } }
      let page = names.prefix(limit)
      return AudioBrowsePage(
        rows: page.map { AudioEntityPageRow(kind: kind, name: $0, bookCount: counts[$0] ?? 0) },
        next: names.count > limit ? page.last.map { AudioEntityCursor(kind: kind, name: $0) } : nil)
    }
  }

  public func entityBookPage(
    kind: AudioEntityKind, name: String, after cursor: AudioEntityBookCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudiobookPageRow, AudioEntityBookCursor> {
    if let cursor, cursor.kind != kind || cursor.name != name {
      throw AudioBrowsePagingError.staleCursor
    }
    let limit = Self.clamped(limit)
    let column = Self.column(kind)
    return try await database.readAsync { db in
      // The text match only narrows the read to this entity's neighbourhood; membership is the
      // exact name among the value's entries, decided below.
      let fetched = try Row.fetchAll(
        db,
        sql: """
          SELECT item.id, item.serverItemId, item.title, item.sortTitle, item.author,
            item.serverUpdatedAt, \(column) AS value
          \(Self.listableAudiobooksSQL)
            AND instr(\(column), ?) > 0
          """,
        arguments: [name])
      struct Book {
        let rowID: Int64
        let sortTitle: String
        let sequence: Double?
        let row: AudiobookPageRow
      }
      var books = fetched.compactMap { row -> Book? in
        guard let entry = Self.entries(kind, in: row["value"]).first(where: { $0.name == name }),
          let identity = ListeningIdentity.audiobook(itemID: row["serverItemId"])
        else { return nil }
        return Book(
          rowID: row["id"], sortTitle: row["sortTitle"],
          sequence: SeriesFlattenedName.sequenceValue(entry.sequence),
          row: AudiobookPageRow(
            identity: identity, title: row["title"], author: row["author"],
            serverUpdatedAt: row["serverUpdatedAt"], seriesSequence: entry.sequence))
      }
      books.sort { lhs, rhs in
        switch (lhs.sequence, rhs.sequence) {
        case (let left?, let right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return (lhs.sortTitle, lhs.rowID) < (rhs.sortTitle, rhs.rowID)
        }
      }
      var start = 0
      if let cursor {
        guard let index = books.firstIndex(where: { $0.rowID == cursor.rowID }) else {
          throw AudioBrowsePagingError.staleCursor
        }
        start = index + 1
      }
      let page = books[start...].prefix(limit)
      return AudioBrowsePage(
        rows: page.map(\.row),
        next: books.count > start + limit
          ? page.last.map { AudioEntityBookCursor(kind: kind, name: name, rowID: $0.rowID) } : nil)
    }
  }
}
