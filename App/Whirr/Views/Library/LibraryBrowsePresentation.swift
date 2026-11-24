import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

/// Pure title-section derivation for `LibraryBrowseView`'s native list section index.
enum LibraryBrowsePresentation {
  enum RowPlaybackStatus: Equatable {
    case inProgress
    case finished

    var label: String {
      switch self {
      case .inProgress: ItemProgressCopy.badgeLabel
      case .finished: ItemFinishedCopy.badgeLabel
      }
    }

    var systemImage: String {
      switch self {
      case .inProgress: PodcastEpisodePlaybackStatus.inProgress.systemImage
      case .finished: ItemFinishedCopy.badgeSystemImage
      }
    }
  }

  /// The Library's top-level browse dimension. Separate from `BrowseFilters`: a filter narrows
  /// titles, whereas a mode changes the kind of thing the reader is browsing.
  nonisolated enum Mode: CaseIterable, Hashable, Sendable {
    case titles
    case authors
    case series
    /// Collections, then playlists, in one list.
    case collections

    var label: String {
      switch self {
      case .titles: "Titles"
      case .authors: "Authors"
      case .series: "Series"
      case .collections: "Collections"
      }
    }

    var entityKind: SearchResultKind? {
      switch self {
      case .titles, .collections: nil
      case .authors: .author
      case .series: .series
      }
    }
  }

  nonisolated enum PlaceholderAction: Equatable {
    case retry

    var label: String { "Retry" }
  }

  nonisolated enum Placeholder: Equatable {
    case loading(message: String)
    case empty(title: String, message: String, systemImage: String)
    case error(
      title: String, message: String, systemImage: String, action: PlaceholderAction)

    /// The no-button states promise pull-to-refresh. The error Retry button is the explicit
    /// recovery affordance and must stay interactive.
    var allowsHitTesting: Bool {
      if case .error = self { return true }
      return false
    }

    var action: PlaceholderAction? {
      if case .error(_, _, _, let action) = self { return action }
      return nil
    }
  }

  static func placeholder(
    for state: LibraryBrowseModel.State, filters: BrowseFilters
  ) -> Placeholder? {
    switch state {
    case .loading:
      return .loading(message: state.copyText(for: filters))
    case .empty:
      return .empty(
        title: state.emptyTitle(for: filters), message: state.copyText(for: filters),
        systemImage: emptyStateSymbol(for: state, filters: filters))
    case .error:
      return .error(
        title: "Couldn't Load Library", message: state.copyText(for: filters),
        systemImage: "exclamationmark.triangle", action: .retry)
    case .filteredEmpty, .loaded, .partiallySynced, .staleOffline:
      return nil
    }
  }

  nonisolated enum SystemOwner: Equatable {
    case systemList
  }

