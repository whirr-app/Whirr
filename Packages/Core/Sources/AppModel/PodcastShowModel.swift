import Foundation
import Observation
import Persistence
import SyncEngine

public enum PodcastEpisodeFilter: String, Sendable, Equatable, Hashable, CaseIterable {
  case all
  case unplayed
  case played
  case downloaded
}

/// Episode list copy that `PodcastCopy`'s state strings do not cover: the filter controls, and the
/// "cache is fine, this filter matches nothing" case. `State.empty`'s copy would tell a user with
/// 20 cached episodes that nothing is cached.
public enum PodcastShowListCopy {
  public static let noEpisodesTitle = "No Episodes"
  public static let noEpisodesSystemImage = "waveform"
  public static let noMatchingEpisodesTitle = "No Matching Episodes"
  public static let noMatchingEpisodesSystemImage = "line.3.horizontal.decrease.circle"
  public static let searchPrompt = "Search episodes"
  public static let clearSearchLabel = "Clear episode search"

  public static func filterLabel(_ filter: PodcastEpisodeFilter) -> String {
    switch filter {
    case .all: "All"
    case .unplayed: "Unplayed"
    case .played: "Played"
    case .downloaded: "Downloads"
    }
  }

  /// Names the filter that is hiding the cached episodes, and how to see them again.
  public static func noMatches(_ filter: PodcastEpisodeFilter) -> String {
    switch filter {
    case .all: "No episodes to show."
    case .unplayed: "Every cached episode is played. Choose All to see them."
    case .played: "No cached episode is played yet. Choose All to see them."
    case .downloaded: "No cached episode is downloaded to this device. Choose All to see them."
    }
  }

  public static func noMatches(_ filter: PodcastEpisodeFilter, query: String) -> String {
    guard LibraryQuickFilter.isEffective(query) else { return noMatches(filter) }
    let subject =
      switch filter {
      case .all: "episodes"
      case .unplayed: "unplayed episodes"
      case .played: "played episodes"
      case .downloaded: "downloaded episodes"
      }
    let displayQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return
      "No \(subject) match “\(displayQuery)”. Try another search or choose a different filter."
  }
}

/// An episode intent that failed with a message already written for the user (the reason a
/// playback start refused, say). The screen shows it verbatim instead of the generic
/// `PodcastCopy.actionFailed`.
public struct PodcastEpisodeIntentFailure: Error, Sendable, Equatable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

public protocol PodcastEpisodeIntents: Sendable {
  func play(itemID: String, episodeID: String) async throws
  /// Front of the queue. `addToUpNext` is the far end.
  func playNext(itemID: String, episodeID: String) async throws
  func addToUpNext(itemID: String, episodeID: String) async throws
  @discardableResult
  func saveForLater(itemID: String, episodeID: String) async throws -> SavedShelfSaveOutcome
  func removeFromSaved(itemID: String, episodeID: String) async throws
  func download(itemID: String, episodeID: String) async throws
  func pauseDownload(itemID: String, episodeID: String) async throws
  func resumeDownload(itemID: String, episodeID: String) async throws
  func removeDownload(itemID: String, episodeID: String) async throws
  /// `duration` is the completed position to record, resolved by the caller from the episode's own
  /// cached row, never the show's (which is the sum of every episode).
  func markAsFinished(itemID: String, episodeID: String, duration: Double?) async throws
  func resetProgress(itemID: String, episodeID: String) async throws
  func removeFromContinueListening(itemID: String, episodeID: String) async throws
  /// The show-level bulk action. One transaction, one drain; see
  /// `ItemProgressIntents.setEpisodesFinished`.
  func markAll(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws
}

extension PodcastEpisodeIntents {
  public func removeFromContinueListening(itemID: String, episodeID: String) async throws {}
}

public struct NoOpPodcastEpisodeIntents: PodcastEpisodeIntents, Sendable {
  public init() {}
  public func play(itemID: String, episodeID: String) async throws {}
  public func playNext(itemID: String, episodeID: String) async throws {}
  public func addToUpNext(itemID: String, episodeID: String) async throws {}
  @discardableResult
  public func saveForLater(
    itemID: String, episodeID: String
  ) async throws -> SavedShelfSaveOutcome {
    .saved
  }
  public func removeFromSaved(itemID: String, episodeID: String) async throws {}
  public func download(itemID: String, episodeID: String) async throws {}
  public func pauseDownload(itemID: String, episodeID: String) async throws {}
  public func resumeDownload(itemID: String, episodeID: String) async throws {}
  public func removeDownload(itemID: String, episodeID: String) async throws {}
  public func markAsFinished(itemID: String, episodeID: String, duration: Double?) async throws {}
  public func resetProgress(itemID: String, episodeID: String) async throws {}
  public func markAll(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {}
}

@MainActor
@Observable
public final class PodcastShowModel {
  public enum State: String, Sendable, Equatable, CaseIterable {
    case loading
    case empty
    case loaded
    case refreshing
    case staleOffline
    case recoverableError
    case partiallyDecoded

