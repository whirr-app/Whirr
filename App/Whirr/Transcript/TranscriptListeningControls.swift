import AppModel
import SwiftUI

/// What the transcript and Look Back sheets' play/pause shows. Tapping a sentence is the seek, so
/// listening along needs only a way to stop and carry on without closing the sheet.
nonisolated enum TranscriptPlayPause {
  struct Presentation: Equatable {
    let title: String
    let systemImage: String
  }

  /// Nil while the sheet's title is not the one loaded: there is nothing to pause, and playing it
  /// would start somewhere other than the text in front of the listener.
  static func presentation(isLoaded: Bool, isPlaybackIntended: Bool) -> Presentation? {
    guard isLoaded else { return nil }
    return isPlaybackIntended
      ? Presentation(title: "Pause", systemImage: "pause.fill")
      : Presentation(title: "Play", systemImage: "play.fill")
  }
}

/// The sheets' toolbar play/pause. Its own view, so the player's state re-runs this body alone and
/// not the sheet's.
struct TranscriptPlayPauseButton: View {
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  /// False hides it even when the title is loaded: Look Back offers it once a sentence has been
  /// tapped, since before that the book sits paused where Look Back opened.
  var isOffered = true

  var body: some View {
    if isOffered,
      let presentation = TranscriptPlayPause.presentation(
        isLoaded: playback.isLoaded(itemID: itemID, episodeID: episodeID),
        isPlaybackIntended: playback.isPlaybackIntended(for: itemID, episodeID: episodeID))
    {
      Button(presentation.title, systemImage: presentation.systemImage) {
        playback.togglePlayPause(itemID: itemID, episodeID: episodeID)
      }
      .contentTransition(.symbolEffect(.replace))
      .tint(.primary)
    }
  }
}

/// Back to the sentence playing, once the listener has scrolled away from it. Clear glass, not the
/// show-tinted capsule: it floats over the text, often the very sentence it returns to, which
/// should read through it.
struct TranscriptNowButton: View {
  let action: () -> Void

  var body: some View {
    Button("Now", systemImage: "arrow.down.to.line", action: action)
      .buttonStyle(.glass)
      .buttonBorderShape(.capsule)
      .controlSize(.large)
      .tint(.primary)
      .padding(.bottom, 12)
  }
}
