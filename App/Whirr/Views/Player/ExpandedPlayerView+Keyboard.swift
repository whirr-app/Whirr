import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

extension ExpandedPlayerView {
  /// Invisible key-command targets (Space play/pause, arrows skip). `TransportControlsView` and
  /// `PlaybackScrubber` (DesignSystem) have no target to attach a `.keyboardShortcut` to, so
  /// hidden `Button`s carry the shortcut and forward to the same intents as the visible controls.
  /// The playhead reads live inside each action (never in `body`), so these carry no per-tick cost.
  var keyboardShortcuts: some View {
    let intents = PlayerTransportIntents(
      playback: playback, itemID: itemID, episodeID: displayedEpisodeID,
      seekFeedback: seekFeedback)
    return Group {
      Button(
        "Play/Pause",
        action: { intents.toggle() }
      )
      .keyboardShortcut(.space, modifiers: [])
      Button(
        "Skip Back",
        action: {
          let delta = Double(
            SkipIntervalConfiguration.resolvedSeconds(storedBackwardSkipSeconds, forward: false))
          intents.skip(by: -delta)
        }
      )
      .keyboardShortcut(.leftArrow, modifiers: [])
      Button(
        "Skip Forward",
        action: {
          let delta = Double(
            SkipIntervalConfiguration.resolvedSeconds(storedForwardSkipSeconds, forward: true))
          intents.skip(by: delta)
        }
      )
      .keyboardShortcut(.rightArrow, modifiers: [])
      // Command-W provides a keyboard close path alongside the visible handle and VoiceOver action.
      Button("Close Player", action: { navigation.collapsePlayer() })
        .keyboardShortcut("w", modifiers: .command)
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }

  /// Reads the playhead when chosen, not when the menu was built; the overflow offers this only
  /// while the shown audiobook is the loaded one.
  func addBookmark() {
    let chapters = (player.state.item?.chapters ?? metadataChapterMap)?.chapters ?? []
    // The resolver returns the live playhead for the loaded identity, which is the only one the
    // overflow offers this for.
    let position = playback.displayedPositionSeconds(itemID: itemID, episodeID: nil, persisted: 0)
    Task { await bookmarks.add(position: position, chapters: chapters) }
  }

  /// Builds the history model on demand, then raises its sheet. Nothing constructs it earlier: its
  /// `init` reads the cache and puts a refresh on the wire, and most player sessions never ask for
  /// history.
  func presentHistory() {
    if historyModel == nil {
      historyModel = makeItemHistoryModel(itemID)
    }
    isShowingHistory = true
  }
}
