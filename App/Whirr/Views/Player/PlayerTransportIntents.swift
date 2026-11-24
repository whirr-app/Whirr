import AppModel

/// The transport gestures every player surface offers.
///
/// A play/pause tap on an active, loaded item toggles, so it pauses and never restarts; any other
/// retained item starts from its saved position. A skip records the same feedback the visible
/// controls show and moves the same resolved interval. Surfaces supply their own interval and
/// feedback; nothing here reads the playhead.
struct PlayerTransportIntents {
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  /// The surface's skip feedback, when it draws one. Mini-player skips are silent.
  let seekFeedback: SeekFeedbackState?

  init(
    playback: PlaybackModel, itemID: String, episodeID: String?,
    seekFeedback: SeekFeedbackState? = nil
  ) {
    self.playback = playback
    self.itemID = itemID
    self.episodeID = episodeID
    self.seekFeedback = seekFeedback
  }

  func toggle() {
    Task { await playback.togglePlayPauseOrPlay(itemID: itemID, episodeID: episodeID) }
  }

  func skip(by delta: Double) {
    seekFeedback?.recordSkip(
      delta: delta, identity: SeekFeedbackState.Identity(itemID: itemID, episodeID: episodeID))
    Task { await playback.skip(itemID: itemID, episodeID: episodeID, by: delta) }
  }
}
