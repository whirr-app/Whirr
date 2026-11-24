import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

extension RootModelTests {
  // MARK: - Fixtures

  func makeDependencies(
    account: FakeAccountLifecycle = FakeAccountLifecycle(),
    library: FakeLibraryReading = FakeLibraryReading(),
    sync: any SyncCoordinating = FakeSyncCoordinating(),
    player: FakePlaybackControlling = FakePlaybackControlling(),
    playbackSync: FakePlaybackSyncing = FakePlaybackSyncing(),
    downloadIntents: any DownloadIntents = NoOpDownloadIntents(),
    listeningQueueReading: any ListeningQueueReading = NoOpListeningQueueStore(),
    listeningQueueStoring: any ListeningQueueStoring = NoOpListeningQueueStore(),
    savedShelfStoring: any SavedShelfStoring = NoOpSavedShelfStore(),
    savedShelfReading: (any SavedShelfReading)? = nil,
    podcastReading: any PodcastReading = NoOpPodcastReading(),
    podcastRefreshing: any PodcastRefreshing = NoOpPodcastRefreshing(),
    nativeFeedManaging: any NativeFeedManaging = NoOpNativeFeedManaging(),
    rssFeedRefreshCoordinator: any RSSFeedRefreshCoordinating = NoOpRSSFeedRefreshCoordinator(),
    appLifecycle: FakeAppLifecycle = FakeAppLifecycle(),
    nativeContinueListeningReading: any NativeContinueListeningReading =
      NoOpNativeContinueListeningReading(),
    nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading =
      RootNativeSubscriptionsAccess(enabled: false),
    makePodcastEpisodeIntents: (@MainActor @Sendable (PlaybackModel) -> any PodcastEpisodeIntents)? = nil,
    librarySelectionReading: any LibrarySelectionReading = NoOpLibrarySelectionStore(),
    isLibrarySelectionPending: @escaping @Sendable () -> Bool = { false },
    hasConfiguredIncludedLibrary: @escaping @Sendable () -> Bool = { false },
    isRemovalPendingSynchronously: @escaping @Sendable () -> Bool = { false }
  ) -> AppDependencies {
    AppDependencies(
      account: account,
      sync: sync,
      library: library,
      player: player,
      playbackSync: playbackSync,
      reader: FakeEPUBRendering(),
      networkConditions: FakeNetworkConditions(),
      appLifecycle: appLifecycle,
      diagnostics: FakeDiagnosticsRecording(),
      isLibrarySelectionPending: isLibrarySelectionPending,
      hasConfiguredIncludedLibrary: hasConfiguredIncludedLibrary,
      isRemovalPendingSynchronously: isRemovalPendingSynchronously,
      downloadReading: NoOpDownloadReading(),
      storageReading: NoOpStorageReading(),
      rssDownloadsReading: NoOpRSSDownloadsReading(),
      deviceStorageCapacityReading: NoOpDeviceStorageCapacityReading(),
      downloadIntents: downloadIntents,
      itemProgressIntents: NoOpItemProgressIntents(),
      downloadPreferences: NoOpDownloadPreferences(),
      artworkCacheAccess: NoOpArtworkCacheAccess(),
      resolutionCenterAccess: NoOpResolutionCenterAccess(),
      extrasAccess: NoOpItemDetailExtrasAccess(),
      historyAccess: NoOpListeningHistoryProviding(),
      listeningStatsAccess: NoOpListeningStatsProviding(),
      audioBookmarkIntents: NoOpAudioBookmarkIntents(),
      homeReading: NoOpHomeReading(),
      nativeLatestPodcastEpisodesReading: NoOpNativeLatestPodcastEpisodesReading(),
      nativeContinueListeningReading: nativeContinueListeningReading,
      playbackBookmarkStoring: NoOpPlaybackBookmarkStoring(),
      podcastReading: podcastReading,
      podcastRefreshing: podcastRefreshing,
      rssFeedRefreshCoordinator: rssFeedRefreshCoordinator,
      makePodcastEpisodeIntents: makePodcastEpisodeIntents,
      listeningQueueReading: listeningQueueReading,
      listeningQueueStoring: listeningQueueStoring,
      savedShelfStoring: savedShelfStoring,
      savedShelfReading: savedShelfReading,
      itemPlaybackSettingsReading: NoOpItemPlaybackSettingsAccess(),
      itemPlaybackSettingsWriting: NoOpItemPlaybackSettingsAccess(),
      playbackPreferences: NoOpPlaybackPreferences(),
      podcastSettingsReading: NoOpPodcastSettingsAccess(),
      podcastSettingsWriting: NoOpPodcastSettingsAccess(),
      podcastShowOrdering: NoOpPodcastShowOrdering(),
      carPlayBrowseSources: .empty,
      searchReading: NoOpSearchReading(),
      recentSearchStore: NoOpRecentSearchStoring(),
      authorSeriesReading: NoOpAuthorSeriesReading(),
      libraryCollections: .unavailable,
      serverAccountReading: NoOpServerAccountReading(),
      librarySelectionReading: librarySelectionReading,
      nativePodcastSubscriptionsReading: nativePodcastSubscriptionsReading,
      accountIdentityReading: NoOpAccountIdentityReading(),
      nativePodcastSubscriptionsWriting: NoOpNativePodcastSubscriptionsWriting(),
      nativeEpisodeServerSaving: NoOpNativeEpisodeServerSaving(),
      nativeEpisodeServerSaveBatchSaving: NoOpNativeEpisodeServerSaveBatchSaving(),
      nativeEpisodeServerSaveRecovering: NoOpNativeEpisodeServerSaveRecovering(),
      nativeEpisodeServerSaveStatusReading: NoOpNativeEpisodeServerSaveStatusReading(),
      nativeEpisodeIDResolving: NoOpNativeEpisodeIDResolving(),
      serverPodcastMutationCapabilityReading: NoOpServerPodcastMutationCapabilityReading(),
      serverPodcastAutomationSettingsWriting: NoOpServerPodcastAutomationSettingsWriting(),
      ebookDelivery: NoOpEbookDelivering(),
      notificationIntentReading: DisabledRSSNotificationIntent(),
      notificationIntentWriting: DisabledRSSNotificationIntent(),
      localNotificationAuthorizer: NoOpRSSLocalNotificationAuthorizer(),
      rssNotificationLifecycle: NoOpRSSNotificationLifecycle(),
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
      nativeFeedRecoveryReading: NoOpNativeFeedRecoveryReading(),
      librarySelectionWriting: NoOpLibrarySelectionStore(),
      librarySelectionDiscovery: NoOpLibrarySelectionDiscovery(),
      nativeFeedFollowing: NoOpNativeFeedFollowing(),
      nativeFeedManaging: nativeFeedManaging,
      nativeSubscriptionOPMLExporter: NoOpNativeSubscriptionOPMLExporter(),
      nativePodcastShowOrdering: NoOpNativePodcastShowOrdering()
    )
  }

