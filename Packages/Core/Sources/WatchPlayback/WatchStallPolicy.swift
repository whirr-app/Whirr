/// When a stream that is wanted to play has stopped making progress for good.
///
/// Pure: the engine reports what the player did with an uptime timestamp, and the caller says
/// whether playback is wanted. Waiting, a stall notice, or a pause nobody asked for all start the
/// clock; playing clears it. After `bound` seconds the stream is `stalled`. A failure to play to
/// the end is `stalled` at once. Each episode is reported once, until playback recovers or the
/// caller resets the policy for a fresh request.
public struct WatchStallPolicy: Sendable, Equatable {
  /// How long a wanted stream may make no progress before it is stalled.
  public static let bound: Double = 15

  public enum Observation: Sendable, Equatable {
    /// The player is waiting to play, buffering or evaluating the buffer.
    case waiting
    case playing
    /// The player is paused. While playback is wanted, nobody asked for this.
    case paused
    /// `AVPlayerItemPlaybackStalled`.
    case playbackStalled
    /// `AVPlayerItemFailedToPlayToEndTime`.
    case failedToPlayToEnd
  }

  public enum Verdict: Sendable, Equatable {
    case none
    /// Nothing yet; check again at this uptime.
    case checkAt(Double)
    case stalled
  }

  private var waitingSince: Double?
  private var reported = false

  public init() {}

  public mutating func observe(_ observation: Observation, wanted: Bool, at now: Double) -> Verdict {
    guard wanted else {
      reset()
      return .none
    }
    switch observation {
    case .playing:
      reset()
      return .none
    case .failedToPlayToEnd:
      guard !reported else { return .none }
      waitingSince = waitingSince ?? now
      reported = true
      return .stalled
    case .waiting, .paused, .playbackStalled:
      guard !reported else { return .none }
      if waitingSince == nil { waitingSince = now }
      return check(wanted: true, at: now)
    }
  }

  /// A check at the time an earlier verdict asked for.
  public mutating func check(wanted: Bool, at now: Double) -> Verdict {
    guard wanted, !reported, let waitingSince else { return .none }
    let deadline = waitingSince + Self.bound
    guard now >= deadline else { return .checkAt(deadline) }
    reported = true
    return .stalled
  }

  public mutating func reset() {
    waitingSince = nil
    reported = false
  }
}
