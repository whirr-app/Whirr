import ABSApi
import Foundation

/// The shared reachability state for the configured Audiobookshelf server.
public enum ServerReachability: Sendable, Equatable {
  /// No request or path update has provided evidence yet.
  case unknown
  case reachable
  case unreachable(ServerUnreachableReason, since: Date)
}

/// The actionable cause of an unreachable server.
public enum ServerUnreachableReason: Sendable, Equatable {
  case noNetworkPath
  case serverUnreachable
}

/// The result of the explicit unauthenticated `/status` probe. The outcome carries
/// no error, response body, URL, or credential material across the SyncEngine boundary.
public enum ServerReachabilityProbeOutcome: Sendable, Equatable {
  case reached
  case didNotReach
}

/// Owns the server reachability state machine shared by SyncEngine consumers.
public actor ServerReachabilityMonitor {
  private let path: any PathObserving
  private let probe: any ServerStatusProbing
  private let appLifecycle: any AppLifecycle
  private let clock: any SyncClock
  private let randomUnit: @Sendable () -> Double
  private let scheduler: any PlaybackCadenceScheduling
  private let timeoutScheduler: any PlaybackCadenceScheduling
  private let probeTimeout: TimeInterval
  private let stateHub: ServerReachabilityStateHub
  private let lifetime: ServerReachabilityMonitorLifetime

  private var state: ServerReachability = .unknown
  private var consecutiveTransportFailures = 0
  private var isPathSatisfied: Bool
  private let pathUpdates: AsyncStream<PathSnapshot>.Continuation

  private var lastDetectionTriggerAt: Date?
  private var recoveryBackoff = BackoffPolicy()
  private var recoveryEpoch: UInt64 = 0
  private var pendingRecoveryEpoch: UInt64?

  private enum ProbeTrigger: Sendable, Equatable {
    case detection
    case recovery(epoch: UInt64)
  }

  private enum ProbeRaceResult: Sendable, Equatable {
    case reached
    case didNotReach
    case timedOut
    case cancelled
  }

  private var nextProbeID: UInt64 = 0
  private var inFlightProbeID: UInt64?
  private var inFlightProbeTrigger: ProbeTrigger?
  private var probeTask: Task<Void, Never>?

  /// One probe per sustained-buffering episode at most. The actor exposes only the debounced
  /// trigger; the sustained-buffering signal comes from the caller.
  public static let detectionDebounceWindow: TimeInterval = 10
  /// A dropped route must not wait for URLSession's ordinary 60-second timeout before changing
  /// reachability state.
  public static let probeTimeout: TimeInterval = 10

  public init(
    path: any PathObserving,
    probe: any ServerStatusProbing,
    appLifecycle: any AppLifecycle,
    clock: any SyncClock = SystemSyncClock(),
    randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    scheduler: any PlaybackCadenceScheduling = SystemPlaybackCadenceScheduler(),
    timeoutScheduler: any PlaybackCadenceScheduling = SystemPlaybackCadenceScheduler(),
    probeTimeout: TimeInterval = ServerReachabilityMonitor.probeTimeout
  ) {
    self.path = path
    self.probe = probe
    self.appLifecycle = appLifecycle
    self.clock = clock
    self.randomUnit = randomUnit
    self.scheduler = scheduler
    self.timeoutScheduler = timeoutScheduler
    self.probeTimeout = max(0, probeTimeout)
    stateHub = ServerReachabilityStateHub(initialState: .unknown)
    let lifetime = ServerReachabilityMonitorLifetime()
    self.lifetime = lifetime
    // The initial path is context for transport failures, not an attempted server probe. Keeping
    // construction at `.unknown` prevents a cold launch from presenting an offline banner.
    isPathSatisfied = path.currentPath.isSatisfied

    // Path updates are funnelled through one stream and drained by one task, so they reach the
    // state machine in the order the system reported them. Spawning a `Task` per callback would
    // not: separate unstructured tasks carry no ordering guarantee, and a satisfied/unsatisfied
    // pair applied backwards would latch an outage that is already over.
    let (stream, continuation) = AsyncStream<PathSnapshot>.makeStream()
    pathUpdates = continuation
    path.startObserving { snapshot in
      continuation.yield(snapshot)
    }
    // Holds `self` weakly, so the monitor stays deallocatable; `deinit` finishes the stream, which
    // is what ends this loop.
    let pathTask = Task { [weak self] in
      for await snapshot in stream {
        await self?.receive(path: snapshot)
      }
    }
    lifetime.add(pathTask)

    // `AppLifecycle.transitions` does not replay. Capture the synchronous current value before
    // subscribing, then handle that value before waiting for a later edge. The weak capture keeps
    // the subscription from making this owner immortal; `deinit` cancels the task explicitly.
    let startsForeground = appLifecycle.isForeground
    let lifecycleStream = appLifecycle.transitions
    let lifecycleTask = Task { [weak self] in
      await self?.handleLifecycle(startsForeground ? .foreground : .background)
      for await transition in lifecycleStream {
        guard Task.isCancelled == false else { return }
        await self?.handleLifecycle(transition)
      }
    }
    lifetime.add(lifecycleTask)
  }

  deinit {
    lifetime.cancelAll()
    probeTask?.cancel()
    path.stopObserving()
    pathUpdates.finish()
    stateHub.finish()
    let scheduler = scheduler
    Task { await scheduler.cancelPending() }
    let timeoutScheduler = timeoutScheduler
    Task { await timeoutScheduler.cancelPending() }
  }

  /// The latest state, available without awaiting the actor.
  public nonisolated var current: ServerReachability {
    stateHub.current
  }

  /// A replay-latest multicast stream. Each subscriber owns an independent stream and its
  /// termination removes only that subscriber.
  public nonisolated var changes: AsyncStream<ServerReachability> {
    stateHub.stream()
  }

  /// Accepts a credential-free event from ABSApi's transport observation seam.
  public func receive(_ event: ServerReachabilityEvent) async {
    switch event {
    case .responded:
      consecutiveTransportFailures = 0
      await transition(to: .reachable)

    case .transportFailure:
      guard isPathSatisfied else {
        consecutiveTransportFailures = 0
        await assertUnreachable(.noNetworkPath)
        return
      }

      consecutiveTransportFailures += 1
      guard consecutiveTransportFailures >= 3 else { return }
      await assertUnreachable(.serverUnreachable)
    }
  }

  /// Accepts the definitive result of an explicit `/status` probe. Unlike passive transport
  /// events, one failed probe is sufficient evidence and never passes through the three-failure
  /// hysteresis counter.
  public func receive(probeOutcome outcome: ServerReachabilityProbeOutcome) async {
    await applyProbeOutcome(outcome)
  }

  /// Plain trigger for the stall scheduler. Independent of
  /// playback observation, and can run from `.unknown`, `.reachable`, or `.unreachable`.
  public func triggerDetectionProbe() {
    let now = clock.now()
    guard inFlightProbeID == nil else { return }
    if let lastDetectionTriggerAt,
      now.timeIntervalSince(lastDetectionTriggerAt) < Self.detectionDebounceWindow
    {
      return
    }
    lastDetectionTriggerAt = now
    startProbe(.detection)
  }

  private func receive(path snapshot: PathSnapshot) async {
    isPathSatisfied = snapshot.isSatisfied
    consecutiveTransportFailures = 0

    guard snapshot.isSatisfied else {
      await assertUnreachable(.noNetworkPath)
      return
    }

    // A live radio is not evidence that the server answered. Preserve a proven server outage;
    // only the no-network state is cleared, and it returns to the evidence-free `.unknown` state.
    if case .unreachable(.noNetworkPath, since: _) = state {
      await transition(to: .unknown)
    }
  }

  /// `since` dates the outage, not the evidence that keeps proving it. An outage already asserted
  /// for `reason` keeps its original date however many further failures or path republications
  /// arrive. `NWPathMonitor` reports an interface change with `isSatisfied` still false as an
  /// ordinary update, and a stalled app can accumulate failures for minutes. A different reason
  /// is a different outage and does start a new date.
  private func assertUnreachable(_ reason: ServerUnreachableReason) async {
    if case .unreachable(reason, since: let existing) = state {
      await transition(to: .unreachable(reason, since: existing))
      return
    }
    await transition(to: .unreachable(reason, since: clock.now()))
  }

  private func applyProbeOutcome(_ outcome: ServerReachabilityProbeOutcome) async {
    switch outcome {
    case .reached:
      consecutiveTransportFailures = 0
      await transition(to: .reachable)

    case .didNotReach:
      guard isPathSatisfied else {
        consecutiveTransportFailures = 0
        await assertUnreachable(.noNetworkPath)
        return
      }
      await assertUnreachable(.serverUnreachable)
    }
  }

  private func transition(to nextState: ServerReachability) async {
    guard nextState != state else { return }
    let wasUnreachable = isUnreachable(state)
    let isNowUnreachable = isUnreachable(nextState)
    state = nextState
    stateHub.publish(nextState)

    if wasUnreachable, isNowUnreachable == false {
      recoveryBackoff.reset()
      recoveryEpoch &+= 1
      pendingRecoveryEpoch = nil
      cancelInFlightRecoveryProbe()
      await scheduler.cancelPending()
    } else if wasUnreachable == false, isNowUnreachable {
      await scheduleInitialRecoveryIfNeeded()
    }
  }

  private func handleLifecycle(_ transition: AppLifecycleTransition) async {
    switch transition {
    case .background:
      recoveryEpoch &+= 1
      pendingRecoveryEpoch = nil
      cancelInFlightRecoveryProbe()
      await scheduler.cancelPending()

    case .foreground:
      guard isUnreachable(state) else { return }
      recoveryEpoch &+= 1
      pendingRecoveryEpoch = nil
      await scheduler.cancelPending()
      guard inFlightProbeID == nil else { return }
      startProbe(.recovery(epoch: recoveryEpoch))
    }
  }

  private func scheduleInitialRecoveryIfNeeded() async {
    guard
      isUnreachable(state), appLifecycle.isForeground,
      pendingRecoveryEpoch == nil, inFlightRecoveryProbe == false
    else { return }
    await scheduleRecovery(after: BackoffPolicy.baseDelay, epoch: recoveryEpoch)
  }

  private func scheduleRecovery(after delay: TimeInterval, epoch: UInt64) async {
    guard
      isUnreachable(state), appLifecycle.isForeground,
      epoch == recoveryEpoch, pendingRecoveryEpoch == nil
    else { return }

    pendingRecoveryEpoch = epoch
    await scheduler.reschedule(after: delay) { [weak self] in
      await self?.recoveryDeadlineFired(epoch: epoch)
    }

    // A lifecycle edge may have interleaved with the scheduler hop. Withdraw the deadline only
    // while this call still owns the pending slot: an interleaving edge that armed its own
    // deadline already took ownership, and cancelling that one would strand recovery with nothing
    // scheduled and nothing left to reschedule it.
    guard pendingRecoveryEpoch == epoch else { return }
    guard isUnreachable(state), appLifecycle.isForeground, epoch == recoveryEpoch else {
      pendingRecoveryEpoch = nil
      await scheduler.cancelPending()
      return
    }
  }

  private func recoveryDeadlineFired(epoch: UInt64) {
    guard pendingRecoveryEpoch == epoch else { return }
    pendingRecoveryEpoch = nil
    guard isUnreachable(state), appLifecycle.isForeground, inFlightProbeID == nil else { return }
    startProbe(.recovery(epoch: epoch))
  }

  private var inFlightRecoveryProbe: Bool {
    guard let inFlightProbeTrigger else { return false }
    if case .recovery = inFlightProbeTrigger { return true }
    return false
  }

  private func cancelInFlightRecoveryProbe() {
    guard inFlightRecoveryProbe else { return }
    probeTask?.cancel()
  }

  private func startProbe(_ trigger: ProbeTrigger) {
    guard inFlightProbeID == nil else { return }

    let id = nextProbeID
    nextProbeID &+= 1
    inFlightProbeID = id
    inFlightProbeTrigger = trigger

    let probe = self.probe
    let timeout = probeTimeout
    let timeoutScheduler = self.timeoutScheduler
    probeTask = Task { [weak self] in
      let result = await Self.executeProbe(
        probe: probe, timeout: timeout, timeoutScheduler: timeoutScheduler)
      guard Task.isCancelled == false else {
        await self?.cancelledProbe(id: id)
        return
      }
      await self?.completeProbe(id: id, trigger: trigger, result: result)
    }
  }

  private static func executeProbe(
    probe: any ServerStatusProbing,
    timeout: TimeInterval,
    timeoutScheduler: any PlaybackCadenceScheduling
  ) async -> ProbeRaceResult {
    let timeoutGate = ProbeTimeoutGate()
    let requestTask = Task<ProbeRequestResult, Never> {
      do {
        try await probe.probeServerStatus()
        return .reached
      } catch let error as URLError {
        return error.code == .cancelled ? .cancelled : .didNotReach
      } catch is CancellationError {
        return .cancelled
      } catch {
        // HTTP status failures (including APIError.serverFailure and APIError.notFound) and
        // APIError.decoding all prove that the server answered. The probe has no reason to
        // publish those details, only the reachability fact.
        return .reached
      }
    }
    timeoutGate.install(requestTask)
    await timeoutScheduler.reschedule(after: timeout) {
      timeoutGate.expire()
    }

    let result = await withTaskCancellationHandler {
      await requestTask.value
    } onCancel: {
      requestTask.cancel()
      Task { await timeoutScheduler.cancelPending() }
    }
    await timeoutScheduler.cancelPending()

    guard Task.isCancelled == false else { return .cancelled }
    // A concrete answer outranks the deadline flag. The request can return just as the timeout
    // fires, and reporting that server's own response as an outage would be the false positive
    // this whole slice exists to avoid. Only an unanswered request becomes `.timedOut`.
    switch result {
    case .reached:
      return .reached
    case .didNotReach:
      return .didNotReach
    case .cancelled:
      return timeoutGate.expired ? .timedOut : .cancelled
    }
  }

  private func cancelledProbe(id: UInt64) async {
    guard inFlightProbeID == id else { return }
    inFlightProbeID = nil
    inFlightProbeTrigger = nil
    probeTask = nil

    // A cancelled probe reports nothing, so it neither clears the outage nor paces the next
    // attempt. Recovery would otherwise be left with no probe running and no deadline armed,
    // waiting on a foreground transition that may never come while the app is already frontmost.
    await scheduleInitialRecoveryIfNeeded()
  }

  private func completeProbe(
    id: UInt64,
    trigger: ProbeTrigger,
    result: ProbeRaceResult
  ) async {
    guard inFlightProbeID == id, inFlightProbeTrigger == trigger else { return }
    inFlightProbeID = nil
    inFlightProbeTrigger = nil
    probeTask = nil

    // A cancelled request carries no verdict about the server, so it must not change state, but
    // it also consumed the attempt that was pacing recovery. Re-arm before returning, or a
    // recovery probe cancelled underneath us silently ends the retry sequence.
    guard result != .cancelled else {
      await scheduleInitialRecoveryIfNeeded()
      return
    }
    let outcome: ServerReachabilityProbeOutcome =
      result == .reached ? .reached : .didNotReach

    switch trigger {
    case .detection:
      await applyProbeOutcome(outcome)
      await scheduleInitialRecoveryIfNeeded()

    case .recovery(let epoch):
      guard epoch == recoveryEpoch, isUnreachable(state), appLifecycle.isForeground else { return }
      await applyProbeOutcome(outcome)
      guard epoch == recoveryEpoch, isUnreachable(state), appLifecycle.isForeground else { return }

      // The first recovery attempt is foreground-immediate. Every failed recovery probe after it
      // advances the shared ABSApi policy, so the delay grows exponentially and remains capped.
      let delay = recoveryBackoff.nextDelay(now: clock.now(), randomUnit: randomUnit())
      await scheduleRecovery(after: delay, epoch: epoch)
    }
  }

  private func isUnreachable(_ value: ServerReachability) -> Bool {
    if case .unreachable = value { return true }
    return false
  }
}

/// Small ABSApi-to-SyncEngine bridge used when composing the production transport observer.
public struct ServerReachabilityMonitorAdapter: ServerReachabilityObserving, Sendable {
  private let monitor: ServerReachabilityMonitor

  public init(monitor: ServerReachabilityMonitor) {
    self.monitor = monitor
  }

  public func reachabilityEvent(_ event: ServerReachabilityEvent) async {
    await monitor.receive(event)
  }
}
