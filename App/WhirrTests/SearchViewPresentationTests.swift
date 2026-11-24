import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// Covers the search screen's presentation policies and text synchronization.
@Suite("Search view presentation")
struct SearchViewPresentationTests {

  @Test("the results list dismisses the keyboard immediately")
  func resultsListDismissesKeyboardImmediately() {
    #expect(SearchViewPresentation.resultsScrollDismissal == .immediately)
  }

  @Test("the idle list dismisses the keyboard interactively")
  func idleListDismissesKeyboardInteractively() {
    #expect(SearchViewPresentation.idleScrollDismissal == .interactively)
  }

  @Test("a recent-search row is tappable across its whole width")
  func recentRowFillsItsRow() {
    #expect(SearchViewPresentation.recentRowFillsRow)
  }

  @Test("a recent-search row exposes clear through a context menu as well as a swipe")
  func recentRowClearActionHasContextMenuAlternative() {
    #expect(SearchViewPresentation.clearRecentAction.title == SearchCopy.clearRecentsButtonTitle)
    #expect(SearchViewPresentation.clearRecentAction.role == .destructive)
  }

  @Test("a field edit the model has not seen is pushed to the model")
  func fieldEditIsPushedToTheModel() {
    #expect(SearchViewPresentation.shouldPushFieldTextToModel(fieldText: "din", modelQuery: ""))
    #expect(SearchViewPresentation.shouldPushFieldTextToModel(fieldText: "", modelQuery: "din"))
  }

