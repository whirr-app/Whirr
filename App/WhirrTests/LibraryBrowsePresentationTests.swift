import AppModel
import DesignSystem
import Persistence
import SwiftUI
import Testing

@testable import Whirr

@Suite("Library browse presentation")
struct LibraryBrowsePresentationTests {

  @Test("browse modes name entities rather than pretending they are title filters")
  func browseModesAreDistinctFromTitleFilters() {
    #expect(
      LibraryBrowsePresentation.Mode.allCases.map(\.label)
        == ["Titles", "Authors", "Series", "Collections"])
    #expect(LibraryBrowsePresentation.Mode.collections.entityKind == nil)
    #expect(LibraryBrowsePresentation.Mode.titles.entityKind == nil)
    #expect(LibraryBrowsePresentation.Mode.authors.entityKind == .author)
    #expect(LibraryBrowsePresentation.Mode.series.entityKind == .series)
  }

  @Test("the shared alphabetizer indexes entity names with the same shelf rules as titles")
  func entitySectionsUseSharedAlphabetization() {
    let entities = [
      AuthorSeriesEntity(
        kind: .series, entityID: "1", name: "The Expanse", libraryID: "library"),
      AuthorSeriesEntity(
        kind: .series, entityID: "2", name: "Wayfarers", libraryID: "library"),
    ]

    let sections = LibraryBrowsePresentation.indexedSections(for: entities, title: \.name)

    #expect(sections.first(where: { $0.id == "E" })?.items.map(\.entityID) == ["1"])
    #expect(sections.first(where: { $0.id == "W" })?.items.map(\.entityID) == ["2"])
  }

  @Test("the alphabet rail and its selection feedback belong to the system list")
  func alphabetIndexUsesNativeListPresentation() {
    #expect(LibraryBrowsePresentation.indexOwner == .systemList)
    #expect(LibraryBrowsePresentation.interactionFeedbackOwner == .systemList)
  }

  @Test("the native index receives every alphabet label while empty sections stay empty")
  func nativeIndexIncludesEmptyAlphabetSections() {
    let sections = LibraryBrowsePresentation.indexedSections(for: [
      Self.item(id: "1", title: "Apple"),
      Self.item(id: "2", title: "Delta"),
    ])

    #expect(sections.map(\.id) == LibraryBrowsePresentation.alphabetIndexTitles)
    #expect(sections.first(where: { $0.id == "A" })?.items.map(\.id) == ["1"])
    #expect(sections.first(where: { $0.id == "B" })?.items.isEmpty == true)
    #expect(sections.first(where: { $0.id == "D" })?.items.map(\.id) == ["2"])
  }

  @Test("titles are grouped under article-ignoring, diacritic-folded alphabet headings")
  func titleSectionsUseShelfAlphabetization() {
    let items = [
      Self.item(id: "1", title: "The Apple"),
      Self.item(id: "2", title: "Écoutez"),
      Self.item(id: "3", title: "1984"),
      Self.item(id: "4", title: "A Bear"),
    ]

    let sections = LibraryBrowsePresentation.sections(for: items)

    #expect(sections.map(\.id) == ["A", "B", "E", "#"])
    #expect(sections.map { $0.items.map(\.id) } == [["1"], ["4"], ["2"], ["3"]])
  }

  @Test("items keep their existing order within an alphabet section")
  func sectionPreservesBrowseOrder() {
    let items = [
      Self.item(id: "1", title: "An Atlas"),
      Self.item(id: "2", title: "Apple"),
      Self.item(id: "3", title: "The Archive"),
    ]

    let sections = LibraryBrowsePresentation.sections(for: items)

    #expect(sections.count == 1)
    #expect(sections[0].items.map(\.id) == ["1", "2", "3"])
  }

  @Test("row playback markers distinguish untouched, in-progress, and finished items")
  func rowPlaybackStatusReflectsPersistedProgress() {
    #expect(
      LibraryBrowsePresentation.rowPlaybackStatus(playbackStatus: nil) == nil)
    #expect(
      LibraryBrowsePresentation.rowPlaybackStatus(playbackStatus: .inProgress) == .inProgress)
    #expect(
      LibraryBrowsePresentation.rowPlaybackStatus(playbackStatus: .finished) == .finished)
    #expect(
      LibraryBrowsePresentation.RowPlaybackStatus.inProgress.systemImage
        == PodcastEpisodePlaybackStatus.inProgress.systemImage)
  }

  @Test("a row's accessibility label names its media kind and playback state")
  func rowAccessibilityLabelIncludesMediaKindAndPlaybackState() {
    let item = Self.item(id: "1", title: "Sea Change")
    let started = Self.item(id: "2", title: "Catching Fire")

    #expect(
      LibraryBrowsePresentation.rowAccessibilityLabel(item: item, playbackStatus: nil)
        == "Sea Change, Unknown author, Audiobook")
    #expect(
      LibraryBrowsePresentation.rowAccessibilityLabel(item: started, playbackStatus: .inProgress)
        == "Catching Fire, Unknown author, Audiobook, In progress")
    #expect(
      LibraryBrowsePresentation.rowAccessibilityLabel(item: item, playbackStatus: .finished)
        == "Sea Change, Unknown author, Audiobook, Finished")
  }

  @Test("each library media kind has the corresponding spoken symbol label")
  func rowAccessibilityLabelDistinguishesMediaKinds() {
    let labels = ItemMediaCategory.allCases.map { category in
      LibraryBrowsePresentation.rowAccessibilityLabel(
        item: Self.item(id: category.rawValue, title: "War and Peace", category: category),
        playbackStatus: nil)
    }

    #expect(
      labels == [
        "War and Peace, Unknown author, Audiobook",
        "War and Peace, Podcast",
        "War and Peace, Unknown author, eBook",
      ])
  }

  /// A show has a creator, not an author, and many feeds name nobody. An unnamed podcast therefore
  /// shows no byline rather than claiming its author is unknown. Books keep the fallback, because
  /// a missing author there is a real gap in the metadata.
  @Test("an unnamed podcast row is quiet where a book row says the author is unknown")
  func podcastRowsAreQuietWithoutACreator() {
    #expect(
      LibraryBrowsePresentation.subtitle(for: Self.item(id: "1", title: "Show", category: .podcast))
        == nil)
    #expect(
      LibraryBrowsePresentation.subtitle(
        for: Self.item(id: "2", title: "Show", category: .podcast, author: "Fixture Broadcasting"))
        == "Fixture Broadcasting")
    #expect(
      LibraryBrowsePresentation.subtitle(for: Self.item(id: "3", title: "Book")) == "Unknown author")
    #expect(
      LibraryBrowsePresentation.subtitle(
        for: Self.item(id: "4", title: "Book", author: "Andy Weir")) == "Andy Weir")
  }

  /// The "still syncing your library" caption sat in the list's layout flow, so each sync start or
  /// finish shoved every row. A burst of short runs made the whole list jump. The fact lives in
  /// the navigation bar, outside that flow.
  @Test("a running sync reports no in-list caption")
  func syncingStateHasNoBanner() {
    let items = [Self.item(id: "1", title: "Apple")]

    #expect(LibraryBrowsePresentation.banner(for: .partiallySynced(items), filters: .unfiltered) == nil)
    #expect(LibraryBrowsePresentation.banner(for: .loaded(items), filters: .unfiltered) == nil)
  }

  @Test("loading and empty use pull-through overlays, while library error keeps Retry reachable")
  func statePlaceholdersKeepRefreshRecoveryReachable() {
    let loading = LibraryBrowsePresentation.placeholder(for: .loading, filters: .unfiltered)
    #expect(loading?.allowsHitTesting == false)
    #expect(loading?.action == nil)

    let empty = LibraryBrowsePresentation.placeholder(for: .empty, filters: .unfiltered)
    #expect(empty?.allowsHitTesting == false)
    #expect(empty?.action == nil)

    let error = LibraryBrowsePresentation.placeholder(for: .error, filters: .unfiltered)
    #expect(error?.allowsHitTesting == true)
    #expect(error?.action == .retry)

    // Filtered-empty is real list content because its Clear Filters button must remain usable.
    #expect(
      LibraryBrowsePresentation.placeholder(
        for: .filteredEmpty, filters: BrowseFilters(downloadedOnly: true)) == nil)
  }

  /// Offline is a settled state, not a flapping one. It says something the rows cannot, and it
  /// stays once shown.
  @Test("the offline state keeps its caption, worded by the model")
  func staleOfflineKeepsItsBanner() {
    let items = [Self.item(id: "1", title: "Apple")]
    let state = LibraryBrowseModel.State.staleOffline(items)

    #expect(LibraryBrowsePresentation.banner(for: state, filters: .unfiltered) == state.copyText(for: .unfiltered))
  }

  // MARK: - The funnel and the filtered-empty state

  /// The funnel has no view state of its own. A second copy of "is a filter on" is how a control
  /// and the list it narrows start disagreeing.
  @Test("the funnel's active state is exactly the model's, with no separate view state")
  func funnelActiveStateMirrorsTheFilters() {
    #expect(LibraryBrowsePresentation.isFilterActive(.unfiltered) == false)
    for filters in [
      BrowseFilters(categories: [.podcast]),
      BrowseFilters(downloadedOnly: true),
      BrowseFilters(playback: .unfinished),
      BrowseFilters(playback: .finished),
      BrowseFilters(categories: [.ebook], downloadedOnly: true, playback: .finished),
    ] {
      #expect(LibraryBrowsePresentation.isFilterActive(filters) == filters.isActive)
      #expect(LibraryBrowsePresentation.isFilterActive(filters))
    }
  }

  /// A persisted filter that matches nothing must read as filtered, never as an empty library, and
  /// must offer a way back.
  @Test("filtered-empty renders different copy from genuinely-empty, and only it offers Clear Filters")
  func filteredEmptyIsDistinctFromGenuinelyEmpty() {
    let filters = BrowseFilters(downloadedOnly: true)

    let filteredTitle = LibraryBrowseModel.State.filteredEmpty.emptyTitle(for: filters)
    let emptyTitle = LibraryBrowseModel.State.empty.emptyTitle(for: filters)
    let filteredMessage = LibraryBrowseModel.State.filteredEmpty.copyText(for: filters)
    let emptyMessage = LibraryBrowseModel.State.empty.copyText(for: filters)

    #expect(filteredTitle != emptyTitle)
    #expect(filteredMessage != emptyMessage)
    #expect(
      LibraryBrowsePresentation.emptyStateSymbol(for: .filteredEmpty, filters: filters)
        != LibraryBrowsePresentation.emptyStateSymbol(for: .empty, filters: filters))
    #expect(LibraryBrowseModel.State.filteredEmpty.offersClearFilters)
    for state: LibraryBrowseModel.State in [
      .loading, .empty, .loaded([]), .partiallySynced([]), .error, .staleOffline([]),
    ] {
      #expect(state.offersClearFilters == false)
    }
  }

  /// The filtered-empty symbol is the funnel itself, matching the "this filter matches nothing"
  /// state in `PodcastShowListCopy`. There is no third glyph.
  @Test("the filtered-empty state pictures the funnel, unfilled")
  func filteredEmptyPicturesTheFunnel() {
    #expect(
      LibraryBrowsePresentation.emptyStateSymbol(for: .filteredEmpty, filters: BrowseFilters(playback: .finished))
        == FilterButtonPresentation.emptyStateSymbolName)
  }

  @Test("the banner still says nothing for filtered-empty - its copy is the empty state's own")
  func filteredEmptyHasNoBanner() {
    #expect(LibraryBrowsePresentation.banner(for: .filteredEmpty, filters: BrowseFilters(downloadedOnly: true)) == nil)
  }

  @Test("the menu reset is enabled only when there is something to clear")
  func clearAllFiltersAvailability() {
    #expect(LibraryBrowsePresentation.canClearAllFilters(.unfiltered) == false)
    #expect(LibraryBrowsePresentation.canClearAllFilters(BrowseFilters(downloadedOnly: true)))
    #expect(LibraryBrowsePresentation.canClearAllFilters(BrowseFilters(playback: .finished)))
    #expect(
      LibraryBrowsePresentation.canClearAllFilters(
        BrowseFilters(categories: MediaFilter.podcasts.browseCategories)))
  }

  private static func item(
    id: String, title: String, category: ItemMediaCategory = .audiobook, author: String? = nil
  ) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id,
      mediaKind: category == .podcast ? "podcast" : "book",
      title: title,
      author: author,
      durationSeconds: nil,
      category: category)
  }
}

