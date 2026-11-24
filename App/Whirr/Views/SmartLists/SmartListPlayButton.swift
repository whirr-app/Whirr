import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// A list's Play, drawn as the episode card's capsule: the same label, the same wash accent and
/// the same Play, Pause and Resume. It speaks for the list's loaded episode when the list holds
/// it, and otherwise for the next in line, and takes that episode's show colour. A view of its own
/// so playback changes redraw the button, not the list.
struct SmartListPlayButton: View {
  let model: SmartListModel
  let playback: PlaybackModel
  let washProvider: HomeWashProvider

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let motion = PodcastEpisodeCardViewPresentation.motion(reduceMotion: reduceMotion)
    let target = SmartListsPresentation.playTarget(in: model.episodes) {
      playback.isLoaded(itemID: $0.itemID, episodeID: $0.episodeID)
    }
    let subject = target?.episode.homeEpisode.washSubject
    let wash = subject.map { washProvider.wash(for: $0) } ?? .drainedNeutral
    let accent =
      PodcastEpisodeCardViewPresentation.playAccentSource(for: wash) == .wash
      ? wash.accentColor
      : nil
    let control = PodcastEpisodeCardPlayControl.resolve(
      isCurrentEpisode: target?.isLoaded == true,
      isPlaybackIntended: target.map {
        playback.isPlaybackIntended(for: $0.episode.itemID, episodeID: $0.episode.episodeID)
      } ?? false)

    Button {
      if let target, control.startsNewSession == false {
        playback.togglePlayPause(itemID: target.episode.itemID, episodeID: target.episode.episodeID)
      } else {
        Task { _ = await model.play() }
      }
    } label: {
      Label {
        Text(SmartListsPresentation.playControlTitle(control))
          .contentTransition(motion.textTransition)
      } icon: {
        Image(systemName: control.systemImage)
          .contentTransition(motion.symbolTransition)
      }
      .playCapsuleLabel()
      // `.borderedProminent` paints its label white whatever the tint, and `AppChrome.tint` is
      // near-white in dark mode (see `AppChrome.onTint`).
      .foregroundStyle(AppChrome.onTint)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .tint(accent ?? AppChrome.tint)
    .animation(motion.controlAnimation, value: control)
    .disabled(control.startsNewSession && (model.isStarting || model.episodes.isEmpty))
    .task(id: subject) {
      guard let subject else { return }
      washProvider.request(
        [subject], intent: .visible, displaySize: PodcastEpisodeCardRowMetrics.coverSize,
        artworkRole: .libraryThumbnail)
    }
  }
}
