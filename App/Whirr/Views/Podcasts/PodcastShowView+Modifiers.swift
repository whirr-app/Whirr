import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

extension PodcastShowView {
  /// The selection failure and batch confirmation alerts, the state explanation, the bulk mark,
  /// the unsubscribe confirmation, and the shared download-failure alert.
  func pageSelectionAlerts<Content: View>(_ content: Content) -> some View {
    content
      .alert("Some Episodes Couldn’t Be Updated", isPresented: $isShowingSelectionFailure) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.actionErrorMessage ?? "Try again.")
      }
      .alert(
        "Selected Episodes",
        isPresented: Binding(
          get: { selection.pending != nil },
          set: { _ in }
        )
      ) {
        Button("Cancel", role: .cancel) { selection.cancelPending() }
        Button(
          selection.pending?.action == .removeDownload ? MediaActionCopy.removeDownloads.title : "Confirm",
          role: selection.pending?.action == .removeDownload ? .destructive : nil
        ) {
          selection.confirmPending { performSelectionAction($0, ids: $1) }
        }
      } message: {
        Text(selectionConfirmationMessage)
      }
      .alert(
        stateIndicator?.title ?? "",
        isPresented: $isShowingStateExplanation
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(stateIndicator?.message ?? "")
      }
      // Every pending action starts in the toolbar menu. By the time this is presented that menu
      // has collapsed, so an alert supplies the stable, centred host that an anchored dialog lacks.
      .alert(
        pendingBulkMark?.message ?? "",
        isPresented: Binding(
          get: { pendingBulkMark != nil },
          set: { if $0 == false { pendingBulkMark = nil } })
      ) {
        if let pendingBulkMark {
          Button(
            pendingBulkMark.confirmLabel,
            role: pendingBulkMark.isDestructive ? .destructive : nil
          ) {
            let kind = pendingBulkMark.kind
            self.pendingBulkMark = nil
            Task { await confirm(kind) }
          }
        }
        Button(StorageCopy.cancel, role: .cancel) { pendingBulkMark = nil }
      }
      .alert(
        PodcastShowViewPresentation.unsubscribeConfirmationTitle,
        isPresented: $isConfirmingUnsubscribe
      ) {
        Button(PodcastShowViewPresentation.unsubscribeConfirmLabel, role: .destructive) {
          Task {
            if await model.unsubscribe() { dismiss() }
          }
        }
        Button(StorageCopy.cancel, role: .cancel) {}
      } message: {
        Text(PodcastShowViewPresentation.unsubscribeConfirmationMessage)
      }
      .podcastDownloadFailureAlert($downloadFailureAlert) { alert, action in
        Task { await model.performAction(action, episodeID: alert.episodeID) }
      }
  }

  /// The server-save sheets and the teardown that drops a staged confirmation when the presentation
  /// changes.
  func serverSaveSheets<Content: View>(_ content: Content) -> some View {
    content
      .nativeEpisodeServerSaveSheets(
        removalConfirmation: $serverRemovalConfirmation,
        choicePrompt: Binding(
          get: { model.serverSave.pendingServerSaveChoice?.prompt },
          set: { if $0 == nil { model.serverSave.dismissServerSaveFeedback() } }),
        podcastName: loadedItem?.title ?? seed?.title,
        episodeCount: model.serverSave.pendingServerSaveChoice?.episodeCount ?? 1,
        savesShow: model.serverSave.batchServerSave?.isShowSave == true,
        onRemoveConfirmed: { episodeID in
          Task { await model.serverSave.removeEpisodeFromServer(episodeID: episodeID) }
        },
        onChoice: { choice in
          Task { await model.serverSave.chooseSaveDestination(choice) }
        },
        onChoiceCancelled: model.serverSave.dismissServerSaveFeedback
      )
      .onChange(of: model.serverSave.serverSavePresentationVersion) { _, _ in
        serverRemovalConfirmation = nil
      }
  }

  /// The four feedback banners, the failure haptic, and the page's wash and refresh tasks.
  func pageFeedbackAndTasks<Content: View>(_ content: Content) -> some View {
    content
      .queueFeedbackBanner(
        message: model.queueFeedbackMessage, onDismiss: model.dismissQueueFeedback
      )
      .queueFeedbackBanner(
        message: model.savedFeedbackMessage, onDismiss: model.dismissSavedFeedback
      )
      .queueFeedbackBanner(
        message: model.continueListeningFeedbackMessage,
        onDismiss: model.dismissContinueListeningFeedback
      )
      // The transient channel, not the status mirror: the banner's own timer clears it, and
      // that clear must not reach the pending destination choice, as `dismissServerSaveFeedback`
      // does when the sheet is cancelled.
      .queueFeedbackBanner(
        message: model.serverSave.serverSaveBannerMessage,
        onDismiss: model.serverSave.dismissServerSaveBanner
      )
      // A failed server save or removal is the only thing on this channel the listener must
      // notice; confirmations tap through the banner above.
      .sensoryFeedback(trigger: model.actionErrorMessage) { _, newMessage in
        newMessage == nil ? nil : ItemActionHaptics.failure
      }
      // The source is part of the task identity: a seedless route is allowed to learn its RSS
      // source from the shell resolver after the first frame, and must then request the real key.
      // The revision likewise arrives with the loaded show. HomeWashProvider already coalesces an
      // identical (revision, source) request.
      .task(id: pageWashTaskKey) {
        let pageSubject = pageWashSubject
        await homeWashProvider.preloadCachedWashes([pageSubject])
        homeWashProvider.request(
          [pageSubject], intent: .visible,
          displaySize: artworkDisplaySize, displayScale: displayScale, artworkRole: .homeCard)
      }
      // Opening the screen is the stale-gated refresh; pull-to-refresh below is never gated.
      .task {
        guard refreshOnAppear else { return }
        await model.refreshOnAppear()
      }
  }
}