  static func selectionSnapshot(included: Bool) -> LibrarySelectionSnapshot {
    LibrarySelectionSnapshot(
      mode: .selected,
      libraries: [
        SelectableLibrary(
          serverLibraryID: "books", name: "Books", mediaType: "book", isAccessible: true,
          isIncluded: included)
      ])
  }

  static func mixedSelectionSnapshot(
    podcastIncluded: Bool, podcastAccessible: Bool = true
  ) -> LibrarySelectionSnapshot {
    LibrarySelectionSnapshot(
      mode: .selected,
      libraries: [
        SelectableLibrary(
          serverLibraryID: "books", name: "Books", mediaType: "book", isAccessible: true,
          isIncluded: true),
        SelectableLibrary(
          serverLibraryID: "pods", name: "Podcasts", mediaType: "podcast",
          isAccessible: podcastAccessible, isIncluded: podcastIncluded),
      ])
  }
}

// MARK: - Fakes

@MainActor
final class RootPlaybackBox {
  var value: PlaybackModel?
}

// Stays: constructed by name in call sites outside this change (RootModelCompositionTests)
// that use actor members; move to `FakeNativeFeedManaging` with them.
actor RootRecordingNativeFeedManaging: NativeFeedManaging {
  private(set) var unsubscribeFeedIDs: [Int64] = []

  func unsubscribe(feedId: Int64) async throws { unsubscribeFeedIDs.append(feedId) }
  func hasCredential(feedId: Int64) async throws -> Bool { false }
  func saveBasicCredential(username: String, password: String, feedId: Int64) async throws {}
  func clearCredential(feedId: Int64) async throws {}
}

