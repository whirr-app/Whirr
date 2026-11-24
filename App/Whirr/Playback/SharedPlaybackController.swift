import CoreSupport
import Foundation
import PlayerCore

/// The one App-owned `PlaybackControlling` conformance production composes around the real
/// `PlayerController`, shared across the system-facing adapters. Two responsibilities:
///
/// 1. User-pause tracking: forwards every user `.pause`, and every `.toggle` about to pause, to
///    `AudioInterruptionRouteAdapter.userDidPause()`. That adapter is built against the undecorated
///    `PlayerController` (`PlaybackHardware`), so its own interruption `.pause`/`.play` never loops
///    back here as a user pause.
/// 2. Progress-event fan-out: `PlayerController.progressEvents` is one `AsyncStream`, safe with one
///    consumer, but consumers (a fresh `PlaybackModel` and `NowPlayingMetadataAdapter` per
///    `AppEnvironment` rebuild) are shorter-lived than this controller, and a torn-down consumer
///    cancels the iterating task, which ends an `AsyncStream` for good and freezes phase and
///    position. So this type owns the one subscription and multicasts it: each
///    `progressEvents`/`secondaryProgressEvents` access gets a fresh stream, and a torn-down
///    subscriber ends only its own.
final class SharedPlaybackController: PlaybackControlling, @unchecked Sendable {
  private let underlying: any PlaybackControlling
  private let interruptionAdapter: AudioInterruptionRouteAdapter
  private let multicaster: ProgressEventMulticaster
  private let relayTask: Task<Void, Never>

  var state: PlayerState { underlying.state }
  /// Forwarded explicitly: the protocol fallback derives this projection from `state`, which
  /// includes the twice-per-second playhead. Wrappers must preserve `PlayerController`'s
  /// independently observed storage or native quick-action menus invalidate on every tick.
  var quickActions: PlayerQuickActionsState { underlying.quickActions }
  /// The live countdown is a separate leaf projection so only its label refreshes each second.
  var quickActionsSleepTimer: SleepTimerState { underlying.quickActionsSleepTimer }
  /// Forwarded explicitly: the protocol default answers out of `state`, which would put every
  /// play/pause surface back on the position's invalidation cadence.
  var isPlaybackIntended: Bool { underlying.isPlaybackIntended }

  var progressEvents: AsyncStream<PlaybackProgressEvent> { multicaster.subscribe() }
  var secondaryProgressEvents: AsyncStream<PlaybackProgressEvent> { multicaster.subscribe() }

  init(underlying: any PlaybackControlling, interruptionAdapter: AudioInterruptionRouteAdapter) {
    self.underlying = underlying
    self.interruptionAdapter = interruptionAdapter

    let multicaster = ProgressEventMulticaster()
    self.multicaster = multicaster

    let events = underlying.progressEvents
    relayTask = Task {
      for await event in events {
        multicaster.yield(event)
      }
      multicaster.finish()
    }
  }

  func send(_ intent: PlayerIntent) {
    if Self.isUserPause(intent, currentPhase: underlying.state.phase) {
      // Every production call site (`PlaybackModel`, `RemoteCommandAdapter`) is already
      // main-actor-isolated, as `PlayerController.send` also assumes.
      MainActor.assumeIsolated {
        interruptionAdapter.userDidPause()
      }
    }
    underlying.send(intent)
  }

  private static func isUserPause(_ intent: PlayerIntent, currentPhase: PlayerPhase) -> Bool {
    switch intent {
    case .pause: return true
    case .toggle: return currentPhase == .playing
    default: return false
    }
  }

  deinit {
    relayTask.cancel()
  }
}

/// Fan-out for `PlaybackProgressEvent`s, built on `CoreSupport.AsyncEventMulticaster`, which
/// documents why an interposed multicaster is required.
typealias ProgressEventMulticaster = AsyncEventMulticaster<PlaybackProgressEvent>

/// A `PlaybackControlling` view over `SharedPlaybackController`'s secondary progress-event
/// subscription, so `NowPlayingMetadataAdapter`'s composition site reads as its own consumer.
struct SecondaryPlaybackControllingView: PlaybackControlling {
  let shared: SharedPlaybackController

  var state: PlayerState { shared.state }
  var quickActions: PlayerQuickActionsState { shared.quickActions }
  var quickActionsSleepTimer: SleepTimerState { shared.quickActionsSleepTimer }
  var isPlaybackIntended: Bool { shared.isPlaybackIntended }
  var progressEvents: AsyncStream<PlaybackProgressEvent> { shared.secondaryProgressEvents }
  func send(_ intent: PlayerIntent) { shared.send(intent) }
}