    public var copyKey: String { "podcast.\(rawValue)" }
    public var copyText: String { PodcastCopy.state(self) }
  }

  public struct ShowMenuCounts: Sendable, Equatable {
    public let unplayed: Int
    public let played: Int
    public let downloadable: Int
    public let removable: Int

    public init(unplayed: Int, played: Int, downloadable: Int, removable: Int) {
      self.unplayed = unplayed
      self.played = played
      self.downloadable = downloadable
      self.removable = removable
    }
  }

  public private(set) var state: State = .loading
  public private(set) var episodes: [PodcastEpisodeSummary] = [] {
    didSet { episodesRevision &+= 1 }
  }
  /// Whether the episode cache has produced its first value for this show. Until it has, an empty
  /// `episodes` means "not read yet", not "nothing cached", and `state` cannot say which because
  /// the appear refresh moves it to `.refreshing` before the first read lands.
  public private(set) var hasReadEpisodeCache = false
  /// Live byte progress for this show's in-flight transfers, keyed by episode id, already floored
  /// to the list quantum by `PodcastReading.observeEpisodeDownloadProgress`. Kept apart from
  /// `episodes` so a transfer's writes never replace the array. Only rows drawing a ring read it
  /// (via `downloadProgressFraction(for:)`, inside their own `body`), so a change invalidates
  /// those rows and nothing else.
  public private(set) var episodeDownloadProgress: [String: Double] = [:]
  public private(set) var diagnostics: PodcastShowDiagnostics?
  /// The show's live, resolved device-side auto-download settings, `nil` until the first
  /// `settingsReading.observeShowSettings(itemID:)` yield. Fed to
  /// `PodcastShowPresentation.diagnosticText` so the "Keeping N newest on this device" hint
  /// tracks Show Settings changes.
  public private(set) var effective: PodcastEffectiveSettings?
  public var filter: PodcastEpisodeFilter = .all
  /// Transient, show-local text. It narrows the same visible episode projection the status chips
  /// do, so menu counts and bulk actions cannot silently target rows hidden by the search.
  public var episodeQuery = ""
  public internal(set) var actionErrorMessage: String?
  public internal(set) var queueFeedbackMessage: String?
  public private(set) var needsAttention = false
  public internal(set) var savedFeedbackMessage: String?
  public internal(set) var continueListeningFeedbackMessage: String?
  /// Single-episode save, batch save and Save Show to Audiobookshelf. Owns its own state and its
  /// stale-result fence; this model hands it the episode list and asks for teardowns.
  public let serverSave: PodcastShowServerSaveModel

  /// The ring fraction for a downloading episode, or `nil` when no transfer with a known total is
  /// in flight for it. `episodes` reports every downloading row as fraction `0`; this is where the
  /// live value lives.
  public func downloadProgressFraction(for episodeID: String) -> Double? {
    episodeDownloadProgress[episodeID]
  }

