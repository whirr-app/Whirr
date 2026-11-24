#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import CoreSupport
  import DesignSystem
  import Foundation
  import Persistence
  import SwiftUI
  import SyncEngine

  extension UIHarness {
    /// Which serverless search state the harness renders.
    /// `.allKinds` (default) settles on every `SearchResultKind`, including an `.ebook`
    /// `mediaCategory` on a `.book` row. `.partial` fails the server fan-out (offline), leaving
    /// local rows behind the "results may be incomplete" banner. `.empty` returns nothing.
    enum SearchScenario: String, CaseIterable {
      case allKinds = "all-kinds"
      case partial
      case empty
    }

    enum SearchHarnessFormFactor: String, CaseIterable {
      case compactPhone
      case regularPad

      var maximumContentWidth: CGFloat {
        switch self {
        case .compactPhone: 430
        case .regularPad: 1_180
        }
      }

      var horizontalSizeClass: UserInterfaceSizeClass {
        switch self {
        case .compactPhone: .compact
        case .regularPad: .regular
        }
      }
    }

    static var searchScenario: SearchScenario {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SEARCH"]
        .flatMap(SearchScenario.init(rawValue:)) ?? .allKinds
    }

    static var searchHarnessFormFactor: SearchHarnessFormFactor {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_FORM_FACTOR"]
        .flatMap(SearchHarnessFormFactor.init(rawValue:)) ?? .compactPhone
    }

    /// `WHIRR_UI_HARNESS_SEARCH_RECENTS=<count>` seeds up to ten recent searches for the idle
    /// search screen. When absent, the harness seeds the fixture query and renders results.
    static var searchRecentSeed: Int? {
      guard
        let raw = ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SEARCH_RECENTS"],
        let count = Int(raw), count >= 0
      else { return nil }
      return min(count, HarnessSearchFixtures.recentQueries.count)
    }
  }

  extension UIHarnessRootView {
    /// `WHIRR_UI_HARNESS_SCREEN=search`: the real `SearchView`/`SearchModel` pair over a fake
    /// `SearchReading`/`SyncCoordinating` pinned to `UIHarness.searchScenario`, so the rendering
    /// and routing code is the production code. The model is held by the screen (not built inline
    /// in `body`) so its one subscription survives re-renders.
    ///
    /// Scenario fake: results and the author/series fan-out are server reads, so with no server the
    /// production `SearchReading` would return nothing. `UIHarness.SearchScenario` selects the
    /// reachable, partial and empty states.
    var searchBody: some View {
      HarnessSearchScreen(session: session)
    }
  }

  /// The search harness renders the production `SearchView` with fake reading and playback
  /// dependencies, while retaining real navigation to a podcast show.
  struct HarnessSearchScreen: View {
    let session: UIHarnessSession

    /// The real `SearchModel` over the fake reads, held here so its one `observeRecent()`
    /// subscription survives re-renders.
    @State private var model = SearchModel(
      library: HarnessSearchLibraryReading(),
      searchReading: HarnessSearchReading(scenario: UIHarness.searchScenario),
      sync: HarnessSearchSyncCoordinating(scenario: UIHarness.searchScenario),
      // Without this the harness could not render the idle screen at all: the default is
      // `NoOpRecentSearchStoring`, whose `observeRecent()` finishes its stream immediately, so
      // `recents` stays empty, `SearchIdleView` always takes its empty-state `ZStack` branch, and
      // the recents `List` never mounts. Seeded to nothing unless
      // `WHIRR_UI_HARNESS_SEARCH_RECENTS` asks, which leaves every other harness screen alone.
      recentSearchStore: HarnessRecentSearchStoring(seedCount: UIHarness.searchRecentSeed ?? 0),
      clock: SystemSearchClock(milliseconds: 0))

    @State private var navigation = NavigationModel()

    var body: some View {
      NavigationStack(path: pathBinding) {
        SearchView(
          model: model,
          library: HarnessSearchLibraryReading(),
          coverClient: session.coverClient,
          downloadStatus: session.downloadStatus,
          finishedStatus: session.finishedStatus,
          actions: session.actions,
          playback: session.playback,
          onSelect: { select($0) },
          onSelectRoute: { _ in },
          onSelectEpisode: { _, _ in },
          onPresentReader: { _, _, _ in },
          onSearch: { _ in }
        )
        .navigationDestination(for: NavigationModel.Route.self) { _ in
          PodcastShowView(
            itemID: HarnessPodcastFixtures.showID,
            library: HarnessPodcastLibraryReading(),
            nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
            coverClient: session.coverClient,
            paletteService: session.paletteService,
            playback: session.playback,
            makeModel: {
              PodcastShowModel(
                itemID: HarnessPodcastFixtures.showID,
                reading: HarnessPodcastReading(scenario: .deviceDownloaded),
                refreshing: HarnessPodcastRefreshing(scenario: .deviceDownloaded))
            },
            onSearch: { _ in },
            onPresentEpisode: { _ in },
            onOpenShowSettings: { _ in },
            refreshOnAppear: true)
        }
      }
      .frame(maxWidth: UIHarness.searchHarnessFormFactor.maximumContentWidth)
      .environment(
        \.horizontalSizeClass,
        UIHarness.searchHarnessFormFactor.horizontalSizeClass
      )
      // A simulated form factor has to reach sheet sizing too, or a sheet raised from this screen
      // would size itself against the device the harness is running on.
      .windowHorizontalSizeClass(UIHarness.searchHarnessFormFactor.horizontalSizeClass)
      .task {
        // Seed the default results scenario; recent-search scenarios are seeded in the model.
        guard UIHarness.searchRecentSeed == nil else { return }
        navigation.section = .search
        model.updateQuery(UIHarnessFixtures.searchQuery)
      }
    }

    /// Mirrors `LibraryShellView.select(_:artworkRole:displaySize:)` so harness rows use the same
    /// podcast route and cached-palette preparation as production.
    private func select(_ item: ItemSummary) {
      let destination = NavigationModel.Route.podcastShow(
        itemID: item.serverItemId, filter: .all, seed: item)
      guard item.category != .podcast else {
        navigation.navigate(to: destination)
        return
      }
      let key = CoverPaletteService.artworkKey(
        itemID: item.serverItemId,
        coverClient: session.coverClient,
        displaySize: WhirrMetric.minimumTouchTarget,
        displayScale: 3,
        role: .libraryThumbnail,
        revision: item.artworkRevision)
      Task {
        await session.paletteService.prepare(
          CoverPaletteRequest(
            identity: CoverPaletteIdentity(key),
            bytes: .paletteSource(displayed: key, coverClient: session.coverClient)))
        navigation.navigate(to: destination)
      }
    }

    private var pathBinding: Binding<[NavigationModel.Route]> {
      Binding(
        get: { navigation[pathFor: .search] },
        set: { navigation[pathFor: .search] = $0 })
    }
  }

  /// Mirrors `LibraryShellView`'s `BottomAccessoryHost` at its no-mini-player setting, which is
  /// still an attached, disabled accessory on 26.1+ rather than no accessory at all.
  struct HarnessBottomAccessory: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
      if #available(iOS 26.1, *) {
        content.tabViewBottomAccessory(isEnabled: false) { Text("Harness accessory") }
      } else {
        content
      }
    }
  }

  /// A simple pushed stand-in for item/show detail used by the harness.
  struct HarnessSearchDestination: Hashable {
    let itemID: String
    let title: String
  }

  struct HarnessSearchDestinationView: View {
    let destination: HarnessSearchDestination

    var body: some View {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<24, id: \.self) { index in
              Text("Row \(index)")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding()
        }
        // The bottom ruler: whatever inset the layout is reserving below this page shows up as
        // black between the stripe and the screen edge, and its height can be read straight off a
        // screenshot.
        Rectangle()
          .fill(.red)
          .frame(height: 8)
      }
      .navigationTitle(destination.title)
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  extension UIHarnessFixtures {
    static let searchQuery = "harness"
  }

  /// `SearchReading` fake for the search harness screen: a fixed local page per scenario.
  /// `.allKinds`/`.partial` both resolve the same book/podcast/episode rows (the local-first half
  /// of the pipeline never depends on the server), `.empty` resolves nothing from either method.
  struct HarnessSearchReading: SearchReading {
    let scenario: UIHarness.SearchScenario

    func searchItems(
      query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int, offset: Int
    ) async throws -> SearchPage {
      guard scenario != .empty else { return SearchPage(rows: [], hasMore: false) }
      return SearchPage(rows: HarnessSearchFixtures.itemRows, hasMore: false)
    }

    func searchEpisodes(
      query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int, offset: Int
    ) async throws -> SearchPage {
      guard scenario != .empty else { return SearchPage(rows: [], hasMore: false) }
      return SearchPage(rows: HarnessSearchFixtures.episodeRows, hasMore: false)
    }

    /// The harness has no database to narrow against, so every id the model offers is admitted.
    /// The harness scenarios exercise composition and layout, not filter membership.
    func admittedItemIDs(_ ids: [String], filters: BrowseFilters) async throws -> Set<String> {
      Set(ids)
    }
  }

  /// `SyncCoordinating` fake for the search harness screen. The fan-out is the only source of
  /// `.author`/`.series` rows (`SearchModel.resolveServerRows` never derives those kinds from
  /// `LibraryReading`), so `.allKinds` is what puts them on screen. `.partial` throws, as an
  /// offline/failed request does, so `SearchModel` falls back to its local-only `.unreachable`
  /// state instead of hanging or crashing.
  struct HarnessSearchSyncCoordinating: SyncCoordinating {
    let scenario: UIHarness.SearchScenario

    private struct HarnessOffline: Error {}

    func refresh() async {}

    func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
      switch scenario {
      case .allKinds:
        return SearchFanOutResult(matches: HarnessSearchFixtures.authorSeriesMatches, failures: [])
      case .partial:
        throw HarnessOffline()
      case .empty:
        return SearchFanOutResult(matches: [], failures: [])
      }
    }
  }

  /// `LibraryReading` fake for the search harness screen: just enough to resolve the one podcast
  /// show the harness episode row belongs to (`SearchView.resolveEpisodeShowTitles`). Every other
  /// method mirrors `HarnessLibraryReading`'s single-yield-then-idle shape.
  struct HarnessSearchLibraryReading: LibraryReading {
    var itemCount: Int { HarnessSearchFixtures.itemRows.count }

    private static let showSummary = ItemSummary(
      serverItemId: HarnessSearchFixtures.podcastShowID, mediaKind: "podcast",
      title: "Ocean Signals", author: "Remote Concern Radio", durationSeconds: nil,
      category: ItemMediaCategory.derive(
        mediaKind: "podcast", numAudioFiles: nil, ebookFormat: nil),
      hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: nil))

    private static let mixedSummary = ItemSummary(
      serverItemId: UIHarnessFixtures.mixedItemID,
      mediaKind: "book",
      title: UIHarnessFixtures.mixedTitle,
      author: UIHarnessFixtures.mixedAuthor,
      durationSeconds: UIHarnessFixtures.duration,
      category: UIHarnessFixtures.mixedCategory,
      hasReadableEbook: UIHarnessFixtures.mixedHasReadableEbook)

    func observeBrowseList(libraryId: String) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield([Self.showSummary]) }
    }
    func observeBrowseList(category: ItemMediaCategory?) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield(category == nil || category == .podcast ? [Self.showSummary] : []) }
    }
    /// No download or progress rows in this fixture, so those dimensions can only exclude. The
    /// fixture is a podcast show, and `ItemFilterPredicate.itemPlayback` excludes shows from every
    /// engaged playback state (a show cannot answer an item-scoped playback question), so only
    /// `.any` admits it.
    func observeBrowseList(filters: BrowseFilters) -> AsyncStream<LibraryBrowseSnapshot> {
      let matches =
        (filters.categories?.contains(.podcast) ?? true)
        && filters.downloadedOnly == false && filters.playback == .any
      return AsyncStream {
        $0.yield(
          LibraryBrowseSnapshot(items: matches ? [Self.showSummary] : [], unfilteredItemCount: 1))
      }
    }
    func observeSyncStatus(libraryId: String) -> AsyncStream<LibrarySyncStatus> {
      AsyncStream {
        $0.yield(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil))
      }
    }
    func observeAggregateSyncStatus() -> AsyncStream<LibrarySyncStatus> {
      AsyncStream {
        $0.yield(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil))
      }
    }
    func observeItemDetail(itemId: String) -> AsyncStream<ItemSummary?> {
      AsyncStream {
        $0.yield(
          itemId == UIHarnessFixtures.mixedItemID ? Self.mixedSummary : Self.showSummary)
      }
    }
    func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]> {
      let summaries = [Self.showSummary, Self.mixedSummary]
      return AsyncStream { $0.yield(summaries.filter { ids.contains($0.serverItemId) }) }
    }
    func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]> {
      AsyncStream { $0.yield([:]) }
    }
  }

  nonisolated enum HarnessSearchFixtures {
    static let libraryID = "harness-search-library"
    static let podcastShowID = "harness-podcast-show"

    /// One `.book` row with the default audiobook category, one mixed `.book` row, one ebook row,
    /// and one `.podcast` row.
    static let itemRows: [SearchResultRow] = [
      SearchResultRow(
        kind: .book, entityID: "harness-book-audio", title: "The Left Hand of Darkness",
        subtitle: "Ursula K. Le Guin",
        mediaCategory: ItemMediaCategory.derive(
          mediaKind: "book", numAudioFiles: 3, ebookFormat: nil),
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: nil), libraryID: libraryID),
      SearchResultRow(
        kind: .book, entityID: UIHarnessFixtures.mixedItemID,
        title: UIHarnessFixtures.mixedTitle, subtitle: UIHarnessFixtures.mixedAuthor,
        mediaCategory: UIHarnessFixtures.mixedCategory,
        hasReadableEbook: UIHarnessFixtures.mixedHasReadableEbook, libraryID: libraryID),
      SearchResultRow(
        kind: .book, entityID: "harness-book-ebook", title: "A Field Guide to Getting Lost",
        subtitle: "Rebecca Solnit",
        mediaCategory: ItemMediaCategory.derive(
          mediaKind: "book", numAudioFiles: 0, ebookFormat: "epub"),
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: "epub"), libraryID: libraryID),
      SearchResultRow(
        kind: .podcast, entityID: podcastShowID, title: "Ocean Signals",
        subtitle: "Remote Concern Radio",
        mediaCategory: ItemMediaCategory.derive(
          mediaKind: "podcast", numAudioFiles: nil, ebookFormat: nil),
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: nil), libraryID: libraryID),
    ]

    static let episodeRows: [SearchResultRow] = [
      SearchResultRow(
        kind: .episode, entityID: "harness-episode", parentItemID: podcastShowID,
        title: "Ep. 214: Deep Sea Cables", libraryID: libraryID)
    ]

    /// `.author`/`.series` only ever arrive through the server fan-out (never local search), so
    /// these live here rather than alongside `itemRows`/`episodeRows` above.
    /// Seeded into `HarnessRecentSearchStoring` by `WHIRR_UI_HARNESS_SEARCH_RECENTS`, most-recent
    /// first. Ten of them because that is the store's own cap, so a seed count can ask for any
    /// legal list length without the fixture running out.
    static let recentQueries: [String] = [
      "le guin", "ocean signals", "solnit", "broken earth", "deep sea cables",
      "wizard of earthsea", "field guide", "remote concern", "dispossessed", "annihilation",
    ]

    static let authorSeriesMatches: [SearchMatch] = [
      SearchMatch(
        kind: .author, libraryId: libraryID, itemId: "harness-author", matchKey: nil,
        matchText: "Ursula K. Le Guin"),
      SearchMatch(
        kind: .series, libraryId: libraryID, itemId: "harness-series", matchKey: nil,
        matchText: "The Broken Earth"),
    ]
  }

  /// Mutable `RecentSearchStoring` fake so the idle screen's controls can clear searches. An
  /// `actor`, like the `SearchModelTests` fake: `observeRecent` continuations are written from any
  /// context.
  actor HarnessRecentSearchStoring: RecentSearchStoring {
    private var current: [RecentSearchQuery]
    private var continuations: [AsyncStream<[RecentSearchQuery]>.Continuation] = []

    /// Seeded newest-first with `lastUsedAt` descending, matching what the real store's
    /// most-recently-used-first ordering would produce. The dates are derived from a fixed epoch
    /// rather than `Date()` so a harness screenshot is reproducible, the same reason
    /// `WHIRR_UI_HARNESS_SCHEME` pins the colour scheme.
    init(seedCount: Int) {
      let epoch = Date(timeIntervalSince1970: 1_760_000_000)
      current = HarnessSearchFixtures.recentQueries.prefix(seedCount).enumerated().map {
        index, query in
        RecentSearchQuery(
          normalizedQuery: query.lowercased(),
          displayQuery: query,
          lastUsedAt: epoch.addingTimeInterval(TimeInterval(-index * 60)))
      }
    }

    func record(query: String) async throws {
      let entry = RecentSearchQuery(
        normalizedQuery: query.lowercased(), displayQuery: query,
        lastUsedAt: Date(timeIntervalSince1970: 1_760_000_000))
      current.removeAll { $0.normalizedQuery == entry.normalizedQuery }
      current.insert(entry, at: 0)
      emit()
    }

    nonisolated func observeRecent() -> AsyncStream<[RecentSearchQuery]> {
      AsyncStream { continuation in
        Task { await self.addContinuation(continuation) }
      }
    }

    private func addContinuation(_ continuation: AsyncStream<[RecentSearchQuery]>.Continuation) {
      continuations.append(continuation)
      continuation.yield(current)
    }

    func clear(query: String) async throws {
      let normalized = query.lowercased()
      current.removeAll { $0.normalizedQuery == normalized }
      emit()
    }

    func clearAll() async throws {
      current = []
      emit()
    }

    private func emit() {
      for continuation in continuations { continuation.yield(current) }
    }
  }
#endif
