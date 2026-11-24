import Foundation

/// Fan-out for a single event producer: each `subscribe()` returns an independent `AsyncStream`
/// that receives every event yielded from that moment on, and a subscriber's teardown (task
/// cancellation, iterator dropped) terminates only its own stream.
///
/// An `AsyncStream` is safe with only one consumer. Where a process-lifetime producer outlives its
/// consumers (`PlayerController.progressEvents` across an `AppEnvironment` rebuild, the
/// background-download adapter across a `DownloadCoordinator` rebuild), a second consumer either
/// races the first for elements or, after the first is torn down, finds the stream finished and
/// silently drops every later event. Each consumer here gets its own complete copy.
///
/// Lock-guarded, not an actor: `yield` arrives from a nonisolated relay task and `subscribe` runs
/// wherever a consumer is constructed, and neither side may suspend.
public final class AsyncEventMulticaster<Event: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
  private var isFinished = false

  public init() {}

  public func subscribe() -> AsyncStream<Event> {
    AsyncStream { continuation in
      let id = UUID()
      lock.lock()
      let finished = isFinished
      if finished == false { continuations[id] = continuation }
      lock.unlock()

      if finished {
        continuation.finish()
        return
      }
      continuation.onTermination = { _ in
        self.lock.lock()
        self.continuations[id] = nil
        self.lock.unlock()
      }
    }
  }

  public func yield(_ event: Event) {
    for continuation in currentContinuations() {
      continuation.yield(event)
    }
  }

  public func finish() {
    lock.lock()
    isFinished = true
    let remaining = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    for continuation in remaining {
      continuation.finish()
    }
  }

  private func currentContinuations() -> [AsyncStream<Event>.Continuation] {
    lock.lock()
    defer { lock.unlock() }
    return Array(continuations.values)
  }
}
