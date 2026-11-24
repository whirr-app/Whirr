import Foundation
import Testing

/// A fake's call log: records calls in order and lets a test wait, bounded, for the log to reach a
/// state. Every fake records through one of these instead of keeping its own array and waiters.
///
/// ```swift
/// public enum Call: Sendable, Equatable { case fetch(id: String), cancel }
/// public let recorder = CallRecorder<Call>(label: "FakeThing")
/// public var calls: [Call] { recorder.calls }
///
/// func fetch(id: String) async throws -> Item {
///   recorder.record(.fetch(id: id))
///   …
/// }
///
/// // In a test:
/// await fake.recorder.waitUntil { $0.contains(.cancel) }
/// ```
public final class CallRecorder<Call: Sendable>: @unchecked Sendable {
  private let state: WaitableState<[Call]>

  /// - Parameter label: names the fake in timeout diagnostics.
  public init(label: String) {
    state = WaitableState([], label: label) { calls in
      let last = calls.last.map { "\($0)" } ?? "none"
      return "recorded \(calls.count) calls; last \(last)"
    }
  }

  public var calls: [Call] { state.value }
  public var count: Int { state.value.count }

  public func record(_ call: Call) {
    state.mutate { $0.append(call) }
  }

  public func removeAll() {
    state.mutate { $0.removeAll() }
  }

  /// Suspends until the call log satisfies `predicate`.
  @discardableResult
  public func waitUntil(
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: @escaping @Sendable ([Call]) -> Bool
  ) async -> TestWaitOutcome {
    await state.waitUntil(
      "satisfying the predicate", timeout: timeout, sourceLocation: sourceLocation, predicate)
  }

  /// Suspends until at least `target` calls have been recorded.
  @discardableResult
  public func waitUntil(
    count target: Int,
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> TestWaitOutcome {
    await state.waitUntil(
      "reaching \(target) calls", timeout: timeout, sourceLocation: sourceLocation
    ) { $0.count >= target }
  }
}
