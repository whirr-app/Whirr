import AppModel
import DesignSystem
import PlayerCore
import SwiftUI

/// The expanded player's fixed lower chrome. Each leaf keeps its own playback observations so
/// per-tick updates stay local to the control that renders them.
struct PlayerChromeRegion: View {
  let player: any PlaybackControlling
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  let fallbackChapterMap: PlaybackChapterMap?
  let fallbackTotalDuration: Double?
  let isEnabled: Bool
  let timelineReadoutStyle: CoverAmbientPalette.TimelineReadoutStyle
  let seekFeedback: SeekFeedbackState
  let playPauseFill: Color
  let playbackRate: PlaybackRateCoordinator
  @Binding var isShowingSleepTimer: Bool
  @Binding var isShowingUpNext: Bool
  let loadedItemID: String?
  let loadedEpisodeID: String?

  var body: some View {
    // Explicit seams rather than one uniform `VStack` spacing: the gaps are different sizes, and
    // each padding sits outside its region's probe so the recorded frames still measure the
    // controls themselves and not the space around them.
    VStack(spacing: 0) {
      PlaybackTimelineSection(
        player: player, playback: playback, itemID: itemID,
        episodeID: episodeID, fallbackChapterMap: fallbackChapterMap,
        fallbackTotalDuration: fallbackTotalDuration,
        isEnabled: isEnabled, timelineReadoutStyle: timelineReadoutStyle,
        seekFeedback: seekFeedback
      )
      .playerLayoutProbed(.scrubber)

      TransportRow(
        playback: playback, itemID: itemID,
        episodeID: episodeID, isEnabled: isEnabled,
        seekFeedback: seekFeedback, playPauseFill: playPauseFill
      )
      .playerLayoutProbed(.transport)
      .padding(.top, PlayerMetric.chromeScrubberToTransportSpacing)

      QuickActionsRow(
        player: player,
        itemID: itemID,
        episodeID: episodeID,
        loadedItemID: loadedItemID,
        loadedEpisodeID: loadedEpisodeID,
        playbackRate: playbackRate,
        isShowingSleepTimer: $isShowingSleepTimer,
        isShowingUpNext: $isShowingUpNext
      )
      .playerLayoutProbed(.quickActions)
      .padding(.top, PlayerMetric.chromeTransportToQuickActionsSpacing)
    }
    .padding(.top, PlayerMetric.chromeTopSeam)
    .playerLayoutProbed(.chrome)
  }
}
