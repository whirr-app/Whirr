import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// One expanded podcast folder. Its show model belongs to the screen rather than to this subtree
/// (see `DownloadsViewPresentation.episodeObservationWarmUp` for why the observation must be open
/// before the folder is built). Every episode removal is handed up to the screen to confirm,
/// because this subtree's rows are the ones a swipe tears down.
struct DownloadedPodcastEpisodesView: View {
  let itemID: String
  let model: PodcastShowModel
  let onRequestDelete: (PendingDownloadDeletion) -> Void

  var body: some View {
    Group {
      switch DownloadsViewPresentation.episodeFolderContent(
        state: model.state, hasEpisodes: model.filteredEpisodes.isEmpty == false)
      {
      case .episodes:
        ForEach(model.filteredEpisodes) { episode in
          episodeRow(episode)
        }
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, WhirrSpacing.small)
          .selectionDisabled()
      case .empty:
        Text("No downloaded episodes")
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, WhirrSpacing.small)
          .selectionDisabled()
      case .unavailable(let state):
        Text(state.copyText)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, WhirrSpacing.small)
          .selectionDisabled()
      }

      if let error = model.actionErrorMessage {
        Text(error)
          .font(WhirrTypeToken.caption2.font)
          .foregroundStyle(WashInk.destructive)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, WhirrSpacing.xSmall)
          .selectionDisabled()
      }
    }
  }

  @ViewBuilder private func episodeRow(_ episode: PodcastEpisodeSummary) -> some View {
    let label = VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      Text(episode.title.isEmpty ? PodcastCopy.untitledEpisode : episode.title)
        .font(WhirrTypeToken.subheadline.font.weight(.semibold))
        .lineLimit(2)
      Text(DownloadsViewPresentation.episodeDetail(episode))
        .font(WhirrTypeToken.caption2.font)
        .foregroundStyle(WashInk.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, WhirrSpacing.xSmall)
    .contentShape(Rectangle())
    // Only reached through an expanded folder, which selection does not draw (the show is
    // selected whole). Removing one episode is this swipe.
    label
      .downloadDeleteSwipeAction(
        label: "Remove \(episode.title)",
        hint: "Asks for confirmation before removing this downloaded episode."
      ) {
        onRequestDelete(
          PendingDownloadDeletion(
            id: episode.id,
            alertTitle: DownloadsViewPresentation.episodeDeleteTitle(title: episode.title),
            message: DownloadsViewPresentation.episodeDeleteMessage
          ) {
            await model.removeDownload(episode.id)
          })
      }
      .accessibilityIdentifier(
        ScreenAccessibilityID.storageEpisodeRowPrefix + itemID + "." + episode.id)
  }

}

extension View {
  func downloadPurgeConfirmationAlert(
    isPresented: Binding<Bool>,
    title: String,
    message: String,
    onConfirm: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) -> some View {
    alert(title, isPresented: isPresented) {
      Button(StorageCopy.confirmRemove, role: .destructive, action: onConfirm)
        .accessibilityHint(message)
      Button(StorageCopy.cancel, role: .cancel, action: onCancel)
    } message: {
      Text(message)
    }
  }

  /// The one delete swipe for every download row: a red capsule, trash glyph over "Remove". Red is
  /// stated because the inherited near-white scene tint would give a white capsule under a white
  /// glyph; no role, as `.destructive` collapses the row before the confirmation is answered
  /// (`DownloadsViewPresentation.SwipeDeleteButtonRole`). `label` is what VoiceOver reads.
  ///
  /// `carriesMenuTwin` is false where the shared item menu closes with the same removal
  /// (`ItemMenuClosingAction`), so two menus don't compete for the press.
  @ViewBuilder
  func downloadDeleteSwipeAction(
    label: String,
    hint: String,
    isDeleting: Bool = false,
    carriesMenuTwin: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    let title = DownloadsViewPresentation.deleteActionTitle
    let systemImage = DownloadsViewPresentation.deleteActionSystemImage

    let swiped = swipeActions(
      edge: .trailing,
      allowsFullSwipe: DownloadsViewPresentation.allowsFullSwipeToDelete
    ) {
      Button(action: action) {
        Label(title, systemImage: systemImage)
      }
      .disabled(isDeleting)
      .tint(.red)
      .accessibilityLabel(label)
      .accessibilityHint(hint)
    }
    if carriesMenuTwin {
      swiped.contextMenu {
        Button(role: .destructive, action: action) {
          Label(title, systemImage: systemImage)
        }
        .disabled(isDeleting)
      }
    } else {
      swiped
    }
  }
}
