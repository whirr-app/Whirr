import AppModel
import Persistence
import SwiftUI

/// The swipe vocabulary a latest-episode row carries, wherever that row is listed.
///
/// Which actions a swipe offers is a property of the episode (downloaded, playing, finished), not
/// the screen. The Latest Episodes shelf and its drill-down render the same
/// `PodcastEpisodeCardRow`, so resolution, rendering and execution live here. The show screen
/// routes through `PodcastShowModel` and shares only the button vocabulary
/// (`PodcastShowViewPresentation.swipeButtons(for:)`).
struct PodcastEpisodeSwipeActionsModifier: ViewModifier {
  let episode: PodcastEpisodeSwipeSubject
  let nowPlaying: ListeningIdentity?
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// A selecting row offers no capsules; the arrays empty rather than the modifier dropping, so the
  /// row keeps its view type across the transition.
  var isSelecting = false
  /// A smart list's Hide, the innermost trailing action. The other lists pass nil.
  var hide: (() -> Void)?

  /// No branch around `content`: a `List` can only count a row without building it when every
  /// modifier on the row yields one view unconditionally. What varies is the buttons.
  func body(content: Content) -> some View {
    let buttons = resolvedButtons()
    return
      content
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        podcastEpisodeSwipeButtons(buttons.leading) { perform($0) }
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        podcastEpisodeSwipeButtons(buttons.trailing) { perform($0) }
        ForEach(hideTitles, id: \.self) { title in
          Button {
            hide?()
          } label: {
            Label(title, systemImage: "eye.slash")
          }
          .tint(.gray)
        }
      }
  }

  /// Hide's title when the row offers it, as an array so the swipe body stays unconditional.
  var hideTitles: [String] {
    hide == nil || isSelecting ? [] : [SmartListRowCopy.hide]
  }

  /// Empty while selecting. `ItemSwipeActionsModifier` renders an episode row from this and
  /// `perform(_:)`, so an episode swipes the same from either modifier.
  func resolvedButtons() -> (
    leading: [PodcastEpisodeSwipeButton], trailing: [PodcastEpisodeSwipeButton]
  ) {
    #if DEBUG
      if HarnessAblation.noSwipeActions { return ([], []) }
    #endif
    guard isSelecting == false else { return ([], []) }
    let identity = ListeningQueueActionPolicy.identity(
      itemID: episode.itemID, episodeID: episode.episodeID, category: .podcast)
    let buttons = PodcastsViewPresentation.swipeButtons(
      deviceAction: actions.downloadAction(for: episode.itemID, episodeID: episode.episodeID),
      itemID: episode.itemID,
      episodeID: episode.episodeID,
      playbackStatus: episode.playbackStatus,
      nowPlaying: nowPlaying,
      isPlaybackIntended: playback.swipeIsPlaybackIntended(
        identity: identity, nowPlaying: nowPlaying))
    return (buttons?.leading ?? [], buttons?.trailing ?? [])
  }

  func perform(_ button: PodcastEpisodeSwipeButton) {
    guard let action = MediaItemAction(actionID: button.id) else { return }

    Task {
      switch action {
      case .playPause:
        await playback.performSwipePlayback(
          pause: button == PodcastShowViewPresentation.pauseSwipeButton, itemID: episode.itemID,
          episodeID: episode.episodeID)
      case .playNext:
        await actions.playNext(itemID: episode.itemID, episodeID: episode.episodeID)
      case .download:
        await actions.requestDownload(
          itemID: episode.itemID, episodeID: episode.episodeID)
      case .removeDownload:
        await actions.removeDownload(itemID: episode.itemID, episodeID: episode.episodeID)
      case .markAsFinished:
        await PodcastEpisodeProgressActions(actions: actions, playback: playback).markAsFinished(
          itemID: episode.itemID, episodeID: episode.episodeID, duration: episode.durationSeconds)
      case .resetProgress:
        await PodcastEpisodeProgressActions(actions: actions, playback: playback).resetProgress(
          itemID: episode.itemID, episodeID: episode.episodeID)
      default:
        return
      }
    }
  }
}

/// The episode facts a swipe reads. An episode reaches lists as a `HomePodcastEpisode` and, on
/// Home's item drill-downs, as a `HomeItem`; both map here so the episode swipes the same either
/// way.
struct PodcastEpisodeSwipeSubject: Equatable {
  let itemID: String
  let episodeID: String
  let playbackStatus: ItemPlaybackStatus?
  let durationSeconds: Double?

  init(
    itemID: String, episodeID: String, playbackStatus: ItemPlaybackStatus?,
    durationSeconds: Double?
  ) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.playbackStatus = playbackStatus
    self.durationSeconds = durationSeconds
  }

  init(_ episode: HomePodcastEpisode) {
    self.init(
      itemID: episode.itemID, episodeID: episode.episodeID,
      playbackStatus: PodcastEpisodeListeningState(
        progressSeconds: episode.progressSeconds, durationSeconds: episode.durationSeconds,
        isFinished: episode.isFinished
      ).playbackStatus,
      durationSeconds: episode.durationSeconds)
  }
}

extension View {
  /// The canonical swipe actions for a `PodcastEpisodeCardRow` in a `List`. Every screen that lists
  /// one applies this (`PodcastEpisodeRowParityTests` pins it).
  func podcastEpisodeSwipeActions(
    episode: HomePodcastEpisode,
    nowPlaying: ListeningIdentity?,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    hide: (() -> Void)? = nil
  ) -> some View {
    modifier(
      PodcastEpisodeSwipeActionsModifier(
        episode: PodcastEpisodeSwipeSubject(episode), nowPlaying: nowPlaying, playback: playback,
        actions: actions, hide: hide))
  }
}
