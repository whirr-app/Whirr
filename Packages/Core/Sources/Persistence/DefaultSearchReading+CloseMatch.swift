import Foundation
import GRDB

extension DefaultSearchReading {
  /// Typo-tolerant candidates for a query strict search could not match. Every canonical query
  /// token must find a word within its `FuzzyTokenMatch` budget in some column (columns OR'd
  /// within a token, tokens ANDed, as in the canonical branch), and rows order by summed best
  /// distance, nearest first. Scoping and filters are `searchItems`' own, catalogue visibility
  /// included, so a row hidden from strict search can never surface here.
  public func closeMatchItems(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int
  ) async throws -> SearchPage {
    guard let fuzzy = Self.fuzzyTokens(query) else { return SearchPage(rows: [], hasMore: false) }
    let literalTokens = SearchQueryNormalizer.tokens(query)

    let (libraryPredicateSQL, libraryArgs) = Self.libraryFilterSQL(libraryIDs)
    let fuzzyColumns = ["item.title", "item.author", "item.seriesName", "item.narratorName"]
    let (tokenDistanceSQL, totalDistanceSQL, allWithinBudgetSQL) = Self.fuzzyDistanceSQL(
      columns: fuzzyColumns, budgets: fuzzy.budgets)
    let downloadedOnlyPredicateSQL = ItemFilterPredicate.itemDownloadedOnly(filters.downloadedOnly)
    let playbackPredicateSQL = ItemFilterPredicate.itemPlayback(filters.playback)
    let categoriesPredicateSQL = Self.itemCategoriesPredicateSQL(filters.categories)

    // `matched` computes one best-distance column per token; `filtered` keeps only rows where every
    // token is within budget. SQLite flattens both CTEs, and the token predicates short-circuit
    // left to right, so a row failing the first token never pays for the others. `matchedField`
    // is `NULL` so `makeRow` resolves the reason in Swift, over the limited page only.
    let sql = """
      WITH matched AS (
        SELECT
          item.id AS itemRowId, item.serverItemId AS serverItemId, item.mediaKind AS mediaKind,
          item.numAudioFiles AS numAudioFiles, item.ebookFormat AS ebookFormat,
          item.title AS title, item.author AS author, item.seriesName AS seriesName,
          item.narratorName AS narratorName, item.sortTitle AS sortTitle,
          item.serverUpdatedAt AS itemServerUpdatedAt,
          library.serverLibraryId AS libraryID,
          \(tokenDistanceSQL)
        FROM item
        JOIN library
          ON library.id = item.libraryId
          AND library.accountId = item.accountId
        WHERE item.accountId = ?
          AND \(ItemVisibilityPredicate.sql)
          AND \(PodcastCatalogueVisibilityPredicate.sql)
          AND (\(libraryPredicateSQL))
          AND (\(downloadedOnlyPredicateSQL))
          AND (\(playbackPredicateSQL))
          AND (\(categoriesPredicateSQL))
      ),
      filtered AS (
        SELECT *, \(totalDistanceSQL) AS totalDistance,
          NULL AS matchedField, NULL AS matchedText
        FROM matched
        WHERE \(allWithinBudgetSQL)
      )
      SELECT * FROM filtered
      ORDER BY totalDistance ASC, sortTitle ASC, itemRowId ASC
      LIMIT ?
      """

    return try await database.readAsync { db in
      guard let accountId = try AccountRecord.fetchOne(db)?.id else {
        return SearchPage(rows: [], hasMore: false)
      }

      // Argument order tracks the `?` placeholders left to right. The distance group in
      // `matched`'s SELECT list is token-major (token 1 once per column, then token 2 once per
      // column), like `searchItems`' canonical group and unlike its field-major literal groups.
      // Budgets are integer literals in the SQL, not placeholders.
      var arguments = StatementArguments()
      arguments += StatementArguments(
        Self.repeatedPatterns(fuzzy.tokens, fieldCount: fuzzyColumns.count))
      arguments += StatementArguments([accountId])
      arguments += StatementArguments(libraryArgs)
      arguments += StatementArguments([limit])

      let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
      return SearchPage(
        rows: rows.map {
          Self.makeRow($0, tokens: literalTokens, canonicalTokens: fuzzy.tokens)
        },
        hasMore: false)
    }
  }

