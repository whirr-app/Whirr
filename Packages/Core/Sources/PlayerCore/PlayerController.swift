import Observation

/// The real `PlaybackControlling` conformance (ARCHITECTURE.md §4). A thin `@MainActor` shell,
/// not an actor, around the pure `PlayerReducer`: it reads the injected clock, feeds intents and
/// engine events into the reducer, and carries out the returned effects against `AudioEngine`.
/// State-machine and listening-delta behaviour lives in `PlayerReducer`.
///
/// `PlaybackControlling` is `Sendable` (so `AppDependencies` can hold it) but not `@MainActor`, so
/// its requirements are nonisolated. This type is only used from the main actor (AppModel and
/// `AudioEngine` are `@MainActor`), so conforming members bridge with `MainActor.assumeIsolated`
/// instead of making the boundary `async`.
@MainActor
@Observable
public final class PlayerController: PlaybackControlling {
  /// A stream may legitimately buffer for over ten seconds with
  /// `automaticallyWaitsToMinimizeStalling`, so the deadline leaves room for a poor connection
  /// while still ending a dead stream.
  public static let stallTimeout: Double = 20
  /// Deadline for AVFoundation preparation of a streamed item, including after a seek. A starting
  /// value, not a measured one, and tunable separately from `stallTimeout`.
  public static let preparationTimeout: Double = 20

  nonisolated public var state: PlayerState {
    MainActor.assumeIsolated { observedState }
  }

  /// Read by the expanded player's native menus instead of `state`. Published only when rate,
  /// timer structure, or loaded-item availability changes.
  nonisolated public var quickActions: PlayerQuickActionsState {
    MainActor.assumeIsolated { observedQuickActions }
  }

  /// Full timer values are published separately so a countdown label can follow its remaining
  /// seconds without making the menu structure depend on the playback tick.
  nonisolated public var quickActionsSleepTimer: SleepTimerState {
    MainActor.assumeIsolated { observedQuickActionsSleepTimer }
  }

  /// Tracked apart from `state`, which carries the playhead. Every play/pause affordance renders
  /// this, and reading it from `state` would invalidate them all twice a second. A presented
  /// context menu rebuilding at that rate re-renders its blurred backdrop, visibly pulsing.
  nonisolated public var isPlaybackIntended: Bool {
    MainActor.assumeIsolated { observedPlaybackIntent }
  }
  nonisolated public let progressEvents: AsyncStream<PlaybackProgressEvent>

  /// Outside Observation: the reducer holds the whole state machine, so tracking it would make
  /// every reader of anything derived from it depend on every mutation. The projected properties
  /// above are the observable surface, published from `perform` at their own rates.
  @ObservationIgnored private var reducer: PlayerReducer
  private var observedState: PlayerState
  private var observedQuickActions: PlayerQuickActionsState
  private var observedQuickActionsSleepTimer: SleepTimerState
  private var observedPlaybackIntent: Bool
  private let engine: any AudioEngine
  private let clock: any PlaybackClock
  private let preferences: any PlaybackPreferences
  private let authorizationRenewer: (any StreamAuthorizationRenewing)?
  private let stallScheduler: (any PlayerStallScheduling)?
  /// Scopes deadlines independently of the reducer's playback generation: one generation can
  /// buffer, recover, and buffer again while an old deadline is still racing in.
  private var stallToken = 0
  /// One renewal per playback attempt (`StreamAuthorizationRenewing`). Cleared by `.ready` (the
  /// next authentication failure is then a new attempt) and by an external `.load`/`.retry`,
  /// never by the automatic reload this flag gates.
  private var didAttemptAuthorizationRenewal = false
  /// Outside the reducer because it is measured on `clock.continuousNow()`, which the reducer
  /// never sees, and must outlive the `load` that resets the reducer's timer.
  @ObservationIgnored private var sleepTimerResumeGrace = SleepTimerResumeGrace()
  private let progressContinuation: AsyncStream<PlaybackProgressEvent>.Continuation
  @ObservationIgnored private var listenerTask: Task<Void, Never>?
  @ObservationIgnored private var timeoutListenerTask: Task<Void, Never>?

