import Foundation
import SyncEngine
import Testing

@testable import Whirr

/// `RealPathObserving`'s first-path wait. An unstarted or not-yet-updated `NWPathMonitor` reports
/// an empty path that reads as "not cellular", so a background guard must not decide from it.
@Suite("Path update latch")
struct PathUpdateLatchTests {
  private let cellular = PathSnapshot(isSatisfied: true, isCellular: true, isConstrained: false)

  @Test("nothing reported means no path, not a default one")
  func noReportTimesOutToNil() async {
    let latch = PathUpdateLatch()
    #expect(latch.latest == nil)
    #expect(await latch.first(within: .milliseconds(50)) == nil)
  }

  @Test("a path reported during the wait is returned")
  func reportDuringTheWaitIsReturned() async throws {
    let latch = PathUpdateLatch()
    let cellular = cellular
    // Detached, like the monitor's own queue: the report must not need the test's actor.
    let reporter = Task.detached {
      try await Task.sleep(for: .milliseconds(30))
      latch.record(cellular)
    }
    #expect(await latch.first(within: .seconds(30)) == cellular)
    #expect(latch.latest == cellular)
    try await reporter.value
  }

  @Test("an already reported path is returned without waiting")
  func alreadyReportedPathReturnsImmediately() async {
    let latch = PathUpdateLatch()
    latch.record(cellular)
    #expect(await latch.first(within: .zero) == cellular)
  }
}