// Stays: constructed by name in call sites outside this change (RootModelCompositionTests)
// that use actor members; move to `FakeSavedShelfStoring` with them.
actor RootRecordingSavedShelf: SavedShelfStoring {
  enum Call: Equatable {
    case save(SavedShelfIdentity)
    case remove(SavedShelfIdentity)
  }

  private(set) var calls: [Call] = []

  @discardableResult
  func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome {
    calls.append(.save(identity))
    return .saved
  }

  func remove(_ identity: SavedShelfIdentity) async throws {
    calls.append(.remove(identity))
  }
}

// Stays: constructed by name in call sites outside this change (RootModelCompositionTests)
// that use actor members; move to `FakeListeningQueueStoring` with them.
actor RootRecordingListeningQueue: ListeningQueueStoring {
  private(set) var appendCalls: [ListeningIdentity] = []
  private(set) var removeCalls: [ListeningIdentity] = []
  private(set) var removedRowIDs: [Int64] = []
  private(set) var acknowledgedCalls: [ListeningIdentity] = []

  @discardableResult
  func append(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws -> ListeningQueueAppendOutcome
  {
    appendCalls.append(identity)
    return .appended
  }

  func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {}
  @discardableResult
  func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] { [] }
  func remove(identity: ListeningIdentity) async throws {
    removeCalls.append(identity)
  }
  func remove(rowID: Int64) async throws {
    removedRowIDs.append(rowID)
  }
  func move(rowID: Int64, to position: Int) async throws {}
  func clear() async throws -> ListeningQueueRestoreToken {
    try await NoOpListeningQueueStore().clear()
  }
  func restore(token: ListeningQueueRestoreToken) async throws {}
  func peekNextLive() async -> ListeningQueueItem? { nil }
  func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {
    acknowledgedCalls.append(identity)
  }
  func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool {
    acknowledgedCalls.append(identity)
    return true
  }
}

final class RootListeningQueueReading: ListeningQueueReading, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<[ListeningQueueItem]>.Continuation?

  func observeQueue() -> AsyncStream<[ListeningQueueItem]> {
    AsyncStream { continuation in
      lock.withLock { self.continuation = continuation }
    }
  }

  func push(_ items: [ListeningQueueItem]) {
    lock.withLock { continuation }?.yield(items)
  }
}

final class LibrarySelectionBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Bool

  init(_ value: Bool) {
    storedValue = value
  }

  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedValue
    }
    set {
      lock.lock()
      storedValue = newValue
      lock.unlock()
    }
  }
}

final class RootSelectionAccess: LibrarySelectionReading, @unchecked Sendable {
  private var continuation: AsyncStream<LibrarySelectionSnapshot>.Continuation?
  private var snapshot: LibrarySelectionSnapshot
  private(set) var isObserving = false

  init(snapshot: LibrarySelectionSnapshot) {
    self.snapshot = snapshot
  }

  func currentSelection() async throws -> LibrarySelectionSnapshot { snapshot }

  func observeSelection() -> AsyncStream<LibrarySelectionSnapshot> {
    AsyncStream { continuation in
      self.continuation = continuation
      self.isObserving = true
      continuation.yield(snapshot)
    }
  }

  func emit(_ snapshot: LibrarySelectionSnapshot) {
    self.snapshot = snapshot
    continuation?.yield(snapshot)
  }
}

// Stays: constructed by name in call sites outside this change (RootModelPodcastTabTests and
// RootModelCompositionTests) that use its `emit`; move to `FakeNativePodcastSubscriptionsReading`
// with them.
final class RootNativeSubscriptionsAccess:
  NativePodcastSubscriptionsReading, @unchecked Sendable
{
  private let lock = NSLock()
  private var enabled: Bool
  private var continuation: AsyncStream<Bool>.Continuation?
  private(set) var observeEnabledCallCount = 0

  init(enabled: Bool) {
    self.enabled = enabled
  }

  func isEnabled() async -> Bool {
    lock.withLock { enabled }
  }

  func observeEnabled() -> AsyncStream<Bool> {
    observeEnabledCallCount += 1
    return AsyncStream { continuation in
      let enabled = lock.withLock {
        self.continuation = continuation
        return self.enabled
      }
      continuation.yield(enabled)
    }
  }

  func emit(_ enabled: Bool) {
    let continuation = lock.withLock {
      self.enabled = enabled
      return self.continuation
    }
    continuation?.yield(enabled)
  }
}

