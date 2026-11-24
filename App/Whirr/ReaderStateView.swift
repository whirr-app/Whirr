import AppModel
import DesignSystem
import SwiftUI

struct ReaderStateView: View {
  let model: ReaderModel
  let theme: DesignSystem.ReaderTheme

  var body: some View {
    VStack(spacing: WhirrSpacing.medium) {
      switch model.state {
      case .idle, .opening:
        // The opaque cover behind this view is immediate; the spinner waits for the model's
        // reveal threshold so a fast local open never flashes it.
        if model.isOpeningIndicatorVisible {
          ProgressView("Opening book…")
        }
      case .downloading(let progress):
        ProgressView(value: progress) { Text("Downloading book…") }
          .frame(maxWidth: 260)
      // A held transfer gets the reason instead of a bar. The bar was the whole problem: on
      // cellular a Wi-Fi hold never moves, so it read as the app being stuck.
      case .downloadHeld:
        Text(model.errorMessage ?? ReaderCopy.downloadFailed)
          .multilineTextAlignment(.center)
        if model.canResumeDownload {
          Button(ReaderCopy.resumeDownload) { Task { await model.resumeDownload() } }
        }
      case .unavailable:
        Text(model.errorMessage ?? ReaderCopy.noEpub)
      case .drmProtected, .recoverableError, .unopenable, .publicationServerFailure:
        Text(model.errorMessage ?? "The book cannot be opened.")
          .multilineTextAlignment(.center)
        if model.canRetryDownload {
          Button("Download again") { Task { await model.retryDownload() } }
        }
      case .reading:
        EmptyView()
      }
    }
    .padding(WhirrSpacing.large)
    .foregroundStyle(theme.palette.foregroundColor)
    // Spinners and the retry button would otherwise use the system accent, which reads as a
    // different app's blue on the sepia and dark pages.
    .tint(theme.palette.accentColor)
    .accessibilityIdentifier(ReaderAccessibilityID.page)
  }
}
