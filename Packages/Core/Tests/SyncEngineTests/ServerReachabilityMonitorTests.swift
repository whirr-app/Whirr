import Foundation
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite("ServerReachabilityMonitor", .timeLimit(.minutes(1)))
struct ServerReachabilityMonitorTests {
  private let initialPath = PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false)

  @Test("a fresh monitor replays unknown and does not assert an outage")
  func freshMonitorIsUnknown() async {
    let (monitor, _, _) = makeMonitor()
    var iterator = monitor.changes.makeAsyncIterator()

    #expect(monitor.current == .unknown)
    #expect(await iterator.next() == .unknown)
  }

  @Test("three consecutive transport failures assert server unreachable")
  func threeFailuresAssertServerUnreachable() async {
    let (monitor, _, _) = makeMonitor()
    var iterator = monitor.changes.makeAsyncIterator()
    _ = await iterator.next()

    await monitor.receive(.transportFailure)
    await monitor.receive(.transportFailure)
    #expect(monitor.current == .unknown)

    await monitor.receive(.transportFailure)
    let expected = ServerReachability.unreachable(.serverUnreachable, since: Date(timeIntervalSince1970: 0))
    #expect(await iterator.next() == expected)
    #expect(monitor.current == expected)
  }

  @Test("a response resets the failure count so only consecutive failures condemn")
  func failuresMustBeConsecutive() async {
    let (monitor, _, _) = makeMonitor()

    await monitor.receive(.transportFailure)
    await monitor.receive(.transportFailure)
    await monitor.receive(.responded)
    await monitor.receive(.transportFailure)
    await monitor.receive(.transportFailure)

    #expect(monitor.current == .reachable)
  }

  @Test("one response clears an unreachable state immediately")
  func responseClearsUnreachable() async {
    let (monitor, _, _) = makeMonitor()

    await assertServerUnreachable(monitor)
    await monitor.receive(.responded)

    #expect(monitor.current == .reachable)
  }

  @Test("an unsatisfied path asserts no-network unreachable immediately")
  func unsatisfiedPathAssertsImmediately() async {
    let (monitor, path, clock) = makeMonitor()
    let expectedSince = clock.now()

    path.simulate(PathSnapshot(isSatisfied: false, isCellular: false, isConstrained: false))

    #expect(await waitUntil { isUnreachable(monitor.current, reason: .noNetworkPath) })
    #expect(monitor.current == .unreachable(.noNetworkPath, since: expectedSince))
  }

  @Test("a satisfied path after no network returns to unknown, not reachable")
  func satisfiedPathDoesNotProveReachability() async {
    let (monitor, path, _) = makeMonitor()
    path.simulate(PathSnapshot(isSatisfied: false, isCellular: false, isConstrained: false))
    #expect(await waitUntil { isUnreachable(monitor.current, reason: .noNetworkPath) })

    path.simulate(initialPath)

    #expect(await waitUntil { monitor.current == .unknown })
  }

  @Test("additional failures preserve the original unreachable since date")
  func unreachableSinceDateIsStable() async {
    let (monitor, _, clock) = makeMonitor()
    let firstDate = clock.now()

    await assertServerUnreachable(monitor)
    clock.advance(by: 100)
    await monitor.receive(.transportFailure)

    #expect(monitor.current == .unreachable(.serverUnreachable, since: firstDate))
  }

  @Test("a later outage dates from when it started, not from the first one")
  func sinceDateTracksTheCurrentOutage() async {
    let (monitor, path, clock) = makeMonitor()
    let unsatisfied = PathSnapshot(isSatisfied: false, isCellular: false, isConstrained: false)

    path.simulate(unsatisfied)
    #expect(await waitUntil { isUnreachable(monitor.current, reason: .noNetworkPath) })
    path.simulate(initialPath)
    #expect(await waitUntil { monitor.current == .unknown })

    clock.advance(by: 100)
    let secondOutage = clock.now()
    path.simulate(unsatisfied)

    #expect(
      await waitUntil { monitor.current == .unreachable(.noNetworkPath, since: secondOutage) })
  }

  @Test("failures while the path is down preserve the original no-network since date")
  func noNetworkSinceDateIsStableAcrossFailures() async {
    let (monitor, path, clock) = makeMonitor()
    let expectedSince = clock.now()

    path.simulate(PathSnapshot(isSatisfied: false, isCellular: false, isConstrained: false))
    #expect(await waitUntil { isUnreachable(monitor.current, reason: .noNetworkPath) })

    clock.advance(by: 100)
    await monitor.receive(.transportFailure)

    #expect(monitor.current == .unreachable(.noNetworkPath, since: expectedSince))
  }

  @Test("a late subscriber receives the settled current state immediately")
  func lateSubscriberReplaysCurrentState() async {
    let (monitor, _, _) = makeMonitor()
    await assertServerUnreachable(monitor)

    var lateIterator = monitor.changes.makeAsyncIterator()

    #expect(await lateIterator.next() == monitor.current)
  }

  @Test("subscribers are multicast and one terminated subscriber does not starve another")
  func subscribersAreIndependent() async {
    let (monitor, _, _) = makeMonitor()
    let survivorStream = monitor.changes
    let doomedStream = monitor.changes
    var survivorIterator = survivorStream.makeAsyncIterator()
    #expect(await survivorIterator.next() == .unknown)

    let started = AsyncFlag()
    let doomedTask = Task {
      var iterator = doomedStream.makeAsyncIterator()
      _ = await iterator.next()
      _ = await iterator.next()
      await started.set()
      _ = await iterator.next()
    }

    await assertServerUnreachable(monitor)
    #expect(isUnreachable(await survivorIterator.next(), reason: .serverUnreachable))
    #expect(await waitUntil { await started.value })

    doomedTask.cancel()
    _ = await doomedTask.value

    await monitor.receive(.responded)
    await assertServerUnreachable(monitor)
    #expect(await survivorIterator.next() == .reachable)
    #expect(isUnreachable(await survivorIterator.next(), reason: .serverUnreachable))
  }

  @Test("the ABSApi adapter forwards events to the monitor")
  func adapterForwardsEvents() async {
    let (monitor, _, _) = makeMonitor()
    let adapter = ServerReachabilityMonitorAdapter(monitor: monitor)

    await adapter.reachabilityEvent(.responded)

    #expect(monitor.current == .reachable)
  }

  @Test("one failed detection probe asserts unreachable without three passive failures")
  func failedDetectionProbeAssertsImmediately() async {
    let harness = makeHarness(scripts: [.transport])

    await harness.monitor.triggerDetectionProbe()

    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(
      await waitUntil {
        isUnreachable(harness.monitor.current, reason: .serverUnreachable)
      })
  }

  @Test("one successful probe clears an unreachable state")
  func successfulProbeClearsUnreachable() async {
    let harness = makeHarness(foreground: false, scripts: [.success])
    #expect(await waitUntil { harness.lifecycle.lifecycleSubscriberCount == 1 })
    await harness.monitor.receive(probeOutcome: .didNotReach)
    #expect(isUnreachable(harness.monitor.current, reason: .serverUnreachable))

    harness.lifecycle.simulateForeground()

    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(await waitUntil { harness.monitor.current == .reachable })
  }

  @Test("HTTP status and decoding failures still prove the server answered")
  func responseFailuresCountAsReached() async {
    for script in [ProbeScript.httpFailure, .notFound, .malformed] {
      let harness = makeHarness(scripts: [script])

      await harness.monitor.triggerDetectionProbe()

      #expect(await waitUntil { await harness.probe.callCount == 1 })
      #expect(await waitUntil { harness.monitor.current == .reachable })
    }
  }

  @Test("a failed probe on an unsatisfied path reports no network path")
  func failedProbeOnUnsatisfiedPathUsesNoNetworkReason() async {
    let harness = makeHarness(scripts: [.transport])
    harness.path.simulate(PathSnapshot(isSatisfied: false, isCellular: false, isConstrained: false))
    #expect(await waitUntil { harness.monitor.current == .unreachable(.noNetworkPath, since: harness.clock.now()) })

    await harness.monitor.triggerDetectionProbe()
    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(isUnreachable(harness.monitor.current, reason: .noNetworkPath))
  }

  @Test("detection triggers inside the debounce window collapse to one probe")
  func detectionTriggersAreDebounced() async {
    let harness = makeHarness(scripts: [.hang])

    await harness.monitor.triggerDetectionProbe()
    #expect(await waitUntil { await harness.probe.callCount == 1 })
    await harness.probe.releaseHangingProbe()
    #expect(await waitUntil { harness.monitor.current == .reachable })

    await harness.monitor.triggerDetectionProbe()
    await harness.monitor.triggerDetectionProbe()

    #expect(await harness.probe.callCount == 1)
  }

  @Test("a detection trigger after the debounce window starts a second probe")
  func detectionTriggerAfterWindowStartsSecondProbe() async {
    let harness = makeHarness(scripts: [.success, .success])

    await harness.monitor.triggerDetectionProbe()
    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(await waitUntil { harness.monitor.current == .reachable })
    harness.clock.advance(by: ServerReachabilityMonitor.detectionDebounceWindow)

    await harness.monitor.triggerDetectionProbe()

    #expect(await waitUntil { await harness.probe.callCount == 2 })
  }

  @Test("recovery fires one probe immediately on foreground")
  func recoveryFiresImmediatelyOnForeground() async {
    let harness = makeHarness(foreground: false, scripts: [.success])
    #expect(await waitUntil { harness.lifecycle.lifecycleSubscriberCount == 1 })

    await harness.monitor.receive(probeOutcome: .didNotReach)
    #expect(await harness.probe.callCount == 0)
    #expect(harness.scheduler.pendingInterval == nil)

    harness.lifecycle.simulateForeground()

    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(await waitUntil { harness.monitor.current == .reachable })
  }

  @Test("recovery delays grow exponentially and stay capped")
  func recoveryBackoffGrowsAndCaps() async {
    let scripts = Array(repeating: ProbeScript.transport, count: 12)
    let harness = makeHarness(foreground: false, randomUnit: 1, scripts: scripts)
    #expect(await waitUntil { harness.lifecycle.lifecycleSubscriberCount == 1 })
    await harness.monitor.receive(probeOutcome: .didNotReach)

    harness.lifecycle.simulateForeground()
    #expect(await waitUntil { await harness.probe.callCount == 1 })

    let expectedDelays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300]
    for (index, expectedDelay) in expectedDelays.enumerated() {
      #expect(await waitUntil { harness.scheduler.pendingInterval == expectedDelay })
      #expect(await harness.scheduler.fire())
      #expect(await waitUntil { await harness.probe.callCount == index + 2 })
    }
  }

  @Test("recovery stops after success and its backoff resets")
  func recoveryStopsAndResetsBackoff() async {
    let harness = makeHarness(
      foreground: false,
      randomUnit: 1,
      scripts: [.transport, .success, .transport])
    #expect(await waitUntil { harness.lifecycle.lifecycleSubscriberCount == 1 })
    await harness.monitor.receive(probeOutcome: .didNotReach)

    harness.lifecycle.simulateForeground()
    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(await waitUntil { harness.scheduler.pendingInterval == 1 })
    #expect(await harness.scheduler.fire())
    #expect(await waitUntil { await harness.probe.callCount == 2 })
    #expect(await waitUntil { harness.monitor.current == .reachable })
    #expect(harness.scheduler.pendingInterval == nil)

    harness.lifecycle.simulateBackground()
    await harness.monitor.receive(probeOutcome: .didNotReach)
    #expect(harness.scheduler.pendingInterval == nil)
    harness.lifecycle.simulateForeground()
    #expect(await waitUntil { await harness.probe.callCount == 3 })
    #expect(await waitUntil { harness.scheduler.pendingInterval == 1 })
  }

  @Test("recovery does not run while backgrounded")
  func recoveryDoesNotRunInBackground() async {
    let harness = makeHarness(foreground: false)
    #expect(await waitUntil { harness.lifecycle.lifecycleSubscriberCount == 1 })
    await harness.monitor.receive(probeOutcome: .didNotReach)

    #expect(harness.scheduler.pendingInterval == nil)
    #expect(await harness.scheduler.fire() == false)
    #expect(await harness.probe.callCount == 0)
  }

  @Test("recovery does not run for reachable or unknown state")
  func recoveryOnlyRunsForUnreachableState() async {
    let harness = makeHarness()
    #expect(await waitUntil { harness.lifecycle.lifecycleSubscriberCount == 1 })

    harness.lifecycle.simulateForeground()
    await harness.monitor.receive(.responded)
    harness.lifecycle.simulateBackground()
    harness.lifecycle.simulateForeground()

    #expect(await harness.probe.callCount == 0)
    #expect(harness.scheduler.pendingInterval == nil)
    #expect(harness.monitor.current == .reachable)
  }

  @Test("probe timeout asserts unreachable and does not emit a passive cancellation failure")
  func probeTimeoutCancelsWithoutPassiveFailure() async throws {
    let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
    let (http, cancellations) = makeBlockingHTTPClient()
    let observer = RecordingServerReachabilityObserving()
    let client = ABSClient(
      server: server,
      httpClient: http,
      tokenStore: InMemoryTokenStore(),
      serverReachabilityObserving: observer)
    let probe = ABSClientServerStatusProbe(client: client)
    let harness = makeHarness(probe: probe, probeTimeout: 0)

    await harness.monitor.triggerDetectionProbe()

    #expect(await waitUntil { http.requests.count == 1 })
    #expect(await harness.timeoutScheduler.fire())
    #expect(
      await waitUntil {
        isUnreachable(harness.monitor.current, reason: .serverUnreachable)
      })
    #expect(await waitUntil { cancellations.count == 1 })
    #expect(await observer.events.isEmpty)
  }

  @Test("a cancelled recovery probe re-arms the retry instead of ending the sequence")
  func cancelledRecoveryProbeReArmsRetry() async {
    let harness = makeHarness(scripts: [.transport, .cancelledRequest, .transport])

    await harness.monitor.triggerDetectionProbe()
    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(await waitUntil { harness.scheduler.pendingInterval == 1 })

    // The recovery attempt is cancelled underneath the monitor, so it reports no verdict. The
    // state must stay unreachable and a further attempt must still be scheduled.
    #expect(await harness.scheduler.fire())
    #expect(await waitUntil { await harness.probe.callCount == 2 })
    #expect(await waitUntil { harness.scheduler.pendingInterval == 1 })
    #expect(isUnreachable(harness.monitor.current, reason: .serverUnreachable))

    #expect(await harness.scheduler.fire())
    #expect(await waitUntil { await harness.probe.callCount == 3 })
  }

  @Test("repeated failed recovery probes preserve the original since date")
  func recoveryFailuresPreserveSinceDate() async {
    let harness = makeHarness(foreground: false, scripts: [.transport, .transport, .transport])
    #expect(await waitUntil { harness.lifecycle.lifecycleSubscriberCount == 1 })
    let expectedSince = harness.clock.now()
    await harness.monitor.receive(probeOutcome: .didNotReach)

    harness.lifecycle.simulateForeground()
    #expect(await waitUntil { await harness.probe.callCount == 1 })
    #expect(await waitUntil { harness.scheduler.pendingInterval == 1 })
    harness.clock.advance(by: 100)
    #expect(await harness.scheduler.fire())
    #expect(await waitUntil { await harness.probe.callCount == 2 })

    #expect(harness.monitor.current == .unreachable(.serverUnreachable, since: expectedSince))
  }

  private func makeMonitor() -> (ServerReachabilityMonitor, FakePathObserving, FakeSyncClock) {
    let harness = makeHarness()
    return (harness.monitor, harness.path, harness.clock)
  }

  private func makeHarness(
    foreground: Bool = true,
    randomUnit: Double = 1,
    scripts: [ProbeScript] = [],
    probe: (any ServerStatusProbing)? = nil,
    probeTimeout: TimeInterval = ServerReachabilityMonitor.probeTimeout
  ) -> MonitorHarness {
    let path = FakePathObserving(initial: initialPath)
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 0))
    let lifecycle = FakeAppLifecycle()
    lifecycle.isForeground = foreground
    let scriptedProbe = FakeServerStatusProbe(scripts: scripts)
    let scheduler = FakePlaybackCadenceScheduling()
    let timeoutScheduler = FakePlaybackCadenceScheduling()
    let monitor = ServerReachabilityMonitor(
      path: path,
      probe: probe ?? scriptedProbe,
      appLifecycle: lifecycle,
      clock: clock,
      randomUnit: { randomUnit },
      scheduler: scheduler,
      timeoutScheduler: timeoutScheduler,
      probeTimeout: probeTimeout)
    return MonitorHarness(
      monitor: monitor,
      path: path,
      clock: clock,
      lifecycle: lifecycle,
      probe: scriptedProbe,
      scheduler: scheduler,
      timeoutScheduler: timeoutScheduler)
  }

  private func assertServerUnreachable(_ monitor: ServerReachabilityMonitor) async {
    await monitor.receive(.transportFailure)
    await monitor.receive(.transportFailure)
    await monitor.receive(.transportFailure)
  }

  private func isUnreachable(
    _ state: ServerReachability?,
    reason: ServerUnreachableReason
  ) -> Bool {
    guard case .some(.unreachable(let actualReason, since: _)) = state else { return false }
    return actualReason == reason
  }

}

