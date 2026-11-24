/// Playback intents and state shared by the player UI, lock screen, and Control Center
/// (ARCHITECTURE.md §4). AppModel sees only this boundary, never `PlayerController` or
/// `AudioEngine`, so it can forward `progressEvents` to `SyncEngine` without importing
/// AVFoundation.
///
/// `Sendable` (not `@MainActor`) so `AppDependencies` can hold `any PlaybackControlling`; the real
/// implementation, `PlayerController`, is `@MainActor`.
public protocol PlaybackControlling: Sendable {
  var state: PlayerState { get }
  /// Stable playback rate, sleep-timer menu shape, and loaded-item availability for native quick
  /// actions. `PlayerController` tracks this apart from `state`, whose playhead changes on every
  /// engine tick.
  var quickActions: PlayerQuickActionsState { get }
  /// The timer value used by the countdown label. Separate from `quickActions` so a live countdown
  /// can update its leaf without rebuilding the menu sources around it.
  var quickActionsSleepTimer: SleepTimerState { get }
  /// Whether the user intends playback to be running. A requirement of its own rather than sugar
  /// for `state.isPlaybackIntended`: `state` carries the playhead and is republished on every
  /// engine tick, while intent flips only when the user (or an interruption) acts. An
  /// `@Observable` conformance lets a play/pause control depend on this alone and rebuild once
  /// per tap instead of twice a second. Anything needing the position keeps reading `state`.
  var isPlaybackIntended: Bool { get }
  var progressEvents: AsyncStream<PlaybackProgressEvent> { get }
  func send(_ intent: PlayerIntent)
}

extension PlaybackControlling {
  /// A fallback for test doubles and forwarding conformances. The real controller overrides this
  /// with separately tracked storage, keeping the expanded player's native menus independent of
  /// position ticks.
  public var quickActions: PlayerQuickActionsState { PlayerQuickActionsState(state: state) }

  public var quickActionsSleepTimer: SleepTimerState { state.sleepTimer }

  /// The answer for conformances with nothing finer to offer: test doubles and forwarding views
  /// that wrap another controller. `PlayerController` overrides it with its own tracked property.
  public var isPlaybackIntended: Bool { state.isPlaybackIntended }
}

/// A source of monotonically increasing wall-clock time, injected so listening-delta accrual
/// (`PlayerReducer`) is deterministic and testable without real sleeps.
public protocol PlaybackClock: Sendable {
  /// Seconds since an arbitrary, fixed reference point. Only differences between two calls are
  /// meaningful.
  func now() -> Double
  /// Seconds since an arbitrary, fixed reference point, counting time the device spent asleep
  /// (which `now()` need not). Only differences between two calls are meaningful, and never
  /// against a reading of `now()`.
  func continuousNow() -> Double
}

extension PlaybackClock {
  /// For clocks that never model device sleep, the two readings are the same clock.
  public func continuousNow() -> Double { now() }
}
