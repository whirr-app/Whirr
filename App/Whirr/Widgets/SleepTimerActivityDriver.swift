import Foundation
import Observation
import PlayerCore
import WidgetProtocol

/// The ActivityKit calls the driver makes, behind a seam so tests can record them.
@MainActor
protocol SleepTimerActivitySink: AnyObject {
  /// The listener can turn Live Activities off for the app; then nothing is started.
  var areActivitiesEnabled: Bool { get }
  /// Whether an activity this sink started is still on screen. The listener can dismiss one, and
  /// the system ends one after eight hours.
  var hasActivity: Bool { get }
  /// Fails outside the foreground unless a `LiveActivityIntent` is performing; the driver tries
  /// again at the next foreground (`reconcile()`).
  func start(_ state: SleepTimerActivityAttributes.ContentState) -> Bool
  func update(_ state: SleepTimerActivityAttributes.ContentState)
  /// Ends every activity of this kind with immediate dismissal, including one a previous process
  /// left behind.
  func endAll()
}

/// What the activity is derived from: the timer, and the parts of the player state it depends
/// on. Read by `reading(_:)` so that, while the timer is off, only the timer is observed and the
/// driver does not wake on every playback tick.
nonisolated struct SleepTimerActivityInput: Equatable, Sendable {
  var timer: SleepTimerMode
  var isPlaying: Bool
  var globalPosition: Double
  var totalDuration: Double?
  var isEpisode: Bool
  var rate: Double

  static let off = SleepTimerActivityInput(
    timer: .off, isPlaying: false, globalPosition: 0, totalDuration: nil, isEpisode: false, rate: 1)

  @MainActor
  static func reading(_ player: any PlaybackControlling) -> SleepTimerActivityInput {
    let timer = player.quickActionsSleepTimer.mode
    guard timer != .off else { return .off }
    let state = player.state
    return SleepTimerActivityInput(
      timer: timer, isPlaying: state.phase == .playing, globalPosition: state.globalPosition,
      totalDuration: state.item?.timeline.totalDuration, isEpisode: state.item?.episodeID != nil,
      rate: state.rate)
  }
}

/// The pure part of the driver: what the activity should show for an input, and whether a new
/// state differs enough from the last one sent to be worth an update.
nonisolated enum SleepTimerActivityDerivation {
  /// An `endsAt` that moves by no more than this is not re-sent. A countdown is decremented on
  /// engine ticks (0.5 s foreground, 2 s background), so its `now + remaining` wobbles by up to a
  /// tick; the system draws the countdown from `endsAt` itself in between.
  static let endsAtTolerance: TimeInterval = 2
  /// `PlayerReducer.itemEndBoundaryTolerance`: an end-of-chapter position this close to the item's
  /// end is the end-of-item choice, which the state stores the same way.
  static let itemEndTolerance: Double = 1

  static func contentState(
    for input: SleepTimerActivityInput, isRunning: Bool, now: Date
  ) -> SleepTimerActivityAttributes.ContentState? {
    switch input.timer {
    case .off:
      return nil
    case .countdown(let remaining):
      let remaining = max(0, remaining.isFinite ? remaining : 0)
      return try? SleepTimerActivityAttributes.ContentState(
        label: .countdown, isRunning: isRunning,
        endsAt: isRunning ? now.addingTimeInterval(remaining) : nil, remainingSeconds: remaining,
        canExtend: true, isFading: remaining < SleepTimerFade.windowSeconds)
    case .endOfChapter(let atPosition):
      // Media seconds become wall-clock seconds at the current rate; a rate change re-derives.
      let rate = input.rate.isFinite && input.rate > 0 ? input.rate : 1
      let media = atPosition - input.globalPosition
      let remaining = max(0, media.isFinite ? media / rate : 0)
      return try? SleepTimerActivityAttributes.ContentState(
        label: label(atPosition: atPosition, input: input), isRunning: isRunning,
        endsAt: isRunning ? now.addingTimeInterval(remaining) : nil, remainingSeconds: remaining,
        canExtend: false, isFading: false)
    }
  }

  static func label(atPosition: Double, input: SleepTimerActivityInput) -> SleepTimerActivityLabel {
    guard let total = input.totalDuration, abs(atPosition - total) <= itemEndTolerance else {
      return .endOfChapter
    }
    return input.isEpisode ? .endOfEpisode : .endOfBook
  }

  static func isMaterialChange(
    from old: SleepTimerActivityAttributes.ContentState?,
    to new: SleepTimerActivityAttributes.ContentState?
  ) -> Bool {
    guard let old, let new else { return (old == nil) != (new == nil) }
    if old.label != new.label || old.isRunning != new.isRunning || old.canExtend != new.canExtend
      || old.isFading != new.isFading
    {
      return true
    }
    if let oldEnd = old.endsAt, let newEnd = new.endsAt {
      return abs(oldEnd.timeIntervalSince(newEnd)) > endsAtTolerance
    }
    return abs(old.remainingSeconds - new.remainingSeconds) > endsAtTolerance
  }
}