private struct MonitorHarness {
  let monitor: ServerReachabilityMonitor
  let path: FakePathObserving
  let clock: FakeSyncClock
  let lifecycle: FakeAppLifecycle
  let probe: FakeServerStatusProbe
  let scheduler: FakePlaybackCadenceScheduling
  let timeoutScheduler: FakePlaybackCadenceScheduling
}

private enum ProbeScript: Sendable {
  case success
  case transport
  case cancelledRequest
  case httpFailure
  case notFound
  case malformed
  case hang
}

private actor FakeServerStatusProbe: ServerStatusProbing {
  private var scripts: [ProbeScript]
  private(set) var callCount = 0
  private var hangingCount = 0
  private var releasedCount = 0
  // A cancelled hanging probe throws; a released one returns.
  private nonisolated let hangGate = TestGate<Result<Void, Error>>(
    label: "FakeServerStatusProbe hanging probe")

  init(scripts: [ProbeScript]) {
    self.scripts = scripts
  }

  func probeServerStatus() async throws {
    callCount += 1
    let script = scripts.isEmpty ? .success : scripts.removeFirst()
    switch script {
    case .success:
      return
    case .transport:
      throw URLError(.cannotConnectToHost)
    case .cancelledRequest:
      throw URLError(.cancelled)
    case .httpFailure:
      throw APIError.serverFailure(statusCode: 500)
    case .notFound:
      throw APIError.notFound
    case .malformed:
      throw APIError.decoding
    case .hang:
      try Task.checkCancellation()
      hangingCount += 1
      hangGate.hold()
      try await hangGate.pass(otherwise: { .failure(CancellationError()) }).get()
    }
  }

  func releaseHangingProbe() async {
    // A probe counts itself before it parks, so wait for the parks this release must free.
    let pending = hangingCount - releasedCount
    if pending > 0 { await hangGate.waitUntilParked(count: pending) }
    releasedCount += pending
    hangGate.releaseParked(.success(()))
  }
}

private actor AsyncFlag {
  private var isSet = false

  var value: Bool { isSet }

  func set() {
    isSet = true
  }
}

private actor RecordingServerReachabilityObserving: ServerReachabilityObserving {
  private(set) var events: [ServerReachabilityEvent] = []

  func reachabilityEvent(_ event: ServerReachabilityEvent) async {
    events.append(event)
  }
}

/// Parks every request until its task is cancelled, then fails it with `URLError(.cancelled)` as
/// URLSession would. `cancellations` counts the requests that ended that way.
private func makeBlockingHTTPClient() -> (
  client: FakeHTTPClient, cancellations: TestCountRecorder
) {
  let gate = TestGate<Void>(label: "reachability probe request")
  gate.hold()
  let cancellations = TestCountRecorder(label: "cancelled probe requests")
  let client = FakeHTTPClient(handler: { _ in
    try Task.checkCancellation()
    await gate.pass(otherwise: {})
    cancellations.record()
    throw URLError(.cancelled)
  })
  return (client, cancellations)
}
