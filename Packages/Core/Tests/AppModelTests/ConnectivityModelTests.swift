import Foundation
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("ConnectivityModel", .serialized)
struct ConnectivityModelTests {
  @Test("starts unknown rather than reading as offline")
  func startsUnknown() {
    let monitor = Self.makeMonitor()
    let model = ConnectivityModel(monitor: monitor)

    #expect(model.reachability == .unknown)
  }

  @Test("projects unreachable and reachable transitions")
  func projectsTransitions() async {
    let monitor = Self.makeMonitor()
    let model = ConnectivityModel(monitor: monitor)

    await monitor.receive(probeOutcome: .didNotReach)
    #expect(await waitUntil { Self.isUnreachable(model.reachability) })

    await monitor.receive(probeOutcome: .reached)
    #expect(await waitUntil { model.reachability == .reachable })
  }

  @Test("receives the monitor's replayed current value when subscribing late")
  func receivesReplayedCurrentValue() async {
    let monitor = Self.makeMonitor()
    await monitor.receive(probeOutcome: .reached)

    let model = ConnectivityModel(monitor: monitor)

    #expect(await waitUntil { model.reachability == .reachable })
  }

  /// What this pins is the retain cycle, not the cancellation: the subscription task captures
  /// `self` weakly, so the model must deallocate while its `for await` is still suspended. The
  /// `deinit` cancel is what then finishes the stream and drops the monitor's subscriber. That is
  /// not asserted, since nothing observable distinguishes it from the weak capture alone without
  /// a test hook on the hub's subscriber table.
  @Test("does not keep itself alive through its subscription")
  func subscriptionDoesNotRetainTheModel() async {
    let monitor = Self.makeMonitor()
    weak var weakModel: ConnectivityModel?

    do {
      let model = ConnectivityModel(monitor: monitor)
      weakModel = model
    }

    #expect(await waitUntil { weakModel == nil })
  }

  private static func makeMonitor() -> ServerReachabilityMonitor {
    // Backgrounded, so the monitor's startup lifecycle task cannot race a test's `.didNotReach`:
    // handled foreground-and-unreachable, it starts a recovery probe, and this no-op probe
    // "succeeds" and flips the state back to `.reachable` before the test observes the outage.
    let lifecycle = FakeAppLifecycle()
    lifecycle.isForeground = false
    return ServerReachabilityMonitor(
      path: StaticPathObserving(),
      probe: NoOpServerStatusProbe(),
      appLifecycle: lifecycle,
      clock: FakeSyncClock(),
      scheduler: FakePlaybackCadenceScheduling(),
      timeoutScheduler: FakePlaybackCadenceScheduling())
  }

  private static func isUnreachable(_ state: ServerReachability) -> Bool {
    if case .unreachable = state { return true }
    return false
  }
}

private struct StaticPathObserving: PathObserving {
  let currentPath = PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false)

  func startObserving(onUpdate: @escaping @Sendable (PathSnapshot) -> Void) {}
  func stopObserving() {}
}

private struct NoOpServerStatusProbe: ServerStatusProbing {
  func probeServerStatus() async throws {}
}
