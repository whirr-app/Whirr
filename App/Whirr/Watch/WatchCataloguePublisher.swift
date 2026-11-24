import AppModel
import Foundation
import Observation
import Persistence
import PlayerCore
import WatchProtocol

/// Produces the latest phone-owned catalogue value and encoded payload from persisted projections.
/// RootComposition owns the transport bridge; this publisher never holds or calls WCSession.
@MainActor
final class WatchCataloguePublisher {
  /// Coalesces a burst: several upstream changes landing together publish once.
  static let publicationDebounceNanoseconds: UInt64 = 50_000_000
  /// Bounds a sustained feed the debounce cannot (a change every 60ms clears it): the nine
  /// `ValueObservation`s re-run on sync bursts and `observePlayback` ticks with the playhead, and
  /// each publication rebuilds and size-checks the catalogue (off the main actor, see
  /// `WatchCatalogueAssembly`). 500ms matches the 0.5s foreground tick, so it only removes burst
  /// amplification; `WCSession.updateApplicationContext` is latest-only and coalesced by the
  /// system regardless. `nonisolated` because a default argument is evaluated outside the
  /// initialiser's main-actor isolation.
  nonisolated static let publicationMinimumInterval: Duration = .milliseconds(500)

  /// Playback-position-only changes (the playhead ticking) republish no more often than this. The
  /// Watch runs the phone's clock forward from each publication at the published rate, as the
  /// system's Now Playing does, so this only bounds how long that estimate goes uncorrected. Any
  /// other playback change, or a playhead that leaves the estimate, publishes at once.
  nonisolated static let positionOnlyPublicationInterval: Duration = .seconds(15)

  /// How far the playhead may run from the Watch's estimate before it republishes at once. A seek,
  /// a skip or an ad skip leaves the line outright; trimmed silence drifts ahead of it. Wider than
  /// the system Now Playing's 1 s because each publication rebuilds the catalogue.
  nonisolated static let playheadDepartureThreshold: Double = 2

  /// The position the Watch last received and the line it runs that position along: forward at
  /// `rate` from `at` while playing, still otherwise.
  struct PublishedPlayhead: Equatable {
    let position: Double
    let at: Date
    let rate: Double

    /// Whether `position` at `now` is far enough off that line that the Watch should be told.
    func isDeparted(by position: Double, at now: Date) -> Bool {
      let expected = self.position + max(0, now.timeIntervalSince(at)) * rate
      return abs(position - expected) > WatchCataloguePublisher.playheadDepartureThreshold
    }
  }

  typealias Publication = @MainActor (WatchCatalogueSnapshot) -> Void
  typealias Assembler = @Sendable (WatchCatalogueAssembly) -> WatchCatalogueSnapshot?
  typealias AudioActivationRefusal = @MainActor @Sendable () -> Bool

  let home: any HomeReading
  let nativeLatest: any NativeLatestPodcastEpisodesReading
  let nativeContinue: any NativeContinueListeningReading
  let rssDownloads: any RSSDownloadsReading
  let bookmarks: any PlaybackBookmarkStoring
  private let accountIdentity: any AccountIdentityReading
  let nativeSubscriptions: any NativePodcastSubscriptionsReading
  let browseModel: WatchPhoneBrowseModel
  lazy var browseEndpoint = WatchPhoneBrowseEndpoint(
    model: browseModel,
    currentStamp: { [weak self] in self?.watchAccountStamp },
    isAvailable: { [weak self] in self?.identity != nil })

  let playback: PlaybackModel?
  private let defaults: UserDefaults
  private var preferenceChanges: PreferenceChanges<String>?
  let publish: Publication
  let assemble: Assembler
  let now: @MainActor @Sendable () -> Date
  let audioActivationWasRefused: AudioActivationRefusal

