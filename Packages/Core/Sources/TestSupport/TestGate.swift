import Foundation
import Testing

/// Holds a faked call in flight until the test releases it, so a test can exercise ordering and
/// cancellation without a sleep.
///
/// A fake calls `pass(otherwise:)` where the real service would do its work. While the gate is
/// open, `pass` returns `otherwise()` at once. After `hold()`, every `pass` parks until the test
/// calls `release(_:)` or `releaseNext(_:)`, and returns the value given there. A throwing call
/// uses `Result` as `Released` and calls `.get()` on what `pass` returns.
///
/// A parked call whose task is cancelled returns `otherwise()` at once, unless the gate was made
/// with `ignoresCancellation: true` to stand in for work that runs to completion regardless (the
/// call then stays parked until released, as the real one would). One the test never releases
/// is claimed by the progress-bounded watchdog (`expireContinuationWaiter`), which records an Issue
/// and returns `otherwise()`, so a forgotten `release` fails the test instead of hanging it.
public final class TestGate<Released: Sendable>: @unchecked Sendable {
  private struct Parked: Sendable {
    let id: UUID
    let continuation: CheckedContinuation<Released, Never>
  }

  private struct Storage: Sendable {
    var isHeld = false
    var parked: [Parked] = []
  }

  // One lock for the flag and the parked calls, so a `release` can never miss a call that is
  // parking at the same moment.
  private let state: WaitableState<Storage>
  private let label: String
  private let ignoresCancellation: Bool

  /// - Parameter label: names the gated call in timeout diagnostics.
  public init(label: String, ignoresCancellation: Bool = false) {
    self.label = label
    self.ignoresCancellation = ignoresCancellation
    state = WaitableState(Storage(), label: label) { storage in
      "held \(storage.isHeld); \(storage.parked.count) parked"
    }
  }

  public var isHeld: Bool { state.value.isHeld }
  public var parkedCount: Int { state.value.parked.count }

  /// Makes every following `pass` park until released.
  public func hold() {
    state.mutate { $0.isHeld = true }
  }

  /// Opens the gate and resumes every parked call with `value`.
  public func release(_ value: Released) {
    let resumed = state.mutate { storage in
      storage.isHeld = false
      defer { storage.parked = [] }
      return storage.parked
    }
    for call in resumed { call.continuation.resume(returning: value) }
  }

  /// Resumes every parked call with `value` and keeps the gate held for the next ones.
  public func releaseParked(_ value: Released) {
    let resumed = state.mutate { storage in
      defer { storage.parked = [] }
      return storage.parked
    }
    for call in resumed { call.continuation.resume(returning: value) }
  }

  /// Resumes the oldest parked call with `value` and keeps the gate held.
  public func releaseNext(_ value: Released) {
    let next = state.mutate { storage in
      storage.parked.isEmpty ? nil : storage.parked.removeFirst()
    }
    next?.continuation.resume(returning: value)
  }

  /// Called by the fake. Returns `otherwise()` while the gate is open; parks while it is held.
  /// A timeout's Issue names the gate's label: the fake's own line would not help a reader.
  public func pass(
    timeout: TimeInterval = 10,
    otherwise: @escaping @Sendable () -> Released
  ) async -> Released {
    let sourceLocation = #_sourceLocation
    guard state.value.isHeld else { return otherwise() }
    let id = UUID()
    let startedAt = Date()
    let state = state
    let removeAndClaim: @Sendable () -> WaiterResumer? = {
      let claimed = state.mutate { storage -> Parked? in
        guard let index = storage.parked.firstIndex(where: { $0.id == id }) else { return nil }
        return storage.parked.remove(at: index)
      }
      guard let claimed else { return nil }
      return { _ in claimed.continuation.resume(returning: otherwise()) }
    }
    let observedState: @Sendable () -> String = {
      let storage = state.value
      return "held \(storage.isHeld); \(storage.parked.count) parked; never released"
    }
    let label = label
    let ignoresCancellation = ignoresCancellation
    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<Released, Never>) in
          let parked = state.mutate { storage -> Bool in
            guard storage.isHeld, ignoresCancellation || Task.isCancelled == false else {
              return false
            }
            storage.parked.append(Parked(id: id, continuation: continuation))
            return true
          }
          guard parked else {
            continuation.resume(returning: otherwise())
            return
          }
          Task {
            await expireContinuationWaiter(
              label: "\(label) held", timeout: timeout, sourceLocation: sourceLocation,
              isRegistered: { state.value.parked.contains { $0.id == id } },
              removeAndClaim: removeAndClaim,
              observedState: observedState)
          }
        }
      },
      onCancel: {
        guard ignoresCancellation == false else { return }
        cancelContinuationWaiter(
          label: "\(label) held", sourceLocation: sourceLocation, startedAt: startedAt,
          observedState: observedState, removeAndClaim: removeAndClaim)
      })
  }

  /// Suspends until at least `count` calls are parked.
  @discardableResult
  public func waitUntilParked(
    count target: Int = 1,
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> TestWaitOutcome {
    await state.waitUntil(
      "parking \(target) calls", timeout: timeout, sourceLocation: sourceLocation
    ) { $0.parked.count >= target }
  }
}

extension TestGate where Released == Void {
  public func release() { release(()) }
  public func releaseNext() { releaseNext(()) }
  public func releaseParked() { releaseParked(()) }
  public func pass() async {
    await pass(otherwise: {})
  }
}
