import AppModel
import DesignSystem
import Foundation
import Persistence

enum PodcastEpisodeViewAction: String, Equatable {
  case playPause = "play-pause"
  case playNext = "play-next"
  case addUpNext = "add-up-next"
  case saveForLater = "save-for-later"
  case removeFromSaved = "remove-from-saved"
  case download = "download"
  case pauseDownload = "pause-download"
  case resumeDownload = "resume-download"
  case removeDownload = "remove-download"
  case markAsFinished = "mark-as-finished"
  case resetProgress = "reset-progress"
  case removeFromContinueListening = "remove-from-continue-listening"
  case saveToServer = "save-to-server"
  case removeFromServer = "remove-from-server"
  case openShow = "open-show"
  case moreFromCreator = "more-from-creator"
  case transcript = "transcript"
  case sendToWatch = "send-to-watch"
  case removeFromWatch = "remove-from-watch"
  /// The failed trailing control's own tap: it presents `PodcastDownloadFailurePresentation`'s
  /// alert rather than retrying, so it has no `AppModel.MediaItemAction`.
  case explainDownloadFailure = "explain-download-failure"
}

nonisolated extension PodcastShowViewPresentation {
  /// The row's Watch mark, from the copy's raw state. Pending states, including a download in
  /// progress on the Watch, share one secondary glyph; delivered is the primary one. Anything the
  /// Watch removed, declined or failed shows nothing, because the row has no copy there.
  static func watchMark(for state: WatchCopyState?) -> PodcastEpisodeWatchMark? {
    switch state {
    case .wanted, .waitingForWatch, .sending: .sending
    case .delivered: .onWatch
    case .removed, .declined, .failed, nil: nil
    }
  }

  /// `nil` for an entry with no data for this episode (only `.moreFromCreator`, which needs a
  /// creator name). `contextAction` is not `private`: `PodcastEpisodeCardView` reuses its mapping.
  ///
  /// A disabled availability's reason, or `nil`. A function, not a `let` in the two server cases:
  /// `contextAction` is one implicit-return `switch`, which a multi-statement case breaks.
  private static func disabledReason(
    _ availability: NativeEpisodeServerSaveAvailability?
  ) -> NativeEpisodeServerSaveDisabledReason? {
    if case .some(.disabled(let reason)) = availability { return reason }
    return nil
  }

  static func contextAction(
    _ action: AppModel.MediaItemAction,
    creator: String?,
    availability: NativeEpisodeServerSaveAvailability? = nil
  ) -> MediaContextAction? {
    switch action {
    case .playPause:
      // Not a Play/Pause toggle here. Resolving the title needs the player's active episode, and
      // this list is built at row-body time on the scroll path, which must not read it. Plain
      // "Play", the same word every menu uses.
      MediaContextAction(
        id: PodcastEpisodeViewAction.playPause.rawValue, label: MediaActionCopy.play.title,
        hint: "Starts playing this episode.", systemImage: MediaActionCopy.play.systemImage)
    // `.openShow` is the show itself; the rest are book entries (`BookMenuPresentation`).
    case .openShow, .read, .moreFrom, .sendToEreader, .viewDetails:
      nil
    case .saveForLater:
      MediaContextAction(
        id: PodcastEpisodeViewAction.saveForLater.rawValue,
        label: ItemContextMenuPresentation.savedEntry(isSaved: false).title,
        hint: "Saves this episode to Saved for Later.",
        systemImage: ItemContextMenuPresentation.savedEntry(isSaved: false).systemImage)
    case .removeFromSaved:
      MediaContextAction(
        id: PodcastEpisodeViewAction.removeFromSaved.rawValue,
        label: ItemContextMenuPresentation.savedEntry(isSaved: true).title,
        hint: "Removes this episode from Saved for Later.",
        systemImage: ItemContextMenuPresentation.savedEntry(isSaved: true).systemImage)
    case .saveToServer:
      MediaContextAction(
        id: PodcastEpisodeViewAction.saveToServer.rawValue,
        label: NativeEpisodeServerSaveCopy.saveAction,
        hint: disabledReason(availability).map(NativeEpisodeServerSaveCopy.disabledReason)
          ?? NativeEpisodeServerSaveCopy.saveHint,
        systemImage: NativeEpisodeServerSaveCopy.saveSystemImage,
        isEnabled: disabledReason(availability) == nil)
    case .removeFromServer:
      MediaContextAction(
        id: PodcastEpisodeViewAction.removeFromServer.rawValue,
        label: NativeEpisodeServerSaveCopy.removeAction,
        hint: disabledReason(availability).map(NativeEpisodeServerSaveCopy.disabledReason)
          ?? NativeEpisodeServerSaveCopy.removeHint,
        systemImage: NativeEpisodeServerSaveCopy.removeSystemImage,
        role: .destructive,
        isEnabled: disabledReason(availability) == nil)
    case .moreFromCreator:
      creator.flatMap { creator in
        let trimmed = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return MediaContextAction(
          id: PodcastEpisodeViewAction.moreFromCreator.rawValue, label: "More from \(trimmed)",
          hint: "Searches for everything else by this creator.",
          systemImage: "dot.radiowaves.left.and.right")
      }
    case .transcript:
      MediaContextAction(
        id: PodcastEpisodeViewAction.transcript.rawValue, label: MediaActionCopy.transcript.title,
        hint: "Shows this episode as text, transcribing it on this iPhone if needed.",
        systemImage: MediaActionCopy.transcript.systemImage)
    case .sendToWatch:
      MediaContextAction(
        id: PodcastEpisodeViewAction.sendToWatch.rawValue, label: MediaActionCopy.sendToWatch.title,
        hint: "Downloads this episode on your Apple Watch.",
        systemImage: MediaActionCopy.sendToWatch.systemImage)
    case .removeFromWatch:
      MediaContextAction(
        id: PodcastEpisodeViewAction.removeFromWatch.rawValue, label: MediaActionCopy.removeFromWatch.title,
        hint: "Removes this episode's copy from your Apple Watch.",
        systemImage: MediaActionCopy.removeFromWatch.systemImage)
    case .playNext:
      MediaContextAction(
        id: PodcastEpisodeViewAction.playNext.rawValue, label: MediaActionCopy.playNext.title,
        hint: "Puts this episode at the front of Up Next.",
        systemImage: MediaActionCopy.playNext.systemImage)
    case .addToUpNext:
      MediaContextAction(
        id: PodcastEpisodeViewAction.addUpNext.rawValue, label: MediaActionCopy.addToUpNext.title,
        hint: "Adds this episode to the end of Up Next.",
        systemImage: MediaActionCopy.addToUpNext.systemImage)
    case .download:
      MediaContextAction(
        id: PodcastEpisodeViewAction.download.rawValue, label: MediaActionCopy.download.title,
        hint: "Downloads this episode to this device.",
        systemImage: MediaActionCopy.download.systemImage)
    case .pauseDownload:
      MediaContextAction(
        id: PodcastEpisodeViewAction.pauseDownload.rawValue, label: "Pause Download",
        hint: "Pauses this device download.", systemImage: "pause.circle")
    case .resumeDownload:
      MediaContextAction(
        id: PodcastEpisodeViewAction.resumeDownload.rawValue, label: "Resume Download",
        hint: "Resumes this device download.", systemImage: "arrow.clockwise")
    case .removeDownload:
      MediaContextAction(
        id: PodcastEpisodeViewAction.removeDownload.rawValue,
        label: ItemContextMenuPresentation.removeDownloadEntry.title,
        hint: "Removes this episode from this device.",
        systemImage: ItemContextMenuPresentation.removeDownloadEntry.systemImage,
        role: ItemContextMenuPresentation.removeDownloadEntry.role)
    case .markAsFinished:
      // Label, glyph and role all come from the one shared entry, so surfaces cannot disagree on
      // whether moving a progress marker is destructive.
      MediaContextAction(
        id: PodcastEpisodeViewAction.markAsFinished.rawValue,
        label: ItemContextMenuPresentation.progressEntry(.markAsFinished).title,
        hint: "Records this episode as fully listened to.",
        systemImage: ItemContextMenuPresentation.progressEntry(.markAsFinished).systemImage,
        role: ItemContextMenuPresentation.progressEntry(.markAsFinished).role)
    case .resetProgress:
      MediaContextAction(
        id: PodcastEpisodeViewAction.resetProgress.rawValue,
        label: ItemContextMenuPresentation.progressEntry(.resetProgress).title,
        hint: "Returns this episode to the beginning.",
        systemImage: ItemContextMenuPresentation.progressEntry(.resetProgress).systemImage,
        role: ItemContextMenuPresentation.progressEntry(.resetProgress).role)
    case .removeFromContinueListening:
      MediaContextAction(
        id: PodcastEpisodeViewAction.removeFromContinueListening.rawValue,
        label: ItemContextMenuPresentation.progressEntry(.removeFromContinueListening).title,
        hint: "Removes this episode from Continue Listening.",
        systemImage: ItemContextMenuPresentation.progressEntry(.removeFromContinueListening).systemImage,
        role: ItemContextMenuPresentation.progressEntry(.removeFromContinueListening).role)
    }
  }

  /// The swipe policy owns edge selection and order; this maps its actions to the same
  /// presentation values as the row's long-press menu. A missing presentation invalidates the
  /// whole mapping so a newly emitted policy action cannot become an invisible swipe button.
  static func swipeButtons(
    for actions: PodcastEpisodeSwipeActions.Actions
  ) -> (leading: [PodcastEpisodeSwipeButton], trailing: [PodcastEpisodeSwipeButton])? {
    guard let leading = swipeButtons(for: actions.leading),
      let trailing = swipeButtons(for: actions.trailing)
    else { return nil }
    guard actions.pausesPlayback else { return (leading: leading, trailing: trailing) }
    return (
      leading: leading.map { $0.id == pauseSwipeButton.id ? pauseSwipeButton : $0 },
      trailing: trailing
    )
  }

  /// `.playPause` on the row that is playing. Same id, so it executes through the same path; the
  /// capsule names the tap, as `PodcastEpisodeCardPlayControl` does.
  static let pauseSwipeButton = PodcastEpisodeSwipeButton(
    id: PodcastEpisodeViewAction.playPause.rawValue, label: MediaActionCopy.pause.title,
    accessibilityLabel: MediaActionCopy.pause.title, hint: "Pauses this episode.",
    systemImage: MediaActionCopy.pause.systemImage,
    role: .standard, tint: .playback)

  private static func swipeButtons(
    for actions: [AppModel.MediaItemAction]
  ) -> [PodcastEpisodeSwipeButton]? {
    let buttons = actions.compactMap { swipeButton(for: $0) }
    guard buttons.count == actions.count else { return nil }
    return buttons
  }

  /// A swipe button for one action: the menu's id, glyph, hint and role from `contextAction`
  /// (keeping the swipe a subset of the menu), plus a short visible label and an explicit fill.
  /// `nil` where the menu is `nil`.
  static func swipeButton(
    for action: AppModel.MediaItemAction
  ) -> PodcastEpisodeSwipeButton? {
    guard let menu = contextAction(action, creator: nil),
      let label = swipeLabel(for: action),
      let tint = swipeTint(for: action)
    else { return nil }

    return PodcastEpisodeSwipeButton(
      id: menu.id, label: label, accessibilityLabel: menu.label, hint: menu.hint,
      systemImage: menu.systemImage, role: menu.role, tint: tint)
  }

  /// The swipe vocabulary, in as few words as the glyph leaves necessary. iOS sizes a swipe capsule
  /// to its title once it passes the capsule's minimum width, so full phrasing would vary row
  /// widths by state. The menu and VoiceOver (`accessibilityLabel`) keep the full phrasing.
  private static func swipeLabel(for action: AppModel.MediaItemAction) -> String? {
    switch action {
    case .playPause: MediaActionCopy.play.title
    case .playNext: MediaActionCopy.playNext.title
    case .addToUpNext: "Up Next"
    case .download: MediaActionCopy.download.title
    case .pauseDownload: "Pause"
    case .resumeDownload: "Resume"
    case .removeDownload: MediaActionCopy.removeSwipeTitle
    case .markAsFinished: "Finished"
    case .resetProgress: "Reset"
    // The saved pair and the Watch pair stay off the swipe edges in v1.
    case .openShow, .moreFromCreator, .saveForLater, .removeFromSaved,
      .removeFromContinueListening, .saveToServer, .removeFromServer, .transcript,
      .sendToWatch, .removeFromWatch, .read, .moreFrom, .sendToEreader, .viewDetails:
      nil
    }
  }

  private static func swipeTint(
    for action: AppModel.MediaItemAction
  ) -> PodcastEpisodeSwipeTint? {
    switch action {
    case .playPause, .playNext, .addToUpNext: .playback
    case .download, .pauseDownload, .resumeDownload: .download
    case .removeDownload: .remove
    case .markAsFinished: .finished
    case .resetProgress: .reset
    case .openShow, .moreFromCreator, .saveForLater, .removeFromSaved,
      .removeFromContinueListening, .saveToServer, .removeFromServer, .transcript,
      .sendToWatch, .removeFromWatch, .read, .moreFrom, .sendToEreader, .viewDetails:
      nil
    }
  }
}
