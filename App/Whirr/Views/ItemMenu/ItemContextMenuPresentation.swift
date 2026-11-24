import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

/// The menu's play/pause button as a pure function of player state, keeping the two
/// `PlaybackModel` reads in the menu's body, not every row's. `ItemMediaCapability` decides the
/// entries; show row versus episode row is the caller's `episodeID`.
enum ItemContextMenuPresentation {
  static let moreFromLabel = MediaActionCopy.moreFrom.title
  static let previewMaximumDimension: CGFloat = 220

  static func previewFrameSize(shapesToCover: Bool) -> CGSize {
    let maximum = previewMaximumDimension
    return shapesToCover
      ? CGSize(width: maximum * 2 / 3, height: maximum)
      : CGSize(width: maximum, height: maximum)
  }

  /// One menu row's full presentation, including whether it is destructive, so this menu, the
  /// player's overflow and the episode row's menu/swipe table cannot disagree about it.
  nonisolated struct MenuEntry: Equatable {
    let title: String
    let systemImage: String
    let role: MediaActionRole

    init(title: String, systemImage: String, role: MediaActionRole = .standard) {
      self.title = title
      self.systemImage = systemImage
      self.role = role
    }

    /// The entry for one `MediaActionCopy` label, which owns every title and glyph.
    init(_ label: MediaActionLabel, role: MediaActionRole = .standard) {
      self.init(title: label.title, systemImage: label.systemImage, role: role)
    }

    /// The `MediaActionRole` to `ButtonRole` mapping, named once so a caller cannot reach for
    /// `.destructive` without going through the entry.
    var buttonRole: ButtonRole? {
      role == .destructive ? .destructive : nil
    }
  }

  /// The ebook menu's opening entry, replacing the audio play/pause button (a book with no audio
  /// files would start a session that never produces sound). No `PlaybackAction`: not a playback
  /// intent. Says "Read" even when finished, unlike the detail bar, to avoid threading the
  /// finished projection into every browse surface.
  static let readButton = MenuEntry(title: ReaderDetailCopy.read, systemImage: "book.fill")

  /// The download row a single-format item draws, and the parent row of the submenu a mixed one
  /// draws in its place.
  static let downloadEntry = MenuEntry(MediaActionCopy.download)

  /// The one removal entry for books and episodes alike, on every surface.
  nonisolated static let removeDownloadEntry = MenuEntry(
    MediaActionCopy.removeDownload, role: .destructive)

  /// The inert row drawn while a removal is in flight, because `.unavailable` is all the coarse
  /// presence reports.
  nonisolated static let removingDownloadEntry = MenuEntry(MediaActionCopy.removingDownload)

  static let viewDetailsEntry = MenuEntry(MediaActionCopy.viewDetails)
  static let viewEpisodesEntry = MenuEntry(MediaActionCopy.viewEpisodes)

  /// One format choice inside that submenu.
  ///
  /// A qualified choice takes its medium's badge symbol from `MediaKindBadge`, so the "eBook" row
  /// shows the same glyph as the cover badge. `.both` is unqualified and keeps the plain download
  /// glyph.
  static func downloadFormatEntry(_ format: ItemDownloadFormat) -> MenuEntry {
    switch format {
    case .audio:
      MenuEntry(
        title: ItemDownloadCopy.formatLabel(for: .audio),
        systemImage: MediaKindBadge.audiobook.symbolName)
    case .ebook:
      MenuEntry(
        title: ItemDownloadCopy.formatLabel(for: .ebook),
        systemImage: MediaKindBadge.ebook.symbolName)
    case .both:
      MenuEntry(
        title: ItemDownloadCopy.formatLabel(for: .both), systemImage: downloadEntry.systemImage)
    }
  }

  /// Shared full-size menu copy for progress actions. Swipe may draw a shorter title in its
  /// capsule, but uses this same entry for its accessibility name.
  ///
  /// Neither is destructive (each moves a progress marker the other moves back); Remove Download
  /// alone keeps the role.
  nonisolated static func progressEntry(
    _ action: MediaProgressAction, usesEbookProgress: Bool = false
  ) -> MenuEntry {
    switch action {
    case .markAsFinished: MenuEntry(MediaActionCopy.markAsFinished)
    case .resetProgress: MenuEntry(MediaActionCopy.resetProgress)
    case .removeFromContinueListening:
      MenuEntry(
        title: usesEbookProgress
          ? "Remove from \(HomeCopy.continueReadingTitle)"
          : MediaActionCopy.removeFromContinueListening.title,
        systemImage: MediaActionCopy.removeFromContinueListening.systemImage)
    }
  }