  /// `preferences` defaults to `NoOpPlaybackPreferences`. The saved rate is read once at
  /// construction; smart-rewind policy is read at each play/toggle boundary so Settings changes
  /// apply without relaunch. Rate changes are persisted by the App-owned coordinator.
  /// Without an `authorizationRenewer` an authentication failure stays failed. Without a
  /// `stallScheduler` there is no stall deadline.
  public init(
    engine: any AudioEngine, clock: any PlaybackClock,
    preferences: any PlaybackPreferences = NoOpPlaybackPreferences(),
    authorizationRenewer: (any StreamAuthorizationRenewing)? = nil,
    stallScheduler: (any PlayerStallScheduling)? = nil
  ) {
    self.engine = engine
    self.clock = clock
    self.preferences = preferences
    self.authorizationRenewer = authorizationRenewer
    self.stallScheduler = stallScheduler
    let initialReducer = PlayerReducer(now: clock.now())
    self.reducer = initialReducer
    self.observedState = initialReducer.state
    self.observedQuickActions = PlayerQuickActionsState(state: initialReducer.state)
    self.observedQuickActionsSleepTimer = initialReducer.state.sleepTimer
    self.observedPlaybackIntent = initialReducer.state.isPlaybackIntended
    var continuation: AsyncStream<PlaybackProgressEvent>.Continuation!
    self.progressEvents = AsyncStream { continuation = $0 }
    self.progressContinuation = continuation

    // Relaunch restore: the saved global rate becomes the reducer's starting rate, visible in
    // `state` before any `.load`. Goes through the reducer, not `send`, so construction never
    // turns a restore into a mutation.
    if let restoredRate = preferences.loadRate() {
      perform(reducer.handle(.setRate(restoredRate), now: clock.now()))
    }

    let events = engine.events
    listenerTask = Task { [weak self] in
      for await event in events {
        self?.apply(engineEvent: event)
      }
    }

    if let stallScheduler {
      let timeouts = stallScheduler.timeouts
      timeoutListenerTask = Task { [weak self] in
        for await token in timeouts {
          self?.apply(stallTimeoutToken: token)
        }
      }
    }
  }

  deinit {
    listenerTask?.cancel()
    timeoutListenerTask?.cancel()
  }

  nonisolated public func send(_ intent: PlayerIntent) {
    MainActor.assumeIsolated {
      // A caller asking for this item again is a fresh attempt, so it re-arms the single
      // automatic renewal. The automatic reload does not come through here.
      switch intent {
      case .load, .retry: didAttemptAuthorizationRenewal = false
      default: break
      }
      apply(intent: intent)
    }
  }

  private func apply(intent: PlayerIntent) {
    let wasPlaybackIntended = reducer.state.isPlaybackIntended
    switch intent {
    case .play, .toggle:
      // Read at the intent boundary so a Settings change applies on the next resume.
      reducer.isSmartRewindEnabled = preferences.loadSmartRewindEnabled()
    case .setSleepTimer(let duration):
      sleepTimerResumeGrace.timerChosen(duration)
    default:
      break
    }
    perform(reducer.handle(intent, now: clock.now()))
    if wasPlaybackIntended == false, reducer.state.isPlaybackIntended {
      restartSleepTimerIfResumedInsideGrace()
    }
  }

  /// A resume shortly after a sleep timer stopped playback starts that timer again. Only a resume
  /// counts (intent going from paused to playing), and only while no timer is running, so a timer
  /// the listener has since chosen is never replaced.
  private func restartSleepTimerIfResumedInsideGrace() {
    guard reducer.state.sleepTimer.mode == .off else { return }
    guard
      let choice = sleepTimerResumeGrace.takeRestorableChoice(
        at: clock.continuousNow(), window: preferences.loadSleepTimerResumeGraceSeconds())
    else { return }
    sleepTimerResumeGrace.timerChosen(choice)
    perform(reducer.restartSleepTimerOnResume(choice, now: clock.now()))
  }

  private func apply(engineEvent: AudioEngineEvent) {
    if case .ready = engineEvent {
      didAttemptAuthorizationRenewal = false
    }
    perform(reducer.handle(engineEvent, now: clock.now()))
    if case .failed(_, let failure) = engineEvent {
      renewAuthorizationAndReloadIfNeeded(after: failure)
    }
  }

  private func apply(stallTimeoutToken token: Int) {
    // A deadline from a previous waiting window must not stall a later healthy one. The reducer
    // also checks its phase so a timeout racing a cancellation is inert.
    guard token == stallToken else { return }
    perform(reducer.handleStallTimeout(now: clock.now()))
  }

