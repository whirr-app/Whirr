#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import Foundation
  import Observation
  import Persistence
  import SwiftUI
  import SyncEngine

  extension UIHarnessRootView {
    /// `WHIRR_UI_HARNESS_SCREEN=home`: the Home screen in a `NavigationStack`, dark
    /// scheme like every other presented harness screen, over `HarnessHomeReading` and a no-op
    /// `HarnessSyncCoordinating`. The card and section-heading closures are no-ops and do not
    /// reach into `NavigationModel`.
    ///
    /// Scenario fake: Home's shelves are synced account data, so with no account the production
    /// `DefaultHomeReading` would publish nothing. The reads are fixtures; the models are the
    /// shipping `HomeModel`/`HomeMoreModel`.
    var homeBody: some View {
      HarnessHomeScreen(session: session)
    }
  }

  /// Home's two models, built from the harness reads the way production builds them from
  /// `HomeReading`/`SyncCoordinating`. Held by the screen in `@State` so their subscriptions survive
  /// re-renders.
  @MainActor
  @Observable
  final class HarnessHomeModels {
    let home: HomeModel
    let latestEpisodes: HomeMoreModel

    init() {
      let reading = HarnessHomeReading()
      let sync = HarnessSyncCoordinating()
      home = HomeModel(home: reading, sync: sync, savedShelf: HarnessSavedShelfReading())
      latestEpisodes = HomeMoreModel(
        section: .newEpisodes, filter: .podcasts, home: reading, sync: sync)
    }
  }

  struct HarnessHomeScreen: View {
    let session: UIHarnessSession
    @State private var models = HarnessHomeModels()

    var body: some View {
      NavigationStack {
        HomeView(
          model: models.home,
          latestEpisodesModel: models.latestEpisodes,
          coverClient: session.coverClient,
          paletteService: session.paletteService,
          playback: session.playback,
          actions: session.actions,
          onSelectItem: { _ in },
          onSelectDownloadedPodcast: { _ in },
          onSelectEpisode: { _, _ in },
          onOpenSection: { _ in },
          onSearch: { _ in }
        )
      }
      .preferredColorScheme(UIHarness.harnessColorScheme)
      .uiHarnessMiniPlayer()
      .overlay {
        if UIHarness.runsScrollScript {
          UIHarnessScrollDriver()
        }
      }
    }
  }

  extension UIHarnessFixtures {
    nonisolated static let homeNow = Date()
    /// `WHIRR_UI_HARNESS_SCALE=N` appends N generated items per shelf shape to the hand-written
    /// edge cases, so a shelf can be driven at its real length without losing the unflattering
    /// fixtures.
    nonisolated static let homeItems: [HomeItem] = baseHomeItems + generatedHomeItems

    nonisolated static var generatedHomeItems: [HomeItem] {
      let extra = HarnessAblation.fixtureScale
      guard extra > 1 else { return [] }
      var items: [HomeItem] = []
      items.reserveCapacity(extra * 2)
      for index in 0..<extra {
        let offset = Double(index)
        let listening = HomeItem(
          serverItemId: "gen-cl-\(index)",
          title: "Generated Continue Listening \(index)",
          author: "Author \(index % 7)",
          category: ItemMediaCategory.audiobook,
          durationSeconds: 30_000 + offset * 137,
          progressSeconds: 1_000 + offset * 91,
          isFinished: false,
          addedAt: homeNow.addingTimeInterval(-offset * 3_600),
          isDownloaded: index % 3 == 0)
        let category: ItemMediaCategory = index % 4 == 0 ? .ebook : .audiobook
        let duration: Double? = index % 4 == 0 ? nil : 20_000 + offset * 53
        let added = HomeItem(
          serverItemId: "gen-ra-\(index)",
          title: "Generated Recently Added \(index)",
          author: "Author \(index % 5)",
          category: category,
          durationSeconds: duration,
          progressSeconds: 0,
          isFinished: false,
          addedAt: homeNow.addingTimeInterval(-offset * 900),
          isDownloaded: index % 4 == 1)
        items.append(listening)
        items.append(added)
      }
      return items
    }

    nonisolated static let baseHomeItems: [HomeItem] = [
      // Continue Listening (known duration): halfway through a long audiobook.
      HomeItem(
        serverItemId: "home-cl-audiobook", title: "The Fellowship of the Ring", author: "J.R.R. Tolkien",
        category: .audiobook, durationSeconds: 36_000, progressSeconds: 18_000, isFinished: false,
        addedAt: homeNow.addingTimeInterval(-2 * 86_400), isDownloaded: true),
      // Mixed audiobook + EPUB: both continuation progress values are present on the same item.
      HomeItem(
        serverItemId: UIHarnessFixtures.mixedItemID, title: UIHarnessFixtures.mixedTitle,
        author: UIHarnessFixtures.mixedAuthor, category: UIHarnessFixtures.mixedCategory,
        hasReadableEbook: UIHarnessFixtures.mixedHasReadableEbook, durationSeconds: UIHarnessFixtures.duration,
        progressSeconds: 7_200, ebookProgress: 0.35, isFinished: false,
        addedAt: homeNow.addingTimeInterval(-86_400), isDownloaded: false),
      // Continue Listening, nil duration: the no-progress-bar/no-caption path.
      HomeItem(
        serverItemId: "home-cl-no-duration", title: "Untitled Field Recording", author: "Unknown",
        category: .audiobook, durationSeconds: nil, progressSeconds: 1_200, isFinished: false,
        addedAt: homeNow.addingTimeInterval(-86_400), isDownloaded: false),
      // Continue Listening, podcast. Also covers the podcast badge.
      HomeItem(
        serverItemId: "home-cl-podcast", title: "Ep. 214: Deep Sea Cables", author: "Ocean Signals",
        category: .podcast, durationSeconds: 2_700, progressSeconds: 600, isFinished: false,
        addedAt: homeNow.addingTimeInterval(-3 * 3_600), isDownloaded: true),
      // Recently added only, ebook. Covers the ebook badge.
      HomeItem(
        serverItemId: "home-ra-ebook", title: "A Field Guide to Getting Lost", author: "Rebecca Solnit",
        category: .ebook, durationSeconds: nil, progressSeconds: 0, isFinished: false,
        addedAt: homeNow.addingTimeInterval(-5 * 86_400), isDownloaded: false),
      // Finished, downloaded, no longer in Continue Listening.
      HomeItem(
        serverItemId: "home-dl-finished", title: "Project Hail Mary", author: "Andy Weir",
        category: .audiobook, durationSeconds: 61_200, progressSeconds: 61_200, isFinished: true,
        addedAt: homeNow.addingTimeInterval(-10 * 86_400), isDownloaded: true),
      // Freshest add, never started, not downloaded.
      HomeItem(
        serverItemId: "home-ra-fresh", title: "Piranesi", author: "Susanna Clarke",
        category: .audiobook, durationSeconds: 28_800, progressSeconds: 0, isFinished: false,
        addedAt: homeNow, isDownloaded: false),
    ]

    nonisolated static let homeContinueSeries: [HomeItem] = [
      HomeItem(
        serverItemId: "home-series-next", title: "The Two Towers", author: "J.R.R. Tolkien",
        category: .audiobook, durationSeconds: 38_400, progressSeconds: 0, isFinished: false,
        addedAt: homeNow.addingTimeInterval(-86_400), isDownloaded: false),
      // Continue Series under the Ebooks filter: this card must take the item-detail path.
      HomeItem(
        serverItemId: "home-series-next-ebook", title: "The Return of the King", author: "J.R.R. Tolkien",
        category: .ebook, durationSeconds: nil, progressSeconds: 0, isFinished: false,
        addedAt: homeNow.addingTimeInterval(-2 * 86_400), isDownloaded: false),
    ]

    nonisolated static let homePodcastEpisodes: [HomePodcastEpisode] =
      [
        HomePodcastEpisode(
          itemID: "home-podcast-show", showTitle: "Ocean Signals", showAuthor: "Harbour Audio",
          episodeID: "home-episode-one", title: "The Cable Layer", subtitle: nil,
          publishedAt: homeNow.addingTimeInterval(-3_600), durationSeconds: 2_400),
        HomePodcastEpisode(
          itemID: "home-podcast-show", showTitle: "Ocean Signals", showAuthor: "Harbour Audio",
          episodeID: "home-episode-two", title: "Signals in the Dark", subtitle: nil,
          publishedAt: homeNow.addingTimeInterval(-7_200), durationSeconds: 2_700),
      ]
      + (3...(12 + 4 * max(0, HarnessAblation.fixtureScale - 1))).map { index in
        HomePodcastEpisode(
          itemID: "home-podcast-show", showTitle: "Ocean Signals", showAuthor: "Harbour Audio",
          episodeID: "home-episode-\(index)", title: "Ocean Dispatch \(index)", subtitle: nil,
          publishedAt: homeNow.addingTimeInterval(Double(index) * -3_600),
          durationSeconds: 2_100 + Double(index * 90))
      }

    nonisolated static let homeSavedEntries: [SavedShelfItem] = [
      SavedShelfItem(
        identity: .item(itemID: "home-saved-book"), savedAt: homeNow,
        subjectTitle: "The Left Hand of Darkness", contextTitle: nil, category: .ebook,
        itemSummary: ItemSummary(
          serverItemId: "home-saved-book", mediaKind: "book",
          title: "The Left Hand of Darkness", author: "Ursula K. Le Guin",
          durationSeconds: nil, category: .ebook, hasReadableEbook: true),
        episode: nil, isUnavailable: false),
      SavedShelfItem(
        identity: .podcastEpisode(itemID: "home-podcast-show", episodeID: "home-episode-two"),
        savedAt: homeNow.addingTimeInterval(-60), subjectTitle: "Signals in the Dark",
        contextTitle: "Ocean Signals", category: .podcast, itemSummary: nil,
        episode: homePodcastEpisodes[1], isUnavailable: false),
      SavedShelfItem(
        identity: .item(itemID: "home-unavailable-save"),
        savedAt: homeNow.addingTimeInterval(-120), subjectTitle: "A Removed Saved Book",
        contextTitle: nil, category: .audiobook, itemSummary: nil, episode: nil,
        isUnavailable: true),
    ]
  }

  /// `HomeReading` fake for the Home harness screen: a fixed set of items, yielded once and then
  /// idle (no simulated sync pipeline). Unflattering rather than idealised: at least one item
  /// per media category, one in-progress item with a known duration (the progress-bar path), and
  /// one with a `nil` duration (the no-progress-bar/no-caption path
  /// `HomeRowPresentation.progressFraction` is defensive against).
  struct HarnessHomeReading: HomeReading {
    func observeContinueReading(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
      let matches = UIHarnessFixtures.homeItems.filter {
        $0.ebookProgress > 0 && $0.isFinished == false && $0.category != .podcast
      }
      guard UIHarness.refreshMutatesContent else {
        return Self.stream(matches, category: category, limit: limit)
      }
      // The shelf the refresh retires. `HomeView` animates `elements` on their IDs, so a shelf that
      // comes and goes is the only fixture change that reaches that animation.
      return AsyncStream { continuation in
        let emit: @Sendable (Int) -> Void = { generation in
          let items = generation.isMultiple(of: 2) ? matches : []
          continuation.yield(Self.limited(items, category: category, limit: limit))
        }
        emit(HarnessHomeRepublisher.shared.currentGeneration)
        HarnessHomeRepublisher.shared.register(emit)
      }
    }

    func observeContinueListening(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
      let matches = UIHarnessFixtures.homeItems.filter { $0.progressSeconds > 0 && $0.isFinished == false }
      return Self.stream(matches, category: category, limit: limit)
    }

    func observeContinueSeries(
      category: ItemMediaCategory?, limit: Int
    ) -> AsyncStream<[HomeItem]> {
      Self.stream(UIHarnessFixtures.homeContinueSeries, category: category, limit: limit)
    }

    func observeNewPodcastEpisodes(
      cutoff: @escaping @Sendable () -> Date, limit: Int
    ) -> AsyncStream<HomeLatestPodcastEpisodesSnapshot> {
      let episodes = Array(
        UIHarnessFixtures.homePodcastEpisodes
          .filter { $0.publishedAt >= cutoff() }
          .prefix(max(0, limit)))
      return AsyncStream {
        $0.yield(HomeLatestPodcastEpisodesSnapshot(all: episodes, nativePreferred: episodes))
      }
    }

    func observeRecentlyAdded(
      category: ItemMediaCategory?, limit: Int
    ) -> AsyncStream<HomeRecentlyAddedSnapshot> {
      let matches = UIHarnessFixtures.homeItems.sorted {
        ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast)
      }
      let items = Self.limited(matches, category: category, limit: limit)
      return AsyncStream {
        $0.yield(HomeRecentlyAddedSnapshot(all: items, nativePreferred: items))
      }
    }

    func observeDownloaded(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
      let matches = UIHarnessFixtures.homeItems.filter(\.isDownloaded)
      return Self.stream(matches, category: category, limit: limit)
    }

    /// Filters by category (when given), applies `limit` after filtering as `DefaultHomeReading`
    /// does, and yields once.
    private static func stream(_ items: [HomeItem], category: ItemMediaCategory?, limit: Int) -> AsyncStream<
      [HomeItem]
    > {
      let entries = limited(items, category: category, limit: limit)
      return AsyncStream { $0.yield(entries) }
    }

    fileprivate static func limited(
      _ items: [HomeItem], category: ItemMediaCategory?, limit: Int
    ) -> [HomeItem] {
      Array(items.filter { category == nil || $0.category == category }.prefix(limit))
    }
  }

  /// Republishes the Home fixtures when the harness sync refreshes, so a pull can change the shelf
  /// set as a real one does. The stock fixtures never change, so otherwise every pull is a no-op
  /// for `HomeView`'s `elements` and leaves its `.animation(_:value:)` (the one scroll-view
  /// modifier Home has that Your Shows lacks) untouched. Off unless `WHIRR_REFRESH_MUTATES=1`,
  /// because scroll measurements depend on a fixed fixture set.
  nonisolated final class HarnessHomeRepublisher: @unchecked Sendable {
    static let shared = HarnessHomeRepublisher()

    private let lock = NSLock()
    private var generation = 0
    private var subscribers: [@Sendable (Int) -> Void] = []

    var currentGeneration: Int {
      lock.lock()
      defer { lock.unlock() }
      return generation
    }

    func register(_ emit: @escaping @Sendable (Int) -> Void) {
      lock.lock()
      subscribers.append(emit)
      lock.unlock()
    }

    func advance() {
      lock.lock()
      generation += 1
      let next = generation
      let current = subscribers
      lock.unlock()
      for emit in current { emit(next) }
    }
  }

  struct HarnessSavedShelfReading: SavedShelfReading {
    func observeSaved(
      filter: ItemMediaCategory?, limit: Int?
    ) -> AsyncStream<[SavedShelfItem]> {
      let matches = UIHarnessFixtures.homeSavedEntries.filter {
        filter == nil || $0.category == filter
      }
      let entries = limit.map { Array(matches.prefix($0)) } ?? matches
      return AsyncStream { $0.yield(entries) }
    }

    func observeSavedIdentities() -> AsyncStream<Set<SavedShelfIdentity>> {
      AsyncStream { $0.yield(Set(UIHarnessFixtures.homeSavedEntries.map(\.identity))) }
    }
  }

  /// `SyncCoordinating` fake for the Home harness screen: pull-to-refresh is a silent no-op, and
  /// search is unused by `HomeModel`. Like `HarnessDownloadIntents`, no-op everywhere.
  struct HarnessSyncCoordinating: SyncCoordinating {
    /// Instant by default, and `WHIRR_REFRESH_DELAY_MS` long when the refresh geometry is being
    /// watched: a pull whose action returns in the same turn never opens the control at all.
    func refresh() async {
      let milliseconds = UIHarness.refreshDelayMilliseconds
      if milliseconds > 0 {
        try? await Task.sleep(for: .milliseconds(milliseconds))
      }
      guard UIHarness.refreshMutatesContent else { return }
      HarnessHomeRepublisher.shared.advance()
    }
    func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
      SearchFanOutResult(matches: [])
    }
  }
#endif
