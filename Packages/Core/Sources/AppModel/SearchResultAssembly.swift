import Persistence

/// Pure result assembly for search. Merges local (on-device FTS) and server rows into one ordered,
/// deduped list, then buckets that list into sections. Free-standing from `SearchModel`: every
/// function here is total and has no I/O, no clocks, no globals.
public enum SearchResultAssembly {

  /// Merges a local result set with a (possibly empty, possibly later-arriving) server result set.
  ///
  /// - Rows the server returned keep the server's order.
  /// - Rows only present locally (the server hasn't indexed them, or hasn't answered yet) are
  ///   appended after, in their original local order, and are never dropped.
  /// - An entity present in both keeps the server's `matchReason` when it has one, else the local
  ///   one.
  /// - `.author`/`.series` rows collapse by name rather than by id (see `dedupeKey(for:)`).
  ///
  /// Calling this twice with the same `local` (first with an empty `server`, then once the server
  /// answers) only inserts newly-confirmed or brand-new rows and never swaps two rows already on
  /// screen, so the list does not jump under a tapping finger.
  public static func merge(
    local: [SearchResultRow], server: [SearchResultRow]
  ) -> [SearchResultRow] {
    let localByKey = Dictionary(
      local.map { (dedupeKey(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
    var seenKeys: Set<String> = []
    var merged: [SearchResultRow] = []
    merged.reserveCapacity(local.count + server.count)

    for serverRow in server {
      let key = dedupeKey(for: serverRow)
      guard seenKeys.insert(key).inserted else { continue }
      if let localRow = localByKey[key] {
        merged.append(backfilled(serverRow, from: localRow))
      } else {
        merged.append(serverRow)
      }
    }

    for localRow in local {
      guard seenKeys.insert(dedupeKey(for: localRow)).inserted else { continue }
      merged.append(localRow)
    }

    return merged
  }

  /// What makes two rows one row here.
  ///
  /// Item-backed kinds key on `id` (kind plus the account-wide server identity).
  ///
  /// `.author`/`.series` cannot: Audiobookshelf files those per library
  /// (`AuthorSeriesEntity.Identity`), so one author can have two ids and the per-library fan-out
  /// returns a row for each. They key on `AuthorSeriesEntity.normalizedName`, the key
  /// `AuthorSeriesEntityStore.entities` merges the Library index under, so both screens collapse
  /// the same rows, including spelling variants (`J.N. Chaney` / `JN Chaney`).
  ///
  /// The first row wins, which is enough to navigate with: `AuthorSeriesModel.loadInitial`
  /// re-resolves the full identity list from the entity index whichever id it was entered by.
  private static func dedupeKey(for row: SearchResultRow) -> String {
    switch row.kind {
    case .author, .series:
      return "\(row.kind.rawValue)#name#\(AuthorSeriesEntity.normalizedName(row.title))"
    case .book, .podcast, .episode:
      return row.id
    }
  }

  /// Buckets a row list (typically `merge`'s output, but any list of rows is valid input) into
  /// query-resolved sections, omitting any section with no rows. Row order within a section is
  /// preserved as given. Ranking is decided upstream and never re-sorted here.
  public static func section(_ input: SearchSectionInput) -> [SearchSection] {
    resolvedSectionOrder(for: input).compactMap { kind in
      let rows = input.rows.filter { $0.kind == kind }
      guard !rows.isEmpty else { return nil }
      return SearchSection(kind: kind, rows: rows, hasMore: input.hasMore[kind] ?? false)
    }
  }

  /// Returns whether the query names an entity row of the requested kind by whole canonical words.
  /// Every query word must occur in the same row's canonical title; prefixes and empty canonical
  /// queries never promote.
  static func promotesEntities(
    query: String, rows: [SearchResultRow], kind: SearchResultKind
  ) -> Bool {
    let queryWords = SearchQueryNormalizer.canonicalize(query).split(separator: " ")
    guard queryWords.isEmpty == false else { return false }

    return rows.contains { row in
      guard row.kind == kind else { return false }
      let nameWords = Set(SearchQueryNormalizer.canonicalize(row.title).split(separator: " "))
      return queryWords.allSatisfy(nameWords.contains)
    }
  }

  private static func resolvedSectionOrder(for input: SearchSectionInput) -> [SearchResultKind] {
    let promotedKinds = sectionOrder.filter { kind in
      promotableKinds.contains(kind)
        && promotesEntities(query: input.query, rows: input.rows, kind: kind)
    }
    return promotedKinds + sectionOrder.filter { !promotedKinds.contains($0) }
  }

  private static let sectionOrder: [SearchResultKind] = [
    .book, .podcast, .episode, .author, .series,
  ]
  private static let promotableKinds: Set<SearchResultKind> = [.author, .series]

  /// The server row wins on identity and order, but per-row detail it lacks falls back to the
  /// local row's. `matchReason` and `mediaCategory` each backfill independently.
  private static func backfilled(
    _ row: SearchResultRow, from localRow: SearchResultRow
  ) -> SearchResultRow {
    SearchResultRow(
      kind: row.kind, entityID: row.entityID, parentItemID: row.parentItemID, title: row.title,
      subtitle: row.subtitle, matchReason: row.matchReason ?? localRow.matchReason,
      mediaCategory: row.mediaCategory ?? localRow.mediaCategory,
      hasReadableEbook: row.hasReadableEbook || localRow.hasReadableEbook,
      seriesName: row.seriesName ?? localRow.seriesName, libraryID: row.libraryID,
      serverUpdatedAt: row.serverUpdatedAt ?? localRow.serverUpdatedAt)
  }
}

/// Input to `SearchResultAssembly.section(_:)`. Bundles the row list with per-section paging
/// state, since `SearchSection.hasMore` is per kind, not one flag for the whole result set
/// (`loadMore` pages one section at a time).
public struct SearchSectionInput: Sendable, Equatable {
  public let rows: [SearchResultRow]
  public let query: String
  public let hasMore: [SearchResultKind: Bool]

  public init(
    rows: [SearchResultRow], query: String, hasMore: [SearchResultKind: Bool] = [:]
  ) {
    self.rows = rows
    self.query = query
    self.hasMore = hasMore
  }
}
