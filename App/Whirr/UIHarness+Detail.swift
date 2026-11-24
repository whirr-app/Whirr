#if DEBUG || PERF_INVESTIGATION
  import Foundation
  import Persistence
  import ReaderCore
  import SyncEngine

  /// Which screen the harness presents. Absent or unrecognised `WHIRR_UI_HARNESS_SCREEN` keeps the
  /// default, the expanded player, so existing player/script/latency runs are unaffected.
  extension UIHarness {
    enum Screen: Equatable {
      case player
      case detail
      case storage
      case home
      /// Home inside the shipping tab shell, for anything that turns on the safe area.
      case homeShell
      /// The Podcasts root with the same fixed projections and scroll driver as Home.
      case podcasts
      /// The Podcasts root with followed native shows and notifications off and undecided, so the
      /// New Episode Notifications offer shows.
      case podcastsNotificationOffer
      /// The expanded player on a downloaded episode with Reduce Ads off and never chosen, so the
      /// one-time offer shows over the transport controls.
      case playerReduceAdsOffer
      case podcastShow
      /// The real episode-card sheet over a generated long-notes episode, for scroll reachability.
      case episodeCard
      /// ADR 0008's regular-width item-detail card over the real Library grid.
      case detailCard
      /// The search results screen, over `UIHarness.searchScenario`'s fake
      /// `SearchReading`/`SyncCoordinating`.
      case search
      /// The reader composition over the frozen reader boundary. The scenario selects the state
      /// projection and local App fake; it never exercises Readium parsing.
      case reader
      /// The Library browse root: the app's only plain `List` with pinned section headers and the
      /// A-Z section index, which is what its page background depends on.
      case library
      /// Settings' Home editor. It is behind login in the shipping app, and its reorder affordances
      /// (an always-on edit mode, a long-press menu) can only be checked by driving them. See
      /// `HomeSettingsView`.
      case homeSettings
    }

    static var screen: Screen {
      screen(for: ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCREEN"])
    }

    static func screen(for rawValue: String?) -> Screen {
      switch rawValue {
      case "detail": return .detail
      case "storage": return .storage
      case "home": return .home
      case "home-shell": return .homeShell
      case "podcasts": return .podcasts
      case "podcasts-notification-offer": return .podcastsNotificationOffer
      case "player-reduce-ads-offer": return .playerReduceAdsOffer
      case "podcast-show": return .podcastShow
      case "episode-card": return .episodeCard
      case "detail-card": return .detailCard
      case "search": return .search
      case "reader": return .reader
      case "library": return .library
      case "home-settings": return .homeSettings
      default: return .player
      }
    }

    /// Which item the detail screen presents. Absent or unrecognised `WHIRR_UI_HARNESS_ITEM` keeps
    /// the plain audiobook fixture; `"mixed"` selects the mixed audiobook+EPUB fixture.
    static var detailItemID: String {
      switch ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_ITEM"] {
      case "mixed": return UIHarnessFixtures.mixedItemID
      case "short-series": return UIHarnessFixtures.shortSeriesItemID
      case "no-series": return UIHarnessFixtures.noSeriesItemID
      case "ebook": return UIHarnessFixtures.ebookItemID
      default: return UIHarnessFixtures.itemID
      }
    }
  }

  /// `StorageReading` fake for the storage harness screen: a fixed set of downloaded items and an
  /// account total, yielded once and then idle (no simulated download pipeline).
  /// `WHIRR_UI_HARNESS_STORAGE=empty` yields no downloaded items, for the empty state.
  struct HarnessStorageReading: StorageReading {
    private static var items: [DownloadedItemTotals] {
      guard ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_STORAGE"] != "empty" else { return [] }
      return [
        DownloadedItemTotals(
          itemId: "home-cl-audiobook", title: "The Fellowship of the Ring",
          totalBytes: 843_000_000),
        DownloadedItemTotals(
          itemId: "home-cl-podcast", title: "Ep. 214: Deep Sea Cables",
          totalBytes: 512_400_000),
        DownloadedItemTotals(
          itemId: "home-dl-finished", title: "Project Hail Mary", totalBytes: 96_800_000),
      ]
    }

    func observeAccountStorageTotals() -> AsyncStream<StorageTotals> {
      AsyncStream { $0.yield(StorageTotals(totalBytes: Self.items.reduce(0) { $0 + $1.totalBytes })) }
    }

    func observeItemStorageTotals(itemId: String) -> AsyncStream<StorageTotals> {
      AsyncStream { $0.yield(StorageTotals(totalBytes: Self.items.first { $0.itemId == itemId }?.totalBytes ?? 0)) }
    }

    func observeDownloadedItems() -> AsyncStream<[DownloadedItemTotals]> {
      AsyncStream { $0.yield(Self.items) }
    }

    /// The same fixture bytes by kind: the two books as audiobooks, the episode as a podcast.
    func observeStorageBreakdown() -> AsyncStream<StorageBreakdown> {
      let podcastBytes = Self.items.first { $0.itemId == "home-cl-podcast" }?.totalBytes ?? 0
      let totalBytes = Self.items.reduce(0) { $0 + $1.totalBytes }
      return AsyncStream {
        $0.yield(StorageBreakdown(audiobookBytes: totalBytes - podcastBytes, podcastBytes: podcastBytes))
      }
    }
  }

  /// `DownloadReading` fake for the item-detail harness screen: yields "not downloaded" once, with
  /// no simulated pipeline. `WHIRR_UI_HARNESS_DOWNLOAD` (DEBUG-only, default off, read only here)
  /// overrides that to screenshot the toolbar bubble's other states: `"active"` steps
  /// `.downloading` to `.completed` once a second, `"paused"` yields `.paused`, `"completed"`
  /// yields `.completed`, and the two `*-only` values expose a completed row for one mixed format.
  struct HarnessDownloadReading: DownloadReading {
    func currentItemDownloadStatus(itemId: String) -> ItemDownloadStatus {
      Self.itemStatus(from: Self.formatStatus())
    }

    func currentItemDownloadStatusAsync(itemId: String) async -> ItemDownloadStatus {
      currentItemDownloadStatus(itemId: itemId)
    }

    func observeItemDownloadAggregate(itemId: String) -> AsyncStream<DownloadAggregate> {
      AsyncStream { $0.yield(DownloadAggregate(state: .none, progressFraction: 0)) }
    }

    func observeItemDownloadStatus(itemId: String) -> AsyncStream<ItemDownloadStatus> {
      switch ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_DOWNLOAD"] {
      case "active":
        return AsyncStream { continuation in
          let task = Task {
            var fraction = 0.05
            while fraction < 1 {
              continuation.yield(.downloading(progressFraction: fraction))
              try? await Task.sleep(for: .seconds(1))
              fraction = min(1, fraction + 0.08)
            }
            continuation.yield(.completed)
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      default:
        return AsyncStream { $0.yield(Self.itemStatus(from: Self.formatStatus())) }
      }
    }

    func currentItemFormatDownloadStatus(itemId: String) -> ItemFormatDownloadStatus {
      Self.formatStatus()
    }

    func currentItemFormatDownloadStatusAsync(itemId: String) async -> ItemFormatDownloadStatus {
      currentItemFormatDownloadStatus(itemId: itemId)
    }

    func observeItemFormatDownloadStatus(itemId: String)
      -> AsyncStream<ItemFormatDownloadStatus>
    {
      guard ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_DOWNLOAD"] == "active" else {
        return AsyncStream { $0.yield(Self.formatStatus()) }
      }
      return AsyncStream { continuation in
        let task = Task {
          var fraction = 0.05
          while fraction < 1 {
            continuation.yield(Self.formatStatus(progressFraction: fraction))
            try? await Task.sleep(for: .seconds(1))
            fraction = min(1, fraction + 0.08)
          }
          continuation.yield(Self.formatStatus(isComplete: true))
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    private static func formatStatus(
      progressFraction: Double = 0.05, isComplete: Bool = false
    ) -> ItemFormatDownloadStatus {
      switch ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_DOWNLOAD"] {
      case "active":
        return ItemFormatDownloadStatus(
          audio: isComplete ? .completed : .downloading(progressFraction: progressFraction))
      case "paused":
        return ItemFormatDownloadStatus(audio: .paused)
      case "completed":
        return ItemFormatDownloadStatus(audio: .completed, ebook: .completed)
      case "audio-only":
        return ItemFormatDownloadStatus(audio: .completed)
      case "ebook-only":
        return ItemFormatDownloadStatus(ebook: .completed)
      default:
        return ItemFormatDownloadStatus()
      }
    }

    /// Mirrors `DownloadStatusReducer`'s item-level rule for the format fixtures this harness
    /// exposes: missing formats have no rows, deleting rows are ignored when another format is
    /// live, and the most actionable live state wins over completion.
    private static func itemStatus(from formatStatus: ItemFormatDownloadStatus) -> ItemDownloadStatus {
      let statuses = [formatStatus.audio, formatStatus.ebook]
        .filter { $0 != .notDownloaded }
      guard statuses.isEmpty == false else { return .notDownloaded }

      let liveStatuses = statuses.filter { $0 != .deleting }
      guard liveStatuses.isEmpty == false else { return .deleting }
      if liveStatuses.contains(.pausedAuth) { return .pausedAuth }
      if let failed = liveStatuses.first(where: {
        if case .failed = $0 { return true }
        return false
      }), case .failed(let category) = failed {
        return .failed(category: category)
      }
      if liveStatuses.contains(.paused) { return .paused }
      if let downloading = liveStatuses.first(where: {
        if case .downloading = $0 { return true }
        return false
      }), case .downloading(let fraction) = downloading {
        return .downloading(progressFraction: fraction)
      }
      if liveStatuses.contains(.waitingForWiFi) { return .waitingForWiFi }
      if liveStatuses.contains(.interrupted) { return .interrupted }
      if liveStatuses.contains(.queued) { return .queued }
      return .completed
    }

    /// The list-facing projection, driven by the same `WHIRR_UI_HARNESS_DOWNLOAD` switch as the
    /// detailed stream above. It must also cover the list fixtures: keying only
    /// `UIHarnessFixtures.itemID` would leave every Home card and library row `.none` and never
    /// draw the badge. The Home fixtures' own `isDownloaded` flags are honoured for a real mix.
    func observeItemDownloadPresence() -> AsyncStream<[String: ItemDownloadPresence]> {
      var presence: [String: ItemDownloadPresence] = [:]
      for item in UIHarnessFixtures.homeItems where item.isDownloaded {
        presence[item.serverItemId] = .completed
      }
      switch ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_DOWNLOAD"] {
      case "active", "paused": presence[UIHarnessFixtures.itemID] = .partial
      case "completed", "audio-only", "ebook-only":
        presence[UIHarnessFixtures.itemID] = .completed
      default: break
      }
      return AsyncStream { $0.yield(presence) }
    }

    /// The episode-scoped projection, taken from the same podcast fixtures the show screen renders
    /// so the player's overflow menu offers Download/Delete Download consistently with the episode
    /// row the harness was opened from.
    func observeEpisodeDownloadPresence()
      -> AsyncStream<[EpisodeDownloadKey: ItemDownloadPresence]>
    {
      let episodes =
        HarnessPodcastFixtures.episodes(for: UIHarness.podcastScenario) ?? []
      var presence: [EpisodeDownloadKey: ItemDownloadPresence] = [:]
      for episode in episodes {
        let resolved = ItemDownloadPresence.resolve(episode.downloadStatus)
        guard resolved != .none else { continue }
        presence[
          EpisodeDownloadKey(
            itemID: HarnessPodcastFixtures.showID, episodeID: episode.id)] = resolved
      }
      return AsyncStream { $0.yield(presence) }
    }
  }

  /// `DownloadIntents` fake: every intent is a silent no-op, as in `HarnessAccountLifecycle` and
  /// `HarnessAppLifecycle`.
  struct HarnessDownloadIntents: DownloadIntents {
    func requestDownload(itemID: String) async throws {}
    func requestEbookDownload(itemID: String) async throws {}
    func requestSupplementDownload(itemID: String, fileIno: String) async throws {}
    func requestEpisodeDownload(itemID: String, episodeID: String) async throws {}
    func pauseEpisodeDownload(itemID: String, episodeID: String) async throws {}
    func resumeEpisodeDownload(itemID: String, episodeID: String) async throws {}
    func purgeEpisodeDownload(
      itemID: String, episodeID: String, source: DownloadPurgeSource
    ) async throws {}
    func pauseEbookDownload(itemID: String) async throws {}
    func resumeEbookDownload(itemID: String) async throws {}
    func purgeEbookDownload(itemID: String, source: DownloadPurgeSource) async throws {}
    func pauseItemDownload(itemID: String) async throws {}
    func resumeItemDownload(itemID: String) async throws {}
    func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {}
    func purgeAllDownloads(source: DownloadPurgeSource) async throws {}
    func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws {}
    func isQueuePausedForLowDisk() async -> Bool { false }
  }

  /// `ItemDetailExtrasAccess` fake for the detail harness screen: 10 chapters spread evenly
  /// across the harness item's ~10hr duration, plus a series/narrator line, so the Chapters tab
  /// has enough rows to exercise scrolling and current-chapter/played-state styling.
  struct HarnessItemDetailExtrasAccess: ItemDetailExtrasAccess {
    static let chapterCount = 10

    func itemDetailExtras(itemId: String) async -> ItemDetailExtras? {
      let chapterLength = UIHarnessFixtures.duration / Double(Self.chapterCount)
      let chapters = (0..<Self.chapterCount).map { index in
        ItemChapterInfo(
          title: "Chapter \(index + 1)",
          start: Double(index) * chapterLength,
          end: Double(index + 1) * chapterLength)
      }
      // Extras must agree with the `ItemSummary` the same fixture publishes. A shared series string
      // would put a series row on the item that exists to show the block without one, and chapters
      // on the item that has no audio to divide.
      switch itemId {
      case UIHarnessFixtures.shortSeriesItemID:
        return ItemDetailExtras(
          seriesName: UIHarnessFixtures.shortSeriesName,
          narrator: UIHarnessFixtures.shortSeriesNarrator,
          chapters: chapters,
          description:
            "<p>A missing woman, an abandoned ship, and a war that no one on Ceres asked for.</p>")
      case UIHarnessFixtures.noSeriesItemID:
        return ItemDetailExtras(
          seriesName: nil,
          narrator: UIHarnessFixtures.noSeriesNarrator,
          chapters: chapters,
          description:
            "<p>Ryland Grace wakes alone on a spacecraft with no memory of why he is there.</p>")
      case UIHarnessFixtures.ebookItemID:
        return ItemDetailExtras(
          seriesName: nil, narrator: nil, chapters: [],
          description:
            "<p>An envoy arrives on a world whose inhabitants have no fixed sex, and finds that "
            + "every assumption he brought with him is the wrong one.</p>")
      default:
        return ItemDetailExtras(
          seriesName: "Richard Hannay Adventures #1", narrator: "Full-Cast Ensemble",
          chapters: chapters,
          description:
            "<p>Richard Hannay returns to London to find a dead man in his flat and a plot he "
            + "cannot prove.</p>")
      }
    }
  }

  /// `EPUBTableOfContentsReading` fake for the detail harness screen: the reader harness's own
  /// entries, so the Contents tab exercises nesting depth without an EPUB on disk.
  struct HarnessEPUBTableOfContentsReading: EPUBTableOfContentsReading {
    func tableOfContents(localFileURL: URL) async throws -> [TOCEntry] {
      UIHarnessReaderScenario.tocEntries
    }
  }

  /// `ListeningHistoryProviding` fake for the detail harness screen: 5 fixed past sessions spread
  /// over the last several days, newest first, as `ItemHistoryModel` documents. Cache and refresh
  /// resolve to the same list; there is no simulated network to make them differ.
  struct HarnessListeningHistoryProviding: ListeningHistoryProviding {
    private static let sessionCount = 5
    private static let entries: [ListeningHistoryEntry] = (0..<sessionCount).map { index in
      ListeningHistoryEntry(
        sessionId: "harness-session-\(index)",
        startedAt: Date().addingTimeInterval(-Double(index + 1) * 86_400),
        startPosition: Double(index) * 1_800,
        endPosition: Double(index) * 1_800 + 1_200,
        listenedSeconds: 1_200
      )
    }

    func cachedListeningHistory(itemId: String) async -> [ListeningHistoryEntry] { Self.entries }

    // `@concurrent` on the callback matches the requirement as `SyncEngine` (Swift 6 mode) states
    // it. Without it the App target's default `nonisolated(nonsending)` isolation applies here and
    // the conformance silently fails to match.
    @discardableResult
    func refreshListeningHistory(
      itemId: String, onPagePersisted: @escaping @Sendable @concurrent () async -> Void
    ) async -> Bool {
      await onPagePersisted()
      return true
    }
  }
#endif
