import Foundation
import WatchProtocol

/// Counts the Watch's listening time and remembers when each title was last listened to.
///
/// Time is taken in intervals between marks on the system uptime clock. An interval counts only
/// when the audio was playing at both of its ends, so a transition never adds or loses a tick
/// depending on which side of it a sample landed, and each interval is taken once. An interval is
/// capped, as a suspended process can leave a long gap that was not listening.
public struct WatchListeningClock: Sendable {
  public static let maximumInterval: TimeInterval = 5

  private var mark: (uptime: TimeInterval, playing: Bool)?
  private var lastListened: [WatchSelection: Date] = [:]

  public init() {}

  /// Starts a new interval at `uptime`, discarding any time not yet taken.
  public mutating func restart(at uptime: TimeInterval, playing: Bool) {
    mark = (uptime, playing)
  }

  /// Ends the current interval at `uptime`, starts the next, and returns the seconds listened in
  /// the one that ended.
  public mutating func take(at uptime: TimeInterval, playing: Bool) -> TimeInterval {
    defer { mark = (uptime, playing) }
    guard let mark, mark.playing, playing else { return 0 }
    return min(Self.maximumInterval, max(0, uptime - mark.uptime))
  }

  /// When `selection` was last listened to or moved by the user on this Watch.
  public func lastListened(_ selection: WatchSelection) -> Date? {
    lastListened[selection]
  }

  public mutating func noteListening(_ selection: WatchSelection, at date: Date) {
    lastListened[selection] = date
  }

  /// Forgets every title, as an account change must.
  public mutating func reset() {
    self = Self()
  }
}
