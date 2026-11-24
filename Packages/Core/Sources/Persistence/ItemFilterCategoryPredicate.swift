/// The SQL for category filter membership, kept beside `ItemCategoryPredicate`.
///
/// `ItemCategoryPredicate` is the identity predicate (mirrors `ItemMediaCategory.derive`); this
/// one answers whether an item belongs in a category filter. An item with audio files and a
/// readable EPUB belongs in both Audiobooks and Ebooks; with only a PDF supplement, just
/// Audiobooks.
public enum ItemFilterCategoryPredicate {
  static func sql(_ category: ItemMediaCategory?) -> String {
    switch category {
    case .ebook:
      return """
        item.mediaKind != 'podcast'
        AND item.ebookFormat IS NOT NULL
        AND \(ItemCategoryPredicate.hasDocumentSQL)
        AND (
          COALESCE(item.numAudioFiles, 0) <= 0
          OR \(ItemCategoryPredicate.hasReadableEbookSQL)
        )
        """
    default:
      return ItemCategoryPredicate.sql(category)
    }
  }

  /// Pure counterpart of the SQL predicate, used after Search merges server and local rows.
  public static func matches(
    _ category: ItemMediaCategory,
    primaryCategory: ItemMediaCategory,
    hasReadableEbook: Bool
  ) -> Bool {
    switch category {
    case .audiobook:
      return primaryCategory == .audiobook
    case .podcast:
      return primaryCategory == .podcast
    case .ebook:
      return primaryCategory == .ebook
        || (primaryCategory == .audiobook && hasReadableEbook)
    }
  }

  /// Multiple selected media categories have OR semantics. `nil` and an empty set are both
  /// unfiltered so this remains total for callers outside `BrowseFilters`.
  public static func matches(
    _ categories: Set<ItemMediaCategory>?,
    primaryCategory: ItemMediaCategory,
    hasReadableEbook: Bool
  ) -> Bool {
    guard let categories, categories.isEmpty == false else { return true }
    return categories.contains {
      matches($0, primaryCategory: primaryCategory, hasReadableEbook: hasReadableEbook)
    }
  }
}
