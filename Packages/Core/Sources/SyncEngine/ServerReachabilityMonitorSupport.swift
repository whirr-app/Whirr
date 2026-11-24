import Foundation

/// Keeps the monitor's weak-self subscription tasks cancellable without making the actor escape
/// from its initializer before every stored property is initialized. The registry itself has no
/// reference back to the actor, so it does not change the monitor's lifetime semantics.
final class ServerReachabilityMonitorLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []

  func add(_ task: Task<Void, Never>) {
    lock.lock()
    tasks.append(task)
    lock.unlock()
  }

  func cancelAll() {
    lock.lock()
    let tasks = self.tasks
    self.tasks.removeAll()
    lock.unlock()
    for task in tasks {
      task.cancel()
    }
  }
}

enum ProbeRequestResult: Sendable, Equatable {
  case reached
  case didNotReach
  case cancelled
}

/// Coordinates cancellation of one request with its virtual/real timeout deadline. The deadline
/// scheduler has a one-pending-deadline contract, so recovery and probe-timeout schedulers are
/// separate instances even though both reuse `PlaybackCadenceScheduling`.
final class ProbeTimeoutGate: @unchecked Sendable {
  private let lock = NSLock()
  private var requestTask: Task<ProbeRequestResult, Never>?
  private var didExpire = false

  func install(_ requestTask: Task<ProbeRequestResult, Never>) {
    lock.lock()
    self.requestTask = requestTask
    let shouldCancel = didExpire
    lock.unlock()
    if shouldCancel {
      requestTask.cancel()
    }
  }

  func expire() {
    lock.lock()
    didExpire = true
    let requestTask = self.requestTask
    lock.unlock()
    requestTask?.cancel()
  }

  var expired: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didExpire
  }
}

/// Lock-backed state and stream storage lets the actor expose a synchronous current value and a
/// nonisolated replaying stream: subscription does not need to await the actor, while the actor
/// remains the sole owner of state transitions.
final class ServerReachabilityStateHub: @unchecked Sendable {
  private let lock = NSLock()
  private var state: ServerReachability
  private var subscribers: [UUID: AsyncStream<ServerReachability>.Continuation] = [:]
  private var isFinished = false

  init(initialState: ServerReachability) {
    state = initialState
  }

  var current: ServerReachability {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  func stream() -> AsyncStream<ServerReachability> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }

      lock.lock()
      guard isFinished == false else {
        lock.unlock()
        continuation.finish()
        return
      }
      subscribers[id] = continuation
      continuation.yield(state)
      lock.unlock()

      continuation.onTermination = { [weak self] _ in
        self?.removeSubscriber(id: id)
      }
    }
  }

  func publish(_ nextState: ServerReachability) {
    lock.lock()
    guard isFinished == false, nextState != state else {
      lock.unlock()
      return
    }
    state = nextState
    for continuation in subscribers.values {
      continuation.yield(nextState)
    }
    lock.unlock()
  }

  func finish() {
    lock.lock()
    guard isFinished == false else {
      lock.unlock()
      return
    }
    isFinished = true
    let continuations = Array(subscribers.values)
    subscribers.removeAll()
    lock.unlock()
    for continuation in continuations {
      continuation.finish()
    }
  }

  private func removeSubscriber(id: UUID) {
    lock.lock()
    subscribers.removeValue(forKey: id)
    lock.unlock()
  }
}
