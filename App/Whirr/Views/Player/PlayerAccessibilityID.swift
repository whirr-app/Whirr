import Persistence

/// Semantic accessibility identifiers for the player surfaces, so `WhirrTests` and UI automation
/// can address controls by name, not view-tree position. `expandedOrder` is the expanded player's
/// VoiceOver/keyboard order, top to bottom, as a plain array `WhirrTests` can assert against.
enum PlayerAccessibilityID {
  /// The whole persistent mini-player (`MiniPlayerContainerView`). `MiniPlayerView` (DesignSystem)
  /// already labels and orders its own title/progress region and play/pause control; this
  /// identifier addresses the composed whole.
  static let miniPlayerContainer = "player.mini.container"
  /// The regular-width bar's speed and running-sleep-timer menus.
  static let miniPlayerRate = "player.mini.rate"
  static let miniPlayerSleepTimer = "player.mini.sleepTimer"

  /// The grabber at the top of the page. The full-screen presentation supplies none of its own, so
  /// this is both the visible pull-down affordance and the assistive-technology way out.
  static let expandedDismissHandle = "player.expanded.dismissHandle"
  static let expandedCover = "player.expanded.cover"
  static let expandedByline = "player.expanded.byline"
  static let expandedMore = "player.expanded.more"
  static let expandedStatusBanner = "player.expanded.statusBanner"
  /// The ad-skip receipt floating above the transport controls, and its Undo.
  static let adSkipReceipt = "player.expanded.adSkipReceipt"
  static let adSkipUndo = "player.expanded.adSkipUndo"
  static let adSkipStatus = "player.expanded.adSkipStatus"
  static let adSkipCheckNow = "player.expanded.adSkipCheckNow"
  /// The one-time Reduce Ads offer, which takes the status line's place while the setting is off.
  static let adSkipOffer = "player.expanded.adSkipOffer"
  static let adSkipOfferAccept = "player.expanded.adSkipOffer.accept"
  static let adSkipOfferDismiss = "player.expanded.adSkipOffer.dismiss"
  static let expandedScrubber = "player.expanded.scrubber"
  /// The whole transport cluster (`TransportControlsView`: skip-back, play-pause, skip-forward).
  /// DesignSystem already orders and labels those three internally.
  static let expandedTransportControls = "player.expanded.transportControls"
  /// The compact chapter stepper beneath title/author: previous chapter, the current
  /// chapter selector, then next chapter. The whole group is omitted for a confirmed chapterless
  /// book or podcast episode; the centre opens the existing `ChapterSelectorSheet`.
  static let expandedPreviousChapter = "player.expanded.previousChapter"
  static let expandedChapters = "player.expanded.chapters"
  static let expandedNextChapter = "player.expanded.nextChapter"
  static let expandedRate = "player.expanded.rate"
  static let expandedSleepTimer = "player.expanded.sleepTimer"
  static let expandedAudioRoute = "player.expanded.audioRoute"
  static let expandedUpNext = "player.expanded.upNext"

  /// The View Details entry inside the overflow menu. Absent from `expandedOrder`: a menu item is
  /// reached through `expandedMore`, not laid out beside it.
  static let expandedDetails = "player.expanded.details"

  /// The Listening History entry inside the overflow menu, and the sheet it raises. Both are absent
  /// from `expandedOrder`: a menu item is reached through `expandedMore`, and the sheet is its
  /// own presentation over the page.
  static let expandedHistory = "player.expanded.history"
  static let expandedTranscript = "player.expanded.transcript"
  static let expandedLookBack = "player.expanded.lookBack"
  static let historySheet = "player.history.sheet"

  /// The speed card and its Voice Boost toggle. Absent from `expandedOrder`: the card is a popover
  /// reached through `expandedRate` or `miniPlayerRate`, as history is reached through More.
  static let rateCard = "player.rateCard"
  static let rateCardVoiceBoost = "player.rateCard.voiceBoost"

  /// The queue sheet. Absent from `expandedOrder`: it is its own presentation raised over the
  /// player page, not another control laid out inside it.
  static let queueList = "player.queue.list"
  static let queueClear = "player.queue.clear"
  static let queueUndo = "player.queue.undo"
  static let queueStopSmartList = "player.queue.stopSmartList"

  /// The chapter sheets' Select mode switch and its Add to Up Next button.
  static let chapterSelectMode = "chapters.selectMode"
  static let chapterQueueSelection = "chapters.queueSelection"

  /// Carries the row id: a book queued as several chapters has one row per chapter.
  static func queueRow(identity: ListeningIdentity, rowID: Int64) -> String {
    if let episodeID = identity.episodeID {
      return "player.queue.\(identity.itemID).episode.\(episodeID).row.\(rowID)"
    }
    return "player.queue.\(identity.itemID).row.\(rowID)"
  }

  /// Logical traversal order inside the expanded player. Every width uses the same stacked visual
  /// order: the dismiss handle leads, followed by artwork, metadata, status, scrubber, transport,
  /// and the bottom quick actions. A plain array `WhirrTests` can assert against without rendering.
  static let expandedOrder: [String] = [
    expandedDismissHandle,
    expandedCover,
    expandedByline,
    expandedPreviousChapter,
    expandedChapters,
    expandedNextChapter,
    expandedStatusBanner,
    expandedScrubber,
    expandedTransportControls,
    expandedSleepTimer,
    expandedRate,
    expandedAudioRoute,
    expandedUpNext,
    expandedMore,
  ]
}
