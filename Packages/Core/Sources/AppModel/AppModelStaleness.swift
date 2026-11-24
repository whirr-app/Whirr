import Foundation

/// The shared cache-freshness policy used by AppModel surfaces.
public enum AppModelStaleness {
  public static let defaultStaleAfter: TimeInterval = 24 * 60 * 60

  static func isStale(
    lastCompletedAt: Date?, now: Date, staleAfter: TimeInterval
  ) -> Bool {
    guard let lastCompletedAt else { return true }
    return now.timeIntervalSince(lastCompletedAt) > staleAfter
  }
}
