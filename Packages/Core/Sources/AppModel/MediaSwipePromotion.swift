import Persistence

/// The one "bring it closer" verb a leading swipe offers a row with audio.
///
/// Shared by every shelf: Play versus Play Next depends on the player and queue, not the screen.
public enum MediaSwipePromotion: Sendable, Equatable {
  /// Nothing is playing so the leading edge starts this row, or this row is the player's identity
  /// (paused or merely retained) and the edge resumes it.
  case play
  /// This row is the one playing. Play Next is meaningless here and an empty edge still lets the
  /// row slide open onto nothing, so the leading swipe pauses it.
  case pause
  /// Something else is playing and the queue policy admits this identity.
  case playNext

  /// `nil` when something else is playing and `ListeningQueueActionPolicy` withholds Play Next.
  /// The row then has no leading edge rather than a capsule that would do nothing.
  ///
  /// `isPlaybackIntended` is the player's play/pause intent, consulted only for the playing row,
  /// so a caller can pass `false` for every other row without reading the player.
  public static func leading(
    identity: ListeningIdentity?, nowPlaying: ListeningIdentity?, isPlaybackIntended: Bool
  ) -> MediaSwipePromotion? {
    guard let nowPlaying else { return .play }
    if let identity, identity == nowPlaying {
      return isPlaybackIntended ? .pause : .play
    }
    guard
      ListeningQueueActionPolicy.availability(for: identity, nowPlaying: nowPlaying).offersPlayNext
    else { return nil }
    return .playNext
  }
}
