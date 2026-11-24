import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// The menu's items. A child view rather than an inline `@ViewBuilder` body so its state reads are
/// scoped to the presented menu (see `ItemContextMenuModifier`'s note).
///
/// Not `private`: the item-detail toolbar overflow presents these same items from a `Menu`, and a
/// second copy of the list would let the two surfaces disagree about what a book can do.
struct ItemContextMenuContent: View {
  @Environment(\.episodeTranscriptOpener) var transcriptOpener
  @Environment(\.watchCopies) var watchCopies

  let itemID: String
  let author: String?
  let duration: Double?
  let category: ItemMediaCategory
  let hasReadableEbook: Bool
  let usesEbookProgress: Bool
  let episodeID: String?
  let playbackStatus: () -> ItemPlaybackStatus?
  let showsNarratorLink: Bool
  let narratorLabel: String
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// The UI raising this menu. An episode menu's suppression context is read from it, never named
  /// by the caller.
  let placement: PodcastMenuBearingSurface
  /// The book-menu counterpart of `placement`'s surface. Which entries a book draws is the same
  /// kind of decision `PodcastShowPresentation.suppressedActions(on:)` makes for an episode (see
  /// `BookMenuSurface`).
  var bookSurface: BookMenuSurface = .browse
  var closingAction: ItemMenuClosingAction? = nil
  let onOpen: () -> Void
  let onRead: (() -> Void)?
  let onSearch: (String) -> Void

  /// Read in the presented menu's own body, never at row-body time (the reason this is a child
  /// view, see `ItemContextMenuModifier`'s note). `PlaybackModel.nowPlayingIdentity` is
  /// deduplicated, so the playhead cannot wake this read.
  var queueAvailability: ListeningQueueActionAvailability {
    ListeningQueueActionPolicy.availability(
      itemID: itemID, episodeID: episodeID, category: category,
      nowPlaying: playback.nowPlayingIdentity)
  }

  var isCurrentlyPlaying: Bool {
    playback.isPlaybackIntended(for: itemID, episodeID: episodeID)
  }

  /// The same derivation the detail tabs, the download bubble, and the read affordance use, so a
  /// PDF sidecar cannot be a supplement on one surface and an ebook on this one.
  var capability: ItemMediaCapability {
    ItemMediaCapability.derive(category: category, hasReadableEbook: hasReadableEbook)
  }

  @ViewBuilder
  var body: some View {
    MediaActionMenuItems(sections: menuSections) { row in
      if let selection = ItemMenuSelection(id: row.id) { select(selection) }
    }
  }

  /// Books and episodes both follow `MediaItemMenuSection.allCases` and draw through the one
  /// renderer. Their entries differ, but the top-level order changes for both families together.
  var menuSections: [[MediaContextAction]] {
    let closing = closingAction.map { ItemContextMenuPresentation.closingRow($0) }
    switch capability {
    case .audio, .ebook, .audioAndEbook, .unsupportedDocument:
      return ItemContextMenuPresentation.menuSections(
        bookSections, context: bookRowContext, closing: closing)
    case .podcast:
      // Show or episode is row identity rather than media capability, so it is the one branch
      // `ItemMediaCapability` does not take for us.
      return ItemContextMenuPresentation.menuSections(
        episodeID == nil
          ? [MediaItemActionSection(kind: .navigation, actions: [.openShow])] : episodeSections,
        context: episodeRowContext, closing: closing)
    }
  }

  /// Runs one selected row. The model calls are the same for both families except where an
  /// episode names its episode or a book names its format.
  func select(_ selection: ItemMenuSelection) {
    switch selection {
    case .action(let action): perform(action)
    case .downloadFormat(let format):
      Task { await actions.requestDownload(itemID: itemID, format: format) }
    case .sendToEreader(let deviceName):
      Task { await actions.sendEbook(itemID: itemID, deviceName: deviceName) }
    case .creatorLink:
      if let author { onSearch(author) }
    case .closingAction:
      closingAction?.action()
    case .sendToWatchAnyway:
      Task { await watchCopies?.sendBook(itemID: itemID) }
    case .narratorLink:
      Task {
        await actions.loadExtrasIfNeeded(itemID: itemID)
        if let narrator = actions.narrator(for: itemID), narrator.isEmpty == false {
          onSearch(narrator)
        }
      }
    }
  }

  /// Re-reads the player rather than trusting the row's title: the row is compared on its
  /// sections, so the closure that runs may be a pass older than the title shown.
  func perform(_ action: MediaItemAction) {
    switch action {
    case .playPause: togglePlayback()
    case .playNext:
      Task { await actions.playNext(itemID: itemID, episodeID: episodeID) }
    case .addToUpNext:
      Task { await actions.addToUpNext(itemID: itemID, episodeID: episodeID) }
    case .saveForLater:
      Task { await actions.saveForLater(itemID: itemID, episodeID: episodeID) }
    case .removeFromSaved:
      Task { await actions.removeFromSaved(itemID: itemID, episodeID: episodeID) }
    case .download:
      Task { await actions.requestDownload(itemID: itemID, episodeID: episodeID) }
    case .removeDownload:
      Task { await actions.removeDownload(itemID: itemID, episodeID: episodeID) }
    case .markAsFinished:
      Task {
        await episodeProgressActions.markAsFinished(
          itemID: itemID, episodeID: episodeID, duration: duration)
      }
    case .resetProgress:
      Task {
        if let episodeID {
          await episodeProgressActions.resetProgress(itemID: itemID, episodeID: episodeID)
        } else {
          await episodeProgressActions.resetProgress(
            itemID: itemID, episodeID: nil, category: category)
        }
      }
    case .removeFromContinueListening:
      Task { await actions.removeFromContinueListening(itemID: itemID, episodeID: episodeID) }
    case .transcript:
      if let episodeID { transcriptOpener?.open(itemID, episodeID, nil) }
    case .sendToWatch:
      Task {
        if let episodeID {
          await watchCopies?.send(itemID: itemID, episodeID: episodeID)
        } else {
          await watchCopies?.sendBook(itemID: itemID)
        }
      }
    case .removeFromWatch:
      Task {
        if let episodeID {
          await watchCopies?.remove(itemID: itemID, episodeID: episodeID)
        } else {
          await watchCopies?.removeBook(itemID: itemID)
        }
      }
    case .read: onRead?()
    case .openShow, .viewDetails: onOpen()
    case .moreFromCreator:
      if let author { onSearch(author) }
    // Submenu parents, never selected themselves, and entries this menu never draws.
    case .moreFrom, .sendToEreader, .pauseDownload, .resumeDownload, .saveToServer,
      .removeFromServer:
      break
    }
  }

  /// The progress writes whose durability depends on disturbing the live session at the right
  /// moment. The ordering lives in AppModel (`PodcastEpisodeProgressActions`) rather than here, so
  /// the swipe surface cannot re-derive it and drift.
  var episodeProgressActions: PodcastEpisodeProgressActions {
    PodcastEpisodeProgressActions(actions: actions, playback: playback)
  }

  /// Saved membership, or `nil` while unresolved so the entry is withheld rather than flashed.
  var savedMembership: Bool? {
    actions.hasResolvedSavedMembership
      ? actions.isSaved(itemID: itemID, episodeID: episodeID)
      : nil
  }
}