  /// Read on every pass of the screen and toolbar, several times per keystroke, so the answer is
  /// kept until one of its inputs changes. Search keys are built only once a query is effective,
  /// and the key cache rebuilds only the episodes whose text has changed since.
  public var filteredEpisodes: [PodcastEpisodeSummary] {
    // Read through the observed accessors even on a cache hit, so a caller stays subscribed to
    // every input of the answer it is handed.
    let episodes = self.episodes
    let filter = self.filter
    let fragments = LibraryQuickFilter.fragments(episodeQuery)
    if let memo = filteredEpisodesMemo, memo.episodesRevision == episodesRevision,
      memo.filter == filter, memo.fragments == fragments
    {
      return memo.result
    }

    let result: [PodcastEpisodeSummary]
    if fragments.isEmpty {
      result = filter == .all ? episodes : episodes.filter { Self.includes($0, in: filter) }
    } else {
      let keys = episodeSearchKeys.keys(for: episodes)
      result = zip(episodes, keys).compactMap { episode, key in
        Self.includes(episode, in: filter)
          && LibraryQuickFilter.matches(fragments: fragments, searchKey: key) ? episode : nil
      }
    }
    filteredEpisodesMemo = FilteredEpisodesMemo(
      episodesRevision: episodesRevision, filter: filter, fragments: fragments, result: result)
    return result
  }

  /// The first effective query on a long show would otherwise build every episode's search key on
  /// the main actor, a few hundred milliseconds of stall. Focusing the search field starts that
  /// work off it; a keystroke that lands before the warmup finishes builds its keys inline. Returns
  /// `nil` when every episode already has a key or a warmup is already running.
  @discardableResult
  public func warmEpisodeSearchKeys() -> Task<Void, Never>? {
    guard episodeSearchWarmup == nil else { return nil }
    let pending = episodeSearchKeys.pendingSearchFields(for: episodes)
    guard pending.isEmpty == false else { return nil }
    let itemID = itemID
    let task = Task { [weak self] in
      let warmup = await Task.detached(priority: .userInitiated) {
        LibraryQuickFilter.SearchKeyCache.Warmup(pending)
      }.value
      guard let self, Task.isCancelled == false, self.itemID == itemID else { return }
      self.episodeSearchKeys.adopt(warmup)
      self.episodeSearchWarmup = nil
    }
    episodeSearchWarmup = task
    return task
  }

  var episodeSearchKeyComputations: Int { episodeSearchKeys.computedKeyCount }
  var episodeSearchKeyEntryCount: Int { episodeSearchKeys.entryCount }

  private static func includes(
    _ episode: PodcastEpisodeSummary, in filter: PodcastEpisodeFilter
  ) -> Bool {
    switch filter {
    case .all: true
    case .unplayed: !episode.isPlayed
    case .played: episode.isPlayed
    case .downloaded: episode.downloadStatus == .completed
    }
  }

  /// The four counts used to build the options menu. The filtered list is materialized once, and
  /// every menu predicate is evaluated in this one pass; the action helpers below remain separate
  /// because bulk actions resolve their targets at action time.
  public var showMenuCounts: ShowMenuCounts {
    let episodes = filteredEpisodes
    var unplayed = 0
    var played = 0
    var downloadable = 0
    var removable = 0

    for episode in episodes {
      if episode.isFinished == false { unplayed += 1 }
      if episode.isFinished == true { played += 1 }
      if episode.isAvailableOnServer && episode.downloadStatus == .notDownloaded {
        downloadable += 1
      }
      if episode.downloadStatus != .notDownloaded && episode.downloadStatus != .deleting {
        removable += 1
      }
    }

    return ShowMenuCounts(
      unplayed: unplayed, played: played, downloadable: downloadable, removable: removable)
  }

