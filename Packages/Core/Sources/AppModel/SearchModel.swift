import Foundation
import Observation
import Persistence
import SyncEngine

/// Library search, local-first and never blank. A settled query renders local (on-device) rows as
/// soon as they resolve, then merges the server's fan-out result in place once it answers, via
/// `SearchResultAssembly.merge`/`section`. A server failure or an unindexed row never blanks what
/// local already found, it only adds to it. Filters, recents and paging sit on top (see the
/// sections below).
@MainActor
@Observable
public final class SearchModel {
  public enum State: Sendable, Equatable {
    /// Nothing typed, or the field was cleared.
    case idle
    /// Typed, but below `minimumQueryLength`. No request was made.
    case queryTooShort
    /// Debounce elapsed; local search returned nothing yet, so there is nothing to show until
    /// either local or the server answers.
    case searching
    /// Sectioned, deduped rows for a settled query, and why (if at all) they might not be
    /// everything.
    case results(sections: [SearchSection], completeness: ResultsCompleteness)
    /// A completed query (local and server both) matched nothing, and the close-match fallback
    /// found nothing either or did not run because a filter was active.
    case empty
    /// The server fan-out failed before any local row could be shown. Distinct from `.empty` so
    /// the UI does not suggest clearing filters as though the query succeeded.
    case emptyUnreachable
    /// Strict search settled with nothing, but local rows lie within a small edit distance of every
    /// query token. Its own case, never rows inside `.results`, so an approximate row cannot appear
    /// in an exact section. Never paged: every section's `hasMore` is `false`. `completeness` is
    /// the settled fan-out's, so a set found while libraries failed still says so.
    case closeMatches(sections: [SearchSection], completeness: ResultsCompleteness)
  }

  /// Why a result set might not be everything. Two of the four cases need no annotation.
  ///
  /// Separate cases because "server not answered yet", "some libraries failed" and "fan-out never
  /// reached the server" need different copy. Every search passes through `.awaitingServer`, which
  /// must not look like an offline fault.
  public enum ResultsCompleteness: Sendable, Equatable {
    /// The local-first phase: local rows are on screen and the fan-out is still in flight. Not
    /// annotated, since the search field's own activity already says it.
    case awaitingServer
    /// Every library answered. Nothing is missing that the server knows about.
    case complete
    /// The server answered, but `failedLibraries` of them did not. The rows shown are real; some
    /// library's matches are missing from them.
    case partial(failedLibraries: Int)
    /// The fan-out itself failed and no library was reached. Only this is the offline case.
    case unreachable
  }

  public private(set) var state: State = .idle
  public private(set) var query: String = ""

  /// The same filter type and mutators the Library holds (so both mount the identical
  /// `BrowseFilterMenu`), persisted under its own key (`BrowseFilterStorage.Screen.search`).
  /// Unlike `LibraryBrowseModel`, a change re-runs the query undebounced: Search has no standing
  /// projection to re-narrow.
  public private(set) var filters: BrowseFilters
  /// Most-recently-used first, for the idle screen. Kept in sync with
  /// `RecentSearchStoring.observeRecent()` for the lifetime of this model.
  public private(set) var recents: [RecentSearchQuery] = []

  /// Search spans the whole account, never one library. Both the local reader and the server
  /// fan-out take `nil` to mean that, so there is no library id to hold. ABS keeps podcasts in a
  /// library of their own, so holding one would hide every podcast from search.
  private static let allLibraries: [String]? = nil
  private let library: any LibraryReading
  private let searchReading: any SearchReading
  private let sync: any SyncCoordinating
  private let recentSearchStore: any RecentSearchStoring
  private let clock: any SearchClock
  private let defaults: any BrowseFilterDefaults
  private let minimumQueryLength: Int
  /// Forwarded to both the local query and the server fan-out, so local and server pages are
  /// comparably sized.
  private let resultLimit: Int

  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var recentsTask: Task<Void, Never>?
  /// Bumped on every query, filter or `selectRecent` change. A debounced or in-flight attempt
  /// started under an earlier generation checks this before touching `state`, so a stale
  /// response cannot overwrite newer results even if it resumes after the newer one finished.
  private var generation = GenerationFence()
  /// Recent history reflects deliberate submissions, not the live, debounced searches driven by
  /// field edits. These generation markers keep a submit attached to exactly the query the user
  /// submitted, including when the server response is still in flight.
  private var submittedGeneration: GenerationFence.Token?
  private var settledGeneration: GenerationFence.Token?
  private var recordedRecentGeneration: GenerationFence.Token?

