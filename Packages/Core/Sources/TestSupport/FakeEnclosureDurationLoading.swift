import AppModel
import Foundation

/// `EnclosureDurationLoading`'s fake. Every load is recorded, then answers from the stubbed
/// result or failure, or from a handler that decides per URL (a local file against a remote
/// enclosure, say).
///
/// `gate` parks every load until the test releases it, so a test can prove that callers coalesce
/// or that a second load starts while the first is still running. A load that was parked and whose
/// task was cancelled in the meantime throws `CancellationError` once it resumes, as a real
/// measurement would.
public final class FakeEnclosureDurationLoading: EnclosureDurationLoading, @unchecked Sendable {
  /// Every `loadDuration(for:)` URL, in order, recorded before the gate or the answer.
  public let recorder = CallRecorder<URL>(label: "FakeEnclosureDurationLoading loads")

  /// Hold it (`hold()`) to park each load until the test calls `release()` or `releaseNext()`.
  /// Open by default, so a load answers at once.
  public let gate = TestGate<Void>(label: "FakeEnclosureDurationLoading.loadDuration")

  private let result: Locked<Double?>
  private let failure: Locked<(any Error)?>
  private let handler = Locked<(@Sendable (URL) async throws -> Double?)?>(nil)

  /// - Parameters:
  ///   - result: what every load returns (default `nil`, an unmeasurable file).
  ///   - failure: when set, every load throws it instead.
  public init(result: Double? = nil, failure: (any Error)? = nil) {
    self.result = Locked(result)
    self.failure = Locked(failure)
  }

  /// Answers every load from `handler` instead of the stubbed result or failure. The load is still
  /// recorded, and still waits on `gate`, first.
  public init(handler: @escaping @Sendable (URL) async throws -> Double?) {
    result = Locked(nil)
    failure = Locked(nil)
    self.handler.value = handler
  }

  /// The URLs loaded so far, in order.
  public var loadedURLs: [URL] { recorder.calls }

  /// How many loads have been requested.
  public var callCount: Int { recorder.count }

  /// What every load returns from now on. Clears a stubbed failure.
  public func stubResult(_ result: Double?) {
    self.result.value = result
    failure.value = nil
  }

  /// Makes every load throw `error` from now on.
  public func stubFailure(_ error: (any Error)?) {
    failure.value = error
  }

  /// Replaces the handler; `nil` returns to the stubbed result and failure.
  public func setHandler(_ handler: (@Sendable (URL) async throws -> Double?)?) {
    self.handler.value = handler
  }

  public func loadDuration(for enclosureURL: URL) async throws -> Double? {
    recorder.record(enclosureURL)
    let wasGated = gate.isHeld
    await gate.pass()
    if wasGated { try Task.checkCancellation() }
    if let handler = handler.value { return try await handler(enclosureURL) }
    if let failure = failure.value { throw failure }
    return result.value
  }
}
