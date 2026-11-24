import Foundation
import GRDB

/// The production `SearchReading` conformance. Cross-library by construction: sync pulls every
/// library into one account-scoped `item` table carrying `mediaKind`, so `libraryIDs: nil`
/// searches every library and a non-nil, empty set matches nothing (not "unfiltered").
///
/// Candidates come from the `itemSearch`/`episodeSearch` FTS5 tables, ranked by `bm25()`.
/// `searchFold` is registered connection-wide by `AppDatabase`'s `prepareDatabase` (the `v10`
/// triggers need it on any writing connection), not here.
///
/// A row is a candidate if any of three mechanisms matches:
/// - An FTS5 `MATCH` (`"tok1"* AND "tok2"* ...`, one quoted prefix term per
///   `SearchQueryNormalizer.tokens` token, so no user input parses as FTS5 syntax) against the
///   whole row. Terms AND across all columns, so tokens spanning author and title match. `bm25()`
///   (title weighted above the rest) is an `ORDER BY` tie-breaker.
/// - Per-column, per-token `LIKE`. The default `unicode61` tokenizer matches only whole tokens or
///   prefixes, so "ocean" never `MATCH`es "Subocean Mysteries"; `LIKE` finds that mid-word row at
///   a lower tier.
/// - A canonical per-token fallback over `searchCanonical`, ANDed across the row, admitting
///   `S.A.`/`SA`, `O'Brien`/`OBrien` and `Jean-Luc`/`Jean Luc` equivalents. It runs inside
///   candidate selection, before ranking and pagination.
///
/// The five literal tiers (exact > prefix > word-start > title-substring > other-field) stay
/// authoritative, with canonical-only matches in a sixth. `bm25` cannot reproduce that ordering,
/// so it only breaks ties within a tier.
///
/// `downloadedOnly`/`playback` are correlated `EXISTS`/`NOT EXISTS` predicates inside the `matched`
/// CTE, so they filter before `ORDER BY`/`LIMIT`. They live in `ItemFilterPredicate`, shared with
/// the Library's browse filter and Home's Downloaded shelf. Search uses the item- and
/// episode-scoped download functions (episode-scoped rows are excluded per
/// `DownloadStore.itemPresence`), never the library-entry scope.
///
/// `categories` uses the filter-membership predicate, OR'd across the set, filtering `matched`.
/// Episodes have no category (they are podcast content), so `searchEpisodes` returns an empty
/// page without touching the database when `categories` is non-empty and excludes `.podcast`.
public struct DefaultSearchReading: SearchReading, Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func admittedItemIDs(_ ids: [String], filters: BrowseFilters) async throws -> Set<String> {
    guard ids.isEmpty == false else { return [] }

    let downloadedOnlyPredicateSQL = ItemFilterPredicate.itemDownloadedOnly(filters.downloadedOnly)
    let playbackPredicateSQL = ItemFilterPredicate.itemPlayback(filters.playback)
    let categoriesPredicateSQL = Self.itemCategoriesPredicateSQL(filters.categories)
    let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
    let sql = """
      SELECT item.serverItemId
      FROM item
      JOIN library
        ON library.id = item.libraryId
        AND library.accountId = item.accountId
      WHERE item.accountId = ?
        AND \(ItemVisibilityPredicate.sql)
        AND \(PodcastCatalogueVisibilityPredicate.sql)
        AND (\(downloadedOnlyPredicateSQL))
        AND (\(playbackPredicateSQL))
        AND (\(categoriesPredicateSQL))
        AND item.serverItemId IN (\(placeholders))
      """