  /// One podcast episode's menu, in order, derived from `PodcastShowPresentation.episodeActions`
  /// so the show screen's rows and every list row offer the same entries in the same order (see
  /// `episodeMenuIsIdenticalAcrossSurfacesExceptSuppressedEntries`).
  ///
  /// The download portion is lossy: the coarse `ItemDownloadPresence` can't tell a paused transfer
  /// from a queued one (a per-episode status observation would return to the scroll path), so a
  /// stalled download is resumed from the show screen. `queueAvailability` is the one
  /// player-aware decision, from `ListeningQueueActionPolicy`. `offersTranscript` is whether the
  /// app can open transcripts and the download has finished, which `downloadAction` cannot say;
  /// a purge in flight is no longer a download to read.
  static func podcastEpisodeSections(
    downloadAction: ItemContextMenuDownloadAction,
    surface: PodcastMenuSurface,
    isSaved: Bool? = nil,
    queueAvailability: ListeningQueueActionAvailability,
    playbackStatus: ItemPlaybackStatus? = nil,
    isCurrentlyPlaying: Bool = false,
    isHidden: Bool = false,
    offersTranscript: Bool = false,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) -> [MediaItemActionSection] {
    let status: ItemDownloadStatus =
      switch downloadAction {
      case .download: .notDownloaded
      // `.unavailable` keeps `.completed`'s shape so the entry still appears, inert and reading
      // "Removing Download…", rather than vanishing mid-purge.
      case .remove, .unavailable: .completed
      }
    return PodcastShowPresentation.episodeActionSections(
      status: status, isAvailableOnServer: true, surface: surface,
      isSaved: isSaved, playbackStatus: playbackStatus,
      isCurrentlyPlaying: isCurrentlyPlaying, isHidden: isHidden,
      offersTranscript: offersTranscript && downloadAction == .remove,
      watchCopy: watchCopy
    ).compactMap { section in
      let entries = ListeningQueueActionPolicy.apply(queueAvailability, to: section.actions)
      return entries.isEmpty
        ? nil
        : MediaItemActionSection(kind: section.kind, actions: entries)
    }
  }

  /// The flattened form used by ordering tests and consumers that do not draw section dividers.
  /// It derives from `podcastEpisodeSections`, never from a second ordering policy.
  static func podcastEpisodeEntries(
    downloadAction: ItemContextMenuDownloadAction,
    surface: PodcastMenuSurface,
    isSaved: Bool? = nil,
    queueAvailability: ListeningQueueActionAvailability,
    playbackStatus: ItemPlaybackStatus? = nil,
    isCurrentlyPlaying: Bool = false,
    isHidden: Bool = false,
    offersTranscript: Bool = false,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) -> [MediaItemAction] {
    podcastEpisodeSections(
      downloadAction: downloadAction,
      surface: surface,
      isSaved: isSaved,
      queueAvailability: queueAvailability,
      playbackStatus: playbackStatus,
      isCurrentlyPlaying: isCurrentlyPlaying,
      isHidden: isHidden,
      offersTranscript: offersTranscript,
      watchCopy: watchCopy
    ).flatMap(\.actions)
  }

  /// The two queue entries' copy, shared by the audiobook and podcast-episode branches so they
  /// cannot label the same intent differently. Matches `PodcastShowViewPresentation.contextAction`.
  struct QueueEntry: Equatable {
    let title: String
    let systemImage: String
  }

  /// The saved entry used by both menu families. The filled symbol is never the only state signal:
  /// the title says whether this is Save for Later or Remove from Saved.
  nonisolated static func savedEntry(isSaved: Bool) -> MenuEntry {
    isSaved
      ? MenuEntry(MediaActionCopy.removeFromSaved)
      : MenuEntry(MediaActionCopy.saveForLater)
  }

  static func queueEntry(_ action: ListeningQueueMenuAction) -> QueueEntry {
    switch action {
    case .playNext:
      QueueEntry(
        title: MediaActionCopy.playNext.title, systemImage: MediaActionCopy.playNext.systemImage)
    case .addToUpNext:
      QueueEntry(
        title: MediaActionCopy.addToUpNext.title,
        systemImage: MediaActionCopy.addToUpNext.systemImage)
    }
  }