  var itemID: String
  let reading: any PodcastReading
  private let refreshing: any PodcastRefreshing
  let episodeIntents: any PodcastEpisodeIntents
  let episodeActionExecutor: PodcastEpisodeIntentExecutor
  let savedStatus: SavedStatusStore?
  let continueListeningVisibility: ContinueListeningVisibilityStore?
  private let settingsReading: any PodcastSettingsReading
  private let nativePodcastUnfollowing: any NativePodcastUnfollowing
  private let nativeFeedRecoveryReading: any NativeFeedRecoveryReading
  @ObservationIgnored private var episodesRevision = 0
  @ObservationIgnored private var episodeSearchKeys = LibraryQuickFilter.SearchKeyCache()
  @ObservationIgnored private var filteredEpisodesMemo: FilteredEpisodesMemo?
  private struct FilteredEpisodesMemo {
    let episodesRevision: Int
    let filter: PodcastEpisodeFilter
    let fragments: [String]
    let result: [PodcastEpisodeSummary]
  }
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var downloadProgressTask: Task<Void, Never>?
  @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var settingsTask: Task<Void, Never>?
  @ObservationIgnored private var recoveryTask: Task<Void, Never>?
  @ObservationIgnored private var episodeSearchWarmup: Task<Void, Never>?

  /// The active smart list's name, or nil. Play Next queues behind a run, so its confirmation
  /// names the list ("Plays after Commute").
  @ObservationIgnored let activeSmartListName: @MainActor @Sendable () -> String?

  public init(
    itemID: String,
    reading: any PodcastReading,
    nativeEpisodeIDResolving: any NativeEpisodeIDResolving = NoOpNativeEpisodeIDResolving(),
    refreshing: any PodcastRefreshing = NoOpPodcastRefreshing(),
    episodeIntents: any PodcastEpisodeIntents = NoOpPodcastEpisodeIntents(),
    savedStatus: SavedStatusStore? = nil,
    continueListeningVisibility: ContinueListeningVisibilityStore? = nil,
    settingsReading: any PodcastSettingsReading = NoOpPodcastSettingsReading(),
    nativePodcastUnfollowing: (any NativePodcastUnfollowing)? = nil,
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    nativeFeedRecoveryReading: any NativeFeedRecoveryReading = NoOpNativeFeedRecoveryReading(),
    nativeEpisodeServerSaving: any NativeEpisodeServerSaving = NoOpNativeEpisodeServerSaving(),
    nativeEpisodeServerSaveBatchSaving: any NativeEpisodeServerSaveBatchSaving =
      NoOpNativeEpisodeServerSaveBatchSaving(),
    nativeEpisodeServerSaveRecovering: any NativeEpisodeServerSaveRecovering =
      NoOpNativeEpisodeServerSaveRecovering(),
    nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading =
      NoOpNativeEpisodeServerSaveStatusReading(),
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading =
      NoOpServerPodcastMutationCapabilityReading(),
    nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    accountIdentityReading: any AccountIdentityReading = NoOpAccountIdentityReading(),
    librarySyncRequester: any LibrarySyncRequesting = NoOpLibrarySyncRequester(),
    nativeShowsReading: any NativePodcastShowsReading = NoOpNativePodcastShowsReading(),
    serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting =
      NoOpServerPodcastAutomationSettingsWriting(),
    stopPlaybackForUnfollow: @escaping @MainActor @Sendable (String) async throws -> Void = { _ in },
    initialFilter: PodcastEpisodeFilter = .all,
    activeSmartListName: @escaping @MainActor @Sendable () -> String? = { nil }
  ) {
    self.activeSmartListName = activeSmartListName
    self.itemID = itemID
    self.reading = reading
    self.refreshing = refreshing
    self.episodeIntents = episodeIntents
    self.episodeActionExecutor = PodcastEpisodeIntentExecutor(intents: episodeIntents)
    self.savedStatus = savedStatus
    self.continueListeningVisibility = continueListeningVisibility
    self.settingsReading = settingsReading
    self.nativePodcastUnfollowing =
      nativePodcastUnfollowing
      ?? NativePodcastUnfollowAction(
        feedManaging: nativeFeedManaging, stopPlayback: stopPlaybackForUnfollow)
    self.nativeFeedRecoveryReading = nativeFeedRecoveryReading
    serverSave = PodcastShowServerSaveModel(
      itemID: itemID,
      reading: reading,
      nativeFeedManaging: nativeFeedManaging,
      nativeEpisodeServerSaving: nativeEpisodeServerSaving,
      nativeEpisodeServerSaveBatchSaving: nativeEpisodeServerSaveBatchSaving,
      nativeEpisodeServerSaveRecovering: nativeEpisodeServerSaveRecovering,
      nativeEpisodeServerSaveStatusReading: nativeEpisodeServerSaveStatusReading,
      nativeEpisodeIDResolving: nativeEpisodeIDResolving,
      serverPodcastMutationCapabilityReading: serverPodcastMutationCapabilityReading,
      nativePodcastSubscriptionsReading: nativePodcastSubscriptionsReading,
      accountIdentityReading: accountIdentityReading,
      librarySyncRequester: librarySyncRequester,
      nativeShowsReading: nativeShowsReading,
      serverPodcastAutomationSettingsWriting: serverPodcastAutomationSettingsWriting)
    filter = initialFilter
    subscribe(itemID: itemID)
    serverSave.attach(host: self)
  }

