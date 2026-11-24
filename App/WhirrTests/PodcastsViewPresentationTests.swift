import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// `PodcastsView` composes three independently loading models. Which of them may hold the whole
/// screen at `.loading`, and how a browse state becomes a grid of shows, is derived here, not
/// inline. Follows the convention of `PodcastShowViewPresentation`.
@Suite("Podcasts view presentation")
struct PodcastsViewPresentationTests {

  @Test("a filter change carries Home's motion, and Reduce Motion's fade instead")
  func filterChangeMotionMatchesHome() {
    #expect(
      PodcastsViewPresentation.filterChangeMotion(reduceMotion: false)
        == HomeViewPresentation.ContinueListeningDismissalMotion.springAway.animation)
    #expect(
      PodcastsViewPresentation.filterChangeMotion(reduceMotion: true)
        == HomeViewPresentation.ContinueListeningDismissalMotion.fade.animation)
  }

  @Test("Continue Listening is Home's section, and absent when there is nothing to continue")
  func continueListeningSectionMatchesHome() throws {
    #expect(PodcastsViewPresentation.continueListeningSection([]) == nil)

    let items = [Self.continueItem(id: "b"), Self.continueItem(id: "a")]
    let section = try #require(PodcastsViewPresentation.continueListeningSection(items))
    #expect(section.kind == .continueListening)
    #expect(section.title == HomeCopy.continueListeningTitle)
    #expect(section.content == .items(items))
  }

  @Test("podcast filters keep their editorial order and labels")
  func podcastFiltersHaveStableOrderAndLabels() {
    // No "New" chip. The Latest Episodes heading already opens the full list, and a chip showing
    // the same rows in-page would duplicate it.
    #expect(PodcastsViewPresentation.Filter.allCases == [.all, .yourShows, .downloaded])
    #expect(
      PodcastsViewPresentation.Filter.allCases.map(\.label) == [
        "All", "Shows", "Downloads",
      ])
  }

  @Test("downloaded shows merge native feeds before server shows while preserving source order")
  func downloadedShowsMergeBothSources() throws {
    let serverShows = [Self.show(id: "show-3"), Self.show(id: "show-1"), Self.show(id: "show-2")]
    let nativeShows = [
      Self.show(id: try #require(PodcastSourceIdentity.rss(feedId: 8)).itemId),
      Self.show(id: try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId),
      Self.show(id: try #require(PodcastSourceIdentity.rss(feedId: 9)).itemId),
    ]
    let episodeDownloadKeys = [
      EpisodeDownloadKey(itemID: "show-2", episodeID: "episode-2"),
      EpisodeDownloadKey(itemID: "show-3", episodeID: "episode-3"),
    ]

    let downloaded = PodcastsViewPresentation.downloadedShows(
      serverShows: serverShows,
      nativeShows: nativeShows,
      downloadedServerIDs: Set(episodeDownloadKeys.map(\.itemID)),
      downloadedNativeFeedIDs: [7, 8])

    #expect(
      downloaded.map(\.serverItemId) == [
        try #require(PodcastSourceIdentity.rss(feedId: 8)).itemId,
        try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId,
        "show-3", "show-2",
      ])
  }

  @Test("latest episode wash requests deduplicate show IDs only on the All page")
  func latestEpisodeWashItemIDsAreDistinctAndFilterScoped() {
    let episodes = [
      Self.episode(itemID: "show-2", episodeID: "episode-1"),
      Self.episode(itemID: "show-1", episodeID: "episode-2"),
      Self.episode(itemID: "show-2", episodeID: "episode-3"),
    ]

    #expect(
      PodcastsViewPresentation.latestEpisodeWashItemIDs(for: .all, episodes: episodes)
        == ["show-2", "show-1"])
    #expect(
      PodcastsViewPresentation.latestEpisodeWashItemIDs(for: .yourShows, episodes: episodes)
        .isEmpty)
    #expect(
      PodcastsViewPresentation.latestEpisodeWashItemIDs(for: .downloaded, episodes: episodes)
        .isEmpty)
  }

  /// The page shows a short list and leaves the rest to the heading's full list, so it colours only
  /// the shows it draws.
  @Test("the page lists the first ten latest episodes and colours only their shows")
  func latestEpisodePreviewIsTheFirstTen() {
    let episodes = (0..<14).map { Self.episode(itemID: "show-\($0)", episodeID: "episode-\($0)") }

    #expect(
      PodcastsViewPresentation.latestEpisodePreview(episodes).map(\.episodeID)
        == (0..<10).map { "episode-\($0)" })
    #expect(
      PodcastsViewPresentation.latestEpisodeWashItemIDs(for: .all, episodes: episodes)
        == (0..<10).map { "show-\($0)" })
    #expect(PodcastsViewPresentation.latestEpisodePreview([]).isEmpty)
  }

  @MainActor
  @Test("native-off Podcasts keeps the same ABS models and shell download projection")
  func nativeOffPodcastsConstructionKeepsTheABSPath() throws {
    let composition = try Self.makeComposition()

    for nativeSubscriptionsEnabled in [false, true] {
      _ = PodcastsView(
        listeningModel: composition.podcastListeningModel,
        latestModel: composition.podcastLatestModel,
        showsModel: composition.podcastShowsOrderedModel,
        nativeShowsModel: composition.nativePodcastShowsModel,
        hasIncludedPodcastLibrary: true,
        nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
        coverClient: composition.environment.coverImageClient,
        paletteService: composition.environment.paletteService,
        downloadStatus: composition.downloadStatus,
        playback: composition.root.playback,
        actions: composition.actions,
        onSelectShow: { _ in },
        onSelectDownloadedShow: { _ in },
        onSelectEpisode: { _, _ in },
        onOpenContinueListening: {},
        onOpenLatestEpisodes: {},
        onOpenShows: {},
        onAddFeed: {},
        onSearch: { _ in })
    }
  }

  @Test("only the Downloads filter opens show tiles on the downloaded-episodes filter")
  func downloadsFilterOpensShowsOnDownloadedEpisodes() {
    for filter in PodcastsViewPresentation.Filter.allCases {
      #expect(
        PodcastsViewPresentation.showTileEpisodeFilter(for: filter)
          == (filter == .downloaded ? .downloaded : .all))
    }
  }

  @Test("followable empty states offer Add Podcast only while native subscriptions are enabled")
  func followableEmptyStatesRespectTheNativePreference() {
    for filter in [
      PodcastsViewPresentation.Filter.all,
      .yourShows,
    ] {
      let enabled = PodcastsViewPresentation.emptyState(
        for: filter, nativeSubscriptionsEnabled: true)
      let disabled = PodcastsViewPresentation.emptyState(
        for: filter, nativeSubscriptionsEnabled: false)

      #expect(enabled.actionLabel == "Add Podcast")
      #expect(disabled.actionLabel == nil)
      #expect(enabled.title.localizedCaseInsensitiveContains("rss") == false)
      #expect(enabled.message.localizedCaseInsensitiveContains("rss") == false)
    }
  }

  @Test("downloads never offer Add Podcast")
  func downloadedEmptyStateOffersNoNativeAction() {
    for enabled in [false, true] {
      let content = PodcastsViewPresentation.emptyState(
        for: .downloaded, nativeSubscriptionsEnabled: enabled)

      #expect(content.actionLabel == nil)
      #expect(content.title == "No Downloads Yet")
    }
  }

  @Test("server shows require both an included library and non-empty rows")
  func serverShowsSectionRequiresIncludedLibraryAndShows() {
    let shows = [Self.show(id: "server-show")]

    #expect(
      PodcastsViewPresentation.showsServerSection(
        hasIncludedPodcastLibrary: true, serverShows: shows))
    #expect(
      PodcastsViewPresentation.showsServerSection(
        hasIncludedPodcastLibrary: false, serverShows: shows) == false)
    #expect(
      PodcastsViewPresentation.showsServerSection(
        hasIncludedPodcastLibrary: true, serverShows: []) == false)
  }

  @MainActor
  @Test("podcasts root keeps native and ABS show observations distinct")
  func podcastsTabObservationSourcesStaySeparated() throws {
    let composition = try Self.makeComposition()

    #expect(
      ObjectIdentifier(composition.nativePodcastShowsModel)
        != ObjectIdentifier(composition.podcastShowsOrderedModel))
  }

  @Test("podcast placeholders are decided by the selected filter")
  func podcastPlaceholdersFollowSelectedFilter() {
    let loadedShows = PodcastShowsModel.State.loaded(
      Self.snapshot(.alphabetical, [Self.show(id: "show-1")]))
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .all,
        continueListening: .loading,
        latestEpisodes: .loading,
        shows: .loading,
        hasContent: false)
        == .loading)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .yourShows,
        continueListening: .loaded,
        latestEpisodes: .loaded,
        shows: .loading,
        hasContent: false)
        == .loading)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .downloaded,
        continueListening: .loaded,
        latestEpisodes: .loaded,
        shows: loadedShows,
        rssDownloadsHaveLoaded: false,
        hasContent: false)
        == .loading)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .downloaded,
        continueListening: .loaded,
        latestEpisodes: .loaded,
        shows: loadedShows,
        rssDownloadsHaveLoaded: false,
        hasContent: true)
        == nil)

    #expect(
      PodcastsViewPresentation.placeholder(
        for: .all,
        continueListening: .empty,
        latestEpisodes: .empty,
        shows: .empty,
        hasContent: false)
        == .empty)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .yourShows,
        continueListening: .loaded,
        latestEpisodes: .loaded,
        shows: .empty,
        hasContent: false)
        == .empty)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .downloaded,
        continueListening: .loaded,
        latestEpisodes: .loaded,
        shows: loadedShows,
        hasContent: false)
        == .empty)

    for filter in PodcastsViewPresentation.Filter.allCases {
      #expect(
        PodcastsViewPresentation.placeholder(
          for: filter,
          continueListening: .loaded,
          latestEpisodes: .loaded,
          shows: loadedShows,
          hasContent: true)
          == nil)
    }
  }

  @Test("an episode is playing only when identity and playback intent both match")
  func episodePlayingDecisionRequiresMatchingActivePlayback() {
    let episode = Self.episode(itemID: "show-1", episodeID: "episode-1")
    let identity = ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1")

    #expect(
      PodcastsViewPresentation.isPlaying(
        episode: episode, nowPlaying: identity, isPlaybackActive: true))
    #expect(
      PodcastsViewPresentation.isPlaying(
        episode: episode, nowPlaying: identity, isPlaybackActive: false) == false)
    #expect(
      PodcastsViewPresentation.isPlaying(
        episode: episode,
        nowPlaying: .podcastEpisode(itemID: "show-2", episodeID: "episode-2"),
        isPlaybackActive: true)
        == false)
  }

  @Test("a native-feed episode reads as playing when the player holds its rss identity")
  func nativeFeedEpisodePlayingDecisionMatchesItsRSSIdentity() throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)?.itemId)
    let episode = Self.episode(itemID: itemID, episodeID: "episode-1")
    let identity = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "episode-1"))

    #expect(
      PodcastsViewPresentation.isPlaying(
        episode: episode, nowPlaying: identity, isPlaybackActive: true))
    #expect(
      PodcastsViewPresentation.isPlaying(
        episode: episode,
        nowPlaying: .rssEpisode(feedID: 7, episodeID: "episode-2"),
        isPlaybackActive: true)
        == false)
    #expect(
      PodcastsViewPresentation.isPlaying(
        episode: episode, nowPlaying: nil, isPlaybackActive: true) == false)
  }

  /// Every surface that renders a podcast owes a long-press menu, as Home, Library and Search do.
  /// Adding a section without a menu fails here, not on a device.
  @Test(arguments: PodcastMenuBearingSurface.allCases)
  func everyPodcastSurfaceOffersAMenu(surface: PodcastMenuBearingSurface) {
    #expect(ItemContextMenuAvailability.offersMenu(for: .podcast))

    // Both branches draw the `.podcast` menu family; the row's `episodeID` picks the show pair or
    // the episode sections within it.
    #expect(ItemMediaCapability.derive(category: .podcast, hasReadableEbook: false) == .podcast)

    guard surface.isEpisodeSurface else {
      // Show-level surfaces raise the show menu, which is a fixed pair of entries.
      return
    }

    let entries = ItemContextMenuPresentation.podcastEpisodeEntries(
      downloadAction: .download, surface: surface.menuSurface, queueAvailability: .both,
      playbackStatus: .inProgress)
    #expect(entries.isEmpty == false)
    // Playback and progress reach every episode surface, whatever else that surface suppresses.
    #expect(entries.contains(.playPause))
    #expect(entries.contains(.markAsFinished))
    #expect(entries.contains(.resetProgress))
  }

  /// The remaining suppressions, asserted from the surface inventory so a surface mapped to the
  /// wrong context fails. No browse surface raises a menu from inside the queue. The server-save
  /// pair is gated to the show screen and episode card and suppressed outright on browse surfaces;
  /// the set is asserted whole, so a third action is a defect.
  @Test func onlyTheShowScreenSuppressesAnythingBeyondTheServerPair() {
    let serverPair: Set<MediaItemAction> = [.saveToServer, .removeFromServer]
    for surface in PodcastMenuBearingSurface.allCases where surface.isEpisodeSurface {
      let suppressed = PodcastShowPresentation.suppressedActions(on: surface.menuSurface)
      switch surface {
      case .podcastShowEpisodeRow:
        #expect(suppressed == [.openShow])
      default:
        #expect(
          suppressed == serverPair,
          "browse surfaces suppress the placement-gated server pair and nothing else")
      }
    }
  }

  /// A leading Up Next toolbar button's Liquid Glass shape would promise a lightweight affordance
  /// and then push a whole page. Viewing the queue belongs to the expanded player alone, so the
  /// root draws no toolbar control of its own. Nothing replaces it on Home, Library or Search
  /// either.
  @Test func theRootInstallsAddPodcastButNoQueueToolbarControl() {
    #expect(PodcastsViewPresentation.rootToolbarItems == ["Add Podcast"])
    #expect(
      PodcastsViewPresentation.rootToolbarItems.contains { $0.localizedCaseInsensitiveContains("up next") }
        == false)
  }

  private static func show(
    id: String, title: String? = nil, fingerprint: String? = nil
  ) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "podcast", title: title ?? "Show \(id)", author: "Publisher",
      durationSeconds: nil, category: .podcast, podcastFeedFingerprint: fingerprint)
  }

  private static func fingerprint(_ hexDigit: Character) -> String {
    String(repeating: String(hexDigit), count: PodcastFeedIdentity.fingerprintCharacterCount)
  }

  @MainActor
  private static func makeComposition() throws -> RootComposition {
    let database = try AppDatabase.inMemory()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-podcasts-view-" + UUID().uuidString, isDirectory: true)
    return RootComposition(
      hardware: PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering()),
      mode: .automatic,
      database: database,
      applicationSupportDirectory: directory, watchCompanionRuntime: nil)
  }

  private static func episode(itemID: String, episodeID: String) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID, showTitle: "Show", showAuthor: "Publisher", episodeID: episodeID,
      title: "Episode", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      durationSeconds: 1_800)
  }

  private static func continueItem(id: String) -> HomeItem {
    HomeItem(
      serverItemId: id, title: "Show \(id)", author: "Publisher", category: .podcast,
      durationSeconds: 1_800, progressSeconds: 600, isFinished: false,
      addedAt: Date(timeIntervalSince1970: 1), isDownloaded: false,
      episodeID: "episode-\(id)", episodeTitle: "Episode")
  }

  // MARK: - Shows

  private static func snapshot(
    _ mode: PodcastShowSortMode, _ shows: [ItemSummary]
  ) -> PodcastShowsSnapshot {
    PodcastShowsSnapshot(mode: mode, shows: shows)
  }

  @Test("every state that carries cached shows renders them, settled or not")
  func everyStateCarryingShowsRendersThem() {
    let shows = [Self.show(id: "a"), Self.show(id: "b")]
    let snapshot = Self.snapshot(.alphabetical, shows)

    #expect(PodcastsViewPresentation.shows(in: .loaded(snapshot)) == shows)
    #expect(PodcastsViewPresentation.shows(in: .partiallySynced(snapshot)) == shows)
    #expect(PodcastsViewPresentation.shows(in: .staleOffline(snapshot)) == shows)
  }

  @Test("show order is preserved, never re-sorted for the grid")
  func showOrderIsPreserved() {
    let shows = [Self.show(id: "c"), Self.show(id: "a"), Self.show(id: "b")]
    let snapshot = Self.snapshot(.custom, shows)
    #expect(PodcastsViewPresentation.shows(in: .loaded(snapshot)).map(\.serverItemId) == ["c", "a", "b"])
  }

  @Test("states that carry no shows produce none")
  func statesWithoutShowsProduceNone() {
    #expect(PodcastsViewPresentation.shows(in: .loading).isEmpty)
    #expect(PodcastsViewPresentation.shows(in: .empty).isEmpty)
    #expect(PodcastsViewPresentation.shows(in: .error).isEmpty)
  }

  // MARK: - Root preview and navigable heading

  @MainActor
  @Test("the root preview is the first eight shows, in the store's order")
  func yourShowsPreviewUsesFirstEightOrderedShows() async {
    let shows = (1...10).map { Self.show(id: "\($0)") }
    let model = Self.makeShowsModel(shows, mode: .custom)
    await waitUntil { model.state != .loading }

    let preview = model.preview(limit: PodcastsViewPresentation.previewLimit)
    #expect(preview.map(\.serverItemId) == shows.prefix(8).map(\.serverItemId))
  }

  @MainActor
  @Test("fewer shows than the cap means the preview is every show, not a padded grid")
  func yourShowsPreviewUsesAllShowsWhenFewerThanCap() async {
    let shows = (1...3).map { Self.show(id: "\($0)") }
    let model = Self.makeShowsModel(shows, mode: .alphabetical)
    await waitUntil { model.state != .loading }

    let preview = model.preview(limit: PodcastsViewPresentation.previewLimit)
    #expect(preview.map(\.serverItemId) == shows.map(\.serverItemId))
  }

  /// The root's preview and the all-shows page (`PodcastShowsView`) read the same model. A preview
  /// is never a second sort, only a shorter prefix of the identical sequence that
  /// `PodcastShowsViewPresentation.shows(in:)` renders unbounded.
  @MainActor
  @Test("the root's preview is a literal prefix of the all-shows page's own order")
  func rootAndAllShowsPageShareTheSameOrder() async {
    let shows = [
      Self.show(id: "z"), Self.show(id: "m"), Self.show(id: "a"), Self.show(id: "q"),
      Self.show(id: "b"), Self.show(id: "y"), Self.show(id: "c"),
    ]
    let model = Self.makeShowsModel(shows, mode: .custom)
    await waitUntil { model.state != .loading }

    let preview = model.preview(limit: PodcastsViewPresentation.previewLimit)
    let allShows = PodcastShowsViewPresentation.shows(in: model.state)

    #expect(allShows.map(\.serverItemId) == shows.map(\.serverItemId))
    #expect(preview == Array(allShows.prefix(PodcastsViewPresentation.previewLimit)))
  }

  // MARK: - Overflow footer

  @Test("the footer counts every show once the preview hides some")
  func showsFooterTitleCountsEveryShowWhenSomeAreHidden() {
    #expect(PodcastsViewPresentation.showsFooterTitle(totalCount: 47, shownCount: 8) == "All 47 Shows")
    #expect(PodcastsViewPresentation.showsFooterTitle(totalCount: 9, shownCount: 8) == "All 9 Shows")
  }

  @Test("no footer when the grid already shows every show")
  func showsFooterTitleIsAbsentWhenNothingIsHidden() {
    #expect(PodcastsViewPresentation.showsFooterTitle(totalCount: 8, shownCount: 8) == nil)
    #expect(PodcastsViewPresentation.showsFooterTitle(totalCount: 3, shownCount: 3) == nil)
    #expect(PodcastsViewPresentation.showsFooterTitle(totalCount: 0, shownCount: 0) == nil)
  }

  @Test("the Shows chip lists everything, so it never gets a footer")
  func showsChipNeverGetsAFooter() {
    let server = (1...20).map { Self.show(id: "s\($0)") }
    let limit = PodcastsViewPresentation.showsSectionLimit(
      filter: .yourShows, columnWidth: 390, horizontalSizeClass: .compact,
      isAccessibilitySize: false)
    let shown = PodcastsViewPresentation.showsSectionShows(
      nativeShows: [], nativeMode: .alphabetical,
      serverShows: server, serverMode: .alphabetical,
      nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: true, limit: limit)
    #expect(PodcastsViewPresentation.showsFooterTitle(totalCount: 20, shownCount: shown.count) == nil)
  }

  @Test("the heading is reachable whenever the ordered snapshot carries any show, even under the cap")
  func yourShowsHeadingIsReachableWheneverShowsExist() {
    let snapshot = Self.snapshot(.alphabetical, [Self.show(id: "a")])

    #expect(PodcastsViewPresentation.showsHeadingIsReachable(in: .loaded(snapshot)))
    #expect(PodcastsViewPresentation.showsHeadingIsReachable(in: .partiallySynced(snapshot)))
    #expect(PodcastsViewPresentation.showsHeadingIsReachable(in: .staleOffline(snapshot)))
    #expect(PodcastsViewPresentation.showsHeadingIsReachable(in: .loading) == false)
    #expect(PodcastsViewPresentation.showsHeadingIsReachable(in: .empty) == false)
    #expect(PodcastsViewPresentation.showsHeadingIsReachable(in: .error) == false)
  }

  @Test("the heading's hint names both the destination and its editing controls")
  func yourShowsHeadingHintNamesAllShowsAndEditing() {
    #expect(
      PodcastsViewPresentation.showsHeadingAccessibilityHint
        == "Shows all podcasts and editing controls.")
  }

  // MARK: - Merged Your Shows preview

  /// Server order strips a leading article (`ItemSortTitle.derive`) before sorting; native order
  /// does not. Stripped, "Daily" sorts ahead of "Middle Ground", so only a true merge lands the
  /// server show between the two native ones; a native block then a server block does not.
  @Test(
    "both sources alphabetical merge by one shared, article-stripped key - not by a naive title compare or a block concatenation"
  )
  func mergedPreviewAlphabeticalUsesSharedArticleStrippedKey() {
    // Native's SQL order (`feed.title COLLATE NOCASE, feed.id`, no article stripping) puts "The
    // Daily" (T) ahead of "Zephyr Show" (Z), as given here.
    let native = [
      Self.show(id: "rss:1", title: "The Daily"),
      Self.show(id: "rss:2", title: "Zephyr Show"),
    ]
    let server = [Self.show(id: "abs:1", title: "Middle Ground")]

    let preview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .alphabetical,
      server: server, serverMode: .alphabetical,
      limit: 10)

    // An unstripped compare, or a plain concatenation, would place "Middle Ground" (M) ahead of
    // "The Daily" (T), or after "Zephyr Show" entirely. Only the shared stripped key ("daily" <
    // "middle ground" < "zephyr show") lands it in between.
    #expect(preview.map(\.serverItemId) == ["rss:1", "abs:1", "rss:2"])
  }

  @Test("a shared-key tie keeps the native show ahead of the server show, matching downloadedShows' convention")
  func mergedPreviewTiesKeepNativeAheadOfServer() {
    let native = [Self.show(id: "rss:1", title: "Same Title")]
    let server = [Self.show(id: "abs:1", title: "Same Title")]

    let preview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .alphabetical,
      server: server, serverMode: .alphabetical,
      limit: 10)

    #expect(preview.map(\.serverItemId) == ["rss:1", "abs:1"])
  }

  @Test(
    "any mode other than both-alphabetical concatenates the native block, then the server block, each in its own order")
  func mergedPreviewConcatenatesUnlessBothSourcesAreAlphabetical() {
    // Out of alphabetical order on both sides. A custom or most-recent order must survive
    // untouched, never re-sorted by either block.
    let native = [Self.show(id: "rss:2", title: "Zebra"), Self.show(id: "rss:1", title: "Apple")]
    let server = [Self.show(id: "abs:2", title: "Yak"), Self.show(id: "abs:1", title: "Banana")]
    let nonAlphabeticalCombinations: [(native: NativePodcastShowSortMode, server: PodcastShowSortMode)] = [
      (.custom, .alphabetical),
      (.alphabetical, .custom),
      (.custom, .custom),
      (.mostRecent, .alphabetical),
      (.mostRecent, .custom),
    ]

    for combination in nonAlphabeticalCombinations {
      let preview = PodcastsViewPresentation.mergedShowsPreview(
        native: native, nativeMode: combination.native,
        server: server, serverMode: combination.server,
        limit: 10)

      #expect(
        preview.map(\.serverItemId) == ["rss:2", "rss:1", "abs:2", "abs:1"],
        "native: \(combination.native), server: \(combination.server)")
    }
  }

  /// The cap applies to the whole candidate pool the concatenation branch builds, not to each
  /// source pre-capped and then combined. A per-source pre-cap would leave only two native shows
  /// and two server shows here (an even split) instead of exhausting the native block first.
  @Test("the cap is applied to the full candidate pool, never per source before combining")
  func mergedPreviewCapAppliesToTheWholePoolNotPerSource() {
    let native = (1...4).map { Self.show(id: "rss:\($0)") }
    let server = (1...4).map { Self.show(id: "abs:\($0)") }

    let preview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .custom,
      server: server, serverMode: .custom,
      limit: 6)

    #expect(preview.map(\.serverItemId) == ["rss:1", "rss:2", "rss:3", "rss:4", "abs:1", "abs:2"])
  }

  @Test("a negative or zero limit produces no preview")
  func mergedPreviewNegativeOrZeroLimitIsEmpty() {
    let native = [Self.show(id: "rss:1")]
    let server = [Self.show(id: "abs:1")]

    for limit in [0, -1, -6] {
      #expect(
        PodcastsViewPresentation.mergedShowsPreview(
          native: native, nativeMode: .alphabetical,
          server: server, serverMode: .alphabetical,
          limit: limit
        ).isEmpty)
    }
  }

  @Test("the merged section gates each source without changing either source's order")
  func mergedSectionRespectsSourceAvailability() {
    let native = [Self.show(id: "rss:1", title: "Followed")]
    let server = [Self.show(id: "server-1", title: "Server")]

    #expect(
      PodcastsViewPresentation.showsSectionShows(
        nativeShows: native, nativeMode: .alphabetical,
        serverShows: server, serverMode: .alphabetical,
        nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: true
      )
      .map(\.serverItemId) == ["rss:1", "server-1"])
    #expect(
      PodcastsViewPresentation.showsSectionShows(
        nativeShows: native, nativeMode: .alphabetical,
        serverShows: server, serverMode: .alphabetical,
        nativeSubscriptionsEnabled: false, hasIncludedPodcastLibrary: true
      )
      .map(\.serverItemId) == ["server-1"])
    #expect(
      PodcastsViewPresentation.showsSectionShows(
        nativeShows: native, nativeMode: .alphabetical,
        serverShows: server, serverMode: .alphabetical,
        nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: false
      )
      .map(\.serverItemId) == ["rss:1"])
    #expect(
      PodcastsViewPresentation.showsSectionIsReachable(
        nativeShows: native, nativeMode: .alphabetical,
        serverShows: server, serverMode: .alphabetical,
        nativeSubscriptionsEnabled: false, hasIncludedPodcastLibrary: false) == false)
  }

  @Test("source-neutral show status handles partial, offline, and excluded projections")
  func mergedSectionStatusUsesOnlyParticipatingSources() {
    let native = [Self.show(id: "rss:1")]
    let server = [Self.show(id: "server-1")]
    let nativeSnapshot = NativePodcastShowsSnapshot(mode: .alphabetical, shows: native)
    let serverSnapshot = Self.snapshot(.alphabetical, server)

    #expect(
      PodcastsViewPresentation.showsSectionStatus(
        nativeShows: [], nativeState: .loading,
        serverShows: [], serverState: .partiallySynced(Self.snapshot(.alphabetical, [])),
        nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: true) == .loading)
    #expect(
      PodcastsViewPresentation.showsSectionStatus(
        nativeShows: native, nativeState: .loaded(nativeSnapshot),
        serverShows: [], serverState: .error,
        nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: true) == .content)
    #expect(
      PodcastsViewPresentation.showsSectionStatus(
        nativeShows: [], nativeState: .empty,
        serverShows: server, serverState: .staleOffline(serverSnapshot),
        nativeSubscriptionsEnabled: false, hasIncludedPodcastLibrary: true) == .content)
    #expect(
      PodcastsViewPresentation.showsSectionStatus(
        nativeShows: [], nativeState: .loading,
        serverShows: [], serverState: .error,
        nativeSubscriptionsEnabled: false, hasIncludedPodcastLibrary: false) == .empty)
    #expect(
      PodcastsViewPresentation.showsSectionStatus(
        nativeShows: [], nativeState: .empty,
        serverShows: [], serverState: .error,
        nativeSubscriptionsEnabled: false, hasIncludedPodcastLibrary: true) == .error)
  }

  @Test("empty shows surface importing only when direct subscriptions are available")
  func emptyShowsSurfaceImportWhenAvailable() {
    let nativeOnly = PodcastsViewPresentation.emptyState(
      for: .yourShows, nativeSubscriptionsEnabled: true)
    let serverOnly = PodcastsViewPresentation.emptyState(
      for: .yourShows, nativeSubscriptionsEnabled: false)

    #expect(nativeOnly.title == serverOnly.title)
    #expect(nativeOnly.message == "Add a podcast or import subscriptions from another app.")
    #expect(serverOnly.message == "Your shows will appear here.")
    #expect(nativeOnly.actionLabel == "Add Podcast")
    #expect(serverOnly.actionLabel == nil)
  }

  @Test("root all-filter loading ignores disabled and excluded show projections")
  func allFilterLoadingIgnoresUnavailableShowSources() {
    // The episode shelves still form the empty-screen loading barrier when the two show projections
    // have already settled empty.
    let knownEmptyServer = PodcastShowsModel.State.loaded(Self.snapshot(.alphabetical, []))
    let knownEmptyNative = NativePodcastShowsModel.State.loaded(
      NativePodcastShowsSnapshot(mode: .alphabetical, shows: []))
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .all,
        continueListening: .loading,
        latestEpisodes: .empty,
        shows: knownEmptyServer,
        nativeShows: knownEmptyNative,
        nativeSubscriptionsEnabled: true,
        hasIncludedPodcastLibrary: true,
        hasContent: false) == .loading)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .all,
        continueListening: .loading,
        latestEpisodes: .empty,
        shows: .empty,
        nativeShows: .empty,
        nativeSubscriptionsEnabled: true,
        hasIncludedPodcastLibrary: true,
        hasContent: false) == .loading)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .all,
        continueListening: .empty,
        latestEpisodes: .loading,
        shows: knownEmptyServer,
        nativeShows: knownEmptyNative,
        nativeSubscriptionsEnabled: true,
        hasIncludedPodcastLibrary: true,
        hasContent: false) == .loading)

    #expect(
      PodcastsViewPresentation.placeholder(
        for: .all,
        continueListening: .loading,
        latestEpisodes: .loading,
        shows: .loading,
        nativeShows: .loading,
        nativeSubscriptionsEnabled: false,
        hasIncludedPodcastLibrary: false,
        hasContent: false) == .loading)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .all,
        continueListening: .empty,
        latestEpisodes: .empty,
        shows: .loading,
        nativeShows: .loading,
        nativeSubscriptionsEnabled: false,
        hasIncludedPodcastLibrary: false,
        hasContent: false) == .empty)
    #expect(
      PodcastsViewPresentation.placeholder(
        for: .downloaded,
        continueListening: .empty,
        latestEpisodes: .empty,
        shows: .error,
        nativeShows: .loading,
        nativeSubscriptionsEnabled: false,
        hasIncludedPodcastLibrary: false,
        hasContent: false) == .empty)
  }

  @Test("all leading server collisions are filtered before the preview cap")
  func mergedPreviewFiltersCollisionsBeforeApplyingLimit() {
    let twinFingerprint = Self.fingerprint("a")
    let native = [Self.show(id: "rss:1", title: "Twin Show", fingerprint: twinFingerprint)]
    let server =
      (1...6).map {
        Self.show(id: "abs:twin-\($0)", title: "Twin Show", fingerprint: twinFingerprint)
      }
      + [Self.show(id: "abs:solo", title: "Solo Show", fingerprint: Self.fingerprint("b"))]

    let preview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .custom,
      server: server, serverMode: .custom,
      limit: 2)

    // Capping before filtering would return the native row and the first server twin. The later
    // unmatched row fills the second slot only once every collision is removed first.
    #expect(preview.map(\.serverItemId) == ["rss:1", "abs:solo"])
  }

  @Test("duplicate native fingerprints remain while every matching server row is suppressed")
  func mergedPreviewPreservesNativeDuplicatesAndFiltersMultipleServerRowsPerFingerprint() {
    let firstFingerprint = Self.fingerprint("a")
    let secondFingerprint = Self.fingerprint("b")
    let native = [
      Self.show(id: "rss:1", fingerprint: firstFingerprint),
      Self.show(id: "rss:2", fingerprint: firstFingerprint),
      Self.show(id: "rss:3", fingerprint: secondFingerprint),
    ]
    let server = [
      Self.show(id: "abs:first-1", fingerprint: firstFingerprint),
      Self.show(id: "abs:first-2", fingerprint: firstFingerprint),
      Self.show(id: "abs:second", fingerprint: secondFingerprint),
      Self.show(id: "abs:unmatched", fingerprint: Self.fingerprint("c")),
    ]

    let preview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .custom,
      server: server, serverMode: .custom,
      limit: 20)

    #expect(preview.map(\.serverItemId) == ["rss:1", "rss:2", "rss:3", "abs:unmatched"])
  }

  @Test("nil and malformed fingerprints fail open without creating an association")
  func mergedPreviewKeepsNilAndMalformedFingerprintRows() {
    let validFingerprint = Self.fingerprint("a")
    let malformedFingerprint = "not-a-fingerprint"
    let native = [
      Self.show(id: "rss:valid", fingerprint: validFingerprint),
      Self.show(id: "rss:malformed", fingerprint: malformedFingerprint),
      Self.show(id: "rss:nil", fingerprint: nil),
    ]
    let server = [
      Self.show(id: "abs:valid", fingerprint: validFingerprint),
      Self.show(id: "abs:malformed", fingerprint: malformedFingerprint),
      Self.show(id: "abs:nil", fingerprint: nil),
    ]

    let preview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .custom,
      server: server, serverMode: .custom,
      limit: 20)

    #expect(preview.map(\.serverItemId) == ["rss:valid", "rss:malformed", "rss:nil", "abs:malformed", "abs:nil"])
  }

  @Test("same-title shows with different feed fingerprints both remain visible")
  func mergedPreviewDoesNotUseTitleAsCollisionIdentity() {
    let native = [
      Self.show(
        id: "rss:one", title: "Same Title", fingerprint: Self.fingerprint("a"))
    ]
    let server = [
      Self.show(
        id: "abs:other", title: "Same Title", fingerprint: Self.fingerprint("b"))
    ]

    let preview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .alphabetical,
      server: server, serverMode: .alphabetical,
      limit: 20)

    #expect(preview.map(\.serverItemId) == ["rss:one", "abs:other"])
  }

  @Test("native-disabled root previews keep matching server shows visible")
  func mergedSectionNativeOffKeepsServerCollisionVisible() {
    let fingerprint = Self.fingerprint("a")
    let native = [Self.show(id: "rss:one", fingerprint: fingerprint)]
    let server = [Self.show(id: "abs:one", fingerprint: fingerprint)]

    #expect(
      PodcastsViewPresentation.showsSectionShows(
        nativeShows: native, nativeMode: .alphabetical,
        serverShows: server, serverMode: .alphabetical,
        nativeSubscriptionsEnabled: false, hasIncludedPodcastLibrary: true
      )
      .map(\.serverItemId) == ["abs:one"])
  }

  @Test("filtering a collision preserves custom server order and alphabetical shared-key order")
  func mergedPreviewFilteringPreservesOrderingRules() {
    let collisionFingerprint = Self.fingerprint("a")
    let native = [
      Self.show(id: "rss:custom", title: "Native", fingerprint: collisionFingerprint)
    ]
    let customServer = [
      Self.show(id: "abs:removed", title: "First", fingerprint: collisionFingerprint),
      Self.show(id: "abs:second", title: "Second", fingerprint: Self.fingerprint("b")),
      Self.show(id: "abs:first", title: "First Available", fingerprint: Self.fingerprint("c")),
    ]
    let customPreview = PodcastsViewPresentation.mergedShowsPreview(
      native: native, nativeMode: .custom,
      server: customServer, serverMode: .custom,
      limit: 20)
    #expect(customPreview.map(\.serverItemId) == ["rss:custom", "abs:second", "abs:first"])

    let alphabeticalNative = [
      Self.show(id: "rss:zulu", title: "Zulu", fingerprint: collisionFingerprint)
    ]
    let alphabeticalServer = [
      Self.show(id: "abs:removed", title: "Aaron", fingerprint: collisionFingerprint),
      Self.show(id: "abs:middle", title: "Middle", fingerprint: Self.fingerprint("b")),
      Self.show(id: "abs:daily", title: "The Daily", fingerprint: Self.fingerprint("c")),
    ]
    let alphabeticalPreview = PodcastsViewPresentation.mergedShowsPreview(
      native: alphabeticalNative, nativeMode: .alphabetical,
      server: alphabeticalServer, serverMode: .alphabetical,
      limit: 20)
    #expect(alphabeticalPreview.map(\.serverItemId) == ["abs:daily", "abs:middle", "rss:zulu"])
  }

  // MARK: - Cover sizing

  /// The latest-episodes list is an index to scan, not a shelf to browse. The thumbnail stays far
  /// below show-tile size, since anything bigger lets the artwork, not the text, decide how many
  /// episodes fit on a screen. The card decides which square. `HomeMoreView` lists the same card,
  /// and the two drew covers 12pt apart while both claimed to match.
  @Test("the episode thumbnail is the shared card square, far smaller than a show tile's cover")
  func episodeThumbnailIsSmall() {
    #expect(PodcastsViewPresentation.episodeThumbnailSize == PodcastEpisodeCardRowMetrics.coverSize)
    #expect(PodcastEpisodeCardRowMetrics.coverSize > WhirrMetric.minimumTouchTarget)
    #expect(PodcastsViewPresentation.episodeThumbnailSize < PodcastsViewPresentation.showGridMinimumWidth / 2)
  }

  @Test("show tile width includes both editorial surface insets")
  func showTileWidthPreservesTheCoverMetricInsideItsCard() {
    #expect(
      PodcastsViewPresentation.showGridTileWidth
        == PodcastsViewPresentation.showGridMinimumWidth + 2 * WhirrSpacing.small)
  }

  @Test("the episode separator starts after the thumbnail")
  func episodeSeparatorLeadingInsetMatchesTheOldDivider() {
    #expect(
      PodcastsViewPresentation.episodeSeparatorLeadingInset
        == PodcastsViewPresentation.episodeThumbnailSize + WhirrSpacing.medium * 2)
  }

  // MARK: - Show tile height

  /// A show without a publisher has no author line, so it sat shorter than its neighbours that had
  /// one. The line is always reserved, so the view needs one answer to "is there an author to
  /// draw". Blank counts as absent.
  @Test("a blank author is the same as no author, so the reserved line renders empty either way")
  func blankAuthorIsTreatedAsAbsent() {
    #expect(PodcastsViewPresentation.showTileAuthor(nil) == nil)
    #expect(PodcastsViewPresentation.showTileAuthor("") == nil)
    #expect(PodcastsViewPresentation.showTileAuthor("   ") == nil)
    #expect(PodcastsViewPresentation.showTileAuthor("\n\t ") == nil)
  }

  @Test("a real author survives, trimmed of the whitespace a feed padded it with")
  func realAuthorIsKeptAndTrimmed() {
    #expect(PodcastsViewPresentation.showTileAuthor("Publisher") == "Publisher")
    #expect(PodcastsViewPresentation.showTileAuthor("  Publisher\n") == "Publisher")
  }

  /// The credential-recovery line is the exception to reserving a line unconditionally. Most feeds
  /// never need recovering, and reserving it anyway left a blank caption line under every publisher
  /// in the grid. The tile grew a line for a notice nothing was showing.
  @Test("no show in the grid needs attention, so the recovery line takes no height at all")
  func attentionRowIsOmittedWhenNoShowNeedsIt() {
    #expect(
      PodcastsViewPresentation.showTileAttentionRow(
        needsAttention: false, gridNeedsAttention: false) == .omitted)
  }

  /// Once one show in the grid carries the notice, its neighbours reserve the same line, so the
  /// row's tiles stay one height rather than one tile standing a caption taller than the rest.
  @Test("one show needing attention reserves the line on its neighbours, and draws it on itself")
  func attentionRowIsReservedAcrossTheGridThatShowsIt() {
    #expect(
      PodcastsViewPresentation.showTileAttentionRow(
        needsAttention: false, gridNeedsAttention: true) == .reserved)
    #expect(
      PodcastsViewPresentation.showTileAttentionRow(
        needsAttention: true, gridNeedsAttention: true) == .shown)
  }

  // MARK: - Tile provenance

  /// Reuses `PodcastSourceIdentity`'s existing `rss:`-namespace decode rather than adding a source
  /// tag. `downloadedShows` and `PodcastSettingsViewPresentation` make the same decision.
  @Test("provenance is a fact about the show's source, derived from its item id")
  func showTileIsServerSourcedReadsThePodcastSourceIdentity() throws {
    let nativeShow = Self.show(id: try #require(PodcastSourceIdentity.rss(feedId: 1)).itemId)
    let serverShow = Self.show(id: "abs-show")

    #expect(PodcastsViewPresentation.showTileIsServerSourced(nativeShow) == false)
    #expect(PodcastsViewPresentation.showTileIsServerSourced(serverShow))
  }

  /// Only the exception is marked: a badge on every tile is texture rather than signal, and the
  /// followed feed is the tab's norm.
  @Test("the server tile is marked in a mixed grid and the followed tile never is")
  func onlyTheServerTileIsMarkedInAMixedGrid() {
    #expect(
      PodcastsViewPresentation.showTileSourceMark(
        isServerSourced: true, gridMixesSources: true) == .server)
    #expect(
      PodcastsViewPresentation.showTileSourceMark(
        isServerSourced: false, gridMixesSources: true) == nil)
  }

  /// A grid holding one kind of show names its provenance in its own title. The two source pages
  /// always do, and the root grid does too whenever native subscriptions are off or nothing is
  /// followed. Marking every tile there would say nothing.
  @Test("a single-source grid marks nothing, whichever source it holds")
  func aSingleSourceGridMarksNothing() {
    #expect(
      PodcastsViewPresentation.showTileSourceMark(
        isServerSourced: true, gridMixesSources: false) == nil)
    #expect(
      PodcastsViewPresentation.showTileSourceMark(
        isServerSourced: false, gridMixesSources: false) == nil)

    #expect(PodcastsViewPresentation.gridMixesSources(tilesAreServerSourced: [true, false]))
    #expect(
      PodcastsViewPresentation.gridMixesSources(tilesAreServerSourced: [true, true]) == false)
    #expect(
      PodcastsViewPresentation.gridMixesSources(tilesAreServerSourced: [false, false]) == false)
    #expect(PodcastsViewPresentation.gridMixesSources(tilesAreServerSourced: []) == false)
  }

  /// The mark is decorative, so its label is all VoiceOver has left of the caption line it
  /// replaced. The label must name the source, not repeat a heading.
  @Test("the source mark speaks the provenance its caption line used to read")
  func sourceMarkSpeaksItsProvenance() {
    #expect(
      PodcastsViewPresentation.ShowTileSourceMark.server.accessibilityLabel
        == PodcastsViewPresentation.serverProvenanceLabel)
  }

  /// The third caption line is recovery's alone. A server-sourced tile does not reserve it, which
  /// is the point of moving provenance onto the artwork.
  @Test("the reserved third line answers only to recovery")
  func thirdLineIsReservedOnlyForRecovery() {
    #expect(
      PodcastsViewPresentation.showTileAttentionRow(
        needsAttention: false, gridNeedsAttention: false) == .omitted)
  }

  // MARK: - Loading

  @Test("the screen is loading only while every one of the three models is still loading")
  func loadingOnlyWhileEveryModelIsLoading() {
    #expect(
      PodcastsViewPresentation.isLoading(
        continueListening: .loading, latestEpisodes: .loading, shows: .loading))
  }

  /// A slow show list must not blank episodes that have already arrived. Holding the whole screen
  /// at `.loading` while any model is still loading is the defect this guards against.
  @Test("one settled model is enough to start rendering, whatever the other two are doing")
  func oneSettledModelIsEnoughToRender() {
    #expect(
      PodcastsViewPresentation.isLoading(
        continueListening: .loaded, latestEpisodes: .loading, shows: .loading) == false)
    #expect(
      PodcastsViewPresentation.isLoading(
        continueListening: .loading, latestEpisodes: .empty, shows: .loading) == false)
    #expect(
      PodcastsViewPresentation.isLoading(
        continueListening: .loading, latestEpisodes: .loading, shows: .empty) == false)
    #expect(
      PodcastsViewPresentation.isLoading(
        continueListening: .loading, latestEpisodes: .loading, shows: .error) == false)
  }

  @Test("loading, empty, and an unserved shows error stay over one scroll host")
  func nonLoadedStatesUseNonInterceptingOverlayPlaceholders() {
    let states: [(HomeModel.State, HomeMoreModel.State, PodcastShowsModel.State)] = [
      (.loading, .loading, .loading),
      (.empty, .empty, .empty),
      (.empty, .empty, .error),
    ]

    for (listening, latest, shows) in states {
      let placeholder = PodcastsViewPresentation.placeholder(
        continueListening: listening, latestEpisodes: latest, shows: shows, hasContent: false)

      #expect(placeholder != nil)
      if shows == .error {
        #expect(placeholder?.allowsHitTesting == true)
      } else {
        #expect(placeholder?.allowsHitTesting == false)
      }
    }

    #expect(
      PodcastsViewPresentation.placeholder(
        continueListening: .empty, latestEpisodes: .empty, shows: .error, hasContent: false)?.action
        == .retry)

    #expect(
      PodcastsViewPresentation.placeholder(
        continueListening: .loaded, latestEpisodes: .loaded, shows: .error, hasContent: true)
        == nil)
  }

  // MARK: - Episode card routing

  /// The anti-drift test: every cross-show episode surface's tap resolves to the episode card, not
  /// a show push. A surface added to `CrossShowEpisodeSurface` that resolves to `nil` (in practice,
  /// a show push) fails here.
  @Test(arguments: CrossShowEpisodeSurface.allCases)
  func everyCrossShowEpisodeSurfaceOpensTheCard(surface: CrossShowEpisodeSurface) {
    #expect(surface.resolvedEpisodeRef != nil)
  }

  // MARK: - Episode swipe actions

  @Test("latest episode swipes treat every row as server-available")
  func latestEpisodeSwipeActionsUseServerAvailabilityConstant() {
    let buttons = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: "show-1",
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(buttons?.trailing.map(\.id) == ["download", "mark-as-finished"])
  }

  @Test("latest episode leading swipe promotes or starts the row based on playback identity")
  func latestEpisodeLeadingSwipeFollowsPlaybackIdentity() {
    let nothingPlaying = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: "show-1",
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: nil,
      isPlaybackIntended: false)
    let differentEpisodePlaying = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: "show-1",
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: .podcastEpisode(itemID: "show-2", episodeID: "episode-2"),
      isPlaybackIntended: false)
    let rowIsPlaying = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: "show-1",
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: .podcastEpisode(itemID: "show-1", episodeID: "episode-1"),
      isPlaybackIntended: true)

    #expect(nothingPlaying?.leading.map(\.id) == ["play-pause"])
    #expect(differentEpisodePlaying?.leading.map(\.id) == ["play-next"])
    #expect(rowIsPlaying?.leading.map(\.id) == ["play-pause"])
    #expect(rowIsPlaying?.leading.map(\.label) == ["Pause"])
  }

  /// Swipe right offers Play Next on native-feed podcasts too.
  ///
  /// `ListeningIdentity.podcastEpisode` accepts only the ABS namespace, so an `rss:` item id yields
  /// `nil`, which the swipe policy reads as "not queueable" and withdraws the leading edge once the
  /// player holds anything. Only `ListeningQueueActionPolicy.identity` maps the reserved namespace
  /// onto `.rssEpisode`, so both podcast surfaces must resolve through it. Other fixtures were all
  /// ABS-shaped; only a reserved-prefix id catches this.
  @Test("a native-feed row keeps its leading swipe while something else is playing")
  func latestEpisodeLeadingSwipeSurvivesANativeFeedItemID() {
    let nativeFeedItemID = "\(PodcastSourceIdentity.reservedPrefix)7"

    let nothingPlaying = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: nativeFeedItemID,
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: nil,
      isPlaybackIntended: false)
    let differentEpisodePlaying = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: nativeFeedItemID,
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: .podcastEpisode(itemID: "show-2", episodeID: "episode-2"),
      isPlaybackIntended: false)
    let rowIsPlaying = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: nativeFeedItemID,
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: .rssEpisode(feedID: 7, episodeID: "episode-1"),
      isPlaybackIntended: true)

    #expect(nothingPlaying?.leading.map(\.id) == ["play-pause"])
    #expect(differentEpisodePlaying?.leading.map(\.id) == ["play-next"])
    #expect(rowIsPlaying?.leading.map(\.id) == ["play-pause"])
    #expect(rowIsPlaying?.leading.map(\.label) == ["Pause"])
  }

  @Test("latest episode trailing swipe removes a present download before finishing")
  func latestEpisodeTrailingSwipeUsesRemoveDownloadWhenPresent() {
    let buttons = PodcastsViewPresentation.swipeButtons(
      deviceAction: .remove,
      itemID: "show-1",
      episodeID: "episode-1",
      playbackStatus: nil,
      nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(buttons?.trailing.map(\.id) == ["remove-download", "mark-as-finished"])
  }

  @Test("a part-played latest episode preserves the compact two-capsule swipe")
  func partPlayedLatestEpisodePreservesCompactSwipe() {
    let buttons = PodcastsViewPresentation.swipeButtons(
      deviceAction: .download,
      itemID: "show-1",
      episodeID: "episode-1",
      playbackStatus: .inProgress,
      nowPlaying: nil,
      isPlaybackIntended: false)

    #expect(buttons?.trailing.map(\.id) == ["download", "mark-as-finished"])
  }

  // MARK: - PodcastShowsModel fixtures

  @MainActor
  private static func makeShowsModel(
    _ shows: [ItemSummary], mode: PodcastShowSortMode
  ) -> PodcastShowsModel {
    PodcastShowsModel(
      ordering: ShowsOrderingFixture(snapshot: PodcastShowsSnapshot(mode: mode, shows: shows)),
      library: Self.settledLibrary(),
      sync: FakeSyncCoordinating())
  }

  /// A settled aggregate sync status, always. These tests never exercise the running or stale
  /// branches.
  @MainActor
  private static func settledLibrary() -> FakeLibraryReading {
    let library = FakeLibraryReading()
    library.stubAggregateSyncStatus(
      LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date()))
    return library
  }

}

/// A settled, one-shot ordering snapshot. These tests only need the model to reach one steady
/// state, never a follow-up push.
private struct ShowsOrderingFixture: PodcastShowOrdering {
  let snapshot: PodcastShowsSnapshot

  func observeShows() -> AsyncStream<PodcastShowsSnapshot> {
    AsyncStream { continuation in
      continuation.yield(snapshot)
    }
  }

  func replaceCustomOrder(itemIDs: [String]) async throws {}
  func resetToAlphabetical() async throws {}
}
