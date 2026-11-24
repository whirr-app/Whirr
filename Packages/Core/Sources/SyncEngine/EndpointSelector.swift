import Foundation
import Persistence

private enum EndpointProbeAttempt: Sendable {
  case reached
  case failed
  case timedOut
  case cancelled
}

/// Selects the best currently reachable address for the one stored account: every endpoint is
/// probed at once, the most-preferred one that answers inside the preference window wins, and
/// after the window the first answer wins. Selection ends the moment a winner is known; probes
/// still outstanding are abandoned rather than awaited to their timeout.
public actor EndpointSelector {
  public enum Outcome: Sendable, Equatable {
    case noAccount
    case singleEndpoint
    case unchanged(active: String)
    case switched(from: String, to: String)
    case nothingAnswered(active: String)
  }

  private enum SelectionEvent: Sendable {
    case probe(index: Int, attempt: EndpointProbeAttempt)
    case preferenceWindowElapsed
    case preferenceWindowCancelled
  }

  private let accountDAO: AccountDAO
  private let accountEndpointDAO: AccountEndpointDAO
  private let probe: @Sendable (AccountEndpointRecord) async throws -> Void
  private let preferenceWindow: TimeInterval
  private let probeTimeout: TimeInterval
  private let sleep: @Sendable (TimeInterval) async -> Void
  private let now: @Sendable () -> Date
  private var selectionTask: Task<Outcome, Never>?

  public init(
    accountDAO: AccountDAO,
    accountEndpointDAO: AccountEndpointDAO,
    probe: @escaping @Sendable (AccountEndpointRecord) async throws -> Void,
    preferenceWindow: TimeInterval = 2,
    probeTimeout: TimeInterval = ServerReachabilityMonitor.probeTimeout,
    sleep: @escaping @Sendable (TimeInterval) async -> Void = {
      try? await Task.sleep(for: .seconds($0))
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.accountDAO = accountDAO
    self.accountEndpointDAO = accountEndpointDAO
    self.probe = probe
    self.preferenceWindow = max(0, preferenceWindow)
    self.probeTimeout = max(0, probeTimeout)
    self.sleep = sleep
    self.now = now
  }

  /// Concurrent callers share one selection pass, including its probe work and database writes.
  public func select() async -> Outcome {
    if let selectionTask {
      return await selectionTask.value
    }

    let task = Task { [weak self] in
      await self?.performSelection() ?? .noAccount
    }
    selectionTask = task
    return await task.value
  }

  private func performSelection() async -> Outcome {
    defer { selectionTask = nil }

    guard let account = try? accountDAO.fetch(), let accountID = account.id else {
      return .noAccount
    }
    guard let endpoints = try? accountEndpointDAO.fetchAll(accountId: accountID),
      endpoints.isEmpty == false
    else {
      return .noAccount
    }
    guard endpoints.count > 1 else { return .singleEndpoint }

    let orderedEndpoints = endpoints.sorted { lhs, rhs in
      if lhs.isPreferred != rhs.isPreferred {
        return lhs.isPreferred
      }
      if lhs.sortOrder != rhs.sortOrder {
        return lhs.sortOrder < rhs.sortOrder
      }
      return (lhs.id ?? 0) < (rhs.id ?? 0)
    }

    var attempts: [Int: EndpointProbeAttempt] = [:]
    var winnerIndex: Int?
    var preferenceWindowElapsed = false
    var preferenceWindowTimedOut = false
    let preferenceTimer = SelectionTimerBox()

    await withTaskGroup(of: SelectionEvent.self) { group in
      for (index, endpoint) in orderedEndpoints.enumerated() {
        group.addTask { [self] in
          .probe(index: index, attempt: await probeEndpoint(endpoint))
        }
      }
      group.addTask { [sleep, preferenceWindow, preferenceTimer] in
        if await preferenceTimer.start(duration: preferenceWindow, sleep: sleep) {
          return .preferenceWindowElapsed
        }
        return .preferenceWindowCancelled
      }

      while let event = await group.next() {
        switch event {
        case .probe(let index, let attempt):
          attempts[index] = attempt
          guard winnerIndex == nil, case .reached = attempt else { continue }

          if index == orderedEndpoints.startIndex {
            winnerIndex = index
            preferenceWindowElapsed = true
            preferenceTimer.cancel()
            group.cancelAll()
            continue
          }

          if preferenceWindowElapsed {
            // After the preference window, the first successful result wins.
            winnerIndex = index
            group.cancelAll()
          }

        case .preferenceWindowElapsed:
          preferenceWindowElapsed = true
          preferenceWindowTimedOut = true
          guard winnerIndex == nil else { continue }
          winnerIndex = orderedEndpoints.indices.first { index in
            if case .reached? = attempts[index] { return true }
            return false
          }
          if winnerIndex != nil {
            group.cancelAll()
          }

        case .preferenceWindowCancelled:
          break
        }
      }
    }

    for (index, endpoint) in orderedEndpoints.enumerated() {
      guard let endpointID = endpoint.id, let attempt = attempts[index] else { continue }
      switch attempt {
      case .reached:
        try? accountEndpointDAO.markReached(id: endpointID, at: now())
      case .failed, .timedOut:
        try? accountEndpointDAO.markFailed(id: endpointID, at: now())
      case .cancelled:
        // Abandoned once a winner was known. Only an endpoint that had the whole preference
        // window and still had not answered is evidence of a failure; one abandoned because the
        // preferred address answered first has proved nothing either way.
        if preferenceWindowTimedOut {
          try? accountEndpointDAO.markFailed(id: endpointID, at: now())
        }
      }
    }

    guard let winnerIndex, case .reached = attempts[winnerIndex] else {
      return .nothingAnswered(active: account.serverBaseURL)
    }

    let winner = orderedEndpoints[winnerIndex].normalizedURL
    guard winner != account.serverBaseURL else {
      return .unchanged(active: account.serverBaseURL)
    }
    try? accountEndpointDAO.setActive(accountId: accountID, normalizedURL: winner)
    return .switched(from: account.serverBaseURL, to: winner)
  }

  private func probeEndpoint(_ endpoint: AccountEndpointRecord) async -> EndpointProbeAttempt {
    let probe = self.probe
    let sleep = self.sleep
    let timeout = self.probeTimeout
    return await Self.race(
      probe: {
        do {
          try await probe(endpoint)
          return .reached
        } catch is CancellationError {
          return .cancelled
        } catch {
          return .failed
        }
      },
      timeout: timeout,
      sleep: sleep)
  }

  private static func race(
    probe: @escaping @Sendable () async -> EndpointProbeAttempt,
    timeout: TimeInterval,
    sleep: @escaping @Sendable (TimeInterval) async -> Void
  ) async -> EndpointProbeAttempt {
    let box = ProbeRaceBox()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        box.start(probe: probe, timeout: timeout, sleep: sleep, continuation: continuation)
      }
    } onCancel: {
      box.cancel()
    }
  }
}

