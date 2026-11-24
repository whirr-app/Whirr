import AppModel
import Persistence
import SwiftUI
import SyncEngine

extension PodcastShowView {
  var visibleEpisodeIDs: Set<String> { Set(model.filteredEpisodes.map(\.id)) }
  var isBatchServerSaveWorking: Bool { model.serverSave.batchServerSave?.isWorking == true }

  /// The toolbar and selection title are held outside `body`'s modifier chain. Folding either
  /// back in exceeds what the type checker will solve, and it fails as a timeout pointing at the
  /// last thing added rather than the chain that is too big.
  @ToolbarContentBuilder var screenToolbar: some ToolbarContent {
    if editMode.isEditing {
      SelectionToolbar(
        screen: .podcastEpisodes,
        selectedCount: selection.selected.count,
        isEverythingSelected: selection.selected == visibleEpisodeIDs,
        isWorking: selection.isPerforming || isBatchServerSaveWorking,
        isSelectAllEnabled: !visibleEpisodeIDs.isEmpty,
        onToggleSelectAll: {
          selection.selected = selection.selected == visibleEpisodeIDs ? [] : visibleEpisodeIDs
        },
        confirmation: showSaveConfirmation,
        download: { selectionDownloadButton },
        markAsFinished: { selectionMarkAsFinishedButton },
        more: { selectionMoreSlot },
        destructive: { selectionRemoveDownloadsButton }
      )
    } else {
      if let indicator = PodcastShowViewPresentation.stateIndicator(for: model.state) {
        ToolbarItem(placement: .topBarTrailing) { stateIndicatorButton(indicator) }
      }
      ToolbarItem(placement: .topBarTrailing) {
        SelectionEntryButton(
          screen: .podcastEpisodes, isEnabled: !model.filteredEpisodes.isEmpty
        ) {
          editMode = .active
        }
      }
      ToolbarItem(placement: .topBarTrailing) { optionsMenu }
    }
  }

  /// Save Show to Audiobookshelf: opens selection with the first saveable episode preselected and
  /// arms the mark `beginBatchServerSave` consumes. Nothing is sent until the tick, which replaces
  /// Done here, confirms. Selection is set one main-actor turn after `editMode` activates:
  /// `List(selection:)` is nil-bound until editing begins, and a same-transaction selection
  /// surviving is unverified.
  func beginShowSaveSelection() {
    let preselected = model.serverSave.showSavePreselectedEpisodeID
    model.serverSave.armShowSave()
    isSelectingForShowSave = true
    editMode = .active
    Task { @MainActor in
      await Task.yield()
      guard editMode.isEditing, let preselected else { return }
      selection.selected = [preselected]
    }
  }

  /// Present from the Save Show entry until the batch starts; then the ordinary selection bar
  /// returns, with the batch's own Cancel in its More slot.
  private var showSaveConfirmation: SelectionConfirmation? {
    guard isSelectingForShowSave, !isBatchServerSaveWorking else { return nil }
    return SelectionConfirmation(
      label: NativeEpisodeServerSaveCopy.saveAction,
      isEnabled: !selectionActionIsDisabled(.saveToServer),
      confirm: { model.serverSave.beginBatchServerSave(episodeIDs: selection.selected) },
      cancel: { withAnimation { editMode = .inactive } })
  }

  var selectionTitle: String {
    SelectionChromePresentation.title(
      screen: .podcastEpisodes,
      selectedCount: selection.selected.count,
      isWorking: selection.isPerforming || isBatchServerSaveWorking)
  }

  /// Separate properties rather than closures inline at the `SelectionToolbar` call. Four builder
  /// closures in one generic expression exceed what the type checker will solve in reasonable
  /// time, and it fails as a timeout rather than a diagnostic that points at the cause.
  private var selectionDownloadButton: some View {
    Button {
      requestSelectionAction(.download)
    } label: {
      Label(MediaActionCopy.download.title, systemImage: MediaActionCopy.download.systemImage)
    }
    .disabled(selectionActionIsDisabled(.download))
    .accessibilityIdentifier(PodcastAccessibilityID.selectionDownload)
  }

