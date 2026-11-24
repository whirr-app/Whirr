import AppModel
import Persistence
import SwiftUI

extension HomeMoreView {
  var visibleItemIDs: Set<String> {
    Set(model.items.map(\.serverItemId))
  }

  var selectionTitle: String {
    SelectionChromePresentation.title(
      screen: .homeContinue,
      selectedCount: selection.selected.count,
      isWorking: selection.isPerforming)
  }

  var selectionConfirmationTitle: String {
    guard let action = selection.pending?.action else { return "Selected Items" }
    if action == .removeFromContinueListening {
      return HomeMoreSelectionAction.removeFromShelfTitle(section: section)
    }
    return action.title
  }

  var selectionConfirmationMessage: String {
    let count = selection.pending?.ids.count ?? 0
    switch selection.pending?.action {
    case .removeFromContinueListening:
      let shelfTitle =
        section == .continueReading
        ? HomeCopy.continueReadingTitle
        : HomeCopy.continueListeningTitle
      return
        "Remove \(count) selected items from \(shelfTitle)?"
    case .removeDownload:
      return "Remove downloads for \(count) selected items from this device?"
    case .resetProgress:
      return "Reset progress for \(count) selected items to the beginning?"
    // Exhaustive rather than defaulted, so an action added later has to say whether it confirms.
    // These three act immediately and never reach an alert.
    case .markAsFinished, .download, .addToUpNext, nil:
      return "Selected Items"
    }
  }

  @ToolbarContentBuilder var selectionToolbar: some ToolbarContent {
    if HomeMoreSelectionPolicy.offersSelection(section: section) {
      if selectionEditMode.isEditing {
        SelectionToolbar(
          screen: .homeContinue,
          selectedCount: selection.selected.count,
          isEverythingSelected: selection.selected == visibleItemIDs,
          isWorking: selection.isPerforming,
          isSelectAllEnabled: !visibleItemIDs.isEmpty,
          onToggleSelectAll: {
            selection.selected = selection.selected == visibleItemIDs ? [] : visibleItemIDs
          },
          download: {
            SelectionDownloadControl(
              hasFormatChoice: selectedItems(for: .download).contains(where: {
                HomeMoreSelectionPolicy.capability(for: $0)?.offersFormatChoice ?? false
              }),
              isDisabled: selectionActionIsDisabled(.download),
              accessibilityID: HomeAccessibilityID.selectionDownload,
              request: requestDownload)
          },
          markAsFinished: {
            Button(MediaActionCopy.markAsFinished.title, systemImage: MediaActionCopy.markAsFinished.systemImage) {
              requestSelectionAction(.markAsFinished)
            }
            .disabled(selectionActionIsDisabled(.markAsFinished))
          },
          more: {
            Menu {
              Button(MediaActionCopy.resetProgress.title, systemImage: MediaActionCopy.resetProgress.systemImage) {
                requestSelectionAction(.resetProgress)
              }
              .disabled(selectionActionIsDisabled(.resetProgress))
              Button(MediaActionCopy.addToUpNext.title, systemImage: MediaActionCopy.addToUpNext.systemImage) {
                requestSelectionAction(.addToUpNext)
              }
              .disabled(selectionActionIsDisabled(.addToUpNext))
              Divider()
              Button(
                MediaActionCopy.removeDownloads.title, systemImage: MediaActionCopy.removeDownloads.systemImage,
                role: .destructive
              ) {
                requestSelectionAction(.removeDownload)
              }
              .disabled(selectionActionIsDisabled(.removeDownload))
            } label: {
              Label("Continue Actions", systemImage: "ellipsis.circle")
            }
            .disabled(selection.isPerforming || selection.selected.isEmpty)
            .accessibilityIdentifier(HomeAccessibilityID.selectionActions)
          },
          destructive: {
            Button(
              HomeMoreSelectionAction.removeFromShelfTitle(section: section),
              systemImage: "eye.slash"
            ) {
              requestSelectionAction(.removeFromContinueListening)
            }
            .disabled(selectionActionIsDisabled(.removeFromContinueListening))
            .accessibilityIdentifier(HomeAccessibilityID.selectionRemoveFromShelf)
          })
      } else {
        ToolbarItem(placement: .topBarTrailing) {
          SelectionEntryButton(screen: .homeContinue, isEnabled: !model.items.isEmpty) {
            selectionEditMode = .active
          }
        }
      }
    }
  }

  private func selectionActionIsDisabled(_ action: HomeMoreSelectionAction) -> Bool {
    selection.isPerforming || selectedItems(for: action).isEmpty
  }

  private func selectedItems(
    for action: HomeMoreSelectionAction, ids: Set<String>? = nil
  ) -> [HomeItem] {
    let selectedIDs = ids ?? selection.selected
    return model.items.filter { selectedIDs.contains($0.serverItemId) }.filter { item in
      HomeMoreSelectionPolicy.accepts(
        action,
        item: item,
        deviceAction: actions.downloadAction(
          for: item.serverItemId, episodeID: item.episodeID),
        nowPlaying: playback.nowPlayingIdentity,
        isHidden: actions.isHiddenFromContinueListening(
          itemID: item.serverItemId, episodeID: item.episodeID),
        isCurrentlyPlaying: playback.isPlaybackIntended(
          for: item.serverItemId, episodeID: item.episodeID))
    }
  }

  private func requestSelectionAction(_ action: HomeMoreSelectionAction) {
    selection.request(
      action, eligibleIDs: Set(selectedItems(for: action).map(\.serverItemId)),
      requiresConfirmation: action == .removeFromContinueListening || action == .removeDownload
        || action == .resetProgress,
      run: { performSelectionAction($0, ids: $1) })
  }

  func performSelectionAction(
    _ action: HomeMoreSelectionAction,
    ids: Set<String>,
    format: ItemDownloadFormat? = nil
  ) {
    selection.perform(
      targets: {
        selectedItems(for: action, ids: ids).compactMap { item -> (String, ItemBatchTarget)? in
          let downloadFormat = HomeMoreSelectionPolicy.downloadFormat(for: item, requested: format)
          guard action != .download || downloadFormat != nil else { return nil }
          let target = ItemBatchTarget(
            itemID: item.serverItemId, episodeID: item.episodeID, category: item.category,
            durationSeconds: item.durationSeconds, downloadFormat: downloadFormat)
          return (item.serverItemId, target)
        }
      },
      dismissError: actions.dismissActionError,
      batch: { await actions.performBatch(action.batchAction, on: $0, playback: playback).succeeded },
      exitEditMode: { withAnimation { selectionEditMode = .inactive } })
  }

  private func requestDownload(_ format: ItemDownloadFormat?) {
    let ids = Set(selectedItems(for: .download).map(\.serverItemId))
    performSelectionAction(.download, ids: ids, format: format)
  }
}
