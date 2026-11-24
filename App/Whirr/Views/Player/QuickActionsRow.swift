import AppModel
import PlayerCore
import SwiftUI

/// The bottom quick-action row: sleep timer, playback speed, native audio routing, and Up Next.
/// Every control here is scoped to playback and reports the state it is set to. The controls sit
/// directly on the ambient canvas; the system owns their press, menu, focus and accessibility
/// behaviour.
struct QuickActionsRow: View {
  let player: any PlaybackControlling
  let itemID: String
  let episodeID: String?
  let loadedItemID: String?
  let loadedEpisodeID: String?
  /// The one owner of playback speed. The row never sends `.setRate` itself: a raw intent changes
  /// the audio without recording which scope was edited.
  let playbackRate: PlaybackRateCoordinator
  @Binding var isShowingSleepTimer: Bool
  @Binding var isShowingUpNext: Bool
  @AppStorage("player.playbackRate.presets") private var encodedRatePresets = ""
  @AppStorage("player.sleepTimer.presets") private var encodedTimerPresets = ""

  var body: some View {
    let quickActions = player.quickActions
    // A live item only belongs to this row once both identity sources agree. The projection
    // carries just the stable item details this row needs, never the playhead.
    let liveItem = quickActions.item
    let isLiveItem =
      loadedItemID == itemID
      && loadedEpisodeID == episodeID
      && liveItem?.id == itemID
      && liveItem?.episodeID == episodeID
    let sleepTimerCompletion = SleepTimerMenuPresentation.completion(
      isLiveItem: isLiveItem, episodeID: episodeID,
      liveItemHasChapters: liveItem?.hasChapters == true)

    return QuickActionsControls(
      player: player,
      itemID: itemID,
      episodeID: episodeID,
      sleepTimerMode: quickActions.sleepTimerMode,
      rate: PlaybackRateMenuPresentation.displayedRate(
        isLiveItem: isLiveItem, liveRate: quickActions.rate,
        titleRate: playbackRate.effectiveRate(forItemID: itemID)),
      hasRateOverride: playbackRate.hasOverride(forItemID: itemID),
      focusRate: playbackRate.focusRate(forItemID: itemID),
      sleepTimerCompletion: sleepTimerCompletion,
      encodedRatePresets: encodedRatePresets,
      encodedTimerPresets: encodedTimerPresets,
      isShowingSleepTimer: $isShowingSleepTimer,
      isShowingUpNext: $isShowingUpNext,
      onSelectRate: { playbackRate.adjustRate($0, itemID: itemID) },
      onClearRateOverride: { playbackRate.clearOverride(itemID: itemID) }
    )
    .equatable()
  }
}
