import Foundation
import Persistence

/// The Library funnel's copy. Media labels and nouns come from `MediaFilterCopy`, which Home
/// shares, so the vocabulary cannot drift.
///
/// The filter persists across a cold launch, so a reader returning weeks later must be told the
/// list is filtered; a filled funnel glyph cannot say that.
public enum LibraryFilterCopy {
  /// The funnel control's name, which VoiceOver announces when no filter is engaged.
  public static let filterTitle = "Filters"
  public static let downloadedTitle = "Downloaded"
  /// The playback picker's own label (a noun, like `MediaFilterCopy.title`).
  public static let playbackTitle = "Playback"
  /// Confirms and closes the funnel. Every row already commits on tap, so this changes nothing,
  /// but dismissing by tapping outside reads as discarding the choices.
  public static let applyFiltersLabel = "Apply Filters"
  public static let clearFiltersLabel = "Clear Filters"
  public static let clearAllFiltersLabel = "Clear All Filters"

  /// Four labels for four states that partition an item's playback (`PlaybackFilter`). "Unplayed"
  /// selects only items nothing has started; part-listened items fall under "In Progress".
  public static func playbackLabel(for playback: PlaybackFilter) -> String {
    switch playback {
    case .any: return "Any"
    case .unfinished: return "Unplayed"
    case .inProgress: return "In Progress"
    case .finished: return "Finished"
    }
  }

  /// The collapsed playback row's title. The four playback rows live in a submenu, which hides
  /// the checkmark, so the engaged state is named in the parent row. Unengaged it is just the
  /// dimension's name, since "Playback: Any" would claim a filter that is not on.
  public static func playbackMenuLabel(for playback: PlaybackFilter) -> String {
    guard playback != .any else { return playbackTitle }
    return "\(playbackTitle): \(playbackLabel(for: playback))"
  }

  public static func mediaLabel(for filter: MediaFilter) -> String {
    MediaFilterCopy.label(for: filter)
  }

  /// Names every engaged dimension and only those. This is the funnel's accessibility label, so
  /// VoiceOver conveys what a filled glyph shows. Unfiltered, it is just the control's name.
  public static func activeSummary(for filters: BrowseFilters) -> String {
    let engaged = engagedDimensionNames(for: filters)
    guard engaged.isEmpty == false else { return filterTitle }
    return "\(filterTitle): \(engaged.joined(separator: ", "))"
  }

  public static func filteredEmptyTitle(for filters: BrowseFilters) -> String {
    "No Matching Titles"
  }

  public static func emptyTitle(for filters: BrowseFilters) -> String {
    guard let categories = filters.categories, categories.isEmpty == false else {
      return "Your Library Is Empty"
    }
    return "No \(mediaLabels(for: categories).joined(separator: " or ")) Yet"
  }

  /// The noun used by loading/empty copy for a selected set of media kinds. `nil` means the
  /// Library is unfiltered by media kind, so copy must not claim it contains books.
  public static func mediaPluralNoun(for categories: Set<ItemMediaCategory>?) -> String? {
    guard let categories, categories.isEmpty == false else { return nil }
    let nouns = ItemMediaCategory.allCases.compactMap { category -> String? in
      guard categories.contains(category), let filter = mediaFilter(for: category) else { return nil }
      return MediaFilterCopy.pluralNoun(for: filter)
    }
    return nouns.joined(separator: " or ")
  }

  /// Names the engaged dimensions so the reader knows what to undo, and says the filter, not an
  /// empty library, is why the list is blank.
  public static func filteredEmptyMessage(for filters: BrowseFilters) -> String {
    let engaged = engagedDimensionNames(for: filters)
    guard engaged.isEmpty == false else {
      return "Nothing matches the current filter. Clear it to see your library."
    }
    return
      "Nothing in your library matches this filter (\(engaged.joined(separator: ", "))). "
      + "Clear the filter to see everything again."
  }

  /// In the funnel's top-to-bottom order (media kind, Downloaded, playback state).
  private static func engagedDimensionNames(for filters: BrowseFilters) -> [String] {
    var names: [String] = []
    if let categories = filters.categories {
      names.append(mediaLabels(for: categories).joined(separator: ", "))
    }
    if filters.downloadedOnly {
      names.append(downloadedTitle)
    }
    if filters.playback != .any {
      names.append(playbackLabel(for: filters.playback))
    }
    return names
  }

  private static func mediaLabels(for categories: Set<ItemMediaCategory>) -> [String] {
    ItemMediaCategory.allCases.compactMap { category in
      guard categories.contains(category), let filter = mediaFilter(for: category) else { return nil }
      return mediaLabel(for: filter)
    }
  }

  private static func mediaFilter(for category: ItemMediaCategory) -> MediaFilter? {
    MediaFilter.allCases.first { $0.category == category }
  }
}
