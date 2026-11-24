import Persistence

/// All user-facing search copy: section titles, match-reason phrasing, and the empty/idle
/// strings. Views and models never write search copy inline, mirroring `HomeCopy`/`StorageCopy`.
public enum SearchCopy {

  public static func sectionTitle(for kind: SearchResultKind) -> String {
    switch kind {
    case .book: return "Books"
    case .podcast: return "Podcasts"
    case .episode: return "Episodes"
    case .author: return "Authors"
    case .series: return "Series"
    }
  }

  public static let idlePrompt = "Search your library."
  public static let queryTooShortMessage = "Keep typing to search."
  public static let emptyResultsTitle = "No Results"

  public static func emptyResultsMessage(for query: String) -> String {
    "No matches for \"\(query)\"."
  }

  // Media-kind labels come from `MediaFilterCopy` via `LibraryFilterCopy.mediaLabel`, the same
  // vocabulary the Library and Home render.

  /// The idle screen's recents section header.
  public static let recentSearchesHeader = "Recent Searches"

  /// The recents section's clear-all control, shown only when recents exist.
  public static let clearRecentsButtonTitle = "Clear"

  /// A section's load-more control.
  public static let loadMoreButtonTitle = "Load More"

  /// Renders a `matchReason` as "Label: text", e.g. `("narrator", "Rob Inglis")` renders
  /// "Narrator: Rob Inglis". Returns `nil`, rather than a raw field key, when the field has no
  /// copy here, there is no text, or the text is just the row's own title (which the row already
  /// shows).
  public static func matchReasonText(_ reason: SearchMatchReason?, rowTitle: String) -> String? {
    guard let reason, let text = reason.text, !text.isEmpty, text != rowTitle else { return nil }
    guard let label = matchReasonFieldLabels[reason.field] else { return nil }
    return "\(label): \(text)"
  }

  /// Keyed by every field name either producer emits, since an unmapped key renders nothing.
  /// `DefaultSearchReading`'s SQL names the column it matched (`seriesName`, `narratorName`); the
  /// server names its `matchKey`, plural for array-backed buckets (`authors`, `narrators`,
  /// `tags`). Both spellings map to the same label.
  private static let matchReasonFieldLabels: [String: String] = [
    "narrator": "Narrator",
    "narrators": "Narrator",
    "narratorName": "Narrator",
    "author": "Author",
    "authors": "Author",
    "description": "Description",
    "series": "Series",
    "seriesName": "Series",
    "genre": "Genre",
    "genres": "Genre",
    "tag": "Tag",
    "tags": "Tag",
    "publisher": "Publisher",
    "isbn": "ISBN",
    "asin": "ASIN",
  ]
}