  deinit {
    observationTask?.cancel()
    downloadProgressTask?.cancel()
    diagnosticsTask?.cancel()
    refreshTask?.cancel()
    settingsTask?.cancel()
    recoveryTask?.cancel()
    episodeSearchWarmup?.cancel()
  }

  public func show(itemID: String) {
    guard itemID != self.itemID else { return }
    serverSave.show(itemID: itemID)
    observationTask?.cancel()
    downloadProgressTask?.cancel()
    diagnosticsTask?.cancel()
    refreshTask?.cancel()
    refreshTask = nil
    settingsTask?.cancel()
    recoveryTask?.cancel()
    recoveryTask = nil
    self.itemID = itemID
    episodes = []
    episodeSearchKeys = LibraryQuickFilter.SearchKeyCache()
    episodeSearchWarmup?.cancel()
    episodeSearchWarmup = nil
    hasReadEpisodeCache = false
    episodeDownloadProgress = [:]
    diagnostics = nil
    effective = nil
    needsAttention = false
    actionErrorMessage = nil
    queueFeedbackMessage = nil
    savedFeedbackMessage = nil
    continueListeningFeedbackMessage = nil
    state = .loading
    subscribe(itemID: itemID)
  }

  /// The feed id when this show is device-owned. ABS subscriptions remain server-managed.
  var nativeFeedID: Int64? {
    if let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId { return feedID }
    return nil
  }

  public var isNativeFeed: Bool { nativeFeedID != nil }

