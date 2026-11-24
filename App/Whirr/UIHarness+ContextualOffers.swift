#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import Foundation
  import Persistence
  import PlayerCore
  import SwiftUI
  import Synchronization
  import SyncEngine

  /// In-memory stand-ins for what the New Episode Notifications offer reads. One instance for the
  /// process: the harness root is a value and is rebuilt freely, and the offer's state has to
  /// outlive that.
  ///
  /// Scenario fake: the followed collection and the notification permission are device-owned, and
  /// the real authorizer would raise the system prompt.
  @MainActor
  final class HarnessNotificationOffer {
    static let shared = HarnessNotificationOffer()

    let nativeShowsModel = NativePodcastShowsModel(reading: HarnessFollowedShowsReading())
    let notificationModel = PodcastNotificationSettingsModel(
      preference: HarnessNotificationIntent(), authorizer: HarnessNotificationAuthorizer())
    let marker = HarnessNotificationOfferMarker()
  }

  struct HarnessFollowedShowsReading: NativePodcastShowsReading {
    private static let shows = (1...4).map { index in
      ItemSummary(
        serverItemId: "harness-followed-show-\(index)",
        mediaKind: "podcast",
        title: "Followed Show \(index)",
        author: "Harness Publisher \(index)",
        durationSeconds: nil,
        category: .podcast)
    }

    func observeShows() -> AsyncStream<NativePodcastShowsSnapshot> {
      AsyncStream { continuation in
        continuation.yield(NativePodcastShowsSnapshot(mode: .alphabetical, shows: Self.shows))
      }
    }

    func observeShow(itemId: String) -> AsyncStream<ItemSummary?> {
      AsyncStream { continuation in
        continuation.yield(Self.shows.first { $0.serverItemId == itemId })
      }
    }
  }

  private actor HarnessNotificationIntent: RSSNotificationIntentReading,
    RSSNotificationIntentWriting
  {
    private var enabled = false
    func isNewEpisodeNotificationEnabled() async -> Bool { enabled }
    func setNewEpisodeNotificationEnabled(_ enabled: Bool) async { self.enabled = enabled }
  }

  /// Undecided until asked, then allowed, without the system prompt: the real prompt is a device
  /// check.
  private actor HarnessNotificationAuthorizer: RSSLocalNotificationAuthorizing {
    private var status = RSSLocalNotificationAuthorizationStatus.notDetermined
    func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus { status }
    func requestAuthorization() async -> RSSLocalNotificationAuthorizationStatus {
      status = .allowed
      return status
    }
    func backgroundRefreshStatus() async -> BackgroundRefreshStatus { .available }
  }

  final class HarnessNotificationOfferMarker: PodcastNotificationOfferMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    func isAnswered() -> Bool { lock.withLock { answered } }
    func markAnswered() { lock.withLock { answered = true } }
  }

  // MARK: - Reduce Ads offer

  /// A second player over a local, single-file episode, with a status source that says "off" until
  /// the harness's own setting is turned on. Nothing here reaches the real ad-skip composition,
  /// the speech model or `UserDefaults.standard`.
  @MainActor
  final class HarnessReduceAdsOffer {
    static let shared = HarnessReduceAdsOffer()
    static let episodeID = "harness-episode"

    let player: PlayerController
    let playbackRate: PlaybackRateCoordinator
    let playback: PlaybackModel
    let dependencies: AdSkipOfferDependencies

    private init() {
      let suite = "whirr.harness.reduce-ads-offer"
      let defaults = UserDefaults(suiteName: suite) ?? .standard
      defaults.removePersistentDomain(forName: suite)

      let player = PlayerController(engine: HarnessAudioEngine(), clock: SystemPlaybackClock())
      let playbackRate = PlaybackRateCoordinator(
        reading: NoOpItemPlaybackSettingsAccess(),
        writing: NoOpItemPlaybackSettingsAccess(),
        preferences: UserDefaultsPlaybackPreferences(),
        player: player)
      self.player = player
      self.playbackRate = playbackRate
      playback = PlaybackModel(
        sync: HarnessPlaybackSyncing(preparesLocalEpisode: true),
        player: player,
        account: HarnessAccountLifecycle(),
        appLifecycle: HarnessAppLifecycle(),
        rateCoordinator: playbackRate,
        skipRanges: HarnessAdSkipStatusSource(defaults: defaults))
      dependencies = AdSkipOfferDependencies(
        settings: AdSkipSettingsModel(
          installer: HarnessSpeechAsset(), network: HarnessNeverUnmeteredNetwork(),
          defaults: defaults, onInstalled: {}, onForget: {}),
        store: AdSkipOfferStore(defaults: defaults))
    }
  }

  /// No ranges; the status follows the harness's own setting: off and covered, then checking.
  final class HarnessAdSkipStatusSource: PlaybackSkipRangeSource {
    private nonisolated(unsafe) let defaults: UserDefaults
    private let listeners = Listeners()

    /// A `Mutex` cannot be captured by the observer block, so a reference holds it.
    nonisolated final class Listeners: Sendable {
      private let continuations = Mutex<[AsyncStream<Void>.Continuation]>([])

      func add(_ continuation: AsyncStream<Void>.Continuation) {
        continuations.withLock { $0.append(continuation) }
      }

      func yieldAll() {
        continuations.withLock { for continuation in $0 { continuation.yield() } }
      }
    }

    init(defaults: UserDefaults) {
      self.defaults = defaults
      NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
      ) { [listeners] _ in
        listeners.yieldAll()
      }
    }

    func skipRanges(for request: PlaybackSkipRangeRequest) async -> [PlayerSkipRange] { [] }
    func skipRangeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func undoSkip(_ range: PlayerSkipRange, for request: PlaybackSkipRangeRequest) async {}

    func analysisStatus(for request: PlaybackSkipRangeRequest) async -> PlaybackAdAnalysisStatus {
      AdSkipPreference.isEnabled(in: defaults) ? .checking : .notEnabled
    }

    func analysisStatusChanges() -> AsyncStream<Void> {
      AsyncStream { listeners.add($0) }
    }

    func checkNow(for request: PlaybackSkipRangeRequest) async {}
  }

  /// The speech model is absent and never arrives, so Turn On always asks about the download.
  nonisolated struct HarnessSpeechAsset: SpeechAssetInstalling {
    func state() async -> SpeechAssetState { .notInstalled }
    func install(progress: @Sendable (Progress) -> Void) async throws {
      try await Task.sleep(for: .seconds(3_600))
    }
  }

  nonisolated struct HarnessNeverUnmeteredNetwork: UnmeteredNetworkWaiting {
    func waitForUnmeteredNetwork() async throws {
      try await Task.sleep(for: .seconds(3_600))
    }
  }

  extension UIHarnessRootView {
    /// `WHIRR_UI_HARNESS_SCREEN=player-reduce-ads-offer`.
    ///
    /// Scenario fake: ad-skip analysis, the speech model and the stored preference are
    /// device-owned, and the harness must neither prompt nor reach the real analysis pipeline.
    var playerReduceAdsOfferBody: some View {
      let offer = HarnessReduceAdsOffer.shared
      return ZStack {
        Color(red: 0.05, green: 0.45, blue: 0.4).ignoresSafeArea()
        ExpandedPlayerView(
          itemID: UIHarnessFixtures.itemID,
          playback: offer.playback,
          connectivityModel: nil,
          player: offer.player,
          library: session.library,
          nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
          coverClient: session.coverClient,
          navigation: session.navigation,
          paletteService: session.paletteService,
          actions: session.actions,
          playbackRate: offer.playbackRate,
          finishedStatus: session.finishedStatus,
          extrasAccess: session.extrasAccess,
          authorSeriesReading: NoOpAuthorSeriesReading(),
          makeListeningQueueModel: { ListeningQueueModel() },
          makeItemHistoryModel: { itemID in
            ItemHistoryModel(
              itemId: itemID, category: .podcast, history: session.historyAccess)
          },
          effectiveAppColorScheme: Self.harnessColorScheme
        )
      }
      .environment(\.adSkipOfferDependencies, offer.dependencies)
      .task {
        await offer.playback.start(
          itemID: UIHarnessFixtures.itemID, episodeID: HarnessReduceAdsOffer.episodeID)
      }
    }
  }
#endif
