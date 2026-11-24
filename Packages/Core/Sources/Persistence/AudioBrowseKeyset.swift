import GRDB

/// Where the next page of a list starts. Opaque outside Persistence: it holds the ordering key of
/// the last row read, and names the list and order it was read under.
public struct AudioBrowseCursor: Sendable, Hashable {
  let scope: String
  let keys: [DatabaseValue]
}

public enum AudioBrowsePagingError: Error, Equatable, Sendable {
  /// The cursor belongs to another list, or to an order the list is no longer in. Continuing from
  /// it would repeat or skip rows, so the caller starts again from the first page.
  case staleCursor
}

/// One ordering term of a paged list. `expression` must never be NULL (pair a nullable column
/// with an `IS NULL` term and wrap it in `COALESCE`), because a NULL compares as neither before
/// nor after the cursor and its row would be skipped.
struct KeysetTerm: Sendable {
  let expression: String
  var descending = false
}

/// Keyset (cursor) paging over an arbitrary ordering: the order, the "after this row" predicate
/// and the cursor all derive from one list of terms, so they cannot disagree.
struct Keyset: Sendable {
  let scope: String
  let terms: [KeysetTerm]

  /// The key columns, to add to the select list.
  var selection: String {
    terms.enumerated().map { "\($1.expression) AS keyset\($0)" }.joined(separator: ", ")
  }

  var ordering: String {
    "ORDER BY " + terms.map { "\($0.expression) \($0.descending ? "DESC" : "ASC")" }.joined(separator: ", ")
  }

  /// A predicate, starting with `AND`, admitting only rows after the cursor; empty for the first
  /// page.
  func predicate(after cursor: AudioBrowseCursor?) throws -> (sql: String, arguments: StatementArguments) {
    guard let cursor else { return ("", []) }
    guard cursor.scope == scope, cursor.keys.count == terms.count else {
      throw AudioBrowsePagingError.staleCursor
    }
    var alternatives: [String] = []
    var arguments: StatementArguments = []
    for (index, term) in terms.enumerated() {
      // Parenthesized: `x IS NULL > ?` would otherwise bind as `x IS (NULL > ?)`.
      var clauses = terms[..<index].map { "(\($0.expression)) = ?" }
      arguments += StatementArguments(Array(cursor.keys[..<index]))
      clauses.append("(\(term.expression)) \(term.descending ? "<" : ">") ?")
      arguments += [cursor.keys[index]]
      alternatives.append("(" + clauses.joined(separator: " AND ") + ")")
    }
    return ("AND (" + alternatives.joined(separator: " OR ") + ")", arguments)
  }

  func cursor(from row: Row) -> AudioBrowseCursor {
    AudioBrowseCursor(scope: scope, keys: terms.indices.map { row["keyset\($0)"] as DatabaseValue })
  }

  /// Splits `limit + 1` fetched rows into the page and the cursor for the one after it.
  func page(_ fetched: [Row], limit: Int) -> (rows: ArraySlice<Row>, next: AudioBrowseCursor?) {
    let rows = fetched.prefix(limit)
    return (rows, fetched.count > limit ? rows.last.map(cursor(from:)) : nil)
  }
}
