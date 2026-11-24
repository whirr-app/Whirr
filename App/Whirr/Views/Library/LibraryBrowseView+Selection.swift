import AppModel
import Persistence
import SwiftUI

/// The Titles screen's multiselect chrome: title, toolbar, Download, and the batch it runs. The
/// root keeps the mode lifecycle and the projection; selection is a view of that projection.
///
/// Precedent: `PodcastShowView+Selection.swift`.
extension LibraryBrowseRootView {
  var selectionTitle: String {
    SelectionChromePresentation.title(
      screen: .libraryTitles, selectedCount: selection.selected.count,
      isWorking: selection.isPerforming)
  }

  @ToolbarContentBuilder var selectionToolbar: some ToolbarContent {
    if selectionEntry.editMode.isEditing {
      SelectionToolbar(
        screen: .libraryTitles,
        selectedCount: selection.selected.count,
        isEverythingSelected: selection.selected == selectableTitleIDs,
        isWorking: selection.isPerforming,
        isSelectAllEnabled: !selectableTitleIDs.isEmpty,
        onToggleSelectAll: {
          selection.selected = selection.selected == selectableTitleIDs ? [] : selectableTitleIDs
        },
        download: { selectionDownloadButton },
        markAsFinished: {
          selectionButton(.markAsFinished)
        },
        more: {
          Menu {
            selectionButton(.resetProgress)
            selectionButton(.addToUpNext)
            selectionButton(.saveForLater)
          } label: {
            Label("Title Actions", systemImage: "ellipsis.circle")
          }
          .disabled(selection.selected.isEmpty || selection.isPerforming)
        },
        destructive: {
          selectionButton(.removeDownloads)
        })
    }
  }

  /// A mixed selection names the medium; a sole-format selection downloads on one tap. The menu
  /// asks whether any selected title offers a choice, not whether every one does.
  private var selectionDownloadButton: some View {
    let hasFormatChoice = LibraryBrowsePresentation.selectedItems(
      selectableTitles, ids: selection.selected
    ).contains { item in
      ItemMediaCapability.derive(category: item.category, hasReadableEbook: item.hasReadableEbook)
        .offersFormatChoice
    }
    return SelectionDownloadControl(
      hasFormatChoice: hasFormatChoice,
      isDisabled: selection.isPerforming
        || selectionTargets(hasFormatChoice ? .downloadAllFormats : .download).isEmpty,
      showsFormatSymbols: true,
      request: { format in requestSelectionAction(Self.selectionAction(for: format)) })
  }

  /// Maps the shared control's format back to this screen's batch action, so the confirmation
  /// wording stays the screen's.
  nonisolated private static func selectionAction(
    for format: ItemDownloadFormat?
  ) -> LibraryBrowsePresentation.SelectionAction {
    switch format {
    case .audio: return .downloadAudio
    case .ebook: return .downloadEbooks
    case .both: return .downloadAllFormats
    case nil: return .download
    }
  }

  private func selectionButton(_ action: LibraryBrowsePresentation.SelectionAction) -> some View {
    Button(role: action == .removeDownloads ? .destructive : nil) {
      requestSelectionAction(action)
    } label: {
      Label(action.title, systemImage: action.systemImage)
    }
    .disabled(selection.isPerforming || selectionTargets(action).isEmpty)
  }

  private func selectionTargets(
    _ action: LibraryBrowsePresentation.SelectionAction, ids: Set<String>? = nil
  ) -> [ItemSummary] {
    LibraryBrowsePresentation.selectedItems(selectableTitles, ids: ids ?? selection.selected).filter { item in
      LibraryBrowsePresentation.selectionSupports(
        action, item: item, deviceAction: actions.downloadAction(for: item.serverItemId),
        playbackStatus: finishedStatus.playbackStatus(item.serverItemId),
        isSaved: actions.hasResolvedSavedMembership ? actions.isSaved(itemID: item.serverItemId) : nil,
        nowPlaying: playback.nowPlayingIdentity)
    }
  }

  private func requestSelectionAction(_ action: LibraryBrowsePresentation.SelectionAction) {
    // Checked first so a tap during a running batch skips the O(n) eligibility filter.
    guard !selection.isPerforming else { return }
    let ids = Set(selectionTargets(action).map(\.serverItemId))
    selection.request(
      action, eligibleIDs: ids, requiresConfirmation: action.requiresConfirmation(affectedCount: ids.count),
      run: { performSelectionAction($0, ids: $1) })
  }

  /// A download target with no format for this action is refused by the batch and stays selected.
  func performSelectionAction(_ action: LibraryBrowsePresentation.SelectionAction, ids: Set<String>) {
    selection.perform(
      targets: {
        selectionTargets(action, ids: ids).map { item in
          let target = ItemBatchTarget(
            itemID: item.serverItemId, episodeID: nil, category: item.category,
            durationSeconds: item.durationSeconds,
            downloadFormat: LibraryBrowsePresentation.selectionDownloadFormat(action, item: item))
          return (item.serverItemId, target)
        }
      },
      dismissError: actions.dismissActionError,
      batch: { await actions.performBatch(action.batchAction, on: $0, playback: playback).succeeded },
      exitEditMode: { withAnimation { selectionEntry.editMode = .inactive } })
  }
}
