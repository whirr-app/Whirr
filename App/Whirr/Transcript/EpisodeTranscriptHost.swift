import AppModel
import DesignSystem
import SwiftUI

/// Opens the transcript of an episode chosen from a list menu (Home, Library, Search, the show
/// screen). Nil in the environment while the app cannot transcribe, which hides the entry.
/// `accent` is the show's colour where the list knows it, nil for the app's.
struct EpisodeTranscriptOpener {
  let open: @MainActor (_ itemID: String, _ episodeID: String, _ accent: Color?) -> Void
}

extension EnvironmentValues {
  @Entry var episodeTranscriptOpener: EpisodeTranscriptOpener?
}

extension View {
  /// One transcript sheet for every list below the shell, so a list row tracks nothing: the chosen
  /// episode is tracked only once Transcript is chosen. The expanded player and the episode card
  /// keep their own, because each is itself presented and the shell cannot present over it.
  func episodeTranscriptHost(
    coordinator: EpisodeTranscriptCoordinator?, playback: PlaybackModel
  ) -> some View {
    modifier(EpisodeTranscriptHostModifier(coordinator: coordinator, playback: playback))
  }
}

private struct EpisodeTranscriptHostModifier: ViewModifier {
  let coordinator: EpisodeTranscriptCoordinator?
  let playback: PlaybackModel

  @State private var transcript = PlayerTranscriptController()
  @State private var chosen: Chosen?

  private struct Chosen: Equatable {
    let itemID: String
    let episodeID: String
  }

  /// Kept apart from `Chosen`: the same episode opened from another list is still the same one.
  @State private var showAccent: Color?

  func body(content: Content) -> some View {
    content
      .environment(\.episodeTranscriptOpener, coordinator == nil ? nil : opener)
      // The show page passes its colour; a list that does not know it leaves the app's.
      .playerTranscriptSheet(
        transcript, coordinator: coordinator, playback: playback, itemID: chosen?.itemID ?? "",
        episodeID: chosen?.episodeID, accent: .show(showAccent), chapters: { [] })
  }

  private var opener: EpisodeTranscriptOpener {
    EpisodeTranscriptOpener { itemID, episodeID, accent in
      showAccent = accent
      let next = Chosen(itemID: itemID, episodeID: episodeID)
      // The same episode again keeps its tracking, which will not report again: a nil identity
      // is already its answer.
      if next == chosen, transcript.identity == nil {
        transcript.isUnavailablePresented = true
        return
      }
      transcript.open(itemID: itemID, episodeID: episodeID)
      chosen = next
    }
  }
}
