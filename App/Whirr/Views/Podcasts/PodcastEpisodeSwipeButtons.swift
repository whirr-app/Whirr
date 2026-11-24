import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// What a swipe button fills its capsule with.
///
/// Must be explicit: swipe buttons fill from the inherited tint, near-white in dark mode from
/// `WhirrApp`'s scene-root `.tint(AppChrome.tint)`, under SwiftUI's white glyph and title (the
/// trap `AppChrome.onTint` documents). It also outranks `ButtonRole.destructive`'s red, so pair
/// the role with `.tint(.red)`. A token, not a `Color`, so a test can pin the fill unrendered.
enum PodcastEpisodeSwipeTint: String, Equatable {
  /// Starting the episode or moving it up the queue (the leading edge).
  case playback
  /// Bringing the episode onto this device.
  case download
  /// Taking it off again. The only red in the vocabulary: red means "this deletes bytes", so
  /// spending it on a progress edit would make one look like a deletion.
  case remove
  /// Recording the episode as listened to.
  case finished
  /// Sending it back to the beginning.
  case reset
  /// Taking it off the Saved for Later shelf. Not `.remove`: removing a bookmark deletes no
  /// bytes, and red is reserved for the action that does. Both sit on the same edge on that
  /// shelf, so a shared fill would say they did the same thing.
  case savedRemoval

  var color: Color {
    switch self {
    case .playback: .blue
    case .download: .green
    case .remove: .red
    case .finished: .indigo
    case .reset: .orange
    case .savedRemoval: .purple
    }
  }
}

/// One swipe button, on either screen that shows a podcast episode.
///
/// Distinct from the long-press menu's `MediaContextAction` because a swipe button adds a fill
/// (above) and a label short enough not to resize the target. Id, glyph, hint and role are copied
/// from the menu's one table by `PodcastShowViewPresentation.swipeButton(for:)`, so they can't
/// diverge.
struct PodcastEpisodeSwipeButton: Identifiable, Equatable {
  let id: String
  /// The visible title, shortened to hold the capsule at its minimum width.
  let label: String
  /// What VoiceOver announces: the menu's full phrasing. Shortening the drawn label is a layout
  /// decision and must not shorten what the button is called.
  let accessibilityLabel: String
  let hint: String
  let systemImage: String
  let role: MediaActionRole
  let tint: PodcastEpisodeSwipeTint
}

/// One swipe edge's buttons, for either screen. A `@ViewBuilder` function returning `ForEach`, not
/// a wrapper `View`: `.swipeActions` expects `ForEach` as the container. Callers execute
/// differently (`PodcastShowModel`, `ItemActionsModel`), so only rendering is shared.
///
/// Order is `PodcastEpisodeSwipeActions`'; SwiftUI draws outward from the edge, so the first is
/// outermost. Glyph names aren't `.fill` variants, as SwiftUI fills swipe labels itself.
///
/// The menu role is not passed to the `Button`: in `swipeActions` `.destructive` lets SwiftUI
/// delete the source List row and collapse it. Remove Download deletes device bytes, not the
/// episode, so its explicit red tint carries the warning without a row transition.
@ViewBuilder
func podcastEpisodeSwipeButtons(
  _ buttons: [PodcastEpisodeSwipeButton],
  perform: @escaping (PodcastEpisodeSwipeButton) -> Void
) -> some View {
  ForEach(buttons) { button in
    Button {
      perform(button)
    } label: {
      Label(button.label, systemImage: button.systemImage)
    }
    .tint(button.tint.color)
    .accessibilityLabel(button.accessibilityLabel)
    .accessibilityHint(button.hint)
  }
}

extension PlaybackModel {
  /// The `isPlaybackIntended` a swipe policy reads for one row. Only the now-playing row reads the
  /// player's flag, so a play/pause toggle invalidates that row's swipe and not every visible row.
  func swipeIsPlaybackIntended(
    identity: ListeningIdentity?, nowPlaying: ListeningIdentity?
  ) -> Bool {
    identity != nil && identity == nowPlaying && isPlaybackIntended
  }

  /// A leading swipe's Play or Pause. The loaded row toggles in place, so Play resumes the
  /// prepared session rather than opening another; any other row starts. Each verb acts only
  /// while it still matches the player, so a capsule drawn just before the state flipped does not
  /// do the opposite of what it said.
  func performSwipePlayback(pause: Bool, itemID: String, episodeID: String?) async {
    if isLoaded(itemID: itemID, episodeID: episodeID) {
      if isPlaybackIntended(for: itemID, episodeID: episodeID) == pause {
        togglePlayPause(itemID: itemID, episodeID: episodeID)
      }
    } else if pause == false {
      await start(itemID: itemID, episodeID: episodeID)
    }
  }
}
