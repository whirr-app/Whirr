import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// `DownloadsView`'s multiselect: which rows may be selected, the selection toolbar, and the
/// batched removal behind it. The rows selection draws are the screen's ordinary rows (see
/// `DownloadsView+List`).
extension DownloadsView {
  /// Every downloaded row storage is not already tearing down, books and shows alike. A show is
  /// selected whole: `DownloadsViewPresentation.selectionPlan` treats a parent as owning its
  /// children.
  ///
  /// Episodes are removed by swipe or on the show screen, so nothing here produces the episode ids
  /// `selectionPlan` still accepts.
  var selectableItems: [HomeItem] {
    downloadedHomeItems.filter { item in
      storageModel.rows.contains { $0.itemId == item.serverItemId && !$0.isDeleting }
    }
  }

  var eligibleSelectionIDs: Set<DownloadsViewPresentation.SelectionID> {
    guard selectionEditMode.isEditing else { return [] }
    var ids = Set(
      selectableItems.map { DownloadsViewPresentation.SelectionID.absItem($0.serverItemId) })
    if nativeSubscriptionsEnabled {
      for feed in rssDownloadsModel.feeds
      where feed.episodes.contains(where: { $0.state != .deleting }) {
        ids.insert(.rssFeed(feed.id))
      }
    }
    return ids
  }

  @ToolbarContentBuilder var selectionToolbar: some ToolbarContent {
    if selectionEditMode.isEditing {
      SelectionToolbar(
        screen: .downloads,
        selectedCount: selectedDownloadIDs.count,
        isEverythingSelected: selectedDownloadIDs == eligibleSelectionIDs,
        isWorking: isPerformingSelectionAction,
        isSelectAllEnabled: !eligibleSelectionIDs.isEmpty,
        onToggleSelectAll: {
          selectedDownloadIDs = selectedDownloadIDs == eligibleSelectionIDs ? [] : eligibleSelectionIDs
        },
        download: {},
        markAsFinished: {},
        more: {},
        destructive: {
          // The fixed four-slot grammar leaves Download, Mark as Finished, and More empty;
          // Remove Downloads remains in the trailing destructive slot for positional stability.
          Button(role: .destructive) {
            pendingDownloadIDs = selectedDownloadIDs.intersection(eligibleSelectionIDs)
          } label: {
            Label(MediaActionCopy.removeDownloads.title, systemImage: MediaActionCopy.removeDownloads.systemImage)
          }
          .disabled(isPerformingSelectionAction || selectedDownloadIDs.isEmpty)
          .accessibilityIdentifier(ScreenAccessibilityID.storageSelectionRemove)
        }
      )
    } else {
      ToolbarItem(placement: .topBarTrailing) {
        SelectionEntryButton(screen: .downloads, isEnabled: !visibleDownloadRows.isEmpty) {
          selectionEditMode = .active
        }
      }
    }
  }

  func confirmSelectionDeletion() {
    let ids = pendingDownloadIDs.intersection(eligibleSelectionIDs)
    let plan = DownloadsViewPresentation.selectionPlan(selected: ids, eligible: eligibleSelectionIDs)
    pendingDownloadIDs.removeAll()
    dismissActionError()
    guard !plan.isEmpty else { return }
    isPerformingSelectionAction = true
    Task {
      await storageModel.purgeSelectedItemDownloads(plan.absItemIDs)
      for episode in plan.absEpisodeIDs {
        let model = podcastShowModel(episode.itemID)
        await model.removeDownload(episode.episodeID)
        if let error = model.actionErrorMessage { selectionErrorMessage = error }
      }
      if nativeSubscriptionsEnabled {
        await rssDownloadsModel.purgeSelectedDownloads(
          feedIDs: plan.rssFeedIDs,
          episodeIDs: Dictionary(grouping: plan.rssEpisodeIDs, by: \.feedID).mapValues { Set($0.map(\.episodeID)) })
      }
      isPerformingSelectionAction = false
      if actionErrorMessage == nil {
        withAnimation { selectionEditMode = .inactive }
      } else {
        // Optimistic deleting states can prune a row before its purge fails and restores it.
        selectedDownloadIDs = ids.intersection(eligibleSelectionIDs)
      }
    }
  }
}
