import ABSApi
import AppModel
import MediaPlayer
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

/// The App-owned playback hardware singleton: `PlayerController`, `AVQueuePlayerAudioEngine` and
/// the interruption/remote-command/Now Playing adapters that talk to process-wide system surfaces
/// (`MPRemoteCommandCenter.shared()`, `MPNowPlayingInfoCenter.default()`, the shared
/// `AVAudioSession`).
///
/// Constructed once per process (`shared`) and threaded through every `AppEnvironment` rebuild: a
/// second `RemoteCommandAdapter` would leave the previous one's targets on `MPRemoteCommandCenter`
/// and a rebuilt `AVQueuePlayer` would drop in-flight audio. Only `PlaybackSessionCoordinator` is
/// rebuilt.
@MainActor
final class PlaybackHardware {
  /// The process's one instance. A `static let` runs once, whereas `RootView`'s `@State` would
  /// build a fresh `AVQueuePlayer` and a second set of remote-command handlers on each of SwiftUI's
  /// surplus `RootView` constructions.
  static let shared = PlaybackHardware(
    remoteCommandCenter: RealRemoteCommandCenter(),
    sleepTimerActivitySink: ActivityKitSleepTimerSink())

  /// Exposed so `AppEnvironment` can wire `AVQueuePlayerAudioEngine.configure(tracks:)` from a
  /// `PreparedPlayback` before the matching `PlayerIntent.load`
  /// (`StreamConfiguringPlaybackSyncing`).
  let engine: AVQueuePlayerAudioEngine
  /// The single `PlaybackControlling` every consumer (`AppDependencies.player`,
  /// `RemoteCommandAdapter`) shares.
  let player: SharedPlaybackController
  /// The process's one App Intents route. Its account-scoped handler is weak and replaced by
  /// `RootComposition` on login/logout, so a background Siri request cannot keep an obsolete
  /// account graph alive.
  let siriPlaybackActionRouter = SiriPlaybackActionRouter()
  /// The sleep-timer Live Activity, which follows the one player for the process's lifetime.
  /// `nil` when composed without an activity sink, as every test graph is.
  let sleepTimerActivity: SleepTimerActivityDriver?

  /// Late-bound because the object that renews stream credentials is account-scoped and rebuilt
  /// with every `AppEnvironment`, while this hardware and its `PlayerController` are not.
  private let authorizationRenewerBox = StreamAuthorizationRenewerBox()
  /// Late-bound because the rate coordinator is account-scoped and rebuilt with every
  /// `AppEnvironment`, while the remote-command adapter is registered once per process.
  private let rateCoordinatorBox = PlaybackRateCoordinatorBox()
  /// Late-bound because the playback/connection models are rebuilt with every account environment,
  /// while the remote-command and Now Playing integrations remain process-lifetime objects.
  private let playbackAvailabilityBox = PlaybackAvailabilityBox()
  private let remoteCommandAdapter: RemoteCommandAdapter
  private var nowPlayingAdapter: NowPlayingMetadataAdapter?
  private var nowPlayingItemInfoProvider: (any NowPlayingItemInfoProviding)?
  private var nowPlayingArtworkClient: (any ArtworkServing)?
  /// Background App Intents can compose authenticated playback before SwiftUI installs a window.
  /// Start with a safe 1x artwork scale so Now Playing metadata is still published immediately;
  /// `RootView` replaces it with the active window's real scale as soon as a scene appears.
  private var displayScale: CGFloat = 1
  /// Whether any scene has reported its phase to `handleScenePhase`. A launch driven purely by a
  /// background App Intent never has one, so no foreground is assumed on its behalf (see
  /// `noteHeadlessEntry`).
  private var hasObservedScenePhase = false
  /// Keeps the engine's Voice Boost switch in step with the preference for the process's lifetime.
  private var voiceBoostObserver: VoiceBoostPreferenceObserver?

  /// Diagnostic for tests: background intent launches bind Now Playing before any SwiftUI window
  /// supplies its display scale.
  var isNowPlayingMetadataBound: Bool { nowPlayingAdapter != nil }

