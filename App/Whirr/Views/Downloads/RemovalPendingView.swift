import DesignSystem
import SwiftUI

/// The removal-pending screen. `RootModel.resumePendingRemovalIfNeeded()` runs one full resume
/// attempt per call: success clears the gate to `.setup` (`RootView` moves on as
/// `navigation.presentation` changes), while a retryable failure
/// (`AccountRemovalError.deletionFailed`) leaves the gate up without throwing. So this view tracks
/// only whether an attempt is in flight, and shows retry once one finishes with the gate still up.
struct RemovalPendingView: View {
  let onRetry: () async -> Void

  @State private var isResuming = true

  var body: some View {
    Group {
      if isResuming {
        LoadingStateView(message: "Finishing account removal…")
      } else {
        ErrorStateView(
          title: "Couldn't Finish Removing Your Account",
          message:
            "Removing your account's local data failed partway through. Nothing was left signed in only partially — try again.",
          systemImage: "exclamationmark.triangle",
          retryTitle: "Try Again"
        ) {
          Task { await retry() }
        }
        .accessibilityIdentifier(ScreenAccessibilityID.removalPendingRetryButton)
      }
    }
    .accessibilityIdentifier(ScreenAccessibilityID.removalPendingScreen)
    .task { await retry() }
  }

  private func retry() async {
    isResuming = true
    await onRetry()
    // Still here (`RootView` has not swapped this screen out as `navigation.presentation`
    // changed) means this attempt did not clear the gate: a retryable failure, not a success.
    isResuming = false
  }
}