  /// The accumulated local pages fetched so far for the current settled query, kept apart from
  /// `state` so `loadMore` can extend them and re-derive sections without re-running the whole
  /// local-then-server pipeline. Reset on every new query or filter.
  private var localItemRows: [SearchResultRow] = []
  private var localEpisodeRows: [SearchResultRow] = []
  /// The most recent server fan-out's resolved rows, kept so `loadMore` (which never touches the
  /// server, since the fan-out has no offset) can re-merge an extended local pool against them.
  private var lastServerRows: [SearchResultRow] = []
  private var lastCompleteness: ResultsCompleteness = .awaitingServer

  /// `.book`/`.podcast` share one paging cursor because `SearchReading.searchItems` ranks and
  /// pages both kinds together in a single call; `.episode` has its own cursor because
  /// `searchEpisodes` is a separate call. `.author`/`.series` have no local paging cursor: they
  /// only come from the single-shot server fan-out, which has no offset, so `loadMore` no-ops
  /// for those kinds.
  private struct LocalPagingState: Sendable, Equatable {
    var offset = 0
    var hasMore = false
    var isLoading = false
  }
  private var itemsPaging = LocalPagingState()
  private var episodesPaging = LocalPagingState()

  public init(
    library: any LibraryReading,
    searchReading: any SearchReading,
    sync: any SyncCoordinating,
    recentSearchStore: any RecentSearchStoring = NoOpRecentSearchStoring(),
    clock: any SearchClock = SystemSearchClock(),
    minimumQueryLength: Int = 2,
    resultLimit: Int = 25,
    defaults: any BrowseFilterDefaults = UserDefaults.standard
  ) {
    self.library = library
    self.searchReading = searchReading
    self.sync = sync
    self.recentSearchStore = recentSearchStore
    self.clock = clock
    self.minimumQueryLength = minimumQueryLength
    self.resultLimit = resultLimit
    self.defaults = defaults
    // The persisted filter is the starting one, as for the Library. Nothing is searched at
    // construction, so the first query the reader types picks it up through `currentFilters`.
    filters = BrowseFilterStorage.load(.search, from: defaults)

    let store = recentSearchStore
    recentsTask = Task { [weak self] in
      for await value in store.observeRecent() {
        guard Task.isCancelled == false else { return }
        guard let self else { return }
        self.applyRecents(value)
      }
    }
  }

  deinit {
    searchTask?.cancel()
    recentsTask?.cancel()
  }

  /// Bound directly to the search field. Cancels whatever debounce or search was in flight for the
  /// previous input, so the model never races itself.
  public func updateQuery(_ newQuery: String) {
    query = newQuery
    searchTask?.cancel()
    let thisGeneration = generation.advance()

    let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      resetLocalSearchState()
      state = .idle
      return
    }
    guard trimmed.count >= minimumQueryLength else {
      resetLocalSearchState()
      state = .queryTooShort
      return
    }