@Suite("Library quick filter presentation")
struct LibraryQuickFilterPresentationTests {

  @Test("quick-filter prompts name the selected browse mode")
  func promptsNameEachBrowseMode() {
    #expect(
      LibraryBrowsePresentation.quickFilterPrompt(for: .titles) == "Filter your library")
    #expect(LibraryBrowsePresentation.quickFilterPrompt(for: .authors) == "Filter authors")
    #expect(LibraryBrowsePresentation.quickFilterPrompt(for: .series) == "Filter series")
  }

  @Test("the A–Z rail hides only for an effective query")
  func sectionIndexVisibilityFollowsQueryEffectiveness() {
    #expect(
      LibraryBrowsePresentation.sectionIndexVisibility(isQueryEffective: true) == .hidden)
    #expect(
      LibraryBrowsePresentation.sectionIndexVisibility(isQueryEffective: false) == .visible)
  }

  @Test("titles keep loading, empty, and error states in the mode overlay")
  func titleOverlayStatesWinOverQueryEmpty() {
    let states: [LibraryBrowseModel.State] = [.loading, .empty, .error]

    for state in states {
      #expect(
        LibraryBrowsePresentation.titlesRowsPresentation(
          state: state, filters: .unfiltered, query: "Psy", matchCount: 0) == .none)
    }
  }

  @Test("titles keep the structured-funnel empty state ahead of query-empty")
  func titleFilteredEmptyWinsOverQueryEmpty() {
    #expect(
      LibraryBrowsePresentation.titlesRowsPresentation(
        state: .filteredEmpty, filters: BrowseFilters(downloadedOnly: true), query: "Psy",
        matchCount: 0) == .filteredEmpty)
  }

  @Test("titles query-empty offers Clear Filters only for an active funnel")
  func titleQueryEmptyUsesTheFunnelState() {
    let item = Self.item(id: "1", title: "The Expanse")

    #expect(
      LibraryBrowsePresentation.titlesRowsPresentation(
        state: .loaded([item]), filters: .unfiltered, query: "Psy", matchCount: 0)
        == .queryEmpty(query: "Psy", offersClearFilters: false))
    #expect(
      LibraryBrowsePresentation.titlesRowsPresentation(
        state: .loaded([item]), filters: BrowseFilters(downloadedOnly: true), query: "Psy",
        matchCount: 0)
        == .queryEmpty(query: "Psy", offersClearFilters: true))
  }

  @Test("titles render rows for matches and ineffective queries")
  func titleRowsStayVisibleWhenThereIsNoQueryEmptyCondition() {
    let item = Self.item(id: "1", title: "The Expanse")

    #expect(
      LibraryBrowsePresentation.titlesRowsPresentation(
        state: .loaded([item]), filters: .unfiltered, query: "Psy", matchCount: 1) == .rows)
    #expect(
      LibraryBrowsePresentation.titlesRowsPresentation(
        state: .loaded([item]), filters: .unfiltered, query: " \t\n ", matchCount: 0) == .rows)
  }

  @Test("partially synced and stale offline titles use loaded query-empty policy")
  func titleProgressAndOfflineStatesUseLoadedPolicy() {
    let item = Self.item(id: "1", title: "The Expanse")
    let states: [LibraryBrowseModel.State] = [.partiallySynced([item]), .staleOffline([item])]

    for state in states {
      #expect(
        LibraryBrowsePresentation.titlesRowsPresentation(
          state: state, filters: .unfiltered, query: "Psy", matchCount: 0)
          == .queryEmpty(query: "Psy", offersClearFilters: false))
    }
  }

  @Test("a non-exhausted entity source keeps paging instead of showing query-empty")
  func entityHasMoreSuppressesQueryEmptyUntilSourceIsExhausted() {
    #expect(
      LibraryBrowsePresentation.entityRowsPresentation(
        state: .loaded, filters: .unfiltered, hasMore: true, query: "Psy", matchCount: 0)
        == .rows)
    #expect(
      LibraryBrowsePresentation.entityRowsPresentation(
        state: .loaded, filters: .unfiltered, hasMore: false, query: "Psy", matchCount: 0)
        == .queryEmpty(query: "Psy", offersClearFilters: false))
  }

  @Test("entity overlay and structured-funnel states keep their precedence")
  func entityEmptyStatePrecedence() {
    let states: [AuthorSeriesBrowseModel.State] = [.loading, .empty, .error]

    for state in states {
      #expect(
        LibraryBrowsePresentation.entityRowsPresentation(
          state: state, filters: .unfiltered, hasMore: false, query: "Psy", matchCount: 0)
          == .none)
    }
    #expect(
      LibraryBrowsePresentation.entityRowsPresentation(
        state: .filteredEmpty, filters: BrowseFilters(downloadedOnly: true), hasMore: false,
        query: "Psy", matchCount: 0) == .filteredEmpty)
  }

  @Test("query-empty copy preserves the reader's case, diacritics, and inner text")
  func queryEmptyCopyPreservesOriginalQuery() {
    let query = "\n\t ÉLÉON  \n"

    #expect(
      LibraryBrowsePresentation.queryEmptyTitle(query: query) == "No Results for “ÉLÉON”")
  }

  private static func item(
    id: String, title: String, category: ItemMediaCategory = .audiobook, author: String? = nil
  ) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id,
      mediaKind: category == .podcast ? "podcast" : "book",
      title: title,
      author: author,
      durationSeconds: nil,
      category: category)
  }
}
