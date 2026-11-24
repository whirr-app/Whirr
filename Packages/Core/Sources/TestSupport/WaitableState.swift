import Foundation
import Testing

/// A fake's mutable state that a test can wait on, bounded.
///
/// This is the one continuation waiter behind `CallRecorder`, `TestGate` and `TestCountRecorder`.
/// A waiter's predicate is evaluated atomically with every `mutate`, so a change that lands between
/// the check and the registration cannot be lost. A predicate that never holds is claimed by
/// `expireContinuationWaiter`'s progress-bounded watchdog, which records an Issue naming `label`
/// and the state it last saw, instead of parking the test until the suite's `.timeLimit`.
/// Cancelling the waiting task resumes it with `.cancelled` and records nothing.
public final class WaitableState<State: Sendable>: @unchecked Sendable {
  private struct Waiter {
    let id: UUID
    let predicate: @Sendable (State) -> Bool
    let continuation: CheckedContinuation<TestWaitOutcome, Never>
  }

  private struct Storage {
    var state: State
    var waiters: [Waiter] = []
  }

  private let storage: Locked<Storage>
  private let label: String
  private let describe: @Sendable (State) -> String

  /// - Parameters:
  ///   - label: names the state in timeout diagnostics, e.g. `"FakeHTTPClient requests"`.
  ///   - describe: summarises the state for a timeout diagnostic.
  public init(
    _ initial: State,
    label: String,
    describe: @escaping @Sendable (State) -> String = { "\($0)" }
  ) {
    self.storage = Locked(Storage(state: initial))
    self.label = label
    self.describe = describe
  }

  public var value: State { storage.value.state }

  /// Changes the state under the lock, then resumes every waiter whose predicate now holds.
  @discardableResult
  public func mutate<Result>(_ body: (inout State) -> Result) -> Result {
    let (result, ready) = storage.withValue { storage in
      let result = body(&storage.state)
      let state = storage.state
      var ready: [CheckedContinuation<TestWaitOutcome, Never>] = []
      storage.waiters.removeAll { waiter in
        guard waiter.predicate(state) else { return false }
        ready.append(waiter.continuation)
        return true
      }
      return (result, ready)
    }
    for continuation in ready { continuation.resume(returning: .observed) }
    return result
  }

  /// Suspends until `predicate` holds for the state, or the progress-bounded `timeout` is spent.
  @discardableResult
  public func waitUntil(
    _ what: String? = nil,
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: @escaping @Sendable (State) -> Bool
  ) async -> TestWaitOutcome {
    let waiterID = UUID()
    let startedAt = Date()
    let waitLabel = what.map { "\(label) \($0)" } ?? label
    let box = storage
    let describe = describe

    let removeAndClaim: @Sendable () -> WaiterResumer? = {
      box.withValue { storage in
        guard let index = storage.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
        let continuation = storage.waiters.remove(at: index).continuation
        return { outcome in continuation.resume(returning: outcome) }
      }
    }
    let observedState: @Sendable () -> String = {
      box.withValue { storage in
        "\(describe(storage.state)); \(storage.waiters.count) waiters registered"
      }
    }

    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<TestWaitOutcome, Never>) in
          let alreadySatisfied = box.withValue { storage -> Bool in
            if predicate(storage.state) { return true }
            storage.waiters.append(
              Waiter(id: waiterID, predicate: predicate, continuation: continuation))
            return false
          }
          if alreadySatisfied {
            continuation.resume(returning: .observed)
            return
          }
          if Task.isCancelled {
            cancelContinuationWaiter(
              label: waitLabel, sourceLocation: sourceLocation, startedAt: startedAt,
              observedState: observedState, removeAndClaim: removeAndClaim)
            return
          }
          Task {
            await expireContinuationWaiter(
              label: waitLabel, timeout: timeout, sourceLocation: sourceLocation,
              isRegistered: { box.withValue { $0.waiters.contains { $0.id == waiterID } } },
              removeAndClaim: removeAndClaim,
              observedState: observedState)
          }
        }
      },
      onCancel: {
        cancelContinuationWaiter(
          label: waitLabel, sourceLocation: sourceLocation, startedAt: startedAt,
          observedState: observedState, removeAndClaim: removeAndClaim)
      })
  }
}
