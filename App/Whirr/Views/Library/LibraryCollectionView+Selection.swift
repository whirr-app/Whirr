import AppModel
import Persistence
import SwiftUI

/// The collection screen's selection host, modelled on Saved for Later's. Every action is one
/// `ItemActionsModel.performBatch`. The list itself is read-only in Whirr, so nothing here edits
/// it.
extension LibraryCollectionView {
  var visibleEntryIDs: Set<String> { Set(model.entries.map(\.id)) }

  var isSelectionWorking: Bool { selection.isPerforming }

  var selectionTitle: String {
    SelectionChromePresentation.title(
      screen: .libraryCollection, selectedCount: selection.selected.count, isWorking: isSelectionWorking)
  }

  func selectionHost(_ content: some View) -> some View {
    content
      .toolbar { selectionToolbar }
      .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
      .hidesPlayerAccessory(whileSelecting: editMode.isEditing)
      .environment(\.editMode, $editMode)
      .navigationBarBackButtonHidden(editMode.isEditing)
      .onChange(of: editMode) { _, mode in if !mode.isEditing { selection.selected.removeAll() } }
      .onChange(of: visibleEntryIDs) { _, ids in
        selection.selected.formIntersection(ids)
        // A refresh that emptied the list leaves nothing to select.
        if ids.isEmpty, editMode.isEditing { withAnimation { editMode = .inactive } }
      }
      .alert(
        selection.pending?.action.title ?? "Selected Items",
        isPresented: Binding(get: { selection.pending != nil }, set: { _ in })
      ) {
        Button("Cancel", role: .cancel) { selection.cancelPending() }
        Button(
          selection.pending?.action.title ?? "Confirm",
          role: selection.pending?.action == .resetProgress ? nil : .destructive
        ) {
          selection.confirmPending { performSelectionAction($0, ids: $1) }
        }
      } message: {
        Text(selectionConfirmationMessage)
      }
  }

  @ToolbarContentBuilder private var selectionToolbar: some ToolbarContent {
    if editMode.isEditing {
      SelectionToolbar(
        screen: .libraryCollection,
        selectedCount: selection.selected.count,
        isEverythingSelected: selection.selected == visibleEntryIDs,
        isWorking: isSelectionWorking,
        isSelectAllEnabled: !visibleEntryIDs.isEmpty,
        onToggleSelectAll: {
          selection.selected = selection.selected == visibleEntryIDs ? [] : visibleEntryIDs
        },
        download: { selectionDownloadButton },
        markAsFinished: { selectionMarkAsFinishedButton },
        more: { selectionMoreMenu },
        destructive: {}
      )
    } else {
      ToolbarItem(placement: .topBarTrailing) {
        pinnedDownloadControl
      }
      ToolbarItem(placement: .topBarTrailing) {
        SelectionEntryButton(screen: .libraryCollection, isEnabled: !model.entries.isEmpty) {
          editMode = .active
        }
      }
    }
  }

  // The slots are properties rather than closures written inline at the `SelectionToolbar` call:
  // four builder closures in one generic expression can exceed what the type checker will solve.

  @ViewBuilder private var selectionDownloadButton: some View {
    SelectionDownloadControl(
      hasFormatChoice: selectedEntries(for: .download).contains(
        where: LibraryCollectionSelectionPolicy.offersFormatChoice),
      isDisabled: selectionActionIsDisabled(.download),
      accessibilityID: LibraryAccessibilityID.collectionSelectionDownload,
      request: requestDownload)
  }

  private var selectionMarkAsFinishedButton: some View {
    Button(MediaActionCopy.markAsFinished.title, systemImage: MediaActionCopy.markAsFinished.systemImage) {
      requestSelectionAction(.markAsFinished)
    }
    .disabled(selectionActionIsDisabled(.markAsFinished))
    .accessibilityIdentifier(LibraryAccessibilityID.collectionSelectionMarkAsFinished)
  }

