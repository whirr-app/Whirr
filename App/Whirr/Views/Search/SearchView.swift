import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// Library search over `SearchModel`'s sectioned, local-first state. Idle-screen recents are
/// `SearchIdleView` and the sectioned results list is `SearchResultsList`, each in its own file so
/// they are testable without this file's `.searchable` plumbing.
struct SearchView: View {
  @Bindable var model: SearchModel
  let library: any LibraryReading
  let coverClient: any ArtworkServing
  /// Downloaded/offline badges. One screen-wide projection, read synchronously per row, never a
  /// per-row observation.
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  /// One screen-scoped model behind every row's long-press menu.
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let onSelect: (ItemSummary) -> Void
  /// Optional source-aware handoff used by the shell. Keeping `onSelect` preserves the harness
  /// and other App compositions that do not participate in the zoom transition.
  var onSelectWithSource: ((ItemSummary, BookZoomTransitionSource?) -> Void)? = nil
  /// An author/series row's destination, pushed by the caller (`LibraryShellView`) like
  /// `onSelect`, so this view never needs the shared `NavigationModel`.
  let onSelectRoute: (NavigationModel.Route) -> Void
  /// An episode result opens the episode card, falling back to `onSelect`'s show push only when
  /// `SearchResultsList` can't build a ref from the row.
  let onSelectEpisode: (String, String) -> Void
  /// Opens the reader for an ebook row's long-press Read entry. Threaded from `LibraryShellView`
  /// like `onSelect`.
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  /// The field belongs to this screen, the only one that renders search results. `Tab`'s
  /// `role: .search` integrates it with the tab bar; declaring it on the tab container instead
  /// gives every other tab's navigation bar a copy.
  @State private var queryText = ""
  @FocusState private var searchIsFocused: Bool
  @Environment(\.displayScale) private var displayScale
  /// `parentItemID -> show title` for the `.episode` rows on screen, resolved live via
  /// `library.observeItems(ids:)`. Kept here rather than in `SearchModel` because naming a show
  /// against a row is presentation, not search pipeline.
  @State private var episodeShowTitles: [String: String] = [:]
  /// Per-section in-flight tracking for the load-more control, since `SearchModel.loadMore`
  /// exposes no loading flag (see `SearchViewPresentation.isLoadingMore`).
  @State private var loadingSections: Set<SearchResultKind> = []

