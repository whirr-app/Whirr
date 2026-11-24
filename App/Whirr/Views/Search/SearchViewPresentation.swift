import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

/// Pure presentation logic for the results screen, split out of `SearchView.swift` so it is
/// testable without rendering SwiftUI. Every function is total and reads no state of its own.
struct SearchViewPresentation {
  /// The search field is bottom-anchored (`role: .search`), so a raised keyboard covers the tail
  /// of the list and the last rows are unreachable unless scrolling dismisses it. Results use
  /// `.immediately` because the default `.automatic` does not dismiss here. The idle list uses
  /// `.interactively`, which is drag-driven only, so a mount cannot fire it.
  static let resultsScrollDismissal: ScrollDismissesKeyboardMode = .immediately
  static let idleScrollDismissal: ScrollDismissesKeyboardMode = .interactively
  /// A recents row's `Button` label is a leading-aligned `Label`, and `.buttonStyle(.plain)` hits
  /// only the label's own bounds, so without this the dead space to its right swallows taps.
  static let recentRowFillsRow = true
  /// Search is a browse root beside Home and Podcasts, so it shares their page margin: the base
  /// inset on every full-screen iPad, centring only in a window wider than the browse page.
  static func pageInset(
    availableWidth: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?
  ) -> CGFloat {
    HomePodcastsBrowseLayout.pageInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }
  /// Every navigating row tap resigns the search field first, or the keyboard stays up over the
  /// pushed screen (or leaves a keyboard-height gap when `LibraryShellView.select` delays push).
  static let resignsFocusBeforeNavigating = true

  /// The focus write and the push must be two transactions, not one.
  ///
  /// `searchIsFocused = false` applies at the end of the current update, and a destination pushed
  /// in that update removes the search field first, leaving the keyboard up. Item taps already
  /// push a turn later (`LibraryShellPresentation.selectionNavigationScheduling`,
  /// `.afterCurrentTransaction`); author and series taps are synchronous. So `navigatingAway`
  /// yields once and every callback goes through it, including presenting ones.
  static let navigationWaitsForFocusResignation = true

  /// Whether a change to the search field's text is news to the model, or the field catching up
  /// to a query the model set itself (`selectRecent`, or `showSearch` from another tab). Echoing
  /// it back through `updateQuery` would cancel the undebounced search those paths just started
  /// and restart it behind the 300 ms debounce. `.onChange(of:)` fires identically for a
  /// keystroke and a programmatic mirror, so comparing against the model is the only test.
  static func shouldPushFieldTextToModel(fieldText: String, modelQuery: String) -> Bool {
    fieldText != modelQuery
  }
  static let idlePrompt = "Search your library"
  static let idleSystemImage = "magnifyingglass"
  static let idleWatermarkPointSize: CGFloat = 220
  static let idleWatermarkOpacity = 0.08
  /// The `.emptyUnreachable` state: the fan-out failed and nothing local matched. Distinct from
  /// `resultsBanner(for:)`'s unreachable line, which says "showing what's on this device" and is
  /// false on a screen with no rows.
  static let serverUnreachableTitle = "Can’t Reach the Server"
  static let serverUnreachableMessage =
    "Nothing on this device matches, and the server couldn’t be reached to search the rest."

  /// What, if anything, to say above the rows about their being incomplete. Nothing is said until
  /// the fan-out has settled, and then only if something is missing, in words matching what went
  /// wrong. The local-first phase of every search is incomplete, so it must not caveat.
  static func resultsBanner(for completeness: SearchModel.ResultsCompleteness) -> String? {
    switch completeness {
    case .awaitingServer, .complete:
      // Still fetching, or nothing missing. The search field shows its own activity.
      return nil
    case .partial:
      // No count: "2 of your libraries" invites the question of which, which this screen cannot
      // answer. What the reader can act on is that the list may be short.
      return "Some libraries didn’t respond, so results may be incomplete."
    case .unreachable:
      return "Showing what’s on this device — the server couldn’t be reached."
    }
  }
  /// The `.closeMatches` caption: the only marker that these rows are approximate, so it always
  /// renders. A completeness caveat that also applies follows it in the same card, since a
  /// close-match set found while libraries failed has to say both.
  static func closeMatchesBanner(
    query: String, completeness: SearchModel.ResultsCompleteness
  ) -> String {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let line = "No exact matches for “\(trimmedQuery)” — showing close matches."
    guard let caveat = resultsBanner(for: completeness) else { return line }
    return "\(line) \(caveat)"
  }
  static let searchingMessage = "Searching…"
  static let unknownAuthor = "Unknown author"
  static let unknownShow = "Unknown show"

