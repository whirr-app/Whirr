#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import Foundation
  import Persistence
  import SwiftUI
  import SyncEngine

  extension UIHarness {
    enum PodcastScenario: String, CaseIterable {
      case malformed
      case empty
      case loading
      case offline
      case deviceDownloaded = "device-downloaded"
      case staleShow = "stale-show"
      /// The two longest device-status strings, which no earlier scenario produced, so a row that
      /// truncates or squeezes them out is visible here instead of only on a real cellular device.
      case downloadWaitingForWiFi = "download-waiting-wifi"
      case downloadFailed = "download-failed"
      /// Episodes cached, none matching the selected filter: the screen must blame the filter, not
      /// claim the cache is empty.
      case filteredEmpty = "filtered-empty"
      /// A long list whose last episode is downloading, its progress stepping at the production
      /// cadence (2% every 0.25 s), so a scroll that never reaches that row can be measured.
      case downloadTicking = "download-ticking"
    }

    enum PodcastHarnessFormFactor: String, CaseIterable {
      case compactPhone
      case regularPad
      case accessibilityPhone
      case accessibilityPad

      var maximumContentWidth: CGFloat {
        switch self {
        case .compactPhone, .accessibilityPhone: 430
        case .regularPad, .accessibilityPad:
          // Harness value for the audited landscape pane after the 280 pt sidebar. Production
          // responds to the width LibraryShellView proposes and must never read a constant like this.
          930
        }
      }

      var horizontalSizeClass: UserInterfaceSizeClass {
        switch self {
        case .compactPhone, .accessibilityPhone: .compact
        case .regularPad, .accessibilityPad: .regular
        }
      }

      var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .accessibilityPhone, .accessibilityPad: .accessibility3
        case .compactPhone, .regularPad: .large
        }
      }
    }

    static var podcastScenario: PodcastScenario {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_PODCAST"]
        .flatMap(PodcastScenario.init(rawValue:)) ?? .offline
    }

    static var podcastHarnessFormFactor: PodcastHarnessFormFactor {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_FORM_FACTOR"]
        .flatMap(PodcastHarnessFormFactor.init(rawValue:)) ?? .compactPhone
    }
  }

  extension UIHarnessRootView {
    /// `WHIRR_UI_HARNESS_SCREEN=podcasts`: the Podcasts root over fixture reads.
    ///
    /// Scenario fake: shows, follow state and episodes are synced account data. The root, its
    /// models and the navigation are the shipping ones; `UIHarness.PodcastScenario` selects the
    /// empty, offline, stale and download states.
    var podcastsBody: some View {
      HarnessPodcastsScreen(session: session)
    }

    /// `WHIRR_UI_HARNESS_SCREEN=podcasts-notification-offer`. Everything the offer reads is in
    /// memory, so both buttons work and nothing is persisted or prompted for.
    var podcastsNotificationOfferBody: some View {
      HarnessPodcastsScreen(session: session, showsNotificationOffer: true)
    }

    var podcastShowBody: some View {
      let scenario = UIHarness.podcastScenario
      let content = NavigationStack {
        PodcastShowView(
          itemID: HarnessPodcastFixtures.showID,
          library: HarnessPodcastLibraryReading(),
          nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
          coverClient: session.coverClient,
          paletteService: session.paletteService,
          playback: session.playback,
          makeModel: {
            let model = PodcastShowModel(
              itemID: HarnessPodcastFixtures.showID,
              reading: HarnessPodcastReading(scenario: scenario),
              refreshing: HarnessPodcastRefreshing(scenario: scenario))
            if scenario == .filteredEmpty { model.filter = .downloaded }
            return model
          },
          onSearch: { _ in },
          onPresentEpisode: { _ in },
          onOpenShowSettings: { _ in },
          refreshOnAppear: scenario != .loading)
      }

      return applyingPodcastHarnessFormFactor(to: content)
    }

    private func applyingPodcastHarnessFormFactor<Content: View>(to content: Content) -> some View {
      let formFactor = UIHarness.podcastHarnessFormFactor
      return
        content
        .frame(maxWidth: formFactor.maximumContentWidth)
        .environment(\.horizontalSizeClass, formFactor.horizontalSizeClass)
        // A simulated form factor has to reach sheet sizing too, or a sheet raised from this screen
        // would size itself against the device the harness is running on.
        .windowHorizontalSizeClass(formFactor.horizontalSizeClass)
        .dynamicTypeSize(formFactor.dynamicTypeSize)
    }
  }

  /// The Podcasts root's models, built from the harness reads the way `RootComposition` builds them
  /// from `HomeReading`/`LibraryReading`/`SyncCoordinating`. Held by the screen in `@State` so one
  /// subscription per model survives re-renders.
  @MainActor
  @Observable
  final class HarnessPodcastModels {
    /// A separately filtered subscription, as production gives the Podcasts root its own; the split
    /// keeps audiobook cards out of the Podcasts measurement.
    let listening: HomeModel
    /// The same latest-episodes model Home's shelf reads.
    let latest: HomeMoreModel
    let shows: PodcastShowsModel
    /// Native rows stay disabled in the ABS-only harness; the model still satisfies the real
    /// Podcasts root's complete composition without introducing a second harness variant.
    let nativeShows: NativePodcastShowsModel

    init() {
      let reading = HarnessHomeReading()
      let sync = HarnessSyncCoordinating()
      listening = HomeModel(
        home: reading, sync: sync, filter: .podcasts, savedShelf: HarnessSavedShelfReading())
      latest = HomeMoreModel(
        section: .newEpisodes, filter: .podcasts, home: reading, sync: sync)
      shows = PodcastShowsModel(
        ordering: HarnessPodcastShowOrdering(), library: HarnessLibraryReading(), sync: sync)
      nativeShows = NativePodcastShowsModel(reading: NoOpNativePodcastShowsReading())
    }
  }

  struct HarnessPodcastsScreen: View {
    let session: UIHarnessSession
    var showsNotificationOffer = false

    @State private var models = HarnessPodcastModels()

    var body: some View {
      let content = NavigationStack {
        // Two calls rather than one with optionals: `notificationOffer` is non-optional and defaults
        // to the production preference, so the plain Podcasts screen keeps that default exactly as
        // it had it (`nativeSubscriptionsEnabled: false` suppresses the offer there).
        if showsNotificationOffer {
          let offer = HarnessNotificationOffer.shared
          PodcastsView(
            listeningModel: models.listening,
            latestModel: models.latest,
            showsModel: models.shows,
            nativeShowsModel: offer.nativeShowsModel,
            hasIncludedPodcastLibrary: true,
            nativeSubscriptionsEnabled: true,
            coverClient: session.coverClient,
            paletteService: session.paletteService,
            downloadStatus: session.downloadStatus,
            playback: session.playback,
            actions: session.actions,
            notificationModel: offer.notificationModel,
            notificationOffer: offer.marker,
            onSelectShow: { _ in },
            onSelectDownloadedShow: { _ in },
            onSelectEpisode: { _, _ in },
            onOpenContinueListening: {},
            onOpenLatestEpisodes: {},
            onOpenShows: {},
            onAddFeed: {},
            onSearch: { _ in },
            introduction: AlreadySeenPodcastIntroduction()
          )
        } else {
          PodcastsView(
            listeningModel: models.listening,
            latestModel: models.latest,
            showsModel: models.shows,
            nativeShowsModel: models.nativeShows,
            hasIncludedPodcastLibrary: true,
            nativeSubscriptionsEnabled: false,
            coverClient: session.coverClient,
            paletteService: session.paletteService,
            downloadStatus: session.downloadStatus,
            playback: session.playback,
            actions: session.actions,
            onSelectShow: { _ in },
            onSelectDownloadedShow: { _ in },
            onSelectEpisode: { _, _ in },
            onOpenContinueListening: {},
            onOpenLatestEpisodes: {},
            onOpenShows: {},
            onAddFeed: {},
            onSearch: { _ in },
            introduction: AlreadySeenPodcastIntroduction()
          )
        }
      }
      .preferredColorScheme(UIHarness.harnessColorScheme)
      .uiHarnessMiniPlayer()
      .overlay {
        if UIHarness.runsScrollScript {
          UIHarnessScrollDriver()
        }
      }

      return applyingPodcastHarnessFormFactor(to: content)
    }

    private func applyingPodcastHarnessFormFactor<Content: View>(to content: Content) -> some View {
      let formFactor = UIHarness.podcastHarnessFormFactor
      return
        content
        .frame(maxWidth: formFactor.maximumContentWidth)
        .environment(\.horizontalSizeClass, formFactor.horizontalSizeClass)
        // A simulated form factor has to reach sheet sizing too, or a sheet raised from this screen
        // would size itself against the device the harness is running on.
        .windowHorizontalSizeClass(formFactor.horizontalSizeClass)
        .dynamicTypeSize(formFactor.dynamicTypeSize)
    }
  }

  nonisolated enum HarnessPodcastFixtures: Sendable {
    static let showID = "harness-podcast"
    static let now = Date()
    static let longNotesShowID = "harness-long-notes-show"
    static let longNotesEpisodeID = "harness-long-notes-episode"
    static let longNotesSentinel = "END OF NOTES ✂"
    static let downloadTickingEpisodeID = "ticking-downloading"

    private static let longNotesParagraphs = (1...72).map { index in
      "Field note \(index): The tide station, weather buoy, and distant transmitter describe the "
        + "same event from different angles. This deliberately repetitive paragraph keeps the "
        + "episode-card harness scroll range measurable at every card width."
    }

    /// Long plain-text notes for the card harness. The HTML form preserves the paragraph breaks
    /// through `FeedHTML.paragraphs`, while this value is the checkable display copy.
    static let longNotes =
      (longNotesParagraphs + [longNotesSentinel]).joined(separator: "\n\n")

    private static let longNotesHTML =
      longNotes.components(separatedBy: "\n\n").map { "<p>\($0)</p>" }.joined()

    static let longNotesEpisode = episode(
      id: longNotesEpisodeID, title: "The Last Signal", subtitle: "A deliberately long field report",
      duration: 3_600, publishedAt: now, status: .notDownloaded, available: true,
      episodeDescription: longNotesHTML)

    static let longNotesEpisodeContext = PodcastEpisodeContext(
      episode: longNotesEpisode, showTitle: "Long Notes Radio", showAuthor: "Harness Broadcast",
      artworkURL: nil, artworkFeedURL: nil)

    static func episodes(for scenario: UIHarness.PodcastScenario) -> [PodcastEpisodeSummary]? {
      switch scenario {
      case .loading: nil
      case .empty: []
      case .malformed:
        [
          episode(
            id: "partial", title: "", subtitle: nil, duration: nil,
            publishedAt: nil, status: .notDownloaded, available: false)
        ]
      case .deviceDownloaded:
        [
          episode(
            id: "downloaded", title: "Signals from the Abyss", subtitle: "A field report",
            duration: 3_200, publishedAt: now, status: .completed, available: true)
        ]
      case .downloadWaitingForWiFi:
        [
          episode(
            id: "held", title: "Held Until Wi-Fi", subtitle: "Cellular downloads are off",
            duration: 2_400, publishedAt: now, status: .waitingForWiFi, available: true),
          episode(
            id: "queued-behind", title: "Queued Behind It", subtitle: nil,
            duration: 1_800, publishedAt: now, status: .queued, available: true),
        ]
      case .downloadFailed:
        [
          episode(
            id: "failed-disk", title: "Out of Space", subtitle: "A long failure explanation",
            duration: 2_400, publishedAt: now, status: .failed(category: .lowDisk),
            available: true),
          episode(
            id: "failed-auth", title: "Sign In Again", subtitle: nil, duration: 1_800,
            publishedAt: now, status: .failed(category: .auth), available: true),
        ]
      case .downloadTicking:
        (0..<150).map { index in
          episode(
            id: index == 149 ? downloadTickingEpisodeID : "ticking-\(index)",
            title: "Episode \(150 - index): Notes from the shipping lanes",
            subtitle: "Buoy telemetry, weather routing, and the people who listen to the sea",
            duration: 2_700, publishedAt: now.addingTimeInterval(-86_400 * Double(index)),
            status: index == 149 ? .downloading(progressFraction: 0) : .notDownloaded,
            available: true)
        }
      case .offline, .staleShow, .filteredEmpty:
        [
          episode(
            id: "cached", title: "The Cable That Changed the Ocean",
            subtitle: "Cached while the server is unavailable", duration: 2_700,
            publishedAt: now.addingTimeInterval(-86_400 * 21),
            status: .notDownloaded, available: true)
        ]
      }
    }

    static func episode(
      id: String, title: String, subtitle: String?, duration: Double?,
      publishedAt: Date?, status: ItemDownloadStatus, available: Bool,
      episodeDescription: String? = nil
    ) -> PodcastEpisodeSummary {
      PodcastEpisodeSummary(
        id: id, title: title, subtitle: subtitle, episodeDescription: episodeDescription,
        seasonNumber: nil, episodeNumber: nil, episodeType: nil,
        durationSeconds: duration, sizeBytes: nil, publishedAt: publishedAt,
        progressSeconds: id == "cached" ? 600 : 0, isPlayed: id == "cached",
        isFinished: false, downloadStatus: status, isAvailableOnServer: available)
    }
  }

  struct HarnessPodcastShowOrdering: PodcastShowOrdering {
    private static let shows = (1...12).map { index in
      ItemSummary(
        serverItemId: "harness-podcast-show-\(index)",
        mediaKind: "podcast",
        title: "Harness Podcast \(index)",
        author: "Harness Publisher \(index)",
        durationSeconds: nil,
        category: .podcast)
    }

    func observeShows() -> AsyncStream<PodcastShowsSnapshot> {
      AsyncStream { continuation in
        continuation.yield(PodcastShowsSnapshot(mode: .alphabetical, shows: Self.shows))
      }
    }

    func replaceCustomOrder(itemIDs: [String]) async throws {}
    func resetToAlphabetical() async throws {}
  }

  struct HarnessPodcastLibraryReading: LibraryReading {
    var itemCount: Int { 1 }

    private static let summary = ItemSummary(
      serverItemId: HarnessPodcastFixtures.showID, mediaKind: "podcast",
      title: "Ocean Signals", author: "Remote Concern Radio",
      durationSeconds: nil, category: .podcast,
      // HTML, and long enough to exceed the collapsed three lines, so the harness exercises both
      // the stripping and the tap-to-expand.
      itemDescription: """
        <p>Dispatches from the <b>edge of the shipping lanes</b>: buoy telemetry, weather \
        routing, and the people who listen to the sea for a living.</p><p>New episodes every \
        other Thursday. Hosted by Remote Concern Radio &amp; friends.</p>
        """)

    func observeBrowseList(libraryId: String) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield([Self.summary]) }
    }
    func observeBrowseList(category: ItemMediaCategory?) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield(category == nil || category == .podcast ? [Self.summary] : []) }
    }
    /// No download or progress rows in this fixture, so those dimensions can only exclude. A show
    /// cannot answer an item-scoped playback question, so `ItemFilterPredicate.itemPlayback`
    /// excludes it from every engaged playback state and only `.any` admits it.
    func observeBrowseList(filters: BrowseFilters) -> AsyncStream<LibraryBrowseSnapshot> {
      let matches =
        (filters.categories?.contains(.podcast) ?? true)
        && filters.downloadedOnly == false && filters.playback == .any
      return AsyncStream {
        $0.yield(
          LibraryBrowseSnapshot(items: matches ? [Self.summary] : [], unfilteredItemCount: 1))
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
      AsyncStream { $0.yield(Self.summary) }
    }
    func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield([Self.summary]) }
    }
    func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]> {
      AsyncStream { $0.yield([:]) }
    }
  }

  struct HarnessPodcastReading: PodcastReading {
    let scenario: UIHarness.PodcastScenario

    func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]> {
      AsyncStream { continuation in
        if itemId == HarnessPodcastFixtures.longNotesShowID {
          continuation.yield([HarnessPodcastFixtures.longNotesEpisode])
        } else if let episodes = HarnessPodcastFixtures.episodes(for: scenario) {
          continuation.yield(episodes)
        }
      }
    }

    func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?> {
      AsyncStream { continuation in
        if scenario == .staleShow {
          // All five fields, so the harness shows the server section at its full height rather
          // than the one row a partial fixture would produce.
          continuation.yield(
            PodcastShowDiagnostics(
              autoDownloadEpisodes: false,
              autoDownloadSchedule: "0 */12 * * *",
              lastEpisodeCheck: HarnessPodcastFixtures.now.addingTimeInterval(-86_400 * 21),
              maxEpisodesToKeep: 10,
              maxNewEpisodesToDownload: 3))
        } else {
          continuation.yield(nil)
        }
      }
    }

    func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]> {
      // `WHIRR_UI_HARNESS_NO_TICK=1` keeps the same rows with the progress held still: the control arm.
      guard scenario == .downloadTicking,
        ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_NO_TICK"] != "1"
      else { return AsyncStream { $0.finish() } }
      return AsyncStream { continuation in
        let task = Task {
          var step = 0
          while Task.isCancelled == false {
            continuation.yield([HarnessPodcastFixtures.downloadTickingEpisodeID: Double(step % 50) / 50])
            step += 1
            try? await Task.sleep(for: .milliseconds(250))
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext? {
      guard
        itemID == HarnessPodcastFixtures.longNotesShowID,
        episodeID == HarnessPodcastFixtures.longNotesEpisodeID
      else { return nil }
      return HarnessPodcastFixtures.longNotesEpisodeContext
    }
  }

  struct HarnessPodcastRefreshing: PodcastRefreshing {
    let scenario: UIHarness.PodcastScenario

    func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
      switch scenario {
      case .malformed: return .partial
      case .offline, .staleShow: throw URLError(.notConnectedToInternet)
      case .empty, .deviceDownloaded, .loading, .downloadWaitingForWiFi, .downloadFailed,
        .filteredEmpty, .downloadTicking:
        return .complete
      }
    }
  }
#endif
