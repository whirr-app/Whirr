import Foundation
import Testing

/// Counts occurrences and suspends until the nth one arrives: a `CallRecorder` that only needs the
/// count. Bounded like every waiter here (see `WaitableState`); on timeout it reports the count it
/// saw.
public final class TestCountRecorder: @unchecked Sendable {
  private let state: WaitableState<Int>

  /// - Parameter label: names the thing being counted in timeout diagnostics, e.g.
  ///   `"PodcastRefreshCoordinator context resolutions"`.
  public init(label: String) {
    state = WaitableState(0, label: label) { "counted \($0)" }
  }

  public var count: Int { state.value }

  public func record() {
    state.mutate { $0 += 1 }
  }

  /// Suspends until at least `target` occurrences have been recorded.
  @discardableResult
  public func waitUntil(
    count target: Int,
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> TestWaitOutcome {
    await state.waitUntil("reaching \(target)", timeout: timeout, sourceLocation: sourceLocation) {
      $0 >= target
    }
  }
}