// Stays: constructed by name in RootModelTests.swift and RootModelCompositionTests.swift, which are
// outside this change. Replace with `FakeSyncCoordinating(libraryDiscoveryResult: .reconciled)`
// when those files are in scope.
final class RootDiscoverySync: SyncCoordinating, @unchecked Sendable {
  private(set) var discoveryRefreshCount = 0
  private(set) var refreshCount = 0

  func refresh() async { refreshCount += 1 }

  func refreshLibraryDiscovery() async -> LibraryDiscoveryRefreshResult {
    discoveryRefreshCount += 1
    return .reconciled
  }

  func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
    SearchFanOutResult(matches: [])
  }
}

// Stays: used by RootModelCompositionTests.swift (outside this change), and `FakeSyncCoordinating`
// has no refresh gate or cancelled-refresh count yet; add both with the call-site change.
final class SuspendingSyncCoordinating: SyncCoordinating, @unchecked Sendable {
  private let startRecorder = TestCountRecorder(label: "SuspendingSyncCoordinating refreshes")
  private let cancellationRecorder = TestCountRecorder(
    label: "SuspendingSyncCoordinating cancelled refreshes")
  // Held from the start: a refresh parks until `release()`, which opens the gate for later ones,
  // and returns at once if its task is cancelled.
  private let gate = TestGate<Void>(label: "SuspendingSyncCoordinating refresh")

  init() {
    gate.hold()
  }

  var refreshStartCount: Int { startRecorder.count }

  var cancelledRefreshCount: Int { cancellationRecorder.count }

  func refresh() async {
    startRecorder.record()
    await gate.pass()
    if Task.isCancelled {
      cancellationRecorder.record()
    }
  }

  func release() {
    gate.release()
  }

  func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
    SearchFanOutResult(matches: [])
  }
}

enum RootPodcastError: Error {
  case offline
}

// Stays: constructed by name in call sites outside this change (RootModelCompositionTests)
// that use actor members; move to `FakePodcastReading` with them.
final class RootPodcastReading: PodcastReading, @unchecked Sendable {
  static let episode = PodcastEpisodeSummary(
    id: "episode-1", title: "Episode", subtitle: nil, episodeDescription: nil,
    seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: 120,
    sizeBytes: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000), progressSeconds: 0,
    isPlayed: false, isFinished: false, downloadStatus: .notDownloaded, isAvailableOnServer: true)

  private let lock = NSLock()
  private var continuations: [String: AsyncStream<[PodcastEpisodeSummary]>.Continuation] = [:]

  func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]> {
    AsyncStream { continuation in
      lock.withLock { continuations[itemId] = continuation }
    }
  }

  func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?> {
    AsyncStream { $0.finish() }
  }

  func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext? {
    nil
  }

  func push(_ episodes: [PodcastEpisodeSummary], itemID: String) {
    lock.withLock { continuations[itemID] }?.yield(episodes)
  }
}

// Stays: constructed by name in call sites outside this change (RootModelCompositionTests)
// that use actor members; move to `FakePodcastRefreshing` with them.
actor RootPodcastRefreshing: PodcastRefreshing {
  private var result: Result<PodcastRefreshOutcome, Error> = .success(.complete)

  func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    try result.get()
  }

  func stub(_ result: Result<PodcastRefreshOutcome, Error>) {
    self.result = result
  }
}

actor RootRSSFeedRefreshCoordinator: RSSFeedRefreshCoordinating {
  private(set) var triggers: [RSSFeedRefreshTrigger] = []
  private(set) var cancellations: [RSSFeedRefreshTrigger] = []

  func run(_ trigger: RSSFeedRefreshTrigger) async -> RSSFeedRefreshPassResult {
    triggers.append(trigger)
    return .gated
  }

  func cancel(_ trigger: RSSFeedRefreshTrigger) async { cancellations.append(trigger) }
}