  /// `remoteCommandCenter` is the real `MPRemoteCommandCenter` in production; `WhirrTests` injects
  /// `FakeRemoteCommandRegistering` to prove registration happens once per instance. No default: a
  /// default-argument expression evaluates at the call site's isolation, and
  /// `RealRemoteCommandCenter.init` is `@MainActor`. `sleepTimerActivitySink` is ActivityKit in
  /// production (none: no activity driven); `defaults` is where Voice Boost is read.
  init(
    remoteCommandCenter: any RemoteCommandRegistering,
    sleepTimerActivitySink: (any SleepTimerActivitySink)? = nil,
    defaults: UserDefaults = .standard
  ) {
    let engine = AVQueuePlayerAudioEngine()
    self.engine = engine

    let controller = PlayerController(
      engine: engine, clock: SystemPlaybackClock(), preferences: UserDefaultsPlaybackPreferences(),
      authorizationRenewer: authorizationRenewerBox,
      stallScheduler: TaskPlayerStallScheduler())
    let interruptionAdapter = AudioInterruptionRouteAdapter(player: controller)

    let player = SharedPlaybackController(underlying: controller, interruptionAdapter: interruptionAdapter)
    self.player = player

    remoteCommandAdapter = RemoteCommandAdapter(
      center: remoteCommandCenter, controller: player, rateCoordinator: rateCoordinatorBox,
      playbackAvailability: playbackAvailabilityBox)
    sleepTimerActivity = sleepTimerActivitySink.map { SleepTimerActivityDriver(player: player, sink: $0) }

    remoteCommandAdapter.register()
    sleepTimerActivity?.start()
    voiceBoostObserver = VoiceBoostPreferenceObserver(defaults: defaults) { [weak engine] enabled in
      engine?.setVoiceBoostEnabled(enabled)
    }
  }

  /// Points the process-lifetime `PlayerController` at the current `AppEnvironment`'s stream
  /// decorator, so an engine authentication failure is answered with fresh credentials for this
  /// account. Called once per environment rebuild; the box holds `decorator` weakly, so a
  /// superseded environment's stack is not kept alive.
  func bindStreamAuthorizationRenewer(_ decorator: StreamConfiguringPlaybackSyncing) {
    authorizationRenewerBox.underlying = decorator
  }

  /// Points the process-lifetime `RemoteCommandAdapter` at the current account's rate coordinator,
  /// so a lock-screen or CarPlay speed change writes to this account's overrides. Called once per
  /// environment rebuild; the box holds it weakly, so a superseded coordinator is not kept alive.
  func bindPlaybackRateCoordinator(_ coordinator: PlaybackRateCoordinator) {
    rateCoordinatorBox.underlying = coordinator
  }

  /// Points the process-lifetime system surfaces at the current account's playback and
  /// reachability models. The box keeps both weakly so a logout cannot leave a lock-screen command
  /// recovering the previous account.
  func bindPlaybackAvailability(
    playback: PlaybackModel, connectivityModel: ConnectivityModel?
  ) {
    playbackAvailabilityBox.bind(playback: playback, connectivityModel: connectivityModel)
    nowPlayingAdapter?.refreshPlaybackAvailability()
  }

  /// Points Voice Boost at this account's show settings and its loaded show. Called once per
  /// environment rebuild. Nil settings (a graph with no account) leave the app-wide preference in
  /// charge.
  func bindVoiceBoostShows(
    settings: (any VoiceBoostShowSettingsReading)?, playback: PlaybackModel
  ) {
    guard let settings else {
      voiceBoostObserver?.stopFollowingShows()
      return
    }
    voiceBoostObserver?.followShows(overrides: settings.observeVoiceBoostOverrides()) {
      [weak playback] in
      guard let playback, playback.loadedEpisodeID != nil else { return nil }
      return playback.loadedItemID
    }
  }