  /// The episode counterpart of `closeMatchItems`, over `title` and `subtitle` only. Descriptions
  /// are excluded: distance is judged per word, and a description has hundreds of
  /// them, so nearly every episode would hold some word within one edit of almost any token.
  public func closeMatchEpisodes(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int
  ) async throws -> SearchPage {
    // The same podcast-category short-circuit as `searchEpisodes`: there is no shared episode
    // category predicate to call.
    if let categories = filters.categories, categories.isEmpty == false,
      categories.contains(.podcast) == false
    {
      return SearchPage(rows: [], hasMore: false)
    }
    guard let fuzzy = Self.fuzzyTokens(query) else { return SearchPage(rows: [], hasMore: false) }
    let literalTokens = SearchQueryNormalizer.tokens(query)

    let (libraryPredicateSQL, libraryArgs) = Self.libraryFilterSQL(libraryIDs)
    let fuzzyColumns = ["episode.title", "episode.subtitle"]
    let (tokenDistanceSQL, totalDistanceSQL, allWithinBudgetSQL) = Self.fuzzyDistanceSQL(
      columns: fuzzyColumns, budgets: fuzzy.budgets)
    let downloadedOnlyPredicateSQL = ItemFilterPredicate.episodeDownloadedOnly(
      filters.downloadedOnly)
    let playbackPredicateSQL = ItemFilterPredicate.episodePlayback(filters.playback)

    // Same shape as `closeMatchItems`. No catalogue-visibility predicate, as in `searchEpisodes`.
    // Episodes have no `sortTitle`, so the tie-break is `searchEpisodes`' own `title`.
    let sql = """
      WITH matched AS (
        SELECT
          episode.id AS episodeRowId, episode.serverEpisodeId AS serverEpisodeId,
          episode.title AS title, episode.subtitle AS subtitle,
          NULL AS episodeDescription,
          item.serverItemId AS parentItemID, item.serverUpdatedAt AS itemServerUpdatedAt,
          library.serverLibraryId AS libraryID,
          \(tokenDistanceSQL)
        FROM podcastEpisode AS episode
        JOIN item ON item.id = episode.itemId
        JOIN library
          ON library.id = item.libraryId
          AND library.accountId = item.accountId
        WHERE episode.accountId = ?
          AND episode.softDeleted = 0
          AND \(ItemVisibilityPredicate.sql)
          AND (\(libraryPredicateSQL))
          AND (\(downloadedOnlyPredicateSQL))
          AND (\(playbackPredicateSQL))
      ),
      filtered AS (
        SELECT *, \(totalDistanceSQL) AS totalDistance,
          NULL AS matchedField, NULL AS matchedText
        FROM matched
        WHERE \(allWithinBudgetSQL)
      )
      SELECT * FROM filtered
      ORDER BY totalDistance ASC, title ASC, episodeRowId ASC
      LIMIT ?
      """

    return try await database.readAsync { db in
      guard let accountId = try AccountRecord.fetchOne(db)?.id else {
        return SearchPage(rows: [], hasMore: false)
      }

      // Token-major, as in `closeMatchItems`.
      var arguments = StatementArguments()
      arguments += StatementArguments(
        Self.repeatedPatterns(fuzzy.tokens, fieldCount: fuzzyColumns.count))
      arguments += StatementArguments([accountId])
      arguments += StatementArguments(libraryArgs)
      arguments += StatementArguments([limit])

      let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
      return SearchPage(
        rows: rows.map {
          Self.makeEpisodeRow($0, tokens: literalTokens, canonicalTokens: fuzzy.tokens)
        },
        hasMore: false)
    }
  }

  /// The canonical query tokens and each one's budget, or `nil` when the fallback cannot find
  /// anything strict search did not: with every budget `0`, a candidate needs each token as a
  /// whole word, which strict canonical containment already matches.
  private static func fuzzyTokens(_ query: String) -> (tokens: [String], budgets: [Int])? {
    let tokens = SearchQueryNormalizer.tokens(SearchQueryNormalizer.canonicalize(query))
    let budgets = tokens.map(FuzzyTokenMatch.budget(for:))
    guard budgets.contains(where: { $0 > 0 }) else { return nil }
    return (tokens, budgets)
  }

  /// Larger than any token's budget, so it reads as "this token is close to nothing here".
  private static let fuzzyNoMatch = 99

  /// The SQL for the close-match distance: one `fuzzyTokenN` column per token for `matched`'s
  /// SELECT list (token-major `?` placeholders), their sum, and the predicate that every one is
  /// within budget.
  ///
  /// Two SQLite traps: `searchFuzzyDistance` is `NULL` for most columns and scalar `min()` is
  /// `NULL` if any argument is, so each call is wrapped in `COALESCE`; and one-argument `min()` is
  /// the aggregate (collapsing to a single row), so a single column is emitted bare.
  private static func fuzzyDistanceSQL(
    columns: [String], budgets: [Int]
  ) -> (tokenDistances: String, total: String, allWithinBudget: String) {
    precondition(columns.isEmpty == false && budgets.isEmpty == false)
    let tokenDistances = budgets.enumerated().map { index, budget in
      let perColumn = columns.map {
        "COALESCE(searchFuzzyDistance(\($0), ?, \(budget)), \(Self.fuzzyNoMatch))"
      }
      let best = perColumn.count == 1 ? perColumn[0] : "min(\(perColumn.joined(separator: ", ")))"
      return "\(best) AS fuzzyToken\(index)"
    }
    let names = budgets.indices.map { "fuzzyToken\($0)" }
    return (
      tokenDistances.joined(separator: ",\n          "),
      "(" + names.joined(separator: " + ") + ")",
      names.map { "\($0) < \(Self.fuzzyNoMatch)" }.joined(separator: " AND ")
    )
  }
}
