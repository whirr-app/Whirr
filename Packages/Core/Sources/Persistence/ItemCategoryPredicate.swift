/// The SQL mirror of `ItemMediaCategory.derive`, which owns the logic; keep the two in lockstep.
/// `nil` imposes no constraint; `.podcast` matches `mediaKind` alone; `.audiobook` matches any
/// audio files, or `derive`'s "everything else" fallback; `.ebook` matches no audio files plus a
/// non-empty `ebookFormat`. Composed from the fixed `ItemMediaCategory` case, never caller input,
/// so no argument binding is needed.
///
/// Every category-filtered query shares this string, so projections agree about what an item is.
enum ItemCategoryPredicate {
  /// SQL equivalent of `EbookFormatNormalizer.normalize`, for predicates which only need to
  /// distinguish absent, EPUB, and another document format.
  static let normalizedEbookFormatSQL = """
    LOWER(
      LTRIM(
        TRIM(item.ebookFormat, ' ' || CHAR(9) || CHAR(10) || CHAR(11) || CHAR(12) || CHAR(13)),
        '.'
      )
    )
    """

  static let hasDocumentSQL = "\(normalizedEbookFormatSQL) != ''"
  static let hasReadableEbookSQL = "\(normalizedEbookFormatSQL) = 'epub'"

  static func sql(_ category: ItemMediaCategory?) -> String {
    switch category {
    case nil:
      return "1 = 1"
    case .podcast:
      return "item.mediaKind = 'podcast'"
    case .audiobook:
      return """
        item.mediaKind != 'podcast'
        AND (
          COALESCE(item.numAudioFiles, 0) > 0
          OR item.ebookFormat IS NULL
          OR \(normalizedEbookFormatSQL) = ''
        )
        """
    case .ebook:
      return """
        item.mediaKind != 'podcast'
        AND COALESCE(item.numAudioFiles, 0) <= 0
        AND item.ebookFormat IS NOT NULL
        AND \(hasDocumentSQL)
        """
    }
  }
}
