import Foundation

/// The delay used before asking the reachability monitor to check a remote stream. Four seconds
/// is longer than the one-second expanded-player buffering banner delay, which covers ordinary
/// playback and seek flaps, but well before the twenty-second stall deadline, when detection would
/// be too late to help presentation.
public enum PlaybackBufferingTiming {
  public static let reachabilityProbeDelay: TimeInterval = 4.0
}

/// Suspension used to debounce a sustained buffering episode without coupling `PlaybackModel` to
/// a wall-clock implementation.
public protocol PlaybackBufferingClock: Sendable {
  func sleep() async
}

/// Production clock for the fixed sustained-buffering window.
public struct SystemPlaybackBufferingClock: PlaybackBufferingClock, Sendable {
  private let nanoseconds: UInt64

  public init() {
    nanoseconds = UInt64(PlaybackBufferingTiming.reachabilityProbeDelay * 1_000_000_000)
  }

  public func sleep() async {
    try? await Task.sleep(nanoseconds: nanoseconds)
  }
}
