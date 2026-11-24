import AppModel
import DesignSystem
import SwiftUI

/// The transport cluster. Its render-time player dependencies are the independently tracked
/// playback intent and quick-action item projection; neither includes the playhead. Skip actions
/// read the position live inside the closure, never in `body`.
struct TransportRow: View {
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  let isEnabled: Bool
  let seekFeedback: SeekFeedbackState
  /// The page's ink, filling the play/pause disc like the item-detail Resume button; artwork colour
  /// is the ground behind the controls, never a tint on one. Resolved by the page (which owns the
  /// palette store) so this leaf redraws only on the playback intent.
  let playPauseFill: Color

  @AppStorage(SkipIntervalConfiguration.forwardStorageKey)
  private var storedForwardSkipSeconds = SkipIntervalConfiguration.defaultForwardSeconds
  @AppStorage(SkipIntervalConfiguration.backwardStorageKey)
  private var storedBackwardSkipSeconds = SkipIntervalConfiguration.defaultBackwardSeconds

  var body: some View {
    let intended = playback.isPlaybackIntended(for: itemID)
    let forwardSkipSeconds = SkipIntervalConfiguration.resolvedSeconds(
      storedForwardSkipSeconds, forward: true)
    let backwardSkipSeconds = SkipIntervalConfiguration.resolvedSeconds(
      storedBackwardSkipSeconds, forward: false)
    let intents = PlayerTransportIntents(
      playback: playback, itemID: itemID, episodeID: episodeID, seekFeedback: seekFeedback)
    return TransportControlsView(
      isPlaying: intended,
      playPauseAccessibilityLabel: intended ? "Pause" : "Play",
      playPauseSystemImage: intended ? "pause.fill" : "play.fill",
      skipBackAccessibilityLabel: SkipIntervalConfiguration.accessibilityLabel(
        seconds: backwardSkipSeconds, forward: false),
      skipBackAccessibilityHint: SkipIntervalConfiguration.accessibilityHint(
        seconds: backwardSkipSeconds, forward: false),
      skipBackSystemImage: SkipIntervalConfiguration.systemImage(
        seconds: backwardSkipSeconds, forward: false),
      skipForwardAccessibilityLabel: SkipIntervalConfiguration.accessibilityLabel(
        seconds: forwardSkipSeconds, forward: true),
      skipForwardAccessibilityHint: SkipIntervalConfiguration.accessibilityHint(
        seconds: forwardSkipSeconds, forward: true),
      skipForwardSystemImage: SkipIntervalConfiguration.systemImage(
        seconds: forwardSkipSeconds, forward: true),
      onPlayPauseTap: {
        intents.toggle()
      },
      onSkipBackTap: {
        intents.skip(by: -Double(backwardSkipSeconds))
      },
      onSkipForwardTap: {
        intents.skip(by: Double(forwardSkipSeconds))
      },
      playPauseFill: playPauseFill
    )
    .disabled(isEnabled == false)
    .accessibilityIdentifier(PlayerAccessibilityID.expandedTransportControls)
  }
}