  // MARK: - Sections

  /// Preserves the query-dependent order resolved once by `SearchResultAssembly.section` and drops
  /// any section with no rows, so a blank section never renders a header.
  static func orderedSections(_ sections: [SearchSection]) -> [SearchSection] {
    sections.filter { $0.rows.isEmpty == false }
  }

  // MARK: - Row subtitle

  /// The subtitle for a `.book`/`.podcast` row: the match reason when worth showing
  /// (`SearchCopy.matchReasonText` suppresses unknown fields and text that repeats the title),
  /// else the row's author line, else a fallback so the second line is never blank.
  static func itemSubtitle(for row: SearchResultRow) -> String {
    let reasonOrAuthor =
      SearchCopy.matchReasonText(row.matchReason, rowTitle: row.title) ?? row.subtitle
      ?? unknownAuthor
    guard let series = trimmedSeriesName(row) else { return reasonOrAuthor }
    // Series leads: a result set for one author repeats that author on every row, so the series
    // (which carries the sequence, see `SearchResultRow.seriesName`) tells rows apart and must
    // survive truncation of this single line.
    return "\(series)\(subtitleSeparator)\(reasonOrAuthor)"
  }

  private static let subtitleSeparator = " · "

  /// A row's series, or `nil` when absent, blank, or already named by the match reason that
  /// `itemSubtitle` renders anyway.
  private static func trimmedSeriesName(_ row: SearchResultRow) -> String? {
    guard let series = row.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines),
      series.isEmpty == false
    else { return nil }
    guard row.matchReason?.text != series else { return nil }
    return series
  }

  /// The subtitle for an `.author`/`.series` row: the match reason when present, else a plain
  /// label for the entity kind (an author has no author line of its own).
  static func entitySubtitle(for row: SearchResultRow) -> String {
    if let reasonText = SearchCopy.matchReasonText(row.matchReason, rowTitle: row.title) {
      return reasonText
    }
    switch row.kind {
    case .author: return "Author"
    case .series: return "Series"
    case .book, .podcast, .episode: return ""
    }
  }

  /// An episode's show name from a caller-supplied `parentItemID -> title` lookup, so the mapping
  /// stays pure. Never blank: falls back to `unknownShow` until the parent resolves.
  static func episodeShowName(for row: SearchResultRow, showTitles: [String: String]) -> String {
    guard let parentItemID = row.parentItemID, let title = showTitles[parentItemID],
      title.isEmpty == false
    else { return unknownShow }
    return title
  }

  // MARK: - Routing

  /// The push destination for an author/series row. `nil` for item kinds, which route through
  /// `onSelect(ItemSummary)` to item detail or the podcast show.
  static func route(for row: SearchResultRow) -> NavigationModel.Route? {
    switch row.kind {
    case .author:
      return .author(
        id: row.entityID, libraryID: row.libraryID,
        seed: AuthorSeriesDestinationSeed(
          entity: AuthorSeriesEntity(
            kind: .author, entityID: row.entityID, name: row.title, libraryID: row.libraryID)))
    case .series:
      return .series(
        id: row.entityID, libraryID: row.libraryID,
        seed: AuthorSeriesDestinationSeed(
          entity: AuthorSeriesEntity(
            kind: .series, entityID: row.entityID, name: row.title, libraryID: row.libraryID)))
    case .book, .podcast, .episode: return nil
    }
  }

  // MARK: - Media glyph

  private enum RowGlyph: Equatable {
    case badge(MediaKindBadge)
    case symbol(String)
  }

  /// `.book` uses the row's resolved `mediaCategory` (ebook vs audiobook) and falls back to the
  /// audiobook glyph when it is `nil` (a server hit not yet resolved locally). `.episode` gets a
  /// plain symbol distinct from `.podcast`'s badge so an episode and its show never look
  /// identical. `.author`/`.series` are not media and never use `MediaKindBadge`.
  private static func rowGlyph(for row: SearchResultRow) -> RowGlyph {
    switch row.kind {
    case .book:
      let category = row.mediaCategory ?? .audiobook
      return .badge(HomeViewPresentation.badgeKind(for: category))
    case .podcast:
      return .badge(.podcast)
    case .episode:
      return .symbol("waveform")
    case .author:
      return .symbol("person")
    case .series:
      return .symbol("square.stack")
    }
  }

  /// The SF Symbol name for a row's leading glyph. The view and the tests both read it, so what
  /// is pinned is what renders.
  static func symbolName(for row: SearchResultRow) -> String {
    switch rowGlyph(for: row) {
    case .badge(let badge): return badge.symbolName
    case .symbol(let name): return name
    }
  }

  /// The `MediaKindBadge`/label pair for rows rendered through `MediaKindBadgeView` (`.book` and
  /// `.podcast`, as in library rows). `nil` for `.episode` (plain symbol) and `.author`/`.series`.
  static func mediaBadge(for row: SearchResultRow) -> (kind: MediaKindBadge, label: String)? {
    let category: ItemMediaCategory
    switch row.kind {
    case .book: category = row.mediaCategory ?? .audiobook
    case .podcast: category = .podcast
    case .episode, .author, .series: return nil
    }
    return (HomeViewPresentation.badgeKind(for: category), HomeRowPresentation.badgeLabel(for: category))
  }

  // MARK: - Artwork prefetch (flattened across sections)

  /// The item id a row's cover art is keyed by, or `nil` for `.author`/`.series`. Episodes borrow
  /// their show's cover, so they resolve through `parentItemID`, not `entityID` (the episode id).
  nonisolated static func coverItemID(for row: SearchResultRow) -> String? {
    switch row.kind {
    case .book, .podcast: return row.entityID
    case .episode: return row.parentItemID ?? row.entityID
    case .author, .series: return nil
    }
  }

  /// The prefetcher's `orderedIDs`, flattened across every section in display order. Indexing per
  /// section would break `DirectionalArtworkPrefetcher`'s ahead/behind window after the first.
  static func flattenedCoverItemIDs(_ sections: [SearchSection]) -> [String] {
    sections.flatMap(\.rows).compactMap(coverItemID(for:))
  }

  /// The revision each cover ID in `flattenedCoverItemIDs` is keyed by. First occurrence wins: a
  /// show and its episodes share one cover ID, and every one of them carries the show's revision.
  static func coverRevisionsByID(_ sections: [SearchSection]) -> [String: ArtworkRevision] {
    Dictionary(
      sections.flatMap(\.rows).compactMap { row in
        coverItemID(for: row).map { ($0, row.artworkRevision) }
      },
      uniquingKeysWith: { first, _ in first })
  }

  /// Maps each cover-bearing row's stable `id` (kind-prefixed, unique) to its position in
  /// `flattenedCoverItemIDs`, avoiding an O(n) scan inside the row body.
  static func coverIndexByRowID(_ sections: [SearchSection]) -> [String: Int] {
    var result: [String: Int] = [:]
    var index = 0
    for row in sections.flatMap(\.rows) {
      guard coverItemID(for: row) != nil else { continue }
      result[row.id] = index
      index += 1
    }
    return result
  }

  /// The distinct show item ids the `.episode` rows belong to, in first-seen order. `SearchView`
  /// resolves show titles for them via `LibraryReading.observeItems(ids:)`.
  static func episodeParentItemIDs(_ sections: [SearchSection]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for row in sections.flatMap(\.rows) where row.kind == .episode {
      guard let parentItemID = row.parentItemID, seen.insert(parentItemID).inserted else { continue }
      result.append(parentItemID)
    }
    return result
  }

  // MARK: - Selection

  /// Builds the `ItemSummary` that `onSelect(ItemSummary)` (item detail / podcast show) expects.
  /// `nil` for `.author`/`.series`, which route through `route(for:)`. For `.episode` this is only
  /// the fallback when `episodeRef(for:)` can't build a ref; the primary path opens the episode
  /// card. Carries the row's `serverUpdatedAt`: selection keys the detail palette by cover
  /// revision, and without it the key misses the saved palette and cached thumbnail.
  static func itemSummary(for row: SearchResultRow) -> ItemSummary? {
    switch row.kind {
    case .book:
      return ItemSummary(
        serverItemId: row.entityID, mediaKind: "book", title: row.title, author: row.subtitle,
        durationSeconds: nil, category: row.mediaCategory ?? .audiobook, hasReadableEbook: row.hasReadableEbook,
        serverUpdatedAt: row.serverUpdatedAt)
    case .podcast:
      return ItemSummary(
        serverItemId: row.entityID, mediaKind: "podcast", title: row.title, author: row.subtitle,
        durationSeconds: nil, category: .podcast, hasReadableEbook: row.hasReadableEbook,
        serverUpdatedAt: row.serverUpdatedAt)
    case .episode:
      guard let parentItemID = row.parentItemID else { return nil }
      return ItemSummary(
        serverItemId: parentItemID, mediaKind: "podcast", title: row.title, author: row.subtitle,
        durationSeconds: nil, category: .podcast, hasReadableEbook: row.hasReadableEbook,
        serverUpdatedAt: row.serverUpdatedAt)
    case .author, .series:
      return nil
    }
  }

  /// The `itemContextMenu` identity tuple for an item-kind row. Episodes key the menu by their
  /// show's item id plus their own episode id, since playback and downloads are keyed by that
  /// pair (as in `PodcastShowView`).
  static func contextMenu(for row: SearchResultRow) -> (
    itemID: String, episodeID: String?, category: ItemMediaCategory, hasReadableEbook: Bool
  )? {
    switch row.kind {
    case .book:
      return (row.entityID, nil, row.mediaCategory ?? .audiobook, row.hasReadableEbook)
    case .podcast:
      return (row.entityID, nil, .podcast, false)
    case .episode:
      guard let parentItemID = row.parentItemID else { return nil }
      return (parentItemID, row.entityID, .podcast, false)
    case .author, .series:
      return nil
    }
  }

  /// The episode a `.episode` row's tap should open, from the show (`parentItemID`) and episode
  /// id (`entityID`) pairing that `contextMenu(for:)` also uses. `nil` for other kinds and for an
  /// episode row missing either (a missing `parentItemID`, or an empty `entityID` from a
  /// still-settling index), where `SearchResultsList` falls back to `itemSummary(for:)`.
  nonisolated static func episodeRef(for row: SearchResultRow)
    -> NavigationModel.PodcastEpisodeRef?
  {
    guard row.kind == .episode else { return nil }
    guard let parentItemID = row.parentItemID, parentItemID.isEmpty == false,
      row.entityID.isEmpty == false
    else { return nil }
    return NavigationModel.PodcastEpisodeRef(itemID: parentItemID, episodeID: row.entityID)
  }

  // MARK: - Idle screen recents

  /// Whether the idle screen has nothing but the explanatory empty copy, i.e. no recent searches.
  /// `SearchIdleView` renders one or the other, never both.
  static func showsIdleEmptyState(recents: [RecentSearchQuery]) -> Bool {
    recents.isEmpty
  }

  /// The clear-all control is rendered only when there are recents to clear, so the screen never
  /// shows a non-interactive control.
  static func showsClearRecents(recents: [RecentSearchQuery]) -> Bool {
    recents.isEmpty == false
  }

  // MARK: - Per-section load-more

  /// Whether a section's load-more control renders: only when the section reports more rows.
  /// `.author`/`.series` sections never do, since `SearchModel.loadMore` no-ops for them.
  static func showsLoadMore(for section: SearchSection) -> Bool {
    section.hasMore
  }

  /// Whether a section's load-more control shows its in-progress state. `loadingSections` is
  /// `SearchView`'s own in-flight tracking, since `SearchModel.loadMore` exposes no loading flag.
  static func isLoadingMore(section: SearchResultKind, loadingSections: Set<SearchResultKind>) -> Bool {
    loadingSections.contains(section)
  }
}