  /// Deletes a native subscription and its RSS cascade. The caller dismisses the now-invalid show
  /// after a successful deletion; failures use the same bounded action channel as episode intents.
  public func unsubscribe() async -> Bool {
    guard nativeFeedID != nil else { return false }
    actionErrorMessage = nil
    do {
      try await nativePodcastUnfollowing.unfollow(itemID: itemID)
      actionErrorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch NativePodcastUnfollowError.playbackStopFailed {
      actionErrorMessage = PodcastCopy.unsubscribePlaybackStopFailed
      return false
    } catch {
      actionErrorMessage = PodcastCopy.unsubscribeFailed
      return false
    }
  }

  /// How young a show's last completed refresh may be for opening its screen to skip the
  /// network. Pull-to-refresh and background passes are never gated by this.
  public static let appearRefreshMaximumAge: TimeInterval = 5 * 60

  public func refresh() async {
    await performRefresh { refreshing, itemID in try await refreshing.refresh(itemID: itemID) }
  }

  /// The screen-appear refresh. A show refreshed within `appearRefreshMaximumAge` renders from
  /// its cache alone; a source that keeps no refresh time refreshes as `refresh()` does.
  public func refreshOnAppear() async {
    await performRefresh { refreshing, itemID in
      try await refreshing.refreshIfStale(
        itemID: itemID, maximumAge: Self.appearRefreshMaximumAge)
    }
  }

  private func performRefresh(
    _ operation:
      @escaping @Sendable (any PodcastRefreshing, String) async throws
      -> PodcastRefreshOutcome
  ) async {
    if let refreshTask {
      await refreshTask.value
      return
    }
    let itemID = self.itemID
    state = .refreshing
    let refreshing = self.refreshing
    let task = Task { [weak self] in
      do {
        let outcome = try await operation(refreshing, itemID)
        guard let self, itemID == self.itemID else { return }
        self.state = outcome == .partial ? .partiallyDecoded : self.settledState
      } catch is CancellationError {
        guard let self, itemID == self.itemID else { return }
        self.state = self.settledState
      } catch {
        guard let self, itemID == self.itemID else { return }
        self.state = self.episodes.isEmpty ? .recoverableError : .staleOffline
      }
    }
    refreshTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if itemID == self.itemID { refreshTask = nil }
  }

  private var settledState: State { episodes.isEmpty ? .empty : .loaded }

  /// More rows than the tallest screen shows under the header. The rest arrive with the
  /// observation, below the fold.
  static let firstFrameEpisodeLimit = 24

  private func subscribe(itemID: String) {
    // Taken before the screen's first frame so the page arrives with its rows; the observation's
    // first value lands only after the push has finished. See `PodcastReading.episodePrefix`.
    // A cut-short prefix has not answered for the whole cache, so a filter matching none of its
    // rows must not yet claim that nothing matches.
    if let prefix = reading.episodePrefix(itemId: itemID, limit: Self.firstFrameEpisodeLimit) {
      episodes = prefix.episodes
      hasReadEpisodeCache = prefix.isComplete
      if prefix.isComplete || prefix.episodes.isEmpty == false { state = settledState }
    }
    let episodeStream = reading.observeEpisodes(itemId: itemID)
    let diagnosticsStream = reading.observeShowDiagnostics(itemId: itemID)
    observationTask = Task { [weak self] in
      for await episodes in episodeStream {
        guard let self else { return }
        guard itemID == self.itemID else { return }
        self.episodes = episodes
        self.hasReadEpisodeCache = true
        self.serverSave.episodesDidChange(episodes)
        if self.state == .recoverableError, episodes.isEmpty == false {
          self.state = .staleOffline
        } else if self.state == .loading || self.state == .loaded || self.state == .empty {
          self.state = self.settledState
        }
      }
    }
    diagnosticsTask = Task { [weak self] in
      for await diagnostics in diagnosticsStream {
        guard let self else { return }
        guard itemID == self.itemID else { return }
        self.diagnostics = diagnostics
      }
    }
    let downloadProgressStream = reading.observeEpisodeDownloadProgress(itemId: itemID)
    downloadProgressTask = Task { [weak self] in
      for await progress in downloadProgressStream {
        guard let self else { return }
        guard itemID == self.itemID else { return }
        self.episodeDownloadProgress = progress
      }
    }
    let settingsStream = settingsReading.observeShowSettings(itemID: itemID)
    settingsTask = Task { [weak self] in
      for await detail in settingsStream {
        guard let self else { return }
        guard itemID == self.itemID else { return }
        self.effective = detail?.effective
      }
    }
    guard let feedID = nativeFeedID else { return }
    let recoveryStream = nativeFeedRecoveryReading.observeRecoveryFeedIDs()
    recoveryTask = Task { [weak self] in
      for await feedIDs in recoveryStream {
        guard let self, itemID == self.itemID else { return }
        self.needsAttention = feedIDs.contains(feedID)
      }
    }
  }

}

extension PodcastShowModel: PodcastShowServerSaveHost {
  var serverSaveEpisodes: [PodcastEpisodeSummary] { episodes }
  var serverSaveVisibleEpisodes: [PodcastEpisodeSummary] { filteredEpisodes }

  func reportServerSaveActionError(_ message: String?) {
    actionErrorMessage = message
  }
}
