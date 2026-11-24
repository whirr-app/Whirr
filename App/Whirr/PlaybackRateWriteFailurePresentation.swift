import AppModel
import SwiftUI

/// Reports a failed playback-speed save. `PlaybackRateCoordinator` owns every speed write (player,
/// mini-player, Show Settings, lock screen, CarPlay) and is observed once at the app root, like the
/// start-failure alert, so all reach one alert; two hosts on one value fight, so child views
/// install none.
nonisolated enum PlaybackRateWriteFailurePresentation {
  /// Names the setting that did not save; the coordinator's message says what happened.
  static let alertTitle = "Playback Speed"

  static func isAlertPresented(for message: String?) -> Bool {
    message?.isEmpty == false
  }
}

private struct PlaybackRateWriteFailureAlertModifier: ViewModifier {
  let playbackRate: PlaybackRateCoordinator

  func body(content: Content) -> some View {
    content
      .alert(
        PlaybackRateWriteFailurePresentation.alertTitle,
        isPresented: Binding(
          get: {
            PlaybackRateWriteFailurePresentation.isAlertPresented(
              for: playbackRate.writeFailureMessage)
          },
          set: { isPresented in
            if isPresented == false {
              playbackRate.dismissWriteFailure()
            }
          })
      ) {
        Button("OK", role: .cancel) {
          playbackRate.dismissWriteFailure()
        }
      } message: {
        Text(playbackRate.writeFailureMessage ?? "")
      }
  }
}

extension View {
  /// Presents the shared explanation for a speed the database did not accept. It belongs at the
  /// app root for the reason `playbackStartFailureAlert` does: the surfaces that write a speed span
  /// the shell, the presented player and its sheets, and the system's own remote controls.
  func playbackRateWriteFailureAlert(_ playbackRate: PlaybackRateCoordinator) -> some View {
    modifier(PlaybackRateWriteFailureAlertModifier(playbackRate: playbackRate))
  }
}
