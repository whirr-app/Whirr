import Foundation
import Testing

@testable import AppModel

@Suite struct AppModelStalenessTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  @Test("a missing last-completed date is stale")
  func missingLastCompletedDateIsStale() {
    #expect(
      AppModelStaleness.isStale(
        lastCompletedAt: nil, now: now, staleAfter: 60))
  }

  @Test("a cache exactly staleAfter old is still fresh")
  func exactBoundaryIsFresh() {
    #expect(
      AppModelStaleness.isStale(
        lastCompletedAt: now.addingTimeInterval(-60), now: now, staleAfter: 60) == false)
  }

  @Test("a cache one second past staleAfter is stale")
  func oneSecondPastBoundaryIsStale() {
    #expect(
      AppModelStaleness.isStale(
        lastCompletedAt: now.addingTimeInterval(-61), now: now, staleAfter: 60))
  }

  @Test("the shared default staleness interval is one day")
  func defaultStalenessIntervalIsOneDay() {
    #expect(AppModelStaleness.defaultStaleAfter == 24 * 60 * 60)
  }
}
