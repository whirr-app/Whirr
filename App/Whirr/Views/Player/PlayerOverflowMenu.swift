import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Secondary item actions: view details, listening history, download, the progress submenu, and
/// the download's removal last, in a native menu. The caller draws the trigger (see
/// `PlayerOverflowMenuPresentation.placement`); beside the title it has no siblings to borrow a
/// treatment from, so it needs its own container (`MetadataOverflowTrigger`) or reads as stray.
struct PlayerOverflowMenu<Trigger: View>: View {
  let itemID: String
  /// Non-nil when the player is showing a podcast episode, in which case every action here is
  /// scoped to that episode rather than to its show.
  let episodeID: String?
  let duration: Double?
  let playbackStatus: ItemPlaybackStatus?
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// Whether this scope has listening sessions to show at all
  /// (`PlayerQuickActionsPresentation.showsHistory`).
  let includesHistory: Bool
  /// Raises the history sheet. The presentation belongs to the page, not to a menu that dismisses
  /// itself the moment it is chosen.
  let onShowHistory: () -> Void
  /// How many companion PDFs the item has; zero hides the entry.
  let supplementCount: Int
  /// Raises the page's supplements sheet, for the same reason as `onShowHistory`.
  let onShowSupplements: () -> Void
  /// Leaves for the item's own detail surface, collapsing the player behind it. The navigation
  /// belongs to the page, which alone knows where it currently is.
  let onViewDetails: () -> Void
  /// Saves a bookmark at the playhead; `nil` hides the entry
  /// (`PlayerBookmarkPresentation.canAddBookmark`).
  var onAddBookmark: (() -> Void)? = nil
  /// Raises the page's transcript sheet; `nil` hides the entry. For the same reason as
  /// `onShowHistory`, the presentation belongs to the page.
  var onShowTranscript: (() -> Void)? = nil
  /// Raises the page's Look Back sheet; `nil` hides the entry.
  var onShowLookBack: (() -> Void)? = nil
  @ViewBuilder let trigger: () -> Trigger

  var body: some View {
    let menuActions = PlayerOverflowMenuPresentation.actions(
      downloadAction: actions.downloadAction(for: itemID, episodeID: episodeID),
      includesHistory: includesHistory,
      supplementCount: supplementCount,
      includesAddBookmark: onAddBookmark != nil,
      includesTranscript: onShowTranscript != nil,
      includesLookBack: onShowLookBack != nil,
      playbackStatus: playbackStatus)

    let sections = PlayerOverflowMenuPresentation.sections(menuActions)

    return Menu {
      ForEach(sections.indices, id: \.self) { index in
        if index > sections.startIndex {
          Divider()
        }
        ForEach(sections[index], id: \.self) { entry in
          menuEntry(entry)
        }
      }
    } label: {
      trigger()
    }
    // `.button` lets a `Menu` take a button style at all. The row applies `.plain` to the whole
    // cluster, so the caller's label is drawn unchromed.
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .accessibilityLabel("More options")
    .accessibilityHint("Shows details, download, and progress actions.")
    .accessibilityIdentifier(PlayerAccessibilityID.expandedMore)
  }

  @ViewBuilder
  private func menuEntry(_ entry: PlayerOverflowMenuPresentation.Entry) -> some View {
    switch entry {
    case .action(let action):
      menuItem(action)
    case .submenu(let submenu, let actions):
      Menu {
        ForEach(actions, id: \.self) { action in
          menuItem(action)
        }
      } label: {
        Label(submenu.label.title, systemImage: submenu.label.systemImage)
      }
    }
  }

  @ViewBuilder
  private func menuItem(_ action: PlayerOverflowMenuPresentation.Action) -> some View {
    switch action {
    case .addBookmark:
      Button {
        onAddBookmark?()
      } label: {
        Label(MediaActionCopy.addBookmark.title, systemImage: MediaActionCopy.addBookmark.systemImage)
      }
    case .viewDetails:
      Button(action: onViewDetails) {
        Label(MediaActionCopy.viewDetails.title, systemImage: MediaActionCopy.viewDetails.systemImage)
      }
      .accessibilityIdentifier(PlayerAccessibilityID.expandedDetails)
    case .transcript:
      Button {
        onShowTranscript?()
      } label: {
        Label(MediaActionCopy.transcript.title, systemImage: MediaActionCopy.transcript.systemImage)
      }
      .accessibilityIdentifier(PlayerAccessibilityID.expandedTranscript)
    case .lookBack:
      Button {
        onShowLookBack?()
      } label: {
        Label(LookBackCopy.menuTitle, systemImage: LookBackCopy.menuSymbol)
      }
      .accessibilityIdentifier(PlayerAccessibilityID.expandedLookBack)
    case .history:
      Button(action: onShowHistory) {
        Label(MediaActionCopy.listeningHistory.title, systemImage: MediaActionCopy.listeningHistory.systemImage)
      }
      .accessibilityIdentifier(PlayerAccessibilityID.expandedHistory)
    case .viewSupplement:
      Button(action: onShowSupplements) {
        Label(ItemSupplementPresentation.menuLabel(count: supplementCount), systemImage: "doc.richtext")
      }
    case .download:
      Button {
        Task { await actions.requestDownload(itemID: itemID, episodeID: episodeID) }
      } label: {
        Label(MediaActionCopy.download.title, systemImage: MediaActionCopy.download.systemImage)
      }
    case .deleteDownload:
      Button(role: .destructive) {
        Task { await actions.removeDownload(itemID: itemID, episodeID: episodeID) }
      } label: {
        Label(MediaActionCopy.removeDownload.title, systemImage: MediaActionCopy.removeDownload.systemImage)
      }
    case .deletingDownload:
      Button {
      } label: {
        Label(MediaActionCopy.removingDownload.title, systemImage: MediaActionCopy.removingDownload.systemImage)
      }
      .disabled(true)
    case .markAsFinished:
      let presentation = ItemContextMenuPresentation.progressEntry(.markAsFinished)
      Button(role: presentation.buttonRole) {
        Task {
          await progressActions.markAsFinished(itemID: itemID, episodeID: episodeID, duration: duration)
        }
      } label: {
        Label(presentation.title, systemImage: presentation.systemImage)
      }
    case .resetProgress:
      let presentation = ItemContextMenuPresentation.progressEntry(.resetProgress)
      Button(role: presentation.buttonRole) {
        Task {
          await progressActions.resetProgress(itemID: itemID, episodeID: episodeID)
        }
      } label: {
        Label(presentation.title, systemImage: presentation.systemImage)
      }
    }
  }

  /// Stops or rewinds the live session only when it is this same identity (a sibling episode of
  /// the same show is a different one). The ordering lives in AppModel so surfaces cannot drift.
  private var progressActions: PodcastEpisodeProgressActions {
    PodcastEpisodeProgressActions(actions: actions, playback: playback)
  }
}
