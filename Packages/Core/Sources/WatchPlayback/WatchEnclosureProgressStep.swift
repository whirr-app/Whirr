import Foundation

/// How often the Watch puts download progress in its inventory: at most once per 10%.
/// Each report is a `transferUserInfo` to the phone, so a byte-by-byte report would cost more than
/// the download it describes.
public enum WatchEnclosureProgressStep {
  /// True when nothing has been reported yet, when `current` crossed into a higher tenth than
  /// `lastReported`, or when it reached the end. Equal tenths are not reported again, and a value
  /// that goes backwards (a retry that restarted the transfer) is not reported until it passes the
  /// last tenth again.
  public static func shouldReport(lastReported: Double?, current: Double) -> Bool {
    guard current.isFinite else { return false }
    let value = min(max(current, 0), 1)
    guard let lastReported else { return true }
    let last = lastReported.isFinite ? min(max(lastReported, 0), 1) : 0
    if value >= 1 { return last < 1 }
    return bucket(value) > bucket(last)
  }

  /// `0.7 * 10` is `6.999…`, so a value the caller means as exactly one tenth is nudged up by far
  /// less than a byte before flooring; otherwise a 70% report would wait for 80%.
  private static func bucket(_ value: Double) -> Int64 {
    Int64((value * 10 + 1e-9).rounded(.down))
  }
}