    searchTask = Task { [weak self] in
      guard let self else { return }
      await self.clock.sleep()
      guard Task.isCancelled == false else { return }
      await self.performSearch(query: trimmed, generation: thisGeneration, emitLocalResultsImmediately: true)
    }
  }

  /// Marks the current field value as a deliberate search. Live results still update while the
  /// user types, but only this native search-field submit action makes the eventual non-empty,
  /// settled query eligible for recent history.
  public func submitSearch() {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minimumQueryLength else { return }

    guard let thisGeneration = generation.currentToken else { return }
    submittedGeneration = thisGeneration
    guard settledGeneration == thisGeneration else { return }

    let finalState = state
    Task { [weak self] in
      await self?.recordRecentIfSubmitted(
        finalState, query: trimmed, generation: thisGeneration)
    }
  }

  // MARK: - Filters

  /// Same surface as `LibraryBrowseModel`, so one `BrowseFilterMenu` drives both screens
  /// (`BrowseFiltering`). Every mutator funnels through `applyFilters`, which persists and
  /// re-queries.

  public func isMediaCategorySelected(_ category: ItemMediaCategory) -> Bool {
    filters.categories?.contains(category) ?? false
  }

  /// Additive, like the Library's: selecting Audiobooks and Podcasts asks for both, and
  /// deselecting the last one is the same state as never having selected any.
  public func setMediaCategory(_ category: ItemMediaCategory, isOn: Bool) {
    var categories = filters.categories ?? []
    if isOn {
      categories.insert(category)
    } else {
      categories.remove(category)
    }
    applyFilters(
      BrowseFilters(
        categories: categories, downloadedOnly: filters.downloadedOnly, playback: filters.playback))
  }

  public func updateDownloadedOnly(_ downloadedOnly: Bool) {
    applyFilters(
      BrowseFilters(
        categories: filters.categories, downloadedOnly: downloadedOnly, playback: filters.playback))
  }

  public func updatePlayback(_ playback: PlaybackFilter) {
    applyFilters(
      BrowseFilters(
        categories: filters.categories, downloadedOnly: filters.downloadedOnly, playback: playback))
  }

  public func clearFilters() {
    applyFilters(.unfiltered)
  }

  /// Persists before re-querying, so the value that survives a crash is the one the screen is
  /// about to show. `LibraryBrowseModel.filters`'s `didSet` uses the same ordering.
  private func applyFilters(_ newFilters: BrowseFilters) {
    guard newFilters != filters else { return }
    filters = newFilters
    BrowseFilterStorage.save(newFilters, for: .search, to: defaults)
    rerunCurrentQuery()
  }

  // MARK: - Recents

  /// Repopulates the field with a previously-recorded query and re-runs the search immediately,
  /// like a filter change. No debounce, since selecting a recent is a discrete action.
  public func selectRecent(_ recent: RecentSearchQuery) {
    query = recent.displayQuery
    rerunCurrentQuery()
  }

  /// Removes one recorded recent. The visible list updates through the `observeRecent()`
  /// subscription that populated it, never optimistically, so it cannot disagree with the store.
  public func clearRecent(_ recent: RecentSearchQuery) {
    let store = recentSearchStore
    Task { try? await store.clear(query: recent.displayQuery) }
  }

  /// Empties the recent-search list, with the same observation-driven update as `clearRecent`.
  public func clearRecents() {
    let store = recentSearchStore
    Task { try? await store.clearAll() }
  }

  private func applyRecents(_ value: [RecentSearchQuery]) {
    recents = value
  }

  // MARK: - Paging

  /// Extends the local pool for one section and re-merges it against the last-known server rows.
  /// The server fan-out is never re-issued (`search(libraryIDs:query:limit:)` has no offset).
  /// No-ops when the section has no more rows or a load for it is in flight: the guard and flag
  /// set run before the first `await`, so two concurrent calls cannot both pass.
  public func loadMore(section: SearchResultKind) async {
    // A close-match set is one unpaged page, and the strict cursors describe a different set.
    if case .closeMatches = state { return }
    guard let currentGeneration = generation.currentToken else { return }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedQuery.isEmpty == false else { return }

    switch section {
    case .book, .podcast:
      guard itemsPaging.hasMore, itemsPaging.isLoading == false else { return }
      itemsPaging.isLoading = true
      defer { itemsPaging.isLoading = false }
      guard
        let page = try? await searchReading.searchItems(
          query: trimmedQuery, libraryIDs: Self.allLibraries, filters: currentFilters,
          limit: resultLimit, offset: itemsPaging.offset)
      else { return }
      guard generation.isCurrent(currentGeneration) else { return }
      localItemRows.append(contentsOf: page.rows)
      itemsPaging.offset += page.rows.count
      itemsPaging.hasMore = page.hasMore
      refreshMergedState()

    case .episode:
      guard episodesPaging.hasMore, episodesPaging.isLoading == false else { return }
      episodesPaging.isLoading = true
      defer { episodesPaging.isLoading = false }
      guard
        let page = try? await searchReading.searchEpisodes(
          query: trimmedQuery, libraryIDs: Self.allLibraries, filters: currentFilters,
          limit: resultLimit, offset: episodesPaging.offset)
      else { return }
      guard generation.isCurrent(currentGeneration) else { return }
      localEpisodeRows.append(contentsOf: page.rows)
      episodesPaging.offset += page.rows.count
      episodesPaging.hasMore = page.hasMore
      refreshMergedState()

    case .author, .series:
      // No local paging cursor exists for these kinds (see `LocalPagingState`).
      return
    }
  }

  // MARK: - Search pipeline

  /// Local-emit-then-server-merge: local rows render first, the server's fan-out result merges in
  /// place once it answers, and a generation check gates every write to `state` so a superseded
  /// query cannot overwrite what a newer one settled.
  private func performSearch(
    query: String, generation: GenerationFence.Token, emitLocalResultsImmediately: Bool
  ) async {
    guard self.generation.isCurrent(generation) else { return }

    let filters = currentFilters
    async let itemsPageResult = try? await searchReading.searchItems(
      query: query, libraryIDs: Self.allLibraries, filters: filters, limit: resultLimit, offset: 0)
    async let episodesPageResult = try? await searchReading.searchEpisodes(
      query: query, libraryIDs: Self.allLibraries, filters: filters, limit: resultLimit, offset: 0)
    let itemsPage = await itemsPageResult
    let episodesPage = await episodesPageResult
    guard self.generation.isCurrent(generation) else { return }

    localItemRows = itemsPage?.rows ?? []
    localEpisodeRows = episodesPage?.rows ?? []
    itemsPaging = LocalPagingState(
      offset: localItemRows.count, hasMore: itemsPage?.hasMore ?? false, isLoading: false)
    episodesPaging = LocalPagingState(
      offset: localEpisodeRows.count, hasMore: episodesPage?.hasMore ?? false, isLoading: false)
    lastServerRows = []
    lastCompleteness = .awaitingServer

    let localRows = localItemRows + localEpisodeRows
    let visibleLocalRows = visibleRows(for: localRows)
    if emitLocalResultsImmediately {
      state =
        visibleLocalRows.isEmpty
        ? .searching
        : sectionedState(for: visibleLocalRows, query: query, completeness: .awaitingServer)
    }

    do {
      let fanOut = try await sync.search(libraryIDs: Self.allLibraries, query: query, limit: resultLimit)
      guard self.generation.isCurrent(generation) else { return }
      let serverRows = await resolveServerRows(fanOut.matches)
      guard self.generation.isCurrent(generation) else { return }
      lastServerRows = serverRows
      // Real incompleteness is decided here. `failures` is per-library, so trace which failed.
      SearchTrace.emitFanOutResult(query: query, failures: fanOut.failures)
      lastCompleteness =
        fanOut.failures.isEmpty ? .complete : .partial(failedLibraries: fanOut.failures.count)
      let merged = visibleRows(
        for: SearchResultAssembly.merge(local: localRows, server: serverRows))
      let finalState: State
      if merged.isEmpty {
        // Computed before the single state write, so "No Results" never flashes ahead of the
        // close matches that replace it.
        let fallbackRows = await closeMatchRows(query: query, filters: filters)
        guard self.generation.isCurrent(generation) else { return }
        finalState =
          closeMatchState(for: fallbackRows, query: query, completeness: lastCompleteness)
          ?? .empty
      } else {
        finalState = sectionedState(for: merged, query: query, completeness: lastCompleteness)
      }
      state = finalState
      settledGeneration = generation
      await recordRecentIfSubmitted(finalState, query: query, generation: generation)
    } catch {
      guard self.generation.isCurrent(generation) else { return }
      lastServerRows = []
      lastCompleteness = .unreachable
      SearchTrace.emitFanOutFailure(query: query, error: error)
      let visibleLocalRows = visibleRows(for: localRows)
      let finalState: State
      if visibleLocalRows.isEmpty {
        // Local rows render despite the failure, so local close matches do too.
        let fallbackRows = await closeMatchRows(query: query, filters: filters)
        guard self.generation.isCurrent(generation) else { return }
        finalState =
          closeMatchState(for: fallbackRows, query: query, completeness: .unreachable)
          ?? .emptyUnreachable
      } else {
        finalState = sectionedState(
          for: visibleLocalRows, query: query, completeness: .unreachable)
      }
      state = finalState
      settledGeneration = generation
      await recordRecentIfSubmitted(finalState, query: query, generation: generation)
    }
  }

  /// `SearchMatch` carries no title. For book/podcast/episode kinds it is only a resolved identity
  /// plus why it matched, so rows render from `LibraryReading`'s observed projection. Author and
  /// series hits are never upserted into `item`, so their row renders straight from `matchText`.
  private func resolveServerRows(_ matches: [SearchMatch]) async -> [SearchResultRow] {
    let itemKinds: Set<SearchResultKind> = [.book, .podcast]
    var itemIDs: [String] = []
    var seenItemIDs: Set<String> = []
    for match in matches where itemKinds.contains(match.kind) {
      if seenItemIDs.insert(match.itemId).inserted {
        itemIDs.append(match.itemId)
      }
    }

    // An unfiltered search skips this: every predicate would be the literal `1`, and the
    // remaining soft-delete/inclusion scoping is applied by `observeItems(ids:)` below.
    let admittedIDs: Set<String>
    if itemIDs.isEmpty || currentFilters.isActive == false {
      admittedIDs = Set(itemIDs)
    } else {
      do {
        admittedIDs = try await searchReading.admittedItemIDs(itemIDs, filters: currentFilters)
      } catch {
        // A failed narrowing must not blank server rows, which are additive. Keep every item id
        // and let local resolution remain the final gate.
        admittedIDs = Set(itemIDs)
      }
    }

    var summaries: [String: ItemSummary] = [:]
    if itemIDs.isEmpty == false {
      for await resolved in library.observeItems(ids: itemIDs) {
        summaries = Dictionary(uniqueKeysWithValues: resolved.map { ($0.serverItemId, $0) })
        break
      }
    }

    return matches.compactMap { match in
      switch match.kind {
      case .book, .podcast:
        guard admittedIDs.contains(match.itemId) else { return nil }
        guard let summary = summaries[match.itemId] else { return nil }
        return SearchResultRow(
          kind: match.kind,
          entityID: match.itemId,
          title: summary.title,
          subtitle: summary.author,
          matchReason: match.matchReason,
          mediaCategory: summary.category,
          hasReadableEbook: summary.hasReadableEbook,
          seriesName: summary.seriesName,
          libraryID: match.libraryId,
          serverUpdatedAt: summary.serverUpdatedAt)
      case .episode:
        // `SyncEngine`'s `searchOneLibrary` fan-out cannot produce an episode match, and routing
        // one through the item predicate would exclude it as a podcast rather than judge it.
        return nil
      case .author, .series:
        guard let name = match.matchText, name.isEmpty == false else { return nil }
        return SearchResultRow(
          kind: match.kind,
          entityID: match.itemId,
          title: name,
          matchReason: match.matchReason,
          libraryID: match.libraryId)
      }
    }
  }

  /// What every local query and `loadMore` call is built from. The unfiltered case takes the same
  /// path as every other.
  private var currentFilters: BrowseFilters { filters }

  /// Entity rows have no media category. Asking for a specific media kind promises media results,
  /// so those rows are hidden before the pure assembly step; only a query with no category
  /// narrowing at all exposes them.
  private func visibleRows(for rows: [SearchResultRow]) -> [SearchResultRow] {
    guard let categories = filters.categories, categories.isEmpty == false else { return rows }
    return rows.filter { row in
      let primaryCategory: ItemMediaCategory
      switch row.kind {
      case .author, .series:
        return false
      case .episode, .podcast:
        primaryCategory = .podcast
      case .book:
        primaryCategory = row.mediaCategory ?? .audiobook
      }
      return ItemFilterCategoryPredicate.matches(
        categories,
        primaryCategory: primaryCategory,
        hasReadableEbook: row.hasReadableEbook)
    }
  }

  private func sectionedState(
    for rows: [SearchResultRow], query: String, completeness: ResultsCompleteness
  ) -> State {
    let visibleRows = visibleRows(for: rows)
    let hasMore: [SearchResultKind: Bool] = [
      .book: itemsPaging.hasMore, .podcast: itemsPaging.hasMore, .episode: episodesPaging.hasMore,
      .author: false, .series: false,
    ]
    return .results(
      sections: SearchResultAssembly.section(
        SearchSectionInput(rows: visibleRows, query: query, hasMore: hasMore)),
      completeness: completeness)
  }

  /// The close-match fallback's rows for a query strict search settled empty, or none while a
  /// filter is active: the filtered empty state offers Clear Filters, and an approximate row
  /// inside the filter must not hide an exact match outside it.
  ///
  /// `filters` is the value `performSearch` captured. The caller re-checks `generation` before
  /// using the rows; once it matches, `self.filters` still equals this value, because every filter
  /// change bumps `generation` before its first `await`. Writes no model state.
  private func closeMatchRows(query: String, filters: BrowseFilters) async -> [SearchResultRow] {
    guard filters.isActive == false else { return [] }
    async let itemsPageResult = try? await searchReading.closeMatchItems(
      query: query, libraryIDs: Self.allLibraries, filters: filters, limit: resultLimit)
    async let episodesPageResult = try? await searchReading.closeMatchEpisodes(
      query: query, libraryIDs: Self.allLibraries, filters: filters, limit: resultLimit)
    let itemRows = await itemsPageResult?.rows ?? []
    let episodeRows = await episodesPageResult?.rows ?? []
    return itemRows + episodeRows
  }

  /// `.closeMatches` for whatever of `rows` is visible, or `nil` when none is. Sectioned without
  /// the strict paging cursors: `SearchSectionInput`'s default `hasMore` is `false` for every
  /// kind, so no Load More control renders on a set that is never paged.
  private func closeMatchState(
    for rows: [SearchResultRow], query: String, completeness: ResultsCompleteness
  ) -> State? {
    let visibleRows = visibleRows(for: rows)
    guard visibleRows.isEmpty == false else { return nil }
    return .closeMatches(
      sections: SearchResultAssembly.section(SearchSectionInput(rows: visibleRows, query: query)),
      completeness: completeness)
  }

  /// Re-derives `state` from the current local pool merged against the last-known server rows,
  /// without touching the network. `loadMore`'s update path.
  private func refreshMergedState() {
    let merged = visibleRows(
      for: SearchResultAssembly.merge(
        local: localItemRows + localEpisodeRows, server: lastServerRows))
    guard merged.isEmpty == false else { return }
    state = sectionedState(for: merged, query: self.query, completeness: lastCompleteness)
  }

  /// A recent needs both signals: the native search action explicitly submitted this generation,
  /// and that generation settled with visible results. The recorded marker also makes repeated
  /// submit events idempotent at the model boundary.
  private func recordRecentIfSubmitted(
    _ state: State, query: String, generation: GenerationFence.Token
  ) async {
    guard submittedGeneration == generation else { return }
    guard recordedRecentGeneration != generation else { return }
    guard case .results(let sections, _) = state, sections.isEmpty == false else { return }
    recordedRecentGeneration = generation
    try? await recentSearchStore.record(query: query)
  }

  private func rerunCurrentQuery() {
    searchTask?.cancel()
    let thisGeneration = generation.advance()

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      resetLocalSearchState()
      state = .idle
      return
    }
    guard trimmed.count >= minimumQueryLength else {
      resetLocalSearchState()
      state = .queryTooShort
      return
    }

    state = .searching
    searchTask = Task { [weak self] in
      guard let self else { return }
      await self.performSearch(
        query: trimmed, generation: thisGeneration, emitLocalResultsImmediately: false)
    }
  }

  private func resetLocalSearchState() {
    localItemRows = []
    localEpisodeRows = []
    itemsPaging = LocalPagingState()
    episodesPaging = LocalPagingState()
    lastServerRows = []
    lastCompleteness = .awaitingServer
  }
}