    return try await database.readAsync { db in
      guard let accountId = try AccountRecord.fetchOne(db)?.id else {
        return Set<String>()
      }

      // The predicate fragments are fixed SQL with no bind arguments; only accountId and ids
      // contribute placeholders to this statement.
      var arguments = StatementArguments([accountId])
      arguments += StatementArguments(ids)
      let serverItemIDs = try String.fetchAll(db, sql: sql, arguments: arguments)
      return Set(serverItemIDs)
    }
  }

  public func searchItems(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage {
    let tokens = SearchQueryNormalizer.tokens(query)
    guard tokens.isEmpty == false else { return SearchPage(rows: [], hasMore: false) }

    let normalizedQuery = SearchQueryNormalizer.normalize(query)
    let escapedNormalizedQuery = Self.escapeLikePattern(normalizedQuery)
    let tokenPatterns = tokens.map { "%\(Self.escapeLikePattern($0))%" }
    let canonicalTokens = SearchQueryNormalizer.tokens(SearchQueryNormalizer.canonicalize(query))
    let canonicalTokenPatterns = canonicalTokens.map { "%\(Self.escapeLikePattern($0))%" }
    let ftsMatchExpression = Self.ftsMatchExpression(tokens: tokens)
    let (libraryPredicateSQL, libraryArgs) = Self.libraryFilterSQL(libraryIDs)
    let titleAllSQL = Self.tokenPredicateSQL(column: "item.title", tokenCount: tokens.count, joiner: "AND")
    let authorAllSQL = Self.tokenPredicateSQL(
      column: "item.author", tokenCount: tokens.count, joiner: "AND")
    let seriesAllSQL = Self.tokenPredicateSQL(
      column: "item.seriesName", tokenCount: tokens.count, joiner: "AND")
    let narratorAllSQL = Self.tokenPredicateSQL(
      column: "item.narratorName", tokenCount: tokens.count, joiner: "AND")
    let canonicalRowAllSQL = Self.canonicalRowPredicateSQL(
      columns: ["item.title", "item.author", "item.seriesName", "item.narratorName"],
      tokenCount: canonicalTokens.count)
    let downloadedOnlyPredicateSQL = ItemFilterPredicate.itemDownloadedOnly(filters.downloadedOnly)
    let playbackPredicateSQL = ItemFilterPredicate.itemPlayback(filters.playback)
    let categoriesPredicateSQL = Self.itemCategoriesPredicateSQL(filters.categories)

    // `matched` computes the four per-field "all tokens in this column" predicates plus the FTS5
    // candidate's rowid/bm25 as real columns, so `filtered` can reference them by name (SQLite
    // cannot use a SELECT-list alias in the same SELECT's WHERE, hence the two-stage CTE).
    // `matchedField`/`matchedText` are `NULL` when a row matched only through the cross-column FTS
    // path; `makeRow` resolves that in Swift over just the limited page.
    let sql = """
      WITH matched AS (
        SELECT
          item.id AS itemRowId, item.serverItemId AS serverItemId, item.mediaKind AS mediaKind,
          item.numAudioFiles AS numAudioFiles, item.ebookFormat AS ebookFormat,
          item.title AS title, item.author AS author, item.seriesName AS seriesName,
          item.narratorName AS narratorName, item.sortTitle AS sortTitle,
          item.serverUpdatedAt AS itemServerUpdatedAt,
          library.serverLibraryId AS libraryID,
          (\(titleAllSQL)) AS titleMatch,
          (\(authorAllSQL)) AS authorMatch,
          (\(seriesAllSQL)) AS seriesMatch,
          (\(narratorAllSQL)) AS narratorMatch,
          (\(canonicalRowAllSQL)) AS canonicalMatch,
          fts.rowid AS ftsRowId,
          fts.bm25Score AS bm25Score
        FROM item
        JOIN library
          ON library.id = item.libraryId
          AND library.accountId = item.accountId
        LEFT JOIN (
          SELECT rowid, bm25(itemSearch, 10.0, 3.0, 3.0, 3.0) AS bm25Score
          FROM itemSearch
          WHERE itemSearch MATCH ?
        ) AS fts ON fts.rowid = item.id
        WHERE item.accountId = ?
          AND \(ItemVisibilityPredicate.sql)
          AND \(PodcastCatalogueVisibilityPredicate.sql)
          AND (\(libraryPredicateSQL))
          AND (\(downloadedOnlyPredicateSQL))
          AND (\(playbackPredicateSQL))
          AND (\(categoriesPredicateSQL))
      ),
      filtered AS (
        SELECT *,
          CASE
            WHEN titleMatch = 1 AND searchFold(title) = ? THEN 0
            WHEN titleMatch = 1 AND searchFold(title) LIKE ? ESCAPE '\\' THEN 1
            WHEN titleMatch = 1 AND searchFold(title) LIKE ? ESCAPE '\\' THEN 2
            WHEN titleMatch = 1 THEN 3
            WHEN authorMatch = 1 OR seriesMatch = 1 OR narratorMatch = 1 THEN 4
            WHEN ftsRowId IS NOT NULL THEN 4
            ELSE 5
          END AS rankTier,
          CASE
            WHEN titleMatch = 1 THEN 'title'
            WHEN authorMatch = 1 THEN 'author'
            WHEN seriesMatch = 1 THEN 'seriesName'
            WHEN narratorMatch = 1 THEN 'narratorName'
          END AS matchedField,
          CASE
            WHEN titleMatch = 1 THEN title
            WHEN authorMatch = 1 THEN author
            WHEN seriesMatch = 1 THEN seriesName
            WHEN narratorMatch = 1 THEN narratorName
          END AS matchedText
        FROM matched
        WHERE titleMatch = 1 OR authorMatch = 1 OR seriesMatch = 1 OR narratorMatch = 1
          OR canonicalMatch = 1 OR ftsRowId IS NOT NULL
      )
      SELECT * FROM filtered
      ORDER BY rankTier ASC, COALESCE(bm25Score, 0.0) ASC, sortTitle ASC, itemRowId ASC
      LIMIT ? OFFSET ?
      """

    return try await database.readAsync { db in
      guard let accountId = try AccountRecord.fetchOne(db)?.id else {
        return SearchPage(rows: [], hasMore: false)
      }

      // Fetch one row past `limit` to answer `hasMore` without a second COUNT(*) query. Argument
      // order must track the `?` placeholders as they appear in `sql` above, left to right: the
      // literal LIKE groups and then the token-major canonical row group in `matched`'s SELECT
      // list come before the FTS5 `MATCH` placeholder, which itself comes before `WHERE`.
      var arguments = StatementArguments()
      arguments += StatementArguments(tokenPatterns)
      arguments += StatementArguments(tokenPatterns)
      arguments += StatementArguments(tokenPatterns)
      arguments += StatementArguments(tokenPatterns)
      arguments += StatementArguments(
        Self.repeatedPatterns(canonicalTokenPatterns, fieldCount: 4))
      arguments += StatementArguments([ftsMatchExpression])
      arguments += StatementArguments([accountId])
      arguments += StatementArguments(libraryArgs)
      let prefixArg = "\(escapedNormalizedQuery)%"
      let wordStartArg = "% \(escapedNormalizedQuery)%"
      arguments += StatementArguments([normalizedQuery, prefixArg, wordStartArg])
      arguments += StatementArguments([limit + 1, offset])

      let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
      let hasMore = rows.count > limit
      return SearchPage(
        rows: rows.prefix(limit).map {
          Self.makeRow($0, tokens: tokens, canonicalTokens: canonicalTokens)
        }, hasMore: hasMore)
    }
  }

  public func searchEpisodes(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage {
    // Episodes are podcast content (see the type doc comment), so a non-empty `categories` that
    // excludes `.podcast` can never match. Return early rather than run a query that finds nothing.
    if let categories = filters.categories, categories.isEmpty == false,
      categories.contains(.podcast) == false
    {
      return SearchPage(rows: [], hasMore: false)
    }

    let tokens = SearchQueryNormalizer.tokens(query)
    guard tokens.isEmpty == false else { return SearchPage(rows: [], hasMore: false) }

    let normalizedQuery = SearchQueryNormalizer.normalize(query)
    let escapedNormalizedQuery = Self.escapeLikePattern(normalizedQuery)
    let tokenPatterns = tokens.map { "%\(Self.escapeLikePattern($0))%" }
    let canonicalTokens = SearchQueryNormalizer.tokens(SearchQueryNormalizer.canonicalize(query))
    let canonicalTokenPatterns = canonicalTokens.map { "%\(Self.escapeLikePattern($0))%" }
    let ftsMatchExpression = Self.ftsMatchExpression(tokens: tokens)
    let (libraryPredicateSQL, libraryArgs) = Self.libraryFilterSQL(libraryIDs)
    let titleAllSQL = Self.tokenPredicateSQL(
      column: "episode.title", tokenCount: tokens.count, joiner: "AND")
    let subtitleAllSQL = Self.tokenPredicateSQL(
      column: "episode.subtitle", tokenCount: tokens.count, joiner: "AND")
    // The description is matched and reported as `FeedHTML.plainText`, the same expression the
    // `v83` triggers index, so a query cannot find `href` or a link's URL in the markup.
    let descriptionAllSQL = Self.tokenPredicateSQL(
      column: Self.plainDescriptionSQL, tokenCount: tokens.count, joiner: "AND")
    let canonicalRowAllSQL = Self.canonicalRowPredicateSQL(
      columns: ["episode.title", "episode.subtitle", Self.plainDescriptionSQL],
      tokenCount: canonicalTokens.count)
    let downloadedOnlyPredicateSQL = ItemFilterPredicate.episodeDownloadedOnly(
      filters.downloadedOnly)
    let playbackPredicateSQL = ItemFilterPredicate.episodePlayback(filters.playback)

    // Same two-stage CTE as `searchItems`, with the Swift-side `matchedField` fallback for a
    // cross-column-only match (see `makeEpisodeRow`).
    let sql = """
      WITH matched AS (
        SELECT
          episode.id AS episodeRowId, episode.serverEpisodeId AS serverEpisodeId,
          episode.title AS title, episode.subtitle AS subtitle,
          \(Self.plainDescriptionSQL) AS episodeDescription,
          item.serverItemId AS parentItemID, item.serverUpdatedAt AS itemServerUpdatedAt,
          library.serverLibraryId AS libraryID,
          (\(titleAllSQL)) AS titleMatch,
          (\(subtitleAllSQL)) AS subtitleMatch,
          (\(descriptionAllSQL)) AS descriptionMatch,
          (\(canonicalRowAllSQL)) AS canonicalMatch,
          fts.rowid AS ftsRowId,
          fts.bm25Score AS bm25Score
        FROM podcastEpisode AS episode
        JOIN item ON item.id = episode.itemId
        JOIN library
          ON library.id = item.libraryId
          AND library.accountId = item.accountId
        LEFT JOIN (
          SELECT rowid, bm25(episodeSearch, 10.0, 5.0, 1.0) AS bm25Score
          FROM episodeSearch
          WHERE episodeSearch MATCH ?
        ) AS fts ON fts.rowid = episode.id
        WHERE episode.accountId = ?
          AND episode.softDeleted = 0
          AND \(ItemVisibilityPredicate.sql)
          AND (\(libraryPredicateSQL))
          AND (\(downloadedOnlyPredicateSQL))
          AND (\(playbackPredicateSQL))
      ),
      filtered AS (
        SELECT *,
          CASE
            WHEN titleMatch = 1 AND searchFold(title) = ? THEN 0
            WHEN titleMatch = 1 AND searchFold(title) LIKE ? ESCAPE '\\' THEN 1
            WHEN titleMatch = 1 AND searchFold(title) LIKE ? ESCAPE '\\' THEN 2
            WHEN titleMatch = 1 THEN 3
            WHEN subtitleMatch = 1 OR descriptionMatch = 1 THEN 4
            WHEN ftsRowId IS NOT NULL THEN 4
            ELSE 5
          END AS rankTier,
          CASE
            WHEN titleMatch = 1 THEN 'title'
            WHEN subtitleMatch = 1 THEN 'subtitle'
            WHEN descriptionMatch = 1 THEN 'episodeDescription'
          END AS matchedField,
          CASE
            WHEN titleMatch = 1 THEN title
            WHEN subtitleMatch = 1 THEN subtitle
            WHEN descriptionMatch = 1 THEN episodeDescription
          END AS matchedText
        FROM matched
        WHERE titleMatch = 1 OR subtitleMatch = 1 OR descriptionMatch = 1
          OR canonicalMatch = 1 OR ftsRowId IS NOT NULL
      )
      SELECT * FROM filtered
      ORDER BY rankTier ASC, COALESCE(bm25Score, 0.0) ASC, title ASC, episodeRowId ASC
      LIMIT ? OFFSET ?
      """

    return try await database.readAsync { db in
      guard let accountId = try AccountRecord.fetchOne(db)?.id else {
        return SearchPage(rows: [], hasMore: false)
      }

      // Argument order tracks the `?` placeholders left to right, as in `searchItems`.
      var arguments = StatementArguments()
      arguments += StatementArguments(tokenPatterns)
      arguments += StatementArguments(tokenPatterns)
      arguments += StatementArguments(tokenPatterns)
      arguments += StatementArguments(
        Self.repeatedPatterns(canonicalTokenPatterns, fieldCount: 3))
      arguments += StatementArguments([ftsMatchExpression])
      arguments += StatementArguments([accountId])
      arguments += StatementArguments(libraryArgs)
      let prefixArg = "\(escapedNormalizedQuery)%"
      let wordStartArg = "% \(escapedNormalizedQuery)%"
      arguments += StatementArguments([normalizedQuery, prefixArg, wordStartArg])
      arguments += StatementArguments([limit + 1, offset])

      let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
      let hasMore = rows.count > limit
      return SearchPage(
        rows: rows.prefix(limit).map {
          Self.makeEpisodeRow($0, tokens: tokens, canonicalTokens: canonicalTokens)
        }, hasMore: hasMore)
    }
  }

  // MARK: - SQL

  /// Builds the FTS5 `MATCH` expression from already-tokenised tokens, never raw query text.
  /// `SearchQueryNormalizer.tokens` splits on every non-alphanumeric character, so a token holds no
  /// quote, `*` or boolean syntax; quoting and suffixing `*` makes each a literal prefix term, so
  /// no FTS5 syntax can be injected (`"a OR b"` becomes `a`, `or`, `b` ANDed).
  private static func ftsMatchExpression(tokens: [String]) -> String {
    tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
  }

  /// An episode's description as searchable text. `makeEpisodeRow` reads the column of this name
  /// back, so the Swift-side match fallback and the reported match text are plain text too.
  private static let plainDescriptionSQL = "searchPlainText(episode.episodeDescription)"

  private static func tokenPredicateSQL(column: String, tokenCount: Int, joiner: String) -> String {
    guard tokenCount > 0 else { return "0" }
    return Array(repeating: "searchFold(\(column)) LIKE ? ESCAPE '\\'", count: tokenCount)
      .joined(separator: " \(joiner) ")
  }

  private static func canonicalRowPredicateSQL(columns: [String], tokenCount: Int) -> String {
    guard tokenCount > 0, columns.isEmpty == false else { return "0" }
    let oneToken =
      "(" + columns.map { "searchCanonical(\($0)) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
    return Array(repeating: oneToken, count: tokenCount).joined(separator: " AND ")
  }

  static func repeatedPatterns(_ patterns: [String], fieldCount: Int) -> [String] {
    patterns.flatMap { pattern in Array(repeating: pattern, count: fieldCount) }
  }

  static func libraryFilterSQL(_ libraryIDs: [String]?) -> (sql: String, args: [String]) {
    guard let libraryIDs else { return ("1", []) }
    guard libraryIDs.isEmpty == false else { return ("0", []) }
    let placeholders = Array(repeating: "?", count: libraryIDs.count).joined(separator: ", ")
    return ("library.serverLibraryId IN (\(placeholders))", libraryIDs)
  }

  /// ORs the filter-membership predicate's single-category form across the set. `nil`/empty mean
  /// unfiltered, matching `BrowseFilters.categories`.
  static func itemCategoriesPredicateSQL(_ categories: Set<ItemMediaCategory>?) -> String {
    guard let categories, categories.isEmpty == false else { return "1" }
    return categories.map { "(\(ItemFilterCategoryPredicate.sql($0)))" }.joined(separator: " OR ")
  }

  private static func escapeLikePattern(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  static func makeRow(_ row: Row, tokens: [String], canonicalTokens: [String]) -> SearchResultRow {
    let mediaKind: String = row["mediaKind"]
    let title: String = row["title"]
    let author: String? = row["author"]
    let seriesName: String? = row["seriesName"]
    let narratorName: String? = row["narratorName"]
    let (field, text) = Self.resolvedMatchReason(
      sqlField: row["matchedField"], sqlText: row["matchedText"], tokens: tokens,
      canonicalTokens: canonicalTokens,
      fieldsInPriorityOrder: [
        ("title", title), ("author", author), ("seriesName", seriesName),
        ("narratorName", narratorName),
      ])
    return SearchResultRow(
      kind: mediaKind == "podcast" ? .podcast : .book,
      entityID: row["serverItemId"],
      title: title,
      subtitle: author,
      matchReason: SearchMatchReason(field: field, text: text),
      mediaCategory: ItemMediaCategory.derive(
        mediaKind: mediaKind, numAudioFiles: row["numAudioFiles"], ebookFormat: row["ebookFormat"]),
      hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: row["ebookFormat"]),
      seriesName: seriesName,
      libraryID: row["libraryID"],
      serverUpdatedAt: row["itemServerUpdatedAt"]
    )
  }

  static func makeEpisodeRow(
    _ row: Row, tokens: [String], canonicalTokens: [String]
  ) -> SearchResultRow {
    let title: String = row["title"]
    let subtitle: String? = row["subtitle"]
    let episodeDescription: String? = row["episodeDescription"]
    let (field, text) = Self.resolvedMatchReason(
      sqlField: row["matchedField"], sqlText: row["matchedText"], tokens: tokens,
      canonicalTokens: canonicalTokens,
      fieldsInPriorityOrder: [
        ("title", title), ("subtitle", subtitle), ("episodeDescription", episodeDescription),
      ])
    return SearchResultRow(
      kind: .episode,
      entityID: row["serverEpisodeId"],
      parentItemID: row["parentItemID"],
      title: title,
      subtitle: subtitle,
      matchReason: SearchMatchReason(field: field, text: text),
      libraryID: row["libraryID"],
      serverUpdatedAt: row["itemServerUpdatedAt"]
    )
  }

  /// SQL reports `matchedField`/`matchedText` as `NULL` for a row that matched only through a
  /// cross-column FTS5 or canonical path, where no single field applies. Resolve it over only the
  /// limited page by reporting the highest-priority field containing a literal token, then a
  /// canonical token. Priority matches SQL's same-column order: title > author/subtitle >
  /// seriesName and so on.
  private static func resolvedMatchReason(
    sqlField: String?, sqlText: String?, tokens: [String], canonicalTokens: [String],
    fieldsInPriorityOrder: [(field: String, value: String?)]
  ) -> (field: String, text: String?) {
    if let sqlField { return (sqlField, sqlText) }
    let normalizedTokens = tokens.map { SearchQueryNormalizer.normalize($0) }
    for (field, value) in fieldsInPriorityOrder {
      guard let value else { continue }
      let normalizedValue = SearchQueryNormalizer.normalize(value)
      if normalizedTokens.contains(where: { normalizedValue.contains($0) }) {
        return (field, value)
      }
    }
    for (field, value) in fieldsInPriorityOrder {
      guard let value else { continue }
      let canonicalValue = SearchQueryNormalizer.canonicalize(value)
      if canonicalTokens.contains(where: { canonicalValue.contains($0) }) {
        return (field, value)
      }
    }
    // A close-match row may hold neither a literal nor a canonical token, only a word within a
    // token's edit budget, so the third pass reports the highest-priority field holding one.
    for (field, value) in fieldsInPriorityOrder {
      guard let value else { continue }
      let holdsCloseMatch = canonicalTokens.contains { token in
        FuzzyTokenMatch.bestDistance(
          token: token, in: value, budget: FuzzyTokenMatch.budget(for: token)) != nil
      }
      if holdsCloseMatch { return (field, value) }
    }
    // Candidate selection guarantees a literal or canonical token (or a close-match word) somewhere
    // in the row. Fall back to the first field rather than crash if that is ever violated.
    let first = fieldsInPriorityOrder[0]
    return (first.field, first.value)
  }
}