  /// Renders `ItemActionsModel.queueFeedbackMessage`. A success confirmation does not join
  /// `actionErrorMessage` in the alert, since it needs no acknowledgement and must not interrupt
  /// the listener. It is one transient banner per screen, attached wherever the error alert is.
  enum QueueFeedback {
    /// How long the banner stays up before clearing itself. Named so the test asserts the same
    /// number the view sleeps for.
    static let visibleDuration: Double = 2

    /// The banner has no Undo button, so its symbol and text are purely confirmatory.
    static func isVisible(_ message: String?) -> Bool {
      message?.isEmpty == false
    }

    /// Mirrors the glyph of the action that just completed, so a two-second banner is recognisable
    /// without being read.
    static func systemImage(for message: String) -> String {
      switch message {
      case let message where ListeningQueueCopy.isPlayNextConfirmation(message):
        "text.line.first.and.arrowtriangle.forward"
      case ListeningQueueCopy.addedToUpNext:
        "text.line.last.and.arrowtriangle.forward"
      case ListeningQueueCopy.alreadyInUpNext:
        "checkmark.circle"
      case SavedForLaterCopy.saved, SavedForLaterCopy.alreadySaved:
        "bookmark.fill"
      case SavedForLaterCopy.removed:
        "bookmark.slash"
      case ContinueListeningCopy.removed:
        "eye.slash"
      case NativeEpisodeServerSaveCopy.requested, NativeEpisodeServerSaveCopy.saved:
        "externaldrive.badge.checkmark"
      case NativeEpisodeServerSaveCopy.removed:
        "externaldrive.badge.minus"
      case let message where EbookDeliveryCopy.isSentConfirmation(message):
        EbookDeliveryCopy.sentSystemImage
      default:
        "checkmark"
      }
    }

    /// Which tap accompanies the banner. The weights are `ItemActionHaptics`, shared with the Up
    /// Next sheet's edits. Removals take the mutation tap like any other edit.
    static func haptic(for message: String) -> SensoryFeedback {
      switch message {
      case ListeningQueueCopy.alreadyInUpNext, SavedForLaterCopy.alreadySaved:
        ItemActionHaptics.noOp
      default:
        ItemActionHaptics.mutation
      }
    }
  }

  /// `.removeDownload` is the one entry this surface renders differently: "Removing Download…" and
  /// inert while a purge is in flight, because `.unavailable` is all the coarse presence reports.
  static func isDownloadEntryInert(_ downloadAction: ItemContextMenuDownloadAction) -> Bool {
    downloadAction == .unavailable
  }

  static func creatorLabel(category: ItemMediaCategory, creator: String?) -> String? {
    guard
      let creator = creator?.trimmingCharacters(in: .whitespacesAndNewlines),
      creator.isEmpty == false
    else {
      return nil
    }
    return category == .podcast ? "More from \(creator)" : "Books by \(creator)"
  }

  /// The server joins every credited narrator into one `narratorName` field. A system menu row is
  /// one line, so the credit is capped at the first name plus a count. VoiceOver reads this same
  /// label; the full credit remains on the detail screen.
  static func narratorLabel(_ narrator: String?) -> String {
    let names =
      (narrator ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.isEmpty == false }
    guard let first = names.first else { return "Narrator" }
    guard names.count > 1 else { return "Narrated by \(first)" }
    return "Narrated by \(first) & \(names.count - 1) more"
  }

  nonisolated enum PlaybackAction: Equatable {
    /// This item is already the player's active item: toggle it, never restart it.
    case toggle
    case start
  }

  struct PlaybackButton: Equatable {
    let title: String
    let systemImage: String
    let action: PlaybackAction
  }

  static func playbackButton(isActiveItem: Bool, isPlaybackIntended: Bool) -> PlaybackButton {
    // `isPlaybackIntended` is a property of the player, not of this item, so it only means "this
    // row is playing" once this row is the active item.
    let label = isActiveItem && isPlaybackIntended ? MediaActionCopy.pause : MediaActionCopy.play
    return PlaybackButton(
      title: label.title, systemImage: label.systemImage,
      action: isActiveItem ? .toggle : .start)
  }

  /// The same words as a book's: the menu's preview already says what would play.
  static func podcastPlaybackButton(
    isActiveEpisode: Bool, isPlaybackIntended: Bool
  ) -> PlaybackButton {
    playbackButton(isActiveItem: isActiveEpisode, isPlaybackIntended: isPlaybackIntended)
  }
}