  private var selectionMarkAsFinishedButton: some View {
    Button(MediaActionCopy.markAsFinished.title, systemImage: MediaActionCopy.markAsFinished.systemImage) {
      requestSelectionAction(.markAsFinished)
    }
    .disabled(selectionActionIsDisabled(.markAsFinished))
    .accessibilityIdentifier(PodcastAccessibilityID.selectionMarkAsFinished)
  }

  @ViewBuilder private var selectionMoreSlot: some View {
    if isBatchServerSaveWorking {
      Button(NativeEpisodeServerSaveBatchCopy.cancelAction, systemImage: "xmark.circle") {
        model.serverSave.cancelBatchServerSave()
      }
      .disabled(model.serverSave.batchServerSave?.phase == .cancelling)
      .accessibilityIdentifier(PodcastAccessibilityID.selectionCancelServerSave)
    } else {
      selectionActionsMenu
    }
  }

  private var selectionActionsMenu: some View {
    Menu {
      Button("Mark as Unplayed", systemImage: "arrow.counterclockwise") {
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
      if model.isNativeFeed && model.serverSave.serverMutationCapability.canSave {
        // Save bypasses the regular selection-action pipeline so its batch state leaves the list
        // scrollable while rows report progress.
        Button(
          NativeEpisodeServerSaveCopy.saveAction,
          systemImage: NativeEpisodeServerSaveCopy.saveSystemImage
        ) {
          model.serverSave.beginBatchServerSave(episodeIDs: selection.selected)
        }
        .disabled(selectionActionIsDisabled(.saveToServer))
        .accessibilityIdentifier(PodcastAccessibilityID.selectionSaveToServer)
      }
    } label: {
      Label("Episode Actions", systemImage: "ellipsis.circle")
    }
    .disabled(selection.isPerforming || isBatchServerSaveWorking || selection.selected.isEmpty)
    .accessibilityIdentifier(PodcastAccessibilityID.selectionActions)
  }

  private var selectionRemoveDownloadsButton: some View {
    Button(role: .destructive) {
      requestSelectionAction(.removeDownload)
    } label: {
      Label(MediaActionCopy.removeDownloads.title, systemImage: MediaActionCopy.removeDownloads.systemImage)
    }
    .disabled(selectionActionIsDisabled(.removeDownload))
    .accessibilityIdentifier(PodcastAccessibilityID.selectionRemoveDownloads)
  }

  private func selectionActionIsDisabled(_ action: MediaItemAction) -> Bool {
    selection.isPerforming
      || isBatchServerSaveWorking
      || model.selectedActionTargets(
        action, episodeIDs: selection.selected,
        nowPlaying: playback.nowPlayingIdentity
      ).isEmpty
  }

  private func requestSelectionAction(_ action: MediaItemAction) {
    let ids = Set(
      model.selectedActionTargets(
        action, episodeIDs: selection.selected,
        nowPlaying: playback.nowPlayingIdentity
      ).map(\.id))
    guard !ids.isEmpty, !selection.isPerforming else { return }
    let message: String?
    switch action {
    case .removeDownload:
      message = "Remove downloads for \(ids.count) selected episodes from this device?"
    case .markAsFinished, .resetProgress:
      message = PodcastShowViewPresentation.markAllConfirmation(
        count: ids.count, isFinished: action == .markAsFinished)
    default: message = nil
    }
    if let message { selectionConfirmationMessage = message }
    selection.request(
      action, eligibleIDs: ids, requiresConfirmation: message != nil,
      run: { performSelectionAction($0, ids: $1) })
  }

  /// The model runs the batch and reports which episodes succeeded; the show's own alert is the
  /// failure report, since this page shows no item action alert.
  func performSelectionAction(_ action: MediaItemAction, ids: Set<String>) {
    let nowPlaying = playback.nowPlayingIdentity
    selection.perform(
      ids: { model.selectedActionTargets(action, episodeIDs: ids, nowPlaying: nowPlaying).map(\.id) },
      // `performSelectedAction` clears the model's error itself.
      dismissError: {},
      batch: { episodeIDs in
        let succeeded = await model.performSelectedAction(
          action, episodeIDs: Set(episodeIDs), nowPlaying: nowPlaying)
        if model.actionErrorMessage != nil { isShowingSelectionFailure = true }
        return succeeded
      },
      exitEditMode: { withAnimation { editMode = .inactive } })
  }
}
