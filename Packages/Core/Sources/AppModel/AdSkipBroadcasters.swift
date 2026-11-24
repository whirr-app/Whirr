import Foundation
import Synchronization

/// Holds the latest value and fans each change out to every open stream, starting each new stream
/// with the value it holds.
final class LatestValueBroadcaster<Value: Equatable & Sendable>: Sendable {
  private struct State {
    var latest: Value?
    var continuations: [UUID: AsyncStream<Value?>.Continuation] = [:]
  }

  private let state = Mutex(State())

  var latest: Value? { state.withLock { $0.latest } }

  func stream() -> AsyncStream<Value?> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      state.withLock {
        $0.continuations[id] = continuation
        continuation.yield($0.latest)
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
      }
    }
  }

  func publish(_ value: Value?) {
    let continuations = state.withLock { state -> [AsyncStream<Value?>.Continuation] in
      guard state.latest != value else { return [] }
      state.latest = value
      return Array(state.continuations.values)
    }
    for continuation in continuations { continuation.yield(value) }
  }
}

/// Fans "ranges may have changed" out to every open stream.
final class SkipRangeChangeBroadcaster: Sendable {
  private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

  func stream() -> AsyncStream<Void> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      continuations.withLock { $0[id] = continuation }
      continuation.onTermination = { [weak self] _ in
        _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
      }
    }
  }

  func signal() {
    for continuation in continuations.withLock({ Array($0.values) }) { continuation.yield() }
  }
}