/// The selector must stop waiting at the timeout even when a transport adapter ignores task
/// cancellation. The losing request is cancelled, but its eventual result is
/// detached from selection; the structured task group only waits for this bounded race.
private final class ProbeRaceBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<EndpointProbeAttempt, Never>?
  private var probeTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var resolved = false

  func start(
    probe: @escaping @Sendable () async -> EndpointProbeAttempt,
    timeout: TimeInterval,
    sleep: @escaping @Sendable (TimeInterval) async -> Void,
    continuation: CheckedContinuation<EndpointProbeAttempt, Never>
  ) {
    lock.lock()
    self.continuation = continuation
    let alreadyResolved = resolved
    lock.unlock()
    guard alreadyResolved == false else {
      continuation.resume(returning: .cancelled)
      return
    }

    let probeTask = Task { [weak self] in
      guard let self else { return }
      self.resolve(await probe())
    }
    let timeoutTask = Task { [weak self] in
      await sleep(timeout)
      guard let self else { return }
      self.resolve(.timedOut)
    }

    lock.lock()
    self.probeTask = probeTask
    self.timeoutTask = timeoutTask
    let shouldCancel = resolved
    lock.unlock()
    if shouldCancel {
      probeTask.cancel()
      timeoutTask.cancel()
    }
  }

  func cancel() {
    resolve(.cancelled)
  }

  private func resolve(_ result: EndpointProbeAttempt) {
    lock.lock()
    guard resolved == false else {
      lock.unlock()
      return
    }
    resolved = true
    let continuation = self.continuation
    self.continuation = nil
    let probeTask = self.probeTask
    let timeoutTask = self.timeoutTask
    lock.unlock()

    probeTask?.cancel()
    timeoutTask?.cancel()
    continuation?.resume(returning: result)
  }
}

/// Allows the preference timer to stop waiting even when a test clock or transport ignores
/// task cancellation. The timer's underlying sleeper is still cancelled on resolution.
private final class SelectionTimerBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?
  private var sleeper: Task<Void, Never>?
  private var resolved = false

  func start(
    duration: TimeInterval,
    sleep: @escaping @Sendable (TimeInterval) async -> Void
  ) async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.lock()
        self.continuation = continuation
        let alreadyResolved = resolved
        lock.unlock()
        guard alreadyResolved == false else {
          continuation.resume(returning: false)
          return
        }

        let sleeper = Task { [weak self] in
          await sleep(duration)
          self?.resolve(true)
        }
        lock.lock()
        self.sleeper = sleeper
        let shouldCancel = resolved
        lock.unlock()
        if shouldCancel { sleeper.cancel() }
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() {
    resolve(false)
  }

  private func resolve(_ value: Bool) {
    lock.lock()
    guard resolved == false else {
      lock.unlock()
      return
    }
    resolved = true
    let continuation = self.continuation
    self.continuation = nil
    let sleeper = self.sleeper
    lock.unlock()

    sleeper?.cancel()
    continuation?.resume(returning: value)
  }
}
