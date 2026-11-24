import Foundation
import Testing
import WatchProtocol

/// The conflict rule: the newer listen wins; within the tie window the
/// further position wins; a near-zero or missing shared position never beats real Watch progress.
@Suite struct WatchOfflineConflictPolicyTests {
  let now = Date(timeIntervalSince1970: 10_000)

  private func resolve(
    watch: Double, watchAt: TimeInterval, shared: Double?, sharedAt: TimeInterval?, duration: Double? = nil
  ) -> WatchOfflineConflictPolicy.Resolution? {
    WatchOfflineConflictPolicy.resolve(
      watchPosition: watch, watchListenedAt: now.addingTimeInterval(watchAt),
      sharedPosition: shared, sharedUpdatedAt: sharedAt.map { now.addingTimeInterval($0) },
      duration: duration, now: now)
  }

  @Test func newerWatchListenBeatsOlderSharedValue() {
    #expect(
      resolve(watch: 300, watchAt: -10, shared: 100, sharedAt: -600) == .init(winner: .watch, reason: .watchNewer))
  }

  @Test func newerSharedValueBeatsOlderWatchListenIncludingRewinds() {
    #expect(
      resolve(watch: 300, watchAt: -600, shared: 50, sharedAt: -10) == .init(winner: .shared, reason: .sharedNewer))
  }

  @Test func withinTheTieWindowTheFurtherPositionWinsInBothDirections() {
    #expect(resolve(watch: 300, watchAt: -10, shared: 200, sharedAt: -50) == .init(winner: .watch, reason: .tieFurther))
    #expect(
      resolve(watch: 200, watchAt: -50, shared: 300, sharedAt: -10) == .init(winner: .shared, reason: .tieFurther))
    #expect(resolve(watch: 200, watchAt: -10, shared: 300, sharedAt: -70)?.winner == .shared)
    #expect(resolve(watch: 200, watchAt: -10, shared: 300, sharedAt: -71) == .init(winner: .watch, reason: .watchNewer))
  }

  @Test func aFutureDatedTimestampIsATieNotAWin() {
    #expect(
      resolve(watch: 300, watchAt: -600, shared: 100, sharedAt: 31) == .init(winner: .watch, reason: .futureClockTie))
    #expect(
      resolve(watch: 100, watchAt: 120, shared: 300, sharedAt: -600) == .init(winner: .shared, reason: .futureClockTie))
    #expect(resolve(watch: 100, watchAt: -600, shared: 300, sharedAt: 29)?.reason == .sharedNewer)
  }

  @Test func nearZeroOrMissingSharedPositionNeverBeatsRealWatchProgress() {
    #expect(
      resolve(watch: 40, watchAt: -600, shared: 0, sharedAt: -10) == .init(winner: .watch, reason: .nearZeroShared))
    #expect(resolve(watch: 40, watchAt: -600, shared: 0.5, sharedAt: -10)?.winner == .watch)
    #expect(
      resolve(watch: 40, watchAt: -600, shared: nil, sharedAt: -10) == .init(winner: .watch, reason: .sharedMissing))
    // A Watch that is itself near zero has nothing to protect.
    #expect(resolve(watch: 0.5, watchAt: -600, shared: 0, sharedAt: -10)?.winner == .converged)
  }

  @Test func noSharedTimestampKeepsTheWatch() {
    #expect(
      resolve(watch: 40, watchAt: -10, shared: 300, sharedAt: nil) == .init(winner: .watch, reason: .noSharedTimestamp))
  }

  @Test func positionsWithinOneSecondConverge() {
    #expect(
      resolve(watch: 120, watchAt: -600, shared: 120.5, sharedAt: -10) == .init(winner: .converged, reason: .converged))
  }

  @Test func invalidSidesLoseAndTwoInvalidSidesHaveNoDecision() {
    #expect(
      resolve(watch: .nan, watchAt: -10, shared: 20, sharedAt: -600) == .init(winner: .shared, reason: .watchInvalid))
    #expect(
      resolve(watch: 20, watchAt: -600, shared: -1, sharedAt: -10) == .init(winner: .watch, reason: .sharedInvalid))
    #expect(resolve(watch: 20, watchAt: -600, shared: 150, sharedAt: -10, duration: 100)?.winner == .watch)
    #expect(resolve(watch: .infinity, watchAt: -10, shared: .nan, sharedAt: -10) == nil)
  }
}
