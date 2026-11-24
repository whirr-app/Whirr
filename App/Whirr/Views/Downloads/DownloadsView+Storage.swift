import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// `DownloadsView`'s storage controls (Delete All, the reclaim button, the low-disk banner) and
/// the confirmation and error plumbing every destructive path on the screen shares.
extension DownloadsView {
  var deleteAllButton: some View {
    Button(role: .destructive) {
      storageModel.requestPurgeAll()
    } label: {
      Label(StorageCopy.purgeAllAction, systemImage: "trash.fill")
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
        .foregroundStyle(WashInk.destructive)
    }
    .buttonStyle(.plain)
    .disabled(visibleDownloadRows.isEmpty)
    .opacity(visibleDownloadRows.isEmpty ? 0.45 : 1)
    .editorialCardSurface(.neutral)
    .accessibilityHint(StorageCopy.purgeAllMessage)
    .accessibilityIdentifier(ScreenAccessibilityID.storageDeleteAllButton)
  }

  var reclaimRemovedEpisodesButton: some View {
    Button(role: .destructive) {
      storageModel.requestReclaimTombstonedEpisodes()
    } label: {
      Text(
        storageModel.isReclaimingTombstonedEpisodes
          ? StorageCopy.deletingProgress
          : StorageCopy.reclaimEpisodesAction(bytes: storageModel.tombstonedEpisodeBytes)
      )
      .font(WhirrTypeToken.caption.font.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      .foregroundStyle(WashInk.destructive)
      .editorialCardSurface(.neutral)
    }
    .buttonStyle(.plain)
    .disabled(storageModel.canReclaimTombstonedEpisodeDownloads == false)
    .accessibilityHint(
      StorageCopy.reclaimEpisodesMessage(bytes: storageModel.tombstonedEpisodeBytes)
    )
    .accessibilityIdentifier(ScreenAccessibilityID.storageReclaimEpisodesButton)
  }

  var lowDiskBanner: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      Label("Storage Full", systemImage: "exclamationmark.octagon.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.orange)
      Text(StorageCopy.lowDiskBanner)
        .font(.caption)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
    }
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .accessibilityElement(children: .combine)
  }

  var purgeConfirmationTitle: String {
    switch storageModel.pendingPurgeConfirmation {
    case .item: StorageCopy.purgeItemTitle
    case .all: StorageCopy.purgeAllTitle
    case .tombstonedEpisodes: StorageCopy.reclaimEpisodesTitle
    case nil: ""
    }
  }

  var purgeConfirmationMessage: String {
    switch storageModel.pendingPurgeConfirmation {
    case .item(_, let title): StorageCopy.purgeItemMessage(title: title)
    case .all: StorageCopy.purgeAllMessage
    case .tombstonedEpisodes(let bytes): StorageCopy.reclaimEpisodesMessage(bytes: bytes)
    case nil: ""
    }
  }

  /// The setter ignores `false`: an alert writes it on every dismissal, including its Delete
  /// button's, possibly before the action runs, and cancelling there would make every purge a
  /// no-op. Both buttons resolve the state themselves, so the getter goes false in the same turn
  /// whichever order SwiftUI runs them in.
  var purgeConfirmationBinding: Binding<Bool> {
    Binding(
      get: { storageModel.pendingPurgeConfirmation != nil },
      set: { _ in }
    )
  }

  var actionErrorMessage: String? {
    storageModel.purgeErrorMessage ?? storageModel.reclaimErrorMessage
      ?? (nativeSubscriptionsEnabled ? rssDownloadsModel.actionErrorMessage : nil)
      ?? selectionErrorMessage
  }

  func dismissActionError() {
    selectionErrorMessage = nil
    storageModel.dismissPurgeError()
    storageModel.dismissReclaimError()
    if nativeSubscriptionsEnabled {
      rssDownloadsModel.dismissActionError()
    }
  }

  func confirmPurge() {
    // Not wrapped in a `Task`: `confirmPurge()` takes its staged target synchronously and returns
    // the removal already in flight, so nothing the alert does on the way out can overtake it.
    storageModel.confirmPurge()
  }

  func confirmPendingDeletion() {
    guard let pending = pendingDeletion else { return }
    pendingDeletion = nil
    Task { await pending.perform() }
  }
}
