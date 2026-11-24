import Foundation
import Persistence
import PlayerCore

/// The last local RSS playhead a stop records before teardown clears the model's identity. The
/// position is sent through the ordinary tick boundary so RSS keeps its existing sequence and reset
/// guards; no ABS session is involved.
struct PlaybackTeardownProgress: Sendable, Equatable {
  let itemID: String
  let episodeID: String
  let currentTime: Double
  /// The player had already reached the end of the item. The ordinary end-of-item tick carries
  /// this flag, but a stop can overtake it, and a final tick that reported `false` would then
  /// un-finish an episode the listener really finished.
  let isFinished: Bool

  /// The progress for `itemID`/`episodeID`, or `nil` when that identity is not an RSS episode, is
  /// not the one the player has loaded, or has no finite position.
  static func capture(
    itemID: String, episodeID: String, loadedItemID: String?, loadedEpisodeID: String?,
    playhead: Double, currentTime: Double, phase: PlayerPhase
  ) -> PlaybackTeardownProgress? {
    guard
      PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil,
      loadedItemID == itemID,
      loadedEpisodeID == episodeID
    else { return nil }

    // The larger of the raw playhead and `currentTime`. `RSSEpisodeStateStore` orders ticks by
    // sequence, not position, so it would accept a regression and nothing below protects recorded
    // progress. `currentTime` mirrors the last position a tick recorded, so the max stops a stale
    // or spurious playhead reading at teardown erasing real listening. The cost: a stop between a
    // backward seek and its progress event saves the pre-seek position, which is the lesser loss.
    let position = [playhead, currentTime]
      .filter { $0.isFinite }
      .max()
    guard let position else { return nil }
    return PlaybackTeardownProgress(
      itemID: itemID, episodeID: episodeID, currentTime: max(0, position),
      isFinished: phase == .ended)
  }
}