/// Keeps one sleep-timer Live Activity in step with the player. Process-lifetime, owned by
/// `PlaybackHardware`.
///
/// Running: the countdown advances only in `.playing`, but seeks, skips and chapter selection pass
/// through `.seeking`, so a spell out of `.playing` shorter than `runningHold` keeps the clock.
///
/// Starting: when a timer is set, replaced or extended with no activity, and at each foreground
/// (`reconcile()`). Outside the foreground only a `LiveActivityIntent` may start one, so the app
/// performer reconciles inside `perform()`.
///
/// Ending: whenever the timer is off, and at start, so a killed process's activity doesn't linger.
@MainActor
final class SleepTimerActivityDriver {
  static let runningHold: Duration = .milliseconds(1500)

  typealias HoldScheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>

  private let read: @MainActor () -> SleepTimerActivityInput
  private let sink: any SleepTimerActivitySink
  private let now: @MainActor () -> Date
  private let scheduleHold: HoldScheduler

  private var started = false
  private var generation: UInt64 = 0
  /// The input the driver last read; tests wait on it to know an observation has been handled.
  private(set) var observedInput = SleepTimerActivityInput.off
  private var isRunning = false
  private var holdTask: Task<Void, Never>?
  /// The last state the sink accepted, by `start` or `update`.
  private var lastSent: SleepTimerActivityAttributes.ContentState?
  /// The last derived state, sent or not; a start attempt is judged against it.
  private var lastDerived: SleepTimerActivityAttributes.ContentState?

  init(
    read: @escaping @MainActor () -> SleepTimerActivityInput,
    sink: any SleepTimerActivitySink,
    now: @escaping @MainActor () -> Date = Date.init,
    scheduleHold: @escaping HoldScheduler = SleepTimerActivityDriver.sleepingHold
  ) {
    self.read = read
    self.sink = sink
    self.now = now
    self.scheduleHold = scheduleHold
  }

  convenience init(player: any PlaybackControlling, sink: any SleepTimerActivitySink) {
    self.init(read: { SleepTimerActivityInput.reading(player) }, sink: sink)
  }

  static func sleepingHold(_ duration: Duration, _ expire: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
      do { try await Task.sleep(for: duration) } catch { return }
      expire()
    }
  }

  func start() {
    guard !started else { return }
    started = true
    generation &+= 1
    sink.endAll()
    lastSent = nil
    lastDerived = nil
    observe(generation: generation)
  }

  /// At every foreground, and inside a sleep-timer intent's `perform()`: start the activity if a
  /// timer runs without one.
  func reconcile() {
    guard started else { return }
    refreshInput()
    let derived = derive()
    lastDerived = derived
    guard let derived else { return }
    if sink.hasActivity {
      send(derived)
    } else {
      attemptStart(derived)
    }
  }

  /// Logout: the timer goes off with playback, which ends the activity; this ends it even if the
  /// observation has not run yet.
  func endForLogout() {
    sink.endAll()
    lastSent = nil
  }

  private func observe(generation: UInt64) {
    guard started, self.generation == generation else { return }
    let input = withObservationTracking {
      read()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observe(generation: generation) }
    }
    self.observedInput = input
    updateRunning()
    apply()
  }

  private func refreshInput() {
    observedInput = read()
    updateRunning()
  }

  private func updateRunning() {
    if observedInput.timer == .off {
      cancelHold()
      isRunning = false
    } else if observedInput.isPlaying {
      cancelHold()
      isRunning = true
    } else if isRunning, holdTask == nil {
      let generation = generation
      holdTask = scheduleHold(Self.runningHold) { [weak self] in
        guard let self, self.generation == generation else { return }
        self.holdTask = nil
        // Read directly, not through `updateRunning()`, which would start another hold.
        self.observedInput = self.read()
        if !self.observedInput.isPlaying { self.isRunning = false }
        self.apply()
      }
    }
  }

  private func cancelHold() {
    holdTask?.cancel()
    holdTask = nil
  }

  private func derive() -> SleepTimerActivityAttributes.ContentState? {
    SleepTimerActivityDerivation.contentState(for: observedInput, isRunning: isRunning, now: now())
  }

  private func apply() {
    let previous = lastDerived
    let derived = derive()
    lastDerived = derived
    guard let derived else {
      if lastSent != nil || sink.hasActivity { sink.endAll() }
      lastSent = nil
      return
    }
    if sink.hasActivity {
      send(derived)
    } else if Self.isNewTimer(previous: previous, current: derived) {
      attemptStart(derived)
    }
  }

  /// Set, replaced or extended: there was no timer, its kind changed, or its time went up.
  private static func isNewTimer(
    previous: SleepTimerActivityAttributes.ContentState?,
    current: SleepTimerActivityAttributes.ContentState
  ) -> Bool {
    guard let previous else { return true }
    return previous.label != current.label
      || current.remainingSeconds > previous.remainingSeconds + SleepTimerActivityDerivation.endsAtTolerance
  }

  private func send(_ state: SleepTimerActivityAttributes.ContentState) {
    guard SleepTimerActivityDerivation.isMaterialChange(from: lastSent, to: state) else { return }
    sink.update(state)
    lastSent = state
  }

  private func attemptStart(_ state: SleepTimerActivityAttributes.ContentState) {
    guard sink.areActivitiesEnabled else { return }
    if sink.start(state) { lastSent = state }
  }
}