  @Test("a field edit that only echoes the model's own query is not pushed back")
  func echoedFieldEditIsNotPushedToTheModel() {
    // `selectRecent` sets `query` and starts an undebounced search, then the field mirrors that
    // text. Re-entering `updateQuery` would cancel that search and restart it behind the 300 ms
    // debounce, adding a delay a keystroke does not have.
    #expect(
      SearchViewPresentation.shouldPushFieldTextToModel(
        fieldText: "dinniman", modelQuery: "dinniman") == false)
  }

  // MARK: - Page margin

  @Test("Search keeps the base margin until the window outgrows the browse page")
  func searchPageInsetCentresOnlyBeyondTheBrowsePage() {
    let base = WhirrSpacing.medium
    let pageWidth = HomePodcastsBrowseLayout.pageMaxWidth
    func inset(_ width: CGFloat, _ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
      SearchViewPresentation.pageInset(availableWidth: width, horizontalSizeClass: sizeClass)
    }
    #expect(inset(393, .compact) == base)
    #expect(inset(2000, .compact) == base)
    #expect(inset(2000, nil) == base)
    // Every full-screen iPad runs edge to edge, as Home and the Podcasts root do.
    for width in [CGFloat(744), 1032, 1376, pageWidth + 2 * base] {
      #expect(inset(width, .regular) == base)
    }
    #expect(inset(pageWidth + 2 * base + 200, .regular) == base + 100)
  }

  @Test("Search uses the Home and Podcasts browse margin, not a rule of its own")
  func searchPageInsetMatchesTheBrowseRoots() {
    for width in stride(from: CGFloat(0), through: 3000, by: 125) {
      for sizeClass in [UserInterfaceSizeClass.compact, .regular, nil] {
        #expect(
          SearchViewPresentation.pageInset(availableWidth: width, horizontalSizeClass: sizeClass)
            == HomePodcastsBrowseLayout.pageInset(
              availableWidth: width, horizontalSizeClass: sizeClass))
      }
    }
  }

  // MARK: - Idle screen recents

  @Test("the idle screen shows its empty state only when there are no recents")
  func idleScreenShowsEmptyStateOnlyWithoutRecents() {
    #expect(SearchViewPresentation.showsIdleEmptyState(recents: []))
    #expect(
      SearchViewPresentation.showsIdleEmptyState(
        recents: [makeRecent(query: "Gaiman")])
        == false)
  }

  @Test("the idle empty state uses one short prompt over a quiet search watermark")
  func idleEmptyStatePresentation() {
    #expect(SearchViewPresentation.idleWatermarkPointSize > 100)
    #expect(SearchViewPresentation.idleWatermarkOpacity < 0.15)
  }

  @Test("the clear-all recents control appears only when recents exist")
  func clearAllRecentsControlOnlyWhenRecentsExist() {
    #expect(SearchViewPresentation.showsClearRecents(recents: []) == false)
    #expect(SearchViewPresentation.showsClearRecents(recents: [makeRecent(query: "Gaiman")]))
  }

  // MARK: - Per-section load-more

  @Test("the load-more control appears only for sections reporting hasMore, and reflects in-progress paging")
  func loadMoreControlReflectsSectionState() {
    let hasMoreSection = SearchSection(
      kind: .book, rows: [makeRow(kind: .book, entityID: "b1", title: "Ocean")], hasMore: true)
    let settledSection = SearchSection(
      kind: .podcast,
      rows: [makeRow(kind: .podcast, entityID: "p1", title: "Show", mediaCategory: .podcast)],
      hasMore: false)

    #expect(SearchViewPresentation.showsLoadMore(for: hasMoreSection))
    #expect(SearchViewPresentation.showsLoadMore(for: settledSection) == false)

    #expect(SearchViewPresentation.isLoadingMore(section: .book, loadingSections: [.book]))
    #expect(SearchViewPresentation.isLoadingMore(section: .book, loadingSections: []) == false)
    #expect(SearchViewPresentation.isLoadingMore(section: .podcast, loadingSections: [.book]) == false)
  }

  // MARK: - Sections

  @Test("empty sections are omitted")
  func sectionOrderOmitsEmptySections() {
    let bookSection = SearchSection(
      kind: .book, rows: [makeRow(kind: .book, entityID: "b1", title: "Ocean")], hasMore: false)
    let episodeSection = SearchSection(
      kind: .episode, rows: [makeRow(kind: .episode, entityID: "e1", title: "Ep")], hasMore: false)
    let emptyAuthorSection = SearchSection(kind: .author, rows: [], hasMore: false)
    let sections = [bookSection, emptyAuthorSection, episodeSection]

    let ordered = SearchViewPresentation.orderedSections(sections)

    #expect(ordered.map(\.kind) == [.book, .episode])
    #expect(ordered.map { SearchCopy.sectionTitle(for: $0.kind) } == ["Books", "Episodes"])
  }

  @Test("the view preserves the promoted order resolved by Core")
  func orderedSectionsPreservesResolvedOrder() {
    let authorSection = SearchSection(
      kind: .author, rows: [makeRow(kind: .author, entityID: "a1", title: "Murakami")],
      hasMore: false)
    let seriesSection = SearchSection(
      kind: .series, rows: [makeRow(kind: .series, entityID: "s1", title: "Murakami")],
      hasMore: false)
    let bookSection = SearchSection(
      kind: .book, rows: [makeRow(kind: .book, entityID: "b1", title: "A Book")], hasMore: false)

    let ordered = SearchViewPresentation.orderedSections(
      [authorSection, seriesSection, bookSection])

    #expect(ordered.map(\.kind) == [.author, .series, .book])
  }

  // MARK: - Subtitle and match reason

  @Test("a row with a match reason renders it; a row without one renders the author")
  func itemSubtitleFallsBackToAuthor() {
    let withReason = makeRow(
      kind: .book, entityID: "b1", title: "Ocean", subtitle: "Neil Gaiman",
      matchReason: SearchMatchReason(field: "narrator", text: "Rob Inglis"))
    #expect(SearchViewPresentation.itemSubtitle(for: withReason) == "Narrator: Rob Inglis")

    let withoutReason = makeRow(
      kind: .book, entityID: "b2", title: "Ocean", subtitle: "Neil Gaiman", matchReason: nil)
    #expect(SearchViewPresentation.itemSubtitle(for: withoutReason) == "Neil Gaiman")

    let withNeither = makeRow(kind: .book, entityID: "b3", title: "Ocean", subtitle: nil, matchReason: nil)
    #expect(SearchViewPresentation.itemSubtitle(for: withNeither).isEmpty == false)
  }

  @Test("a row in a series leads with the series, so it survives truncation")
  func itemSubtitleLeadsWithTheSeries() {
    // Every result for "dinniman" reads "Author: Matt Dinniman"; the series is the only part that
    // tells the rows apart, so it goes first rather than off the end of a truncated line.
    let row = makeRow(
      kind: .book, entityID: "b1", title: "The Gate of the Feral Gods", subtitle: "Matt Dinniman",
      matchReason: SearchMatchReason(field: "author", text: "Matt Dinniman"),
      seriesName: "Dungeon Crawler Carl #6")
    #expect(
      SearchViewPresentation.itemSubtitle(for: row)
        == "Dungeon Crawler Carl #6 · Author: Matt Dinniman")
  }

  @Test("a row with no series is unchanged, with no stray separator")
  func itemSubtitleWithoutSeriesIsUnchanged() {
    let row = makeRow(
      kind: .book, entityID: "b1", title: "Ocean", subtitle: "Neil Gaiman", seriesName: nil)
    #expect(SearchViewPresentation.itemSubtitle(for: row) == "Neil Gaiman")

    // A series stored as empty text is "no series", not a series called "".
    let blank = makeRow(
      kind: .book, entityID: "b2", title: "Ocean", subtitle: "Neil Gaiman", seriesName: "   ")
    #expect(SearchViewPresentation.itemSubtitle(for: blank) == "Neil Gaiman")
  }

  @Test("a series row does not repeat its own title as a series name")
  func seriesMatchDoesNotRepeatItself() {
    // The query matched the series, so the match reason already names it. Printing it twice
    // would read "Dungeon Crawler Carl · Series: Dungeon Crawler Carl".
    let row = makeRow(
      kind: .book, entityID: "b1", title: "The Gate of the Feral Gods", subtitle: "Matt Dinniman",
      matchReason: SearchMatchReason(field: "seriesName", text: "Dungeon Crawler Carl #6"),
      seriesName: "Dungeon Crawler Carl #6")
    #expect(SearchViewPresentation.itemSubtitle(for: row) == "Series: Dungeon Crawler Carl #6")
  }

  // MARK: - The incompleteness annotation

  /// Say nothing until the fan-out has settled and something is genuinely missing. A local-first
  /// result must never show an "offline" notice while the server is answering.
  @Test("no annotation while the fan-out is still in flight, and none when it succeeded")
  func noBannerWhileAwaitingOrComplete() {
    #expect(SearchViewPresentation.resultsBanner(for: .awaitingServer) == nil)
    #expect(SearchViewPresentation.resultsBanner(for: .complete) == nil)
  }

  @Test("a settled incompleteness is annotated, and says which kind it is")
  func settledIncompletenessIsAnnotated() {
    let partial = SearchViewPresentation.resultsBanner(for: .partial(failedLibraries: 1))
    let unreachable = SearchViewPresentation.resultsBanner(for: .unreachable)

    #expect(partial?.isEmpty == false)
    #expect(unreachable?.isEmpty == false)
    // The causes differ: a library that 404s is not the device being offline, so the copy
    // must differ too.
    #expect(partial != unreachable)
  }

  /// The count stays out of the copy: "2 of your libraries" invites "which two?", which this
  /// screen cannot answer.
  @Test("the partial annotation reads the same however many libraries failed")
  func partialAnnotationDoesNotCountLibraries() {
    let one = SearchViewPresentation.resultsBanner(for: .partial(failedLibraries: 1))
    #expect(one == SearchViewPresentation.resultsBanner(for: .partial(failedLibraries: 7)))
  }

  // MARK: - Close matches

  @Test("a complete close-match set is captioned as approximate, naming the query")
  func closeMatchesBannerNamesTheQuery() {
    #expect(
      SearchViewPresentation.closeMatchesBanner(query: " gaimn ", completeness: .complete)
        == "No exact matches for “gaimn” — showing close matches.")
    #expect(
      SearchViewPresentation.closeMatchesBanner(query: "gaimn", completeness: .awaitingServer)
        == "No exact matches for “gaimn” — showing close matches.")
  }

  /// The close-match caption and a completeness caveat can both be true. Neither may replace
  /// the other, or a set found offline would read as the best of everything.
  @Test("an incomplete close-match set says both things, close match first")
  func closeMatchesBannerComposesCompleteness() {
    let closeMatchLine = "No exact matches for “gaimn” — showing close matches."
    for completeness in [
      SearchModel.ResultsCompleteness.partial(failedLibraries: 2), .unreachable,
    ] {
      let caveat = SearchViewPresentation.resultsBanner(for: completeness)
      #expect(caveat != nil)
      #expect(
        SearchViewPresentation.closeMatchesBanner(query: "gaimn", completeness: completeness)
          == "\(closeMatchLine) \(caveat ?? "")")
    }
  }

  // MARK: - Entity routes

  @Test("an author row and a series row produce entity routes, not item-detail routes")
  func authorAndSeriesRowsProduceEntityRoutes() {
    let authorRow = makeRow(kind: .author, entityID: "a1", title: "Neil Gaiman")
    let seriesRow = makeRow(kind: .series, entityID: "s1", title: "Discworld")

    #expect(SearchViewPresentation.route(for: authorRow) == .author(id: "a1", libraryID: "lib"))
    #expect(SearchViewPresentation.route(for: seriesRow) == .series(id: "s1", libraryID: "lib"))
    #expect(SearchViewPresentation.route(for: authorRow) != .itemDetail(itemID: "a1"))
    #expect(SearchViewPresentation.route(for: seriesRow) != .itemDetail(itemID: "s1"))

    let bookRow = makeRow(kind: .book, entityID: "b1", title: "Ocean")
    #expect(SearchViewPresentation.route(for: bookRow) == nil)
  }

  // MARK: - Episodes show their show, and read differently from a show row

  @Test("episode rows show their show's name and are visually distinguishable from show rows")
  func episodeRowsShowTheirShow() {
    let episodeRow = makeRow(
      kind: .episode, entityID: "ep1", parentItemID: "show1", title: "Episode Title")
    #expect(
      SearchViewPresentation.episodeShowName(for: episodeRow, showTitles: ["show1": "The Daily"])
        == "The Daily")
    // No resolved title yet (server has not answered, or show not known locally). Never blank.
    #expect(SearchViewPresentation.episodeShowName(for: episodeRow, showTitles: [:]).isEmpty == false)

    let showRow = makeRow(kind: .podcast, entityID: "show1", title: "The Daily", mediaCategory: .podcast)
    #expect(SearchViewPresentation.symbolName(for: episodeRow) != SearchViewPresentation.symbolName(for: showRow))
  }

  // MARK: - Prefetcher indices are global, not per-section

  @Test("the artwork prefetcher's ordered ids span every section, not just one")
  func flattenedCoverItemIDsSpanAllSections() {
    let bookRow1 = makeRow(kind: .book, entityID: "b1", title: "One")
    let bookRow2 = makeRow(kind: .book, entityID: "b2", title: "Two")
    let podcastRow = makeRow(kind: .podcast, entityID: "p1", title: "Show", mediaCategory: .podcast)
    let authorRow = makeRow(kind: .author, entityID: "a1", title: "Author")
    let sections = [
      SearchSection(kind: .book, rows: [bookRow1, bookRow2], hasMore: false),
      SearchSection(kind: .podcast, rows: [podcastRow], hasMore: false),
      SearchSection(kind: .author, rows: [authorRow], hasMore: false),
    ]

    let coverIDs = SearchViewPresentation.flattenedCoverItemIDs(sections)

    // Continuous across the book and podcast sections; the author row (no artwork) is skipped
    // rather than resetting the index back to zero for the next section.
    #expect(coverIDs == ["b1", "b2", "p1"])
  }

  // MARK: - Item-row media glyph, driven by `mediaCategory`

  @Test("an ebook row exposes the ebook symbol")
  func ebookRowExposesEbookSymbol() {
    let row = makeRow(kind: .book, entityID: "b1", title: "Ocean", mediaCategory: .ebook)
    #expect(SearchViewPresentation.symbolName(for: row) == MediaKindBadge.ebook.symbolName)
  }

  @Test("a nil-category book row falls back to the audiobook glyph")
  func nilCategoryBookRowFallsBackToAudiobookGlyph() {
    let row = makeRow(kind: .book, entityID: "b1", title: "Ocean", mediaCategory: nil)
    #expect(SearchViewPresentation.symbolName(for: row) == MediaKindBadge.audiobook.symbolName)
  }

  @Test("a podcast row exposes the podcast symbol")
  func podcastRowExposesPodcastSymbol() {
    let row = makeRow(kind: .podcast, entityID: "p1", title: "Show", mediaCategory: .podcast)
    #expect(SearchViewPresentation.symbolName(for: row) == MediaKindBadge.podcast.symbolName)
  }

  /// An episode found by search must offer what an episode found anywhere else offers. Search
  /// reaches the menu through the same `.itemContextMenu` as every other list, so this pins the
  /// identity triple it hands over. An episode keyed by its own id alone, or with the wrong
  /// category, would silently fall back to a book's menu.
  @Test func episodeResultMenuMatchesCanonicalList() {
    let episode = makeRow(
      kind: .episode, entityID: "ep-1", parentItemID: "show-1", title: "Episode One")
    let menu = SearchViewPresentation.contextMenu(for: episode)

    #expect(menu?.itemID == "show-1", "playback and downloads are keyed by show + episode")
    #expect(menu?.episodeID == "ep-1")
    #expect(menu?.category == .podcast)
    #expect(
      ItemMediaCapability.derive(
        category: menu!.category, hasReadableEbook: menu!.hasReadableEbook) == .podcast)

    // `.episodeList` is the default surface and the one a search hit belongs to. It spans shows,
    // so nothing is suppressed except the placement-gated server pair, which belongs only to the
    // show screen and the episode card.
    #expect(
      ItemContextMenuPresentation.podcastEpisodeEntries(
        downloadAction: .download, surface: .episodeList, queueAvailability: .both)
        == PodcastShowPresentation.episodeActions(
          status: .notDownloaded, isAvailableOnServer: true, surface: .episodeList))
    #expect(
      PodcastShowPresentation.suppressedActions(on: .episodeList)
        == [.saveToServer, .removeFromServer])
  }

  /// A show hit raises the show menu, not an episode one. `contextMenu(for:)` distinguishes
  /// `.podcast` from `.episode` to get this right.
  @Test func showResultRaisesTheShowMenuNotAnEpisodeMenu() {
    let show = makeRow(kind: .podcast, entityID: "show-1", title: "A Show")
    let menu = SearchViewPresentation.contextMenu(for: show)

    // A nil `episodeID` on a `.podcast` capability routes the menu to the show pair, not the
    // episode sections.
    #expect(menu?.episodeID == nil)
    #expect(
      ItemMediaCapability.derive(
        category: menu!.category, hasReadableEbook: menu!.hasReadableEbook) == .podcast)
  }

  // MARK: - Episode results open the card, falling back to the show push

  @Test func episodeResultResolvesToTheEpisodeCard() {
    let row = makeRow(kind: .episode, entityID: "ep-1", parentItemID: "show-1", title: "Episode One")
    let ref = SearchViewPresentation.episodeRef(for: row)
    #expect(ref?.itemID == "show-1")
    #expect(ref?.episodeID == "ep-1")
  }

  @Test func nonEpisodeRowsNeverResolveToAnEpisodeRef() {
    let show = makeRow(kind: .podcast, entityID: "show-1", title: "A Show")
    let book = makeRow(kind: .book, entityID: "b1", title: "Ocean")
    #expect(SearchViewPresentation.episodeRef(for: show) == nil)
    #expect(SearchViewPresentation.episodeRef(for: book) == nil)
  }

  /// When an episode row cannot yet identify both its show and itself, `episodeRef(for:)` yields
  /// nothing and the caller falls back to the show push from `itemSummary(for:)`. That push cannot
  /// be represented when the show itself is unknown.
  @Test func searchEpisodeFallsBackToShowWhenUnresolvable() {
    let missingParent = makeRow(kind: .episode, entityID: "ep-1", parentItemID: nil, title: "Ep")
    #expect(SearchViewPresentation.episodeRef(for: missingParent) == nil)
    #expect(SearchViewPresentation.itemSummary(for: missingParent) == nil)

    let emptyEntityID = makeRow(kind: .episode, entityID: "", parentItemID: "show-1", title: "Ep")
    #expect(SearchViewPresentation.episodeRef(for: emptyEntityID) == nil)
    let fallback = SearchViewPresentation.itemSummary(for: emptyEntityID)
    #expect(fallback?.serverItemId == "show-1")
    #expect(fallback?.category == .podcast)
  }

  /// Selection prepares the detail palette under the summary's cover revision. Without the row's
  /// `serverUpdatedAt`, that key matches neither the saved palette nor the cached thumbnail, so
  /// the detail page opens on the neutral fallback.
  @Test(arguments: [SearchResultKind.book, .podcast, .episode])
  func itemSummaryKeepsTheRowsCoverRevision(kind: SearchResultKind) throws {
    let row = makeRow(
      kind: kind, entityID: "e1", parentItemID: "show-1", title: "Ocean",
      serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let summary = try #require(SearchViewPresentation.itemSummary(for: row))
    #expect(summary.artworkRevision == row.artworkRevision)
    #expect(summary.artworkRevision != .unversioned)
  }

  private func makeRecent(query: String) -> RecentSearchQuery {
    RecentSearchQuery(normalizedQuery: query.lowercased(), displayQuery: query, lastUsedAt: .now)
  }

  private func makeRow(
    kind: SearchResultKind,
    entityID: String,
    parentItemID: String? = nil,
    title: String,
    subtitle: String? = nil,
    matchReason: SearchMatchReason? = nil,
    mediaCategory: ItemMediaCategory? = nil,
    seriesName: String? = nil,
    serverUpdatedAt: Date? = nil
  ) -> SearchResultRow {
    SearchResultRow(
      kind: kind, entityID: entityID, parentItemID: parentItemID, title: title, subtitle: subtitle,
      matchReason: matchReason, mediaCategory: mediaCategory, seriesName: seriesName,
      libraryID: "lib", serverUpdatedAt: serverUpdatedAt)
  }
}
