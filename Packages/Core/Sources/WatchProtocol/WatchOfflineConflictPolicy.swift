import Foundation

/// Decides between the Watch's position and the shared (server) position for one title, without
/// asking the listener. Listening totals are never merged here; only the position is chosen.
///
/// The newer listen wins. Timestamps from different clocks within `tieWindow` of each other
/// cannot say which device was used last, so the further position wins instead, and a timestamp
/// beyond `futureClockAllowance` in the future is treated the same way. A shared position that is
/// missing or near zero never beats real Watch progress: a server reset or an empty row must not
/// erase listening that has not been uploaded yet.
public enum WatchOfflineConflictPolicy {
  public static let positionTolerance = 1.0
  public static let tieWindow: TimeInterval = 60
  public static let futureClockAllowance: TimeInterval = 30
  public static let meaningfulPosition = 1.0

  public enum Winner: Sendable, Equatable {
    case watch
    case shared
    case converged
  }

  public enum Reason: Sendable, Equatable {
    case converged
    case watchInvalid
    case sharedInvalid
    case sharedMissing
    case nearZeroShared
    case noSharedTimestamp
    case futureClockTie
    case tieFurther
    case watchNewer
    case sharedNewer
  }

  public struct Resolution: Sendable, Equatable {
    public let winner: Winner
    public let reason: Reason

    public init(winner: Winner, reason: Reason) {
      self.winner = winner
      self.reason = reason
    }
  }

  /// Returns `nil` only when neither position is usable.
  public static func resolve(
    watchPosition: Double,
    watchListenedAt: Date,
    sharedPosition: Double?,
    sharedUpdatedAt: Date?,
    duration: Double? = nil,
    now: Date = Date()
  ) -> Resolution? {
    let watchValid =
      valid(watchPosition, duration: duration) && watchListenedAt.timeIntervalSince1970.isFinite
    guard let sharedPosition else {
      return watchValid ? Resolution(winner: .watch, reason: .sharedMissing) : nil
    }
    let sharedValid = valid(sharedPosition, duration: duration)
    switch (watchValid, sharedValid) {
    case (false, false): return nil
    case (false, true): return Resolution(winner: .shared, reason: .watchInvalid)
    case (true, false): return Resolution(winner: .watch, reason: .sharedInvalid)
    case (true, true): break
    }
    if abs(watchPosition - sharedPosition) <= positionTolerance {
      return Resolution(winner: .converged, reason: .converged)
    }
    if sharedPosition < meaningfulPosition, watchPosition >= meaningfulPosition {
      return Resolution(winner: .watch, reason: .nearZeroShared)
    }
    guard let sharedUpdatedAt, sharedUpdatedAt.timeIntervalSince1970.isFinite else {
      return Resolution(winner: .watch, reason: .noSharedTimestamp)
    }
    let horizon = now.addingTimeInterval(futureClockAllowance)
    if watchListenedAt > horizon || sharedUpdatedAt > horizon {
      return further(watchPosition, sharedPosition, reason: .futureClockTie)
    }
    if abs(watchListenedAt.timeIntervalSince(sharedUpdatedAt)) <= tieWindow {
      return further(watchPosition, sharedPosition, reason: .tieFurther)
    }
    return watchListenedAt > sharedUpdatedAt
      ? Resolution(winner: .watch, reason: .watchNewer)
      : Resolution(winner: .shared, reason: .sharedNewer)
  }

  private static func further(_ watch: Double, _ shared: Double, reason: Reason) -> Resolution {
    Resolution(winner: watch >= shared ? .watch : .shared, reason: reason)
  }

  private static func valid(_ position: Double, duration: Double?) -> Bool {
    guard position.isFinite, position >= 0 else { return false }
    if let duration, duration.isFinite, duration > 0, position > duration { return false }
    return true
  }
}
