import GRDB

extension SchemaV1 {
  /// Registered on every connection by `AppDatabase`'s configuration, because the triggers below
  /// run on whichever connection performs a write, not only the one `DefaultSearchReading` is
  /// querying from. Folds text as `SearchQueryNormalizer.normalize` does, so the index and a
  /// query built from `SearchQueryNormalizer.tokens` agree by construction.
  static let searchFoldFunction = DatabaseFunction("searchFold", argumentCount: 1, pure: true) {
    values in
    guard let text = String.fromDatabaseValue(values[0]) else { return nil }
    return SearchQueryNormalizer.normalize(text)
  }

  /// Strips markup before folding: the `v83` episode triggers and `DefaultSearchReading`'s
  /// description predicates index and match `FeedHTML.plainText` of the stored HTML, so `href`,
  /// `div` or a link's URL cannot produce an episode. Only `episodeDescription` goes through
  /// this; a title is already text.
  static let searchPlainTextFunction = DatabaseFunction(
    "searchPlainText", argumentCount: 1, pure: true
  ) { values in
    guard let text = String.fromDatabaseValue(values[0]) else { return nil }
    return FeedHTML.plainText(text)
  }

  /// Every SQL function the schema's triggers and the search queries call. Registered in
  /// `AppDatabase`'s `prepareDatabase` for production, and by any test that builds its own
  /// `DatabaseQueue` and runs the migrator: the triggers fire on whichever connection writes.
  static func registerSearchFunctions(_ db: Database) {
    db.add(function: searchFoldFunction)
    db.add(function: searchCanonicalFunction)
    db.add(function: searchFuzzyDistanceFunction)
    db.add(function: searchPlainTextFunction)
  }

  /// Query-time canonical spelling, separate from the FTS write-path fold. The original index
  /// stays the literal candidate and ranking source; this supplies the lower-ranked
  /// punctuation/initialism fallback over the same bounded SQL query.
  static let searchCanonicalFunction = DatabaseFunction(
    "searchCanonical", argumentCount: 1, pure: true
  ) { values in
    guard let text = String.fromDatabaseValue(values[0]) else { return nil }
    return SearchQueryNormalizer.canonicalize(text)
  }

  /// `searchFuzzyDistance(text, token, budget)`: the closest word of `text` to one canonical query
  /// token, as `FuzzyTokenMatch.bestDistance`, or `NULL` when no word is within `budget`. Used by
  /// Search's close-match fallback on the read path only. Unlike `searchFold` and
  /// `searchPlainText` it is in no trigger, index or migration, so changing it needs no schema
  /// change.
  ///
  /// `NULL` is the common answer and scalar `min()` is `NULL` if any argument is, so callers wrap
  /// every call in `COALESCE` before taking a minimum across columns.
  static let searchFuzzyDistanceFunction = DatabaseFunction(
    "searchFuzzyDistance", argumentCount: 3, pure: true
  ) { values in
    guard let text = String.fromDatabaseValue(values[0]),
      let token = String.fromDatabaseValue(values[1]),
      let budget = Int.fromDatabaseValue(values[2]),
      let distance = FuzzyTokenMatch.bestDistance(token: token, in: text, budget: budget)
    else { return nil }
    return distance
  }
}