  var body: some View {
    content
      .navigationTitle("Search")
      .searchable(text: $queryText, prompt: Text(SearchViewPresentation.idlePrompt))
      .searchFocused($searchIsFocused)
      .onSubmit(of: .search) { model.submitSearch() }
      .onChange(of: queryText) { _, newValue in
        guard
          SearchViewPresentation.shouldPushFieldTextToModel(
            fieldText: newValue, modelQuery: model.query)
        else { return }
        model.updateQuery(newValue)
      }
      .onChange(of: model.query) { _, newValue in
        if queryText != newValue { queryText = newValue }
      }
      .onAppear {
        if queryText != model.query { queryText = model.query }
      }
      // One alert for the whole list, not one attached to every row.
      .itemActionErrorAlert(actions)
    // No toolbar here: `LibraryShellView.rootToolbar` supplies the funnel from
    // `rootToolbarTrailingOrder`, the declaration that places the Library's. A `.primaryAction`
    // item declared here beside the shell's `.topBarTrailing` gear reverses the control order.
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .idle:
      SearchIdleView(
        recents: model.recents,
        onSelectRecent: { model.selectRecent($0) },
        onClearRecent: { model.clearRecent($0) },
        onClearRecents: { model.clearRecents() })
    case .queryTooShort:
      LoadingStateView(message: SearchCopy.queryTooShortMessage)
    case .searching:
      LoadingStateView(message: SearchViewPresentation.searchingMessage)
    case .results(let sections, let completeness):
      resultsList(
        sections: sections, banner: SearchViewPresentation.resultsBanner(for: completeness))
    case .closeMatches(let sections, let completeness):
      resultsList(
        sections: sections,
        banner: SearchViewPresentation.closeMatchesBanner(
          query: model.query, completeness: completeness))
    case .empty:
      emptyState
    case .emptyUnreachable:
      EmptyStateView(
        title: SearchViewPresentation.serverUnreachableTitle,
        message: SearchViewPresentation.serverUnreachableMessage,
        systemImage: "magnifyingglass")
    }
  }

  /// The results list for exact and close-match sets alike, so a close-match episode still
  /// resolves its show's name through the `.task` below (else it reads "Unknown show") and every
  /// row tap leaves through `navigatingAway`.
  private func resultsList(sections: [SearchSection], banner: String?) -> some View {
    SearchResultsList(
      sections: sections,
      banner: banner,
      coverClient: coverClient,
      downloadStatus: downloadStatus,
      finishedStatus: finishedStatus,
      actions: actions,
      playback: playback,
      showTitles: episodeShowTitles,
      loadingSections: loadingSections,
      onSelectItem: { item, source in
        // Source is captured at tap time, before the focus-resignation turn. The shell's selection
        // callback owns palette/preflight scheduling.
        navigatingAway {
          if let onSelectWithSource {
            onSelectWithSource(item, source)
          } else {
            onSelect(item)
          }
        }
      },
      onSelectRoute: { route in navigatingAway { onSelectRoute(route) } },
      onSelectEpisode: { itemID, episodeID in
        navigatingAway { onSelectEpisode(itemID, episodeID) }
      },
      onPresentReader: { itemID, title, category in
        navigatingAway { onPresentReader(itemID, title, category) }
      },
      onSearch: onSearch,
      onLoadMore: { section in
        loadingSections.insert(section)
        await model.loadMore(section: section)
        loadingSections.remove(section)
      }
    )
    .task(id: SearchViewPresentation.episodeParentItemIDs(sections)) {
      await resolveEpisodeShowTitles(for: sections)
    }
  }

  /// Offers to clear filters only when one is narrowing the query. The copy is
  /// `LibraryFilterCopy`'s, so both screens name the engaged dimensions the same way.
  @ViewBuilder
  private var emptyState: some View {
    if model.filters.isActive {
      ContentUnavailableView {
        Label(SearchCopy.emptyResultsTitle, systemImage: "magnifyingglass")
      } description: {
        Text(SearchCopy.emptyResultsMessage(for: model.query))
        Text(LibraryFilterCopy.filteredEmptyMessage(for: model.filters))
      } actions: {
        Button(LibraryFilterCopy.clearFiltersLabel) { model.clearFilters() }
          .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
      }
    } else {
      EmptyStateView(
        title: SearchCopy.emptyResultsTitle,
        message: SearchCopy.emptyResultsMessage(for: model.query),
        systemImage: "magnifyingglass")
    }
  }

  /// Puts the search field away, then hands off to the caller's navigation a turn later. See
  /// `SearchViewPresentation.resignsFocusBeforeNavigating` and `navigationWaitsForFocusResignation`
  /// for why. `onSearch` skips this: it re-runs the query on this screen, so the field stays live.
  private func navigatingAway(_ navigate: @escaping () -> Void) {
    guard SearchViewPresentation.resignsFocusBeforeNavigating else {
      navigate()
      return
    }
    searchIsFocused = false
    guard SearchViewPresentation.navigationWaitsForFocusResignation else {
      navigate()
      return
    }
    Task {
      await Task.yield()
      navigate()
    }
  }

  /// One-shot resolve: takes the first emission off `observeItems(ids:)` rather than following the
  /// stream, since a show's title changing while its episode is on screen isn't worth an open
  /// observation.
  private func resolveEpisodeShowTitles(for sections: [SearchSection]) async {
    let parentItemIDs = SearchViewPresentation.episodeParentItemIDs(sections)
    guard parentItemIDs.isEmpty == false else { return }
    for await resolved in library.observeItems(ids: parentItemIDs) {
      guard Task.isCancelled == false else { return }
      episodeShowTitles = Dictionary(
        uniqueKeysWithValues: resolved.map { ($0.serverItemId, $0.title) })
      break
    }
  }
}
