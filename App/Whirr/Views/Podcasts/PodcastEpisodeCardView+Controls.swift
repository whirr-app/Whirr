import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

extension PodcastEpisodeCardView {
  /// The shelf toggle, promoted out of the action menu so that saving costs one tap on the surface
  /// where the decision is made. `isSaved` is `nil` only until membership resolves; the control
  /// renders unsaved and inert rather than flickering into a filled glyph a moment later.
  @ViewBuilder
  func savedControl() -> some View {
    let motion = PodcastEpisodeCardViewPresentation.motion(reduceMotion: reduceMotion)
    let isSaved = model.isSaved
    let entry = ItemContextMenuPresentation.savedEntry(isSaved: isSaved ?? false)
    Button {
      Task { await model.performAction(isSaved == true ? .removeFromSaved : .saveForLater) }
    } label: {
      Image(systemName: entry.systemImage)
        .contentTransition(motion.symbolTransition)
        .episodeCardControlChrome()
    }
    .buttonStyle(.plain)
    .disabled(isSaved == nil)
    .animation(motion.controlAnimation, value: isSaved)
    .accessibilityLabel(entry.title)
    .accessibilityHint(
      isSaved == true
        ? "Removes this episode from Saved for Later."
        : "Saves this episode to Saved for Later.")
  }

  /// `.replace` carries the glyph swap, as in the download control. No symbol effect: the glyph is
  /// the action the tap performs, and animating it reads as work in progress rather than playback.
  func playGlyph(
    _ control: PodcastEpisodeCardPlayControl,
    motion: PodcastEpisodeCardViewPresentation.Motion
  ) -> some View {
    Image(systemName: control.systemImage)
      .contentTransition(motion.symbolTransition)
  }

  @ViewBuilder
  func downloadControl(_ presentation: PodcastEpisodeCardPresentation) -> some View {
    let control = PodcastEpisodeCardViewPresentation.downloadControl(for: presentation)
    Group {
      if let action = control.action, let episodeAction = control.episodeAction {
        // A completed download is the one tap here that destroys something, so it asks first,
        // using the same policy as the audiobook detail bubble.
        if PodcastEpisodeCardViewPresentation.requiresDeleteConfirmation(
          for: control.deviceStatus.kind)
        {
          Button {
            isConfirmingRemove = true
          } label: {
            downloadGlyph(control)
          }
          .accessibilityLabel(action.label)
          .accessibilityHint(action.hint)
          .confirmationDialog(
            StorageCopy.purgeItemTitle, isPresented: $isConfirmingRemove, titleVisibility: .visible
          ) {
            Button(action.label, role: .destructive) {
              Task { await model.performAction(episodeAction) }
            }
            Button(StorageCopy.cancel, role: .cancel) {}
          } message: {
            Text(action.hint)
          }
        } else {
          Button {
            // A failed download explains first (`PodcastDownloadFailurePresentation`); the retry
            // behind `episodeAction` is dispatched only from the alert's Try Again.
            if let alert = PodcastDownloadFailurePresentation.alert(
              for: presentation.deviceDownloadStatus, episodeID: episodeID,
              isAvailableOnServer: presentation.isAvailableOnServer)
            {
              downloadFailureAlert = alert
            } else {
              Task { await model.performAction(episodeAction) }
            }
          } label: {
            downloadGlyph(control)
          }
          .accessibilityLabel(action.label)
          .accessibilityHint(action.hint)
        }
      } else {
        downloadGlyph(control)
          .accessibilityLabel(presentation.deviceDownloadText)
      }
    }
    .buttonStyle(.plain)
  }

  /// The ten device-transfer states differ only by symbol, so a bare swap is a hard cut. `.replace`
  /// gives the change somewhere to happen. An in-flight transfer draws the same determinate ring
  /// as the audiobook bubble rather than a glyph that says only "downloading".
  @ViewBuilder
  func downloadGlyph(
    _ control: PodcastEpisodeCardViewPresentation.DownloadControl
  ) -> some View {
    let motion = PodcastEpisodeCardViewPresentation.motion(reduceMotion: reduceMotion)
    if control.deviceStatus.isIndeterminate {
      ProgressView()
        .progressViewStyle(.circular)
        .frame(width: Metric.progressRingSize, height: Metric.progressRingSize)
        .episodeCardControlChrome()
    } else if let fraction = control.deviceStatus.clampedProgressFraction {
      DownloadProgressRing(
        progressFraction: fraction, systemImage: control.systemImage
      )
      .frame(width: Metric.progressRingSize, height: Metric.progressRingSize)
      .episodeCardControlChrome()
    } else {
      // The glyph says only where the file is. Whether its ads will be skipped is said in words,
      // beside the "Show notes" heading.
      Image(systemName: control.systemImage)
        .contentTransition(motion.symbolTransition)
        .episodeCardControlChrome()
    }
  }
}
