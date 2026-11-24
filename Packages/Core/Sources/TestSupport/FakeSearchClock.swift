import AppModel
import Foundation
import Testing

/// `SearchModel`'s injected debounce seam, so tests never call a real `Task.sleep`. Every `sleep()`
/// parks until `advance()` resumes all parked calls at once. A cancelled sleeper returns at once,
/// so a superseded search leaves nothing behind for a later advance.
public final class FakeSearchClock: SearchClock, @unchecked Sendable {
  private let sleeps = TestGate<Void>(label: "FakeSearchClock.sleep")

  public init() {
    sleeps.hold()
  }

  public func sleep() async {
    await sleeps.pass()
  }

  /// Test-only: how many debounce calls are currently parked in `sleep()`.
  public var pendingSleepCount: Int { sleeps.parkedCount }

  /// Test-only: opens the clock for good. Every parked `sleep()` resumes and every later one
  /// returns at once, for a test that is not about the debounce.
  public func resumeImmediately() {
    sleeps.release()
  }

  /// Test-only: waits for the freshly spawned debounce task to park, then resumes every parked
  /// call. The gate stays held for the next debounce.
  public func advance() async {
    await sleeps.waitUntilParked()
    sleeps.releaseParked()
  }
}