  private var accountTask: Task<Void, Never>?
  var readerTasks: [Task<Void, Never>] = []
  var publicationTask: Task<Void, Never>?
  /// The publication being assembled off the main actor. Only one runs at a time: one due
  /// meanwhile waits in `assemblyPending` and is scheduled when this one emits, so the floor runs
  /// from each emission however long the assembly took.
  var assemblyTask: Task<Void, Never>?
  var assemblyPending = false
  var assemblySequence: UInt64 = 0
  var publicationEpoch: UInt64 = 0
  private var lifecycleEpoch: UInt64 = 0
  var started = false
  var hasObservedAccount = false
  var identity: AccountIdentity?
  var watchAccountStamp: WatchAccountStamp?
  var scopeIdentity: AccountIdentity?
  var nativeEnabled = false
  var absContinue: [HomeItem] = []
  var nativeContinueItems: [HomeItem] = []
  var bookmark: PlaybackBookmark?
  var recentBooks: [HomeItem] = []
  var absLatest: HomeLatestPodcastEpisodesSnapshot?
  var nativeLatestEpisodes: [HomePodcastEpisode] = []
  var absDownloads: [HomeItem] = []
  var nativeDownloadFeeds: [RSSDownloadedFeed] = []
  var lastGeneratedAt: Date?
  let minimumPublicationInterval: Duration
  /// When the last publication ran, not when one last succeeded: the cost this bounds is the
  /// merge/build/encode, which a publication that then declines to emit has already paid.
  var lastPublishedAt: ContinuousClock.Instant?
  /// Everything `observePlayback` reads except the playhead, to tell a tick from a real change.
  var lastPlaybackFingerprint: PlaybackFingerprint?
  /// The playhead of the last emitted catalogue, which the Watch is running its clock from.
  var publishedPlayhead: PublishedPlayhead?

  struct PlaybackFingerprint: Equatable {
    let phase: PlaybackModel.Phase
    let activeItemID: String?
    let activeEpisodeID: String?
    let loadedItemID: String?
    let loadedEpisodeID: String?
    /// The displayed title without its saved position, which moves as progress is saved.
    let displayedItemID: String?
    let displayedEpisodeID: String?
    let displayedTitle: String?
    let rate: Double
    /// The Watch holds its clock at the published chapter's end, so a crossing publishes at once.
    let chapterStart: Double?
  }

  convenience init(
    dependencies: AppDependencies,
    playback: PlaybackModel?,
    minimumPublicationInterval: Duration = WatchCataloguePublisher.publicationMinimumInterval,
    publish: @escaping Publication,
    now: @escaping @MainActor @Sendable () -> Date = Date.init,
    audioActivationWasRefused: @escaping AudioActivationRefusal = { false },
    assemble: @escaping Assembler = { $0.makeSnapshot() }
  ) {
    self.init(
      home: dependencies.homeReading,
      nativeLatest: dependencies.nativeLatestPodcastEpisodesReading,
      nativeContinue: dependencies.nativeContinueListeningReading,
      rssDownloads: dependencies.rssDownloadsReading,
      bookmarks: dependencies.playbackBookmarkStoring,
      accountIdentity: dependencies.accountIdentityReading,
      nativeSubscriptions: dependencies.nativePodcastSubscriptionsReading,
      browseModel: WatchPhoneBrowseModel(
        library: dependencies.library,
        nativeShows: dependencies.nativePodcastShowsReading,
        podcasts: dependencies.podcastReading),
      playback: playback, minimumPublicationInterval: minimumPublicationInterval,
      publish: publish, now: now,
      audioActivationWasRefused: audioActivationWasRefused, assemble: assemble)
  }

  deinit {
    preferenceChanges?.cancel()
    accountTask?.cancel()
    for task in readerTasks {
      task.cancel()
    }
    publicationTask?.cancel()
    assemblyTask?.cancel()
  }