  /// A streamed asset rejected as unauthenticated fails inside AVFoundation, so it never reaches
  /// the transport's own reactive refresh or recovery latch, and every retry replays the same
  /// stale credential. Renews once, then reloads. A failed renewal leaves the item failed, since
  /// its transport has by then raised recovery through the ordinary path.
  private func renewAuthorizationAndReloadIfNeeded(after failure: AudioEngineFailure) {
    guard failure.isAuthenticationFailure, let authorizationRenewer else { return }
    // Only act on a failure the reducer adopted: an event from a generation a later `load` has
    // displaced is stale, and reloading on it would resurrect a dead item.
    guard case .failed(let current) = reducer.state.phase, current == failure else { return }
    guard didAttemptAuthorizationRenewal == false else { return }
    didAttemptAuthorizationRenewal = true

    Task { @MainActor [weak self] in
      guard await authorizationRenewer.renewStreamAuthorizationAndReconfigure() else { return }
      // Not `send`: the automatic path must not re-arm its own one-attempt guard.
      self?.apply(intent: .retry)
    }
  }

  private func perform(_ result: PlayerStepResult) {
    if result.progressEvents.contains(where: { $0.sleepTimerExpiry == .expired }) {
      sleepTimerResumeGrace.timerExpired(at: clock.continuousNow())
    }
    let wasAwaitingAudioPhase = awaitingAudioPhase
    publishReducerState()
    updateStallDeadline(wasAwaitingAudioPhase: wasAwaitingAudioPhase)
    for effect in result.effects { carryOut(effect) }
    for event in result.progressEvents { progressContinuation.yield(event) }
  }

  /// The condition a deadline measures: a streamed item the listener has asked to hear while it
  /// is preparing, buffering, or seeking. Paused waiting is not a stall, and a complete local
  /// download can never be one.
  private var awaitingAudioPhase: PlayerPhase? {
    guard observedState.isPlaybackIntended, observedState.item?.isStreaming == true else { return nil }
    switch observedState.phase {
    case .preparing, .buffering, .seeking:
      return observedState.phase
    default:
      return nil
    }
  }

  /// Derives the single deadline from the edges of the phase condition rather than enumerating
  /// reducer handlers, so every cancellation path follows: ready, stop, load, failure, pause and
  /// generation changes all leave the covered phases. The scheduler replaces the deadline when a
  /// waiting phase changes; a position tick in the same phase leaves it untouched.
  private func updateStallDeadline(wasAwaitingAudioPhase: PlayerPhase?) {
    guard let stallScheduler, wasAwaitingAudioPhase != awaitingAudioPhase else { return }

    if let currentPhase = awaitingAudioPhase {
      stallToken += 1
      let timeout = currentPhase == .buffering ? Self.stallTimeout : Self.preparationTimeout
      stallScheduler.schedule(after: timeout, token: stallToken)
    } else {
      stallScheduler.cancel()
    }
  }

  /// Where the reducer's state becomes observable. `observedState` is written every step for
  /// position-driven surfaces; the narrower projections are assigned only when their visible
  /// values differ, so a position tick leaves intent and menu structure untouched. The reducer
  /// can't give that granularity itself: it isn't `Equatable`, so tracking it notified everyone
  /// every step.
  private func publishReducerState() {
    let latest = reducer.state
    observedState = latest
    let latestQuickActions = PlayerQuickActionsState(state: latest)
    if observedQuickActions != latestQuickActions {
      observedQuickActions = latestQuickActions
    }
    if observedQuickActionsSleepTimer != latest.sleepTimer {
      observedQuickActionsSleepTimer = latest.sleepTimer
    }
    if observedPlaybackIntent != latest.isPlaybackIntended {
      observedPlaybackIntent = latest.isPlaybackIntended
    }
  }

  private func carryOut(_ effect: PlayerEffect) {
    switch effect {
    case .loadEngine(let track, let localOffset, let rate, let generation, let trim):
      engine.load(track: track, localOffset: localOffset, rate: rate, generation: generation, trim: trim)
    case .seekEngine(let localOffset):
      engine.seek(toLocalOffset: localOffset)
    case .play:
      engine.play()
    case .pause:
      engine.pause()
    case .stop:
      engine.stop()
    case .setRate(let rate):
      engine.setRate(rate)
    case .setVolume(let volume):
      engine.setVolume(volume)
    case .setBoundary(let localOffset):
      engine.setBoundary(atLocalOffset: localOffset)
    }
  }
}
