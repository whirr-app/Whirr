import Foundation
import WatchProtocol

/// Chooses where a received RSS episode starts on the Watch. There is no server read while a local
/// copy plays, so the only inputs are the Watch's own last listen and the position the phone sent
/// with the copy.
public enum WatchNativeResumePosition {
  /// Two clocks inside this window cannot say which device was used last, so the further position
  /// wins, exactly as the phone's upload rule decides it. `WatchOfflineConflictPolicy.tieWindow`
  /// is 60 s.
  public static let tieWindow: TimeInterval = WatchOfflineConflictPolicy.tieWindow

  /// Rules, in order:
  /// - neither position is usable → 0;
  /// - one source only → that position;
  /// - an undated phone position never beats a listen on the Watch;
  /// - the newer listen wins; inside `tieWindow` the further position wins;
  /// - a finished Watch listen replays from 0, as `WatchResumePosition` does for a finished title;
  /// - the result is clamped to `[0, duration]`.
  public static func resolve(
    local: WatchNativeListen?,
    phonePosition: Double?,
    phoneLastListenedAt: Date?,
    duration: Double?
  ) -> Double {
    let localPosition = local.flatMap { usable($0.position) ? $0.position : nil }
    let phone = phonePosition.flatMap { usable($0) ? $0 : nil }
    let chosen: Double
    if let local, let localPosition, let phone {
      chosen =
        localWins(
          local: local, localPosition: localPosition, phone: phone,
          phoneLastListenedAt: phoneLastListenedAt)
        ? replay(local, position: localPosition)
        : phone
    } else if let local, let localPosition {
      chosen = replay(local, position: localPosition)
    } else if let phone {
      chosen = phone
    } else {
      chosen = 0
    }
    return clamp(chosen, duration: duration)
  }

  private static func localWins(
    local: WatchNativeListen, localPosition: Double, phone: Double, phoneLastListenedAt: Date?
  ) -> Bool {
    // Positions within `WatchResumePosition.samePlaceTolerance` (2 s) are the same place: the
    // Watch keeps its own position instead of nudging by a second or two.
    guard abs(localPosition - phone) > WatchResumePosition.samePlaceTolerance else { return true }
    guard let phoneAt = phoneLastListenedAt, phoneAt.timeIntervalSinceReferenceDate.isFinite else {
      // A phone position with no listen time never beats a listen on the Watch.
      return true
    }
    guard let localAt = local.lastListenedAt, localAt.timeIntervalSinceReferenceDate.isFinite
    else { return false }
    if abs(localAt.timeIntervalSince(phoneAt)) <= tieWindow { return localPosition >= phone }
    return localAt > phoneAt
  }

  private static func replay(_ local: WatchNativeListen, position: Double) -> Double {
    local.isFinished ? 0 : position
  }

  private static func usable(_ position: Double) -> Bool {
    position.isFinite && position >= 0
  }

  private static func clamp(_ position: Double, duration: Double?) -> Double {
    guard let duration, duration.isFinite, duration > 0 else { return max(0, position) }
    return min(max(0, position), duration)
  }
}