  init(
    home: any HomeReading = NoOpHomeReading(),
    nativeLatest: any NativeLatestPodcastEpisodesReading = NoOpNativeLatestPodcastEpisodesReading(),
    nativeContinue: any NativeContinueListeningReading = NoOpNativeContinueListeningReading(),
    rssDownloads: any RSSDownloadsReading = NoOpRSSDownloadsReading(),
    bookmarks: any PlaybackBookmarkStoring = NoOpPlaybackBookmarkStoring(),
    accountIdentity: any AccountIdentityReading = NoOpAccountIdentityReading(),
    nativeSubscriptions: any NativePodcastSubscriptionsReading = NoOpNativePodcastSubscriptionsReading(),
    browseModel: WatchPhoneBrowseModel? = nil,
    playback: PlaybackModel? = nil,
    defaults: UserDefaults = .standard,
    minimumPublicationInterval: Duration = WatchCataloguePublisher.publicationMinimumInterval,
    publish: @escaping Publication,
    now: @escaping @MainActor @Sendable () -> Date = Date.init,
    audioActivationWasRefused: @escaping AudioActivationRefusal = { false },
    assemble: @escaping Assembler = { $0.makeSnapshot() }
  ) {
    self.home = home
    self.nativeLatest = nativeLatest
    self.nativeContinue = nativeContinue
    self.rssDownloads = rssDownloads
    self.bookmarks = bookmarks
    self.accountIdentity = accountIdentity
    self.nativeSubscriptions = nativeSubscriptions
    self.browseModel =
      browseModel
      ?? WatchPhoneBrowseModel(
        library: WatchEmptyLibraryReading(),
        nativeShows: NoOpNativePodcastShowsReading(),
        podcasts: NoOpPodcastReading())
    self.playback = playback
    self.defaults = defaults
    self.minimumPublicationInterval = minimumPublicationInterval
    self.publish = publish
    self.assemble = assemble
    self.now = now
    self.audioActivationWasRefused = audioActivationWasRefused
  }

  func start() {
    guard started == false else { return }
    started = true
    let changes = PreferenceChanges(read: { [weak self] in
      guard let self else { return "" }
      return MainActor.assumeIsolated { self.preferencesFingerprint }
    })
    preferenceChanges = changes
    changes.observe(names: [UserDefaults.didChangeNotification], object: defaults, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.started else { return }
        self.refresh()
      }
    }
    lifecycleEpoch &+= 1
    let lifetime = lifecycleEpoch
    hasObservedAccount = false
    let stream = accountIdentity.observeAccountIdentity()
    accountTask = Task { [weak self] in
      for await value in stream {
        guard let self, self.started, self.lifecycleEpoch == lifetime, !Task.isCancelled else { return }
        self.accountDidChange(value)
      }
    }
  }

  /// Ends every observation and emits the signed-out/empty context through the injected bridge.
  /// The `publicationEpoch` fence stops a cancelled reader publishing the former account.
  func stopAndPublishSignedOut() {
    stop()
    publishSignedOut()
  }

  func stop() {
    started = false
    preferenceChanges?.cancel()
    preferenceChanges = nil
    lifecycleEpoch &+= 1
    publicationEpoch &+= 1
    accountTask?.cancel()
    accountTask = nil
    cancelReaderTasks()
    publicationTask?.cancel()
    publicationTask = nil
    assemblyTask?.cancel()
    assemblyTask = nil
    assemblyPending = false
    identity = nil
    hasObservedAccount = false
    clearProjection()
    browseModel.unbind()
    watchAccountStamp = nil
  }

  var backwardSkipSeconds: Int {
    SkipIntervalConfiguration.resolvedSeconds(
      defaults.integer(forKey: SkipIntervalConfiguration.backwardStorageKey), forward: false)
  }

  var forwardSkipSeconds: Int {
    SkipIntervalConfiguration.resolvedSeconds(
      defaults.integer(forKey: SkipIntervalConfiguration.forwardStorageKey), forward: true)
  }

  var ratePresets: [Double] {
    PlaybackRatePresetConfiguration.decode(defaults.string(forKey: "player.playbackRate.presets") ?? "").rates
  }

  var removePlayedNativeEpisodes: Bool {
    WatchEpisodeSendPreferences.removesPlayedEpisodes(in: defaults)
  }

  private var preferencesFingerprint: String {
    "\(backwardSkipSeconds)|\(forwardSkipSeconds)|\(ratePresets)|\(removePlayedNativeEpisodes)"
  }
}
