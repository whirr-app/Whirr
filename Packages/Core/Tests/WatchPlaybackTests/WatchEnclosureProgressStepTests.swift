import Foundation
import Testing

@testable import WatchPlayback

/// The at-most-every-10% inventory progress rule.
struct WatchEnclosureProgressStepTests {
  @Test func theFirstValueIsAlwaysReported() {
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: nil, current: 0))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: nil, current: 0.03))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: nil, current: 1))
  }

  @Test func aNewTenthIsReportedAndARepeatedOneIsNot() {
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0, current: 0.09) == false)
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0, current: 0.1))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.31, current: 0.35) == false)
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.31, current: 0.4))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.42, current: 0.5))
  }

  /// 0.7 × 10 is 6.999… in binary, so the boundary must still count as a new tenth.
  @Test func anExactTenthBoundaryIsANewBucket() {
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.65, current: 0.7))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.6, current: 0.7))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.3, current: 0.7))
  }

  @Test func completionIsReportedOnce() {
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.95, current: 1))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.9, current: 1.0))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 1, current: 1) == false)
  }

  @Test func aRestartedDownloadDoesNotReReportOldBuckets() {
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.5, current: 0.2) == false)
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 0.5, current: 0.6))
  }

  @Test func nonFiniteValuesAreNeverReported() {
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: nil, current: .nan) == false)
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: nil, current: .infinity) == false)
  }

  @Test func valuesOutsideTheFractionAreClamped() {
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: nil, current: 2))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: nil, current: -1))
    #expect(WatchEnclosureProgressStep.shouldReport(lastReported: 1, current: 2) == false)
  }
}