  /// Clears the process-wide playback surfaces after the model-level logout preflight has stopped
  /// and detached account-scoped playback. The adapter and remote-command registrations outlive an
  /// `AppEnvironment`, so logout must remove both explicitly.
  func prepareForLogout() {
    siriPlaybackActionRouter.unbind()
    playbackAvailabilityBox.unbind()
    voiceBoostObserver?.stopFollowingShows()
    nowPlayingAdapter?.clear()
    remoteCommandAdapter.teardown()
    sleepTimerActivity?.endForLogout()
  }

  /// Re-enables handlers when a new authenticated shell is composed. Logout tears them down, so a
  /// later login must register the same adapter again.
  func setRemoteCommandsEnabled(_ enabled: Bool) {
    if enabled {
      remoteCommandAdapter.register()
    } else {
      remoteCommandAdapter.teardown()
    }
  }

  /// Rebinds Now Playing metadata to the signed-in account's library data and cover client. Called
  /// once per `AppEnvironment` rebuild, since title, author and cover come from the account-scoped
  /// database. Replacing `nowPlayingAdapter` deallocates the previous one, which cancels its
  /// progress/artwork tasks (`NowPlayingMetadataAdapter.deinit`).
  func rebindNowPlaying(itemInfoProvider: any NowPlayingItemInfoProviding, coverImageClient: any ArtworkServing) {
    nowPlayingItemInfoProvider = itemInfoProvider
    nowPlayingArtworkClient = coverImageClient
    rebuildNowPlayingIfReady()
  }

  /// Drops the engine's position-tick cadence while backgrounded and restores it on return
  /// (`AVQueuePlayerAudioEngine.PositionCadence`). `SceneRegistry` passes phone scenes' phase only
  /// (CarPlay never claims the faster cadence); the first report undoes a headless launch's slower
  /// cadence (`noteHeadlessEntry`). `.inactive` carries no change, as in
  /// `ScenePhaseLifecycleMapper`: iOS posts it entering and leaving the background, so acting
  /// would slow the cadence for an app-switcher peek and race the following `.active`.
  func handleScenePhase(_ phase: ScenePhase) {
    hasObservedScenePhase = true
    switch phase {
    case .active:
      engine.setPositionCadence(.foreground)
      // Only the foreground may start an activity for a timer set where none could start (Siri).
      sleepTimerActivity?.reconcile()
    case .background: engine.setPositionCadence(.background)
    case .inactive: break
    @unknown default: break
    }
  }

  /// Applies the backgrounded cadence to a launch with no phone scene (CarPlay-only, or a
  /// background App Intent via `SiriPlaybackIntentRuntime`), where "Hey Siri, resume listening"
  /// could otherwise play a whole book at the 2 Hz foreground tick. A no-op once any scene has
  /// reported: the same intents run with the app on screen and must not slow the scrubber. A later
  /// scene restores the cadence through its opening report to `SceneRegistry`.
  func noteHeadlessEntry() {
    guard !hasObservedScenePhase else { return }
    engine.setPositionCadence(.background)
  }

  /// Supplies the active SwiftUI window's display scale. `RootView` calls this once installed in a
  /// window; rebuilding on a scale change keeps lock-screen artwork requests aligned with the
  /// window being rendered into.
  func updateDisplayScale(_ displayScale: CGFloat) {
    guard displayScale > 0, self.displayScale != displayScale else { return }
    self.displayScale = displayScale
    rebuildNowPlayingIfReady()
  }

  private func rebuildNowPlayingIfReady() {
    guard let nowPlayingItemInfoProvider, let nowPlayingArtworkClient else {
      return
    }
    nowPlayingAdapter = NowPlayingMetadataAdapter(
      sink: MPNowPlayingInfoCenter.default(),
      controller: SecondaryPlaybackControllingView(shared: player),
      itemInfoProvider: nowPlayingItemInfoProvider,
      coverImageClient: nowPlayingArtworkClient,
      displayScale: displayScale,
      playbackAvailability: playbackAvailabilityBox
    )
  }
}
