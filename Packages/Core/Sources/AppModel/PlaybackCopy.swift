import SyncEngine

/// User-facing playback copy, owned and tested in AppModel. A screen never hardcodes its own
/// strings, mirroring `SetupFlowCopy`.
public enum PlaybackCopy {
  public static let preparing = "Loading…"
  public static let buffering = "Buffering…"
  public static let stalled = "Playback stopped"
  public static let nativeFeedStalled = "Couldn't continue playing. Try again."
  public static let playing = "Playing"
  public static let paused = "Paused"
  public static let seeking = "Seeking…"
  public static let recoverableError = "Playback hit a snag. Tap to retry."
  public static let unrecoverableError = "This title can't be played right now."
  public static let ended = "Finished"

  /// The fallback for a `startSession` failure this catalog does not otherwise distinguish (an
  /// unrecognized error type, or a mapping failure after a successful start; see
  /// `PlaybackModel.start`).
  public static let genericStartFailure = "Couldn't start playback. Try again."

  /// `PlaybackCoordinatorError`'s distinct, actionable message per case (mirrors
  /// `SetupFlowCopy.recoveryMessage(for:)`); any other error type falls back to
  /// `genericStartFailure`.
  public static func startFailureMessage(for error: Error) -> String {
    guard let coordinatorError = error as? PlaybackCoordinatorError else {
      return genericStartFailure
    }
    switch coordinatorError {
    case .notAuthenticated:
      return "You're signed out. Sign in again to play this title."
    case .unknownItem:
      return "This title isn't available yet. Try syncing your library first."
    case .unknownPodcastEpisode:
      return "This episode isn't available yet. Refresh the show and try again."
    case .unusableStream:
      return "This title's audio couldn't be loaded."
    case .persistenceFailed:
      return "Something went wrong preparing playback. Try again."
    case .quiescedForLogout:
      return "You're signing out. Sign back in to resume playback."
    case .localSourceUnavailable:
      return "This download is being removed. Try again once it finishes."
    case .unplayableOffline:
      return "This title isn't downloaded and the server can't be reached right now."
    }
  }
}
