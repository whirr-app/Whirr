import Foundation

/// `PlaybackClock`'s production conformance. `now()` only promises seconds since an arbitrary,
/// fixed reference point. `ProcessInfo.systemUptime` satisfies that and is monotonic, which is all
/// listening-delta accrual and the sleep timer's elapsed-playback accounting need.
public struct SystemPlaybackClock: PlaybackClock {
  public init() {}

  public func now() -> Double {
    ProcessInfo.processInfo.systemUptime
  }

  /// `systemUptime` stops while the device sleeps, so a phone left paused overnight reads as a few
  /// minutes later. `ContinuousClock` keeps counting through sleep, which is what a question like
  /// "did the listener resume shortly after the sleep timer stopped?" has to be measured in.
  public func continuousNow() -> Double {
    let elapsed = (ContinuousClock.now - Self.continuousOrigin).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  private static let continuousOrigin = ContinuousClock.now
}
