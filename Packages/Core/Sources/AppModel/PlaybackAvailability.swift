import Persistence
import SyncEngine

/// Presentation's single answer to whether a remote playback failure should be surfaced, read by
/// the shell banner, the mini-player and the expanded player.
///
/// Not a property on either model: its inputs live in `PlaybackModel` and `ConnectivityModel`, and
/// capturing one from the other would add a cross-model edge to the observation graph.
public enum PlaybackAvailability: Sendable {
  /// A stall is terminal evidence on its own; ordinary buffering only counts once reachability
  /// has answered. `.unknown` returns `false`: a cold launch has attempted nothing, and "server is
  /// down" would show a connectivity banner over everything.
  ///
  /// The streaming guard applies to every phase, including `.stalled`: playback of a complete
  /// local download must never be annotated.
  public static func remotePlaybackUnavailable(
    phase: PlaybackModel.Phase,
    isStreamingSource: Bool,
    reachability: ServerReachability,
    itemID: String? = nil
  ) -> Bool {
    guard isStreamingSource else { return false }
    if let itemID, PodcastSourceIdentity(itemId: itemID) == nil { return false }
    // RSS is device-owned. ABS reachability says nothing about a feed enclosure, so only a
    // terminal stall can make native playback unavailable; it remains actionable by Retry.
    if isRSSSource(itemID) { return phase == .stalled }
    switch phase {
    case .stalled:
      return true
    case .buffering:
      if case .unreachable = reachability { return true }
      return false
    case .idle, .preparing, .playing, .paused, .seeking, .recoverableError, .unrecoverableError,
      .ended:
      return false
    }
  }

  /// Which explanation an unavailable stream carries, or `nil` when playback is fine. Derived here
  /// because the fallback below is a judgement that a second copy would let drift.
  public static func unavailableReason(
    phase: PlaybackModel.Phase,
    isStreamingSource: Bool,
    reachability: ServerReachability,
    itemID: String? = nil
  ) -> ServerUnreachableReason? {
    if let itemID, PodcastSourceIdentity(itemId: itemID) == nil { return nil }
    // Do not surface ABS-specific copy for RSS, including the short window after a terminal stall
    // before any independent feed state could be known. The caller can still use
    // `remotePlaybackUnavailable` to invoke the normal retry path.
    guard isRSSSource(itemID) == false else { return nil }
    guard
      remotePlaybackUnavailable(
        phase: phase, isStreamingSource: isStreamingSource, reachability: reachability,
        itemID: itemID)
    else { return nil }
    if case .unreachable(let reason, since: _) = reachability { return reason }
    // A terminal stream stall is actionable before the reachability probe's result necessarily
    // reaches the model. In that short window, the server-side explanation is the honest fallback:
    // no evidence says the device itself has lost its path.
    return .serverUnreachable
  }

  private static func isRSSSource(_ itemID: String?) -> Bool {
    guard let itemID, PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil else { return false }
    return true
  }
}