  /// SwiftUI's list section index owns its compact layout, scrubbing, and interaction feedback.
  static let indexOwner: SystemOwner = .systemList
  static let interactionFeedbackOwner: SystemOwner = .systemList
  static let alphabetIndexTitles = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init) + ["#"]

  struct Section<Value: Identifiable>: Identifiable {
    let id: String
    let items: [Value]
  }

  static func sections<Value: Identifiable>(
    for values: [Value], title: (Value) -> String
  ) -> [Section<Value>] {
    var grouped: [String: [Value]] = [:]
    for value in values {
      grouped[sectionID(for: title(value)), default: []].append(value)
    }
    return alphabetIndexTitles.compactMap { id in
      guard let values = grouped[id] else { return nil }
      return Section(id: id, items: values)
    }
  }

  static func sections(for items: [ItemSummary]) -> [Section<ItemSummary>] {
    sections(for: items, title: \.title)
  }

  /// Empty sections keep an index label but render no header or rows. This is the system API's
  /// way to expose a complete alphabet without a custom index overlay.
  static func indexedSections<Value: Identifiable>(
    for values: [Value], title: (Value) -> String
  ) -> [Section<Value>] {
    let populated = Dictionary(
      uniqueKeysWithValues: sections(for: values, title: title).map { ($0.id, $0.items) })
    return alphabetIndexTitles.map { id in
      Section(id: id, items: populated[id] ?? [])
    }
  }

  static func indexedSections(for items: [ItemSummary]) -> [Section<ItemSummary>] {
    indexedSections(for: items, title: \.title)
  }

  /// The caption a state renders above the rows, or `nil` for a state that must not push them
  /// around.
  ///
  /// A sync run gets none: it would move every row as bursts of runs start and finish (a run with
  /// no rows is `.loading`, which owns the space). Offline keeps its caption (rows can't say it).
  /// Filtered-empty renders its own copy and way out.
  static func banner(for state: LibraryBrowseModel.State, filters: BrowseFilters) -> String? {
    switch state {
    case .loading, .empty, .loaded, .partiallySynced, .error, .filteredEmpty:
      return nil
    case .staleOffline:
      return state.copyText(for: filters)
    }
  }

  /// Whether the funnel renders as filled. A projection of the model's value, not view state, so
  /// the control and the list it narrows cannot disagree.
  static func isFilterActive(_ filters: BrowseFilters) -> Bool { filters.isActive }

  /// What the two empty states picture. Filtered-empty shows the funnel (the glyph
  /// `PodcastShowListCopy.noMatchingEpisodesSystemImage` uses for "this filter matches nothing"),
  /// so the cause is legible before the copy is read. Everything else pictures the selected media
  /// filter, using the badge's symbol per kind.
  static func emptyStateSymbol(for state: LibraryBrowseModel.State, filters: BrowseFilters) -> String {
    if case .filteredEmpty = state {
      return FilterButtonPresentation.emptyStateSymbolName
    }
    guard let category = MediaFilter(browseCategories: filters.categories).category else {
      return "books.vertical"
    }
    return HomeViewPresentation.badgeKind(for: category).symbolName
  }

  static func canClearAllFilters(_ filters: BrowseFilters) -> Bool {
    filters.isActive
  }

  /// The rendered item projection, or none when the state carries no rows. Authors and Series
  /// derive from this, so all three modes narrow on one filtered set and the scroll gate that holds
  /// a projection back holds it back for every mode at once.
  static func items(in state: LibraryBrowseModel.State) -> [ItemSummary] {
    switch state {
    case .loaded(let items), .partiallySynced(let items), .staleOffline(let items):
      return items
    case .loading, .empty, .error, .filteredEmpty:
      return []
    }
  }

  nonisolated static let unknownAuthor = "Unknown author"

  /// The line under a row's title, or `nil` for a row with none.
  ///
  /// Many podcast feeds name no creator, so an unnamed show says nothing rather than "Unknown
  /// author". Books keep the fallback: a missing author there is a real metadata gap.
  nonisolated static func subtitle(for item: ItemSummary) -> String? {
    if let author = item.author, author.isEmpty == false { return author }
    return item.category == .podcast ? nil : unknownAuthor
  }

  /// The one playback marker a title row carries. Finished wins over progress, since a completed
  /// item usually keeps its final position.
  static func rowPlaybackStatus(
    playbackStatus: ItemPlaybackStatus?
  ) -> RowPlaybackStatus? {
    switch playbackStatus {
    case .inProgress: .inProgress
    case .finished: .finished
    case nil: nil
    }
  }

  // MARK: - Author and series rows

  /// The line under an entity's name.
  ///
  /// Both modes lead with the count. A series puts its author ahead of it, and an author adds how
  /// many series their books span. Empty segments are dropped rather than filled with a
  /// placeholder, so a sparse library gets a short subtitle instead of "Unknown".
  static func entitySubtitle(for group: LibraryEntityGroup) -> String? {
    var segments: [String] = []
    if group.kind == .series, let author = group.primaryAuthorName {
      segments.append(author)
    }
    if let count = group.bookCount {
      segments.append(bookCountText(count))
    }
    if group.kind == .author {
      let seriesCount = group.seriesNames.count
      if seriesCount > 0 {
        segments.append(seriesCount == 1 ? "1 series" : "\(seriesCount) series")
      }
    }
    return segments.isEmpty ? nil : segments.joined(separator: " · ")
  }

  static func bookCountText(_ count: Int) -> String {
    count == 1 ? "1 book" : "\(count) books"
  }

  /// The glyph for an entity with no artwork to borrow. A series reaches this only when none of its
  /// matched items are in the local store; an author always does (no portraits are fetched).
  static func entityPlaceholderSymbol(for kind: SearchResultKind) -> String {
    kind == .author ? "person.fill" : "books.vertical.fill"
  }

  /// One entity row's spoken label. The badges and count sit inside a `Button` whose label replaces
  /// its children for VoiceOver, so the media kinds must be spelled out here.
  static func entityAccessibilityLabel(for group: LibraryEntityGroup) -> String {
    let kinds = group.categories.map(HomeRowPresentation.badgeLabel(for:))
    return ([group.name, entitySubtitle(for: group)] + kinds)
      .compactMap { $0 }
      .joined(separator: ", ")
  }

  /// One row's spoken label. The badges sit inside a `Button` whose label replaces its children
  /// for VoiceOver, so the media kind and finished state must be spelled out here.
  static func rowAccessibilityLabel(
    item: ItemSummary, playbackStatus: ItemPlaybackStatus?
  ) -> String {
    let mediaKind = HomeRowPresentation.badgeLabel(for: item.category)
    let rowPlaybackStatus = rowPlaybackStatus(playbackStatus: playbackStatus)
    return [item.title, subtitle(for: item), mediaKind, rowPlaybackStatus?.label]
      .compactMap { $0 }
      .joined(separator: ", ")
  }

  private static func sectionID(for title: String) -> String {
    let shelfTitle = removingIgnoredArticle(from: title)
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    guard let first = shelfTitle.first else { return "#" }
    let candidate = String(first)
    return alphabetIndexTitles.dropLast().contains(candidate) ? candidate : "#"
  }

  private static func removingIgnoredArticle(from title: String) -> String {
    let lowercased = title.lowercased()
    for prefix in ["the ", "an ", "a "] where lowercased.hasPrefix(prefix) {
      return String(title.dropFirst(prefix.count))
    }
    return title
  }

  // MARK: - Quick filter

  /// The native `.searchable` prompt for each browse mode.
  static func quickFilterPrompt(for mode: Mode) -> String {
    switch mode {
    case .titles: "Filter your library"
    case .authors: "Filter authors"
    case .series: "Filter series"
    case .collections: "Filter collections"
    }
  }

  /// The A-Z rail's visibility.
  static func sectionIndexVisibility(isQueryEffective: Bool) -> Visibility {
    isQueryEffective ? .hidden : .visible
  }

  nonisolated enum RowsPresentation: Equatable {
    /// Ordinary rows.
    case rows
    /// The structured-funnel empty state, with `Clear Filters`.
    case filteredEmpty
    /// A loaded, non-empty source that an effective query narrowed to nothing.
    case queryEmpty(query: String, offersClearFilters: Bool)
    /// A loading/empty/error state that `modeOverlay` owns; the list body renders nothing.
    case none
  }

  static func titlesRowsPresentation(
    state: LibraryBrowseModel.State,
    filters: BrowseFilters,
    query: String,
    matchCount: Int
  ) -> RowsPresentation {
    switch state {
    case .loading, .empty, .error:
      // The overlay owns these states, so a query cannot relabel a failed or empty source as a
      // result of the query.
      return .none
    case .filteredEmpty:
      return .filteredEmpty
    case .loaded, .partiallySynced, .staleOffline:
      guard LibraryQuickFilter.isEffective(query), matchCount == 0 else { return .rows }
      return .queryEmpty(query: query, offersClearFilters: filters.isActive)
    }
  }

  static func entityRowsPresentation(
    state: AuthorSeriesBrowseModel.State,
    filters: BrowseFilters,
    hasMore: Bool,
    query: String,
    matchCount: Int
  ) -> RowsPresentation {
    switch state {
    case .loading, .empty, .error:
      // The overlay owns these states, so a query cannot relabel a failed or empty source as a
      // result of the query.
      return .none
    case .filteredEmpty:
      return .filteredEmpty
    case .loaded:
      // An unexhausted source may still produce a match; its loader row must keep paging instead
      // of claiming that the current page proves there are no results.
      guard hasMore == false else { return .rows }
      guard LibraryQuickFilter.isEffective(query), matchCount == 0 else { return .rows }
      return .queryEmpty(query: query, offersClearFilters: filters.isActive)
    }
  }

  /// `No Results for "Psy"`: the reader's own text, not the folded form.
  static func queryEmptyTitle(query: String) -> String {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return "No Results for “\(trimmedQuery)”"
  }

  static let queryEmptyMessage: String = "Try another search."
  static let queryEmptySymbol: String = "magnifyingglass"
}
