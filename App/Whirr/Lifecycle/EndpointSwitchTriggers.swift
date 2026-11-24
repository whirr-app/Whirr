import AppModel
import Foundation
import Observation
import SyncEngine

/// When the server address is re-selected, and when a finished selection replaces the graph.
/// The decisions only: `EndpointSwitchTriggers` feeds this and carries out what it returns.
struct EndpointSwitchTriggerPolicy {
  /// What the policy watches in the current graph and the player.
  struct Observation: Equatable {
    /// `AppRuntime.generation`: tells a coordinator that advanced from one that was replaced.
    var graphGeneration: Int
    /// Nil for a graph with no coordinator (setup, or a pending removal).
    var switchGeneration: Int?
    var isServerUnreachable: Bool
    var isPlaybackIntended: Bool
  }

  enum Action: Equatable {
    case select(EndpointSwitchCoordinator.Reason)
    /// The coordinator switched address: every URL-bound client needs a graph built on it.
    case rebuildForSwitch
    /// Playback stopped, so a switch it deferred can finish.
    case completeDeferredSwitch
  }

  private var didSelectAtColdLaunch = false
  private var backgroundedAt: Date?
  private var last: Observation?

  /// The first activation of any scene is the cold-launch selection, once per process. A later
  /// one re-selects only after a background long enough for the network to have changed under
  /// the app. Without a graph there is nothing to select for, and the cold launch is still owed.
  mutating func sceneBecameActive(hasGraph: Bool, now: Date) -> Action? {
    defer { backgroundedAt = nil }
    guard didSelectAtColdLaunch else {
      guard hasGraph else { return nil }
      didSelectAtColdLaunch = true
      return .select(.coldLaunch)
    }
    guard let backgroundedAt,
      now.timeIntervalSince(backgroundedAt) > ServerReachabilityMonitor.detectionDebounceWindow
    else { return nil }
    return .select(.foreground)
  }

  mutating func allScenesEnteredBackground(now: Date) {
    backgroundedAt = now
  }

  /// Compares against the previous observation; the first one is only a baseline.
  mutating func observe(_ observation: Observation) -> [Action] {
    defer { last = observation }
    guard let last else { return [] }
    var actions: [Action] = []
    // A replaced graph's coordinator starts again from zero; only the same one counting up is a
    // switch.
    if observation.graphGeneration == last.graphGeneration,
      let old = last.switchGeneration, let new = observation.switchGeneration, new > old
    {
      actions.append(.rebuildForSwitch)
    }
    // Once per unreachable episode, however often its details change.
    if observation.isServerUnreachable, last.isServerUnreachable == false {
      actions.append(.select(.idleUnreachable))
    }
    if last.isPlaybackIntended, observation.isPlaybackIntended == false {
      actions.append(.completeDeferredSwitch)
    }
    return actions
  }
}

/// Drives `EndpointSwitchTriggerPolicy` for the life of the process. Living in `RootView` would
/// leave a process with no phone window (a CarPlay-only drive, when the phone is likely to leave
/// the home network) never re-selecting its address.
@MainActor
final class EndpointSwitchTriggers {
  typealias Observation = EndpointSwitchTriggerPolicy.Observation
  typealias Action = EndpointSwitchTriggerPolicy.Action

  private var policy = EndpointSwitchTriggerPolicy()
  private let observe: @MainActor @Sendable () -> Observation
  private let hasGraph: @MainActor () -> Bool
  private let perform: @MainActor (Action) -> Void
  private let networkChanges: @MainActor (@escaping @MainActor () -> Void) -> Void
  private let now: @MainActor () -> Date
  private var observing: Task<Void, Never>?

  init(
    observe: @escaping @MainActor @Sendable () -> Observation,
    hasGraph: @escaping @MainActor () -> Bool,
    perform: @escaping @MainActor (Action) -> Void,
    networkChanges: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.observe = observe
    self.hasGraph = hasGraph
    self.perform = perform
    self.networkChanges = networkChanges
    self.now = now
  }

  deinit {
    observing?.cancel()
  }

  /// Begins watching the network, the graph and the player. Idempotent.
  func start() {
    guard observing == nil else { return }
    networkChanges { [weak self] in self?.perform(.select(.networkChanged)) }
    let observations = Observations(observe)
    observing = Task { [weak self] in
      for await observation in observations {
        guard Task.isCancelled == false, let self else { return }
        for action in self.policy.observe(observation) { self.perform(action) }
      }
    }
  }

  func sceneBecameActive() {
    if let action = policy.sceneBecameActive(hasGraph: hasGraph(), now: now()) { perform(action) }
  }

  func allScenesEnteredBackground() {
    policy.allScenesEnteredBackground(now: now())
  }
}

extension EndpointSwitchTriggers {
  /// Process-wide: a rebuilt graph must not restart the baseline network.
  private static let networkChangeSignal = NetworkChangeSignal()

  /// The triggers for `runtime`'s current graph, whichever that is when each one fires.
  static func production(for runtime: AppRuntime) -> EndpointSwitchTriggers {
    EndpointSwitchTriggers(
      observe: { [weak runtime] in
        let graph = runtime?.current
        var isServerUnreachable = false
        if case .unreachable(.serverUnreachable, since: _) = graph?.environment.connectivityModel?
          .reachability
        {
          isServerUnreachable = true
        }
        return Observation(
          graphGeneration: runtime?.generation ?? 0,
          switchGeneration: graph?.endpointSwitchCoordinator?.switchGeneration,
          isServerUnreachable: isServerUnreachable,
          // `isPlaybackIntended`, not `state.phase`: `state` carries the playhead.
          isPlaybackIntended: PlaybackHardware.shared.player.isPlaybackIntended)
      },
      hasGraph: { [weak runtime] in runtime?.current != nil },
      perform: { [weak runtime] action in
        guard let runtime, let coordinator = runtime.current?.endpointSwitchCoordinator else {
          return
        }
        switch action {
        case .select(let reason):
          Task { await coordinator.trigger(reason) }
        case .rebuildForSwitch:
          // Same account at another address: the artwork scope is address-independent, so
          // prepared covers stay valid and purging them would only make every visible cover
          // re-stream.
          runtime.rebuild(keepingPreparedArtwork: true, keepingNavigation: true)
        case .completeDeferredSwitch:
          Task {
            // The pause settles the player's phase a moment after the intent changes.
            try? await Task.sleep(for: .seconds(1))
            await coordinator.completeDeferredSwitchIfIdle()
          }
        }
      },
      networkChanges: { networkChangeSignal.start(onChange: $0) })
  }
}