  private var selectionMoreMenu: some View {
    Menu {
      Button(MediaActionCopy.resetProgress.title, systemImage: MediaActionCopy.resetProgress.systemImage) {
        requestSelectionAction(.resetProgress)
      }
      .disabled(selectionActionIsDisabled(.resetProgress))
      Button(MediaActionCopy.addToUpNext.title, systemImage: MediaActionCopy.addToUpNext.systemImage) {
        requestSelectionAction(.addToUpNext)
      }
      .disabled(selectionActionIsDisabled(.addToUpNext))
      Button(MediaActionCopy.saveForLater.title, systemImage: MediaActionCopy.saveForLater.systemImage) {
        requestSelectionAction(.saveForLater)
      }
      .disabled(selectionActionIsDisabled(.saveForLater))
      Divider()
      Button(
        MediaActionCopy.removeDownloads.title, systemImage: MediaActionCopy.removeDownloads.systemImage,
        role: .destructive
      ) {
        requestSelectionAction(.removeDownload)
      }
      .disabled(selectionActionIsDisabled(.removeDownload))
    } label: {
      Label("List Actions", systemImage: "ellipsis.circle")
    }
    .disabled(isSelectionWorking || selection.selected.isEmpty)
    .accessibilityIdentifier(LibraryAccessibilityID.collectionSelectionActions)
  }

  private var selectionConfirmationMessage: String {
    let count = selection.pending?.ids.count ?? 0
    switch selection.pending?.action {
    case .resetProgress: return "Reset progress for \(count) selected items to the beginning?"
    default: return "Remove downloads for \(count) selected items from this device?"
    }
  }

  private func selectionActionIsDisabled(_ action: LibraryCollectionSelectionAction) -> Bool {
    isSelectionWorking || selectedEntries(for: action).isEmpty
  }

  /// The selected entries `action` applies to, in the list's order.
  private func selectedEntries(
    for action: LibraryCollectionSelectionAction, ids: Set<String>? = nil
  ) -> [LibraryCollectionEntry] {
    let nowPlaying = playback.nowPlayingIdentity
    let hasResolvedSaved = actions.hasResolvedSavedMembership
    return LibraryCollectionSelectionPolicy.selectedEntries(model.entries, ids: ids ?? selection.selected)
      .filter { entry in
        LibraryCollectionSelectionPolicy.accepts(
          action, entry: entry,
          deviceAction: actions.downloadAction(for: entry.itemID, episodeID: entry.episodeID),
          isSaved: hasResolvedSaved ? actions.isSaved(itemID: entry.itemID, episodeID: entry.episodeID) : nil,
          nowPlaying: nowPlaying)
      }
  }

  private func requestSelectionAction(_ action: LibraryCollectionSelectionAction) {
    selection.request(
      action, eligibleIDs: Set(selectedEntries(for: action).map(\.id)),
      requiresConfirmation: Self.requiresConfirmation(action),
      run: { performSelectionAction($0, ids: $1) })
  }

  /// Exhaustive, so an action added later has to say whether it confirms.
  private static func requiresConfirmation(_ action: LibraryCollectionSelectionAction) -> Bool {
    switch action {
    case .removeDownload, .resetProgress: true
    case .download, .markAsFinished, .addToUpNext, .saveForLater: false
    }
  }

  private func requestDownload(_ format: ItemDownloadFormat?) {
    let ids = Set(selectedEntries(for: .download).map(\.id))
    performSelectionAction(.download, ids: ids, format: format)
  }

  private func performSelectionAction(
    _ action: LibraryCollectionSelectionAction, ids: Set<String>, format: ItemDownloadFormat? = nil
  ) {
    let batchAction = action.batchAction
    selection.perform(
      targets: {
        selectedEntries(for: action, ids: ids).compactMap { entry -> (String, ItemBatchTarget)? in
          let downloadFormat = LibraryCollectionSelectionPolicy.downloadFormat(for: entry, requested: format)
          guard action != .download || downloadFormat != nil else { return nil }
          return (entry.id, LibraryCollectionSelectionPolicy.batchTarget(for: entry, downloadFormat: downloadFormat))
        }
      },
      dismissError: actions.dismissActionError,
      batch: { await actions.performBatch(batchAction, on: $0, playback: playback).succeeded },
      exitEditMode: { withAnimation { editMode = .inactive } })
  }
}
