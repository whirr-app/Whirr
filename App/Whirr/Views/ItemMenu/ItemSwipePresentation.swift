import AppModel
import DesignSystem
import Persistence

/// Renders `ItemSwipeActions`' choices as swipe buttons.
///
/// Reuses `PodcastEpisodeSwipeButton` and `PodcastEpisodeSwipeTint` (short title, the menu's name
/// for VoiceOver, explicit fill as the scene-root tint outranks `ButtonRole`), keeping "red means
/// this deletes bytes" true in every list. Visible titles are shorter than the menu's
/// (`PodcastShowViewPresentation.swipeLabel`): iOS widens a capsule to its title, so full phrasing
/// would make a row's edge width vary with its state.
enum ItemSwipePresentation {
  static func buttons(for actions: [ItemSwipeAction]) -> [PodcastEpisodeSwipeButton] {
    actions.map { button(for: $0) }
  }

  static func button(for action: ItemSwipeAction) -> PodcastEpisodeSwipeButton {
    switch action {
    case .play:
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: MediaActionCopy.play.title,
        accessibilityLabel: MediaActionCopy.play.title,
        hint: "Starts playing this title.", systemImage: MediaActionCopy.play.systemImage,
        role: .standard,
        tint: .playback)
    case .pause:
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: MediaActionCopy.pause.title,
        accessibilityLabel: MediaActionCopy.pause.title,
        hint: "Pauses this title.", systemImage: MediaActionCopy.pause.systemImage,
        role: .standard, tint: .playback)
    case .playNext:
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: MediaActionCopy.playNext.title,
        accessibilityLabel: ItemContextMenuPresentation.queueEntry(.playNext).title,
        hint: "Puts this at the front of Up Next.",
        systemImage: ItemContextMenuPresentation.queueEntry(.playNext).systemImage,
        role: .standard, tint: .playback)
    case .read:
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: ItemContextMenuPresentation.readButton.title,
        accessibilityLabel: ItemContextMenuPresentation.readButton.title,
        hint: "Opens this book in the reader.",
        systemImage: ItemContextMenuPresentation.readButton.systemImage, role: .standard,
        tint: .playback)
    case .removeFromSaved:
      // "Unsave", not "Remove": on a downloaded row this capsule sits beside Remove Download, and
      // two capsules reading "Remove" risk deleting the wrong thing.
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: "Unsave",
        accessibilityLabel: ItemContextMenuPresentation.savedEntry(isSaved: true).title,
        hint: "Removes this from Saved for Later.",
        systemImage: ItemContextMenuPresentation.savedEntry(isSaved: true).systemImage,
        role: ItemContextMenuPresentation.savedEntry(isSaved: true).role, tint: .savedRemoval)
    case .download:
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: ItemContextMenuPresentation.downloadEntry.title,
        accessibilityLabel: ItemContextMenuPresentation.downloadEntry.title,
        hint: "Downloads this to this device.",
        systemImage: ItemContextMenuPresentation.downloadEntry.systemImage, role: .standard,
        tint: .download)
    case .removeDownload:
      // Same short label, glyph, role and fill as a podcast episode's Remove Download on every
      // other surface.
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: MediaActionCopy.removeSwipeTitle,
        accessibilityLabel: ItemContextMenuPresentation.removeDownloadEntry.title,
        hint: "Removes this from this device.",
        systemImage: ItemContextMenuPresentation.removeDownloadEntry.systemImage,
        role: ItemContextMenuPresentation.removeDownloadEntry.role, tint: .remove)
    case .markAsFinished:
      // The short labels and fills an episode's progress capsules carry, so a book and an episode
      // listed together say the same thing in the same colour.
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: "Finished",
        accessibilityLabel: ItemContextMenuPresentation.progressEntry(.markAsFinished).title,
        hint: "Records this as finished.",
        systemImage: ItemContextMenuPresentation.progressEntry(.markAsFinished).systemImage,
        role: ItemContextMenuPresentation.progressEntry(.markAsFinished).role, tint: .finished)
    case .resetProgress:
      PodcastEpisodeSwipeButton(
        id: action.rawValue, label: "Reset",
        accessibilityLabel: ItemContextMenuPresentation.progressEntry(.resetProgress).title,
        hint: "Returns this to the beginning.",
        systemImage: ItemContextMenuPresentation.progressEntry(.resetProgress).systemImage,
        role: ItemContextMenuPresentation.progressEntry(.resetProgress).role, tint: .reset)
    }
  }
}
