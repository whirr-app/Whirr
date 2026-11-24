import AppModel
import SwiftUI

/// Keeps the shared start-failure surface count explicit. The playback model is observed once at
/// the app root, so every play affordance, including presented player and queue surfaces, reaches
/// the same alert without installing competing alerts in child views.
nonisolated enum PlaybackStartFailurePresentation {
  enum Surface: Hashable, Sendable {
    case sharedAlert
  }

  static let alertTitle = "Playback"

  /// Only a play the user is waiting on earns a modal. An automatic queue advance fails with the
  /// device most likely pocketed and nobody looking, so the failed title stays in the player's
  /// `.recoverableError` phase, where its reason and Retry remain visible without interrupting the
  /// listener with an alert they did not ask for.
  static func surfaces(for failure: PlaybackStartFailure?) -> [Surface] {
    guard let failure, failure.origin == .requested else { return [] }
    return [.sharedAlert]
  }

  static func isAlertPresented(for failure: PlaybackStartFailure?) -> Bool {
    surfaces(for: failure).contains(.sharedAlert)
  }

  static func message(for failure: PlaybackStartFailure?) -> String {
    isAlertPresented(for: failure) ? (failure?.message ?? "") : ""
  }
}

private struct PlaybackStartFailureAlertModifier: ViewModifier {
  let playback: PlaybackModel

  func body(content: Content) -> some View {
    content
      .alert(
        PlaybackStartFailurePresentation.alertTitle,
        isPresented: Binding(
          get: {
            PlaybackStartFailurePresentation.isAlertPresented(for: playback.startFailure)
          },
          set: { isPresented in
            if isPresented == false {
              playback.dismissStartFailure()
            }
          })
      ) {
        Button("OK", role: .cancel) {
          playback.dismissStartFailure()
        }
      } message: {
        Text(PlaybackStartFailurePresentation.message(for: playback.startFailure))
      }
  }
}

extension View {
  /// Presents the one shared explanation for a refused playback start. It belongs at the app
  /// root because player, queue, detail, and list actions can all be active descendants of it.
  func playbackStartFailureAlert(_ playback: PlaybackModel) -> some View {
    modifier(PlaybackStartFailureAlertModifier(playback: playback))
  }
}
