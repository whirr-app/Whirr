import Foundation
import Observation
import SyncEngine
import Testing

@testable import Whirr

/// The endpoint triggers live on the process, not `RootView`. The policy is tested as a value, and
/// one test drives it through real observation.
@MainActor
@Suite("Endpoint switch triggers")
struct EndpointSwitchTriggersTests {
  typealias Policy = EndpointSwitchTriggerPolicy
  private let start = Date(timeIntervalSince1970: 1_000)
  private var longBackground: TimeInterval { ServerReachabilityMonitor.detectionDebounceWindow + 1 }

  @Test("the first activation selects for cold launch, once per process")
  func coldLaunchOnce() {
    var policy = Policy()

    #expect(policy.sceneBecameActive(hasGraph: true, now: start) == .select(.coldLaunch))
    #expect(policy.sceneBecameActive(hasGraph: true, now: start) == nil)
  }

  @Test("an activation with no graph leaves the cold-launch selection owed")
  func coldLaunchWaitsForGraph() {
    var policy = Policy()

    #expect(policy.sceneBecameActive(hasGraph: false, now: start) == nil)
    #expect(policy.sceneBecameActive(hasGraph: true, now: start) == .select(.coldLaunch))
  }

  @Test("returning from a long background re-selects; a short one does not")
  func foregroundAfterLongBackground() {
    var policy = Policy()
    _ = policy.sceneBecameActive(hasGraph: true, now: start)

    policy.allScenesEnteredBackground(now: start)
    #expect(policy.sceneBecameActive(hasGraph: true, now: start + 1) == nil)

    policy.allScenesEnteredBackground(now: start)
    #expect(
      policy.sceneBecameActive(hasGraph: true, now: start + longBackground) == .select(.foreground))
    // The background was consumed: a bounce through inactive is not another return.
    #expect(policy.sceneBecameActive(hasGraph: true, now: start + 2 * longBackground) == nil)
  }

  @Test("the first observation is a baseline")
  func firstObservationIsBaseline() {
    var policy = Policy()

    #expect(policy.observe(observation(switchGeneration: 3, unreachable: true)).isEmpty)
  }

  @Test("a coordinator that advances rebuilds the graph; a replaced one does not")
  func switchGenerationRebuilds() {
    var policy = Policy()
    _ = policy.observe(observation(switchGeneration: 0))

    #expect(policy.observe(observation(switchGeneration: 1)) == [.rebuildForSwitch])
    // The rebuild's fresh coordinator starts from zero, under a new graph generation.
    #expect(policy.observe(observation(graph: 1, switchGeneration: 0)).isEmpty)
    // A setup graph has no coordinator, and gaining one at login is not a switch.
    #expect(policy.observe(observation(graph: 2, switchGeneration: nil)).isEmpty)
    #expect(policy.observe(observation(graph: 3, switchGeneration: 5)).isEmpty)
  }

  @Test("an unreachable server selects once per episode")
  func unreachableOncePerEpisode() {
    var policy = Policy()
    _ = policy.observe(observation())

    #expect(policy.observe(observation(unreachable: true)) == [.select(.idleUnreachable)])
    #expect(policy.observe(observation(unreachable: true, playing: true)).isEmpty)
    _ = policy.observe(observation())
    #expect(policy.observe(observation(unreachable: true)) == [.select(.idleUnreachable)])
  }

  @Test("playback stopping completes a deferred switch")
  func pauseCompletesDeferredSwitch() {
    var policy = Policy()
    _ = policy.observe(observation(playing: true))

    #expect(policy.observe(observation(playing: false)) == [.completeDeferredSwitch])
    #expect(policy.observe(observation(playing: true)).isEmpty)
  }

  @Test("started triggers act on observed changes and on a network change")
  func startedTriggersFollowObservation() async throws {
    let source = Source()
    let performed = Performed()
    var networkChanged: (@MainActor () -> Void)?
    let triggers = EndpointSwitchTriggers(
      observe: {
        Policy.Observation(
          graphGeneration: 0, switchGeneration: source.switchGeneration,
          isServerUnreachable: false, isPlaybackIntended: false)
      },
      hasGraph: { true },
      perform: { performed.actions.append($0) },
      networkChanges: { networkChanged = $0 })

    triggers.start()
    triggers.start()
    networkChanged?()
    #expect(performed.actions == [.select(.networkChanged)])

    // Let the baseline observation land before changing what it watches.
    try await Task.sleep(for: .milliseconds(50))
    source.switchGeneration = 1
    for _ in 0..<200 where performed.actions.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(performed.actions == [.select(.networkChanged), .rebuildForSwitch])
  }

  private func observation(
    graph: Int = 0, switchGeneration: Int? = 0, unreachable: Bool = false, playing: Bool = false
  ) -> Policy.Observation {
    Policy.Observation(
      graphGeneration: graph, switchGeneration: switchGeneration,
      isServerUnreachable: unreachable, isPlaybackIntended: playing)
  }

  @MainActor
  private final class Performed {
    var actions: [Policy.Action] = []
  }
}

/// At file scope: `@Observable` cannot extend a type nested privately in the suite.
@MainActor
@Observable
private final class Source {
  var switchGeneration = 0
}
