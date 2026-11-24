import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// What a failed podcast download's trailing control does, for every surface that draws one.
///
/// A tap explains first, with an alert titled "Download failed" carrying `ItemDownloadCopy`'s
/// per-category reason, and retries only from its Try Again; the long-press Resume Download
/// retries directly. The show row and episode card share this type so they can't drift: label,
/// hint and id from `control(for:)`, alert from `alert(for:)`, dispatch from `actions(for:alert:)`,
/// presentation from `podcastDownloadFailureAlert`.
nonisolated enum PodcastDownloadFailurePresentation {
  static let title = ItemDownloadCopy.failedTitle
  static let tryAgainLabel = "Try Again"
  static let cancelLabel = StorageCopy.cancel

  /// The control's VoiceOver label and hint. The label is the warning; the hint says the tap
  /// explains rather than acts, so a user who wants an immediate retry knows to use the menu.
  static let controlLabel = ItemDownloadCopy.failedTitle
  static let controlHint = "Shows why this download failed and offers to try again."

  /// One alert, for one episode. `Identifiable` so a list-level `@State` can hold whichever row's
  /// alert is up; `Equatable` so tests can compare the row's and the card's answers directly.
  struct Alert: Equatable, Identifiable {
    let episodeID: String
    let category: DownloadErrorCategory
    /// The action Try Again dispatches, as `PodcastShowPresentation.primaryDeviceAction` answers
    /// it for a failed row.
    let retryAction: AppModel.MediaItemAction

    var id: String { episodeID }
    var message: String { ItemDownloadCopy.failureReason(category: category) }
  }

  enum Choice: Equatable {
    case tryAgain
    case cancel
  }

  /// The trailing control for a failed download, or `nil` in every other state so the caller falls
  /// through to its ordinary status-derived action. The id has no `MediaItemAction` behind
  /// it because the tap presents rather than performs.
  static func control(for status: ItemDownloadStatus) -> MediaContextAction? {
    guard case .failed = status else { return nil }
    return MediaContextAction(
      id: PodcastEpisodeViewAction.explainDownloadFailure.rawValue,
      label: controlLabel,
      hint: controlHint,
      systemImage: "exclamationmark.circle")
  }

  /// The alert a tap on the failed control presents, or `nil` when the state is not a failure.
  static func alert(
    for status: ItemDownloadStatus, episodeID: String, isAvailableOnServer: Bool
  ) -> Alert? {
    guard case .failed(let category) = status,
      let retryAction = PodcastShowPresentation.primaryDeviceAction(
        status: status, isAvailableOnServer: isAvailableOnServer)
    else { return nil }
    return Alert(episodeID: episodeID, category: category, retryAction: retryAction)
  }

  /// What one alert button dispatches: Try Again the one retry, Cancel nothing.
  static func actions(for choice: Choice, alert: Alert) -> [AppModel.MediaItemAction] {
    switch choice {
    case .tryAgain: [alert.retryAction]
    case .cancel: []
    }
  }
}

extension View {
  /// Presents `PodcastDownloadFailurePresentation`'s alert for whichever episode's control was
  /// tapped, dispatching Try Again's retry through `perform` together with the alert it came from
  /// (a list host needs its episode id). Applied by every surface that draws the failed control, so
  /// the alert's title, message and buttons are spelled once.
  func podcastDownloadFailureAlert(
    _ alert: Binding<PodcastDownloadFailurePresentation.Alert?>,
    perform: @escaping (PodcastDownloadFailurePresentation.Alert, AppModel.MediaItemAction) -> Void
  ) -> some View {
    self.alert(
      PodcastDownloadFailurePresentation.title,
      isPresented: Binding(
        get: { alert.wrappedValue != nil },
        set: { if $0 == false { alert.wrappedValue = nil } }),
      presenting: alert.wrappedValue
    ) { presented in
      Button(PodcastDownloadFailurePresentation.tryAgainLabel) {
        for action in PodcastDownloadFailurePresentation.actions(for: .tryAgain, alert: presented) {
          perform(presented, action)
        }
      }
      Button(PodcastDownloadFailurePresentation.cancelLabel, role: .cancel) {
        for action in PodcastDownloadFailurePresentation.actions(for: .cancel, alert: presented) {
          perform(presented, action)
        }
      }
    } message: { presented in
      Text(presented.message)
    }
  }
}
