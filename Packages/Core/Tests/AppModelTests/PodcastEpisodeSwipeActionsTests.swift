import Persistence
import Testing

@testable import AppModel

@Suite("Podcast episode swipe actions")
struct PodcastEpisodeSwipeActionsTests {
  private static let episodeIdentity = ListeningIdentity.podcastEpisode(
    itemID: "show-1", episodeID: "episode-1")
  private static let otherIdentity = ListeningIdentity.podcastEpisode(
    itemID: "show-2", episodeID: "episode-2")

  @Test("all download action cases map to the expected trailing device action")
  func downloadActionMapsToTrailingDeviceAction() {
    let cases: [(ItemContextMenuDownloadAction, Bool, [MediaItemAction])] = [
      (.download, true, [.download]),
      (.remove, true, [.removeDownload]),
      (.unavailable, true, []),
    ]

    for (deviceAction, isAvailableOnServer, expectedDeviceActions) in cases {
      let actions = PodcastEpisodeSwipeActions.actions(
        deviceAction: deviceAction,
        isAvailableOnServer: isAvailableOnServer,
        playbackStatus: nil,
        identity: Self.episodeIdentity,
        nowPlaying: nil, isPlaybackIntended: false)

      #expect(Array(actions.trailing.prefix(expectedDeviceActions.count)) == expectedDeviceActions)
    }
  }

  @Test("an unavailable server never produces a download swipe action")
  func unavailableServerDoesNotProduceDownload() {
    let actions = PodcastEpisodeSwipeActions.actions(
      deviceAction: .download,
      isAvailableOnServer: false,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: nil, isPlaybackIntended: false)

    #expect(actions.trailing.contains(.download) == false)
  }

  @Test("leading action follows the four player states")
  func leadingActionFollowsPlayerState() {
    let somethingElsePlaying = PodcastEpisodeSwipeActions.actions(
      deviceAction: .unavailable,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: Self.otherIdentity, isPlaybackIntended: false)
    let nothingPlayingOrRetained = PodcastEpisodeSwipeActions.actions(
      deviceAction: .unavailable,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: nil, isPlaybackIntended: false)
    let thisRowIsPlaying = PodcastEpisodeSwipeActions.actions(
      deviceAction: .unavailable,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: Self.episodeIdentity, isPlaybackIntended: true)
    let thisRowIsPaused = PodcastEpisodeSwipeActions.actions(
      deviceAction: .unavailable,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: Self.episodeIdentity, isPlaybackIntended: false)

    #expect(somethingElsePlaying.leading == [.playNext])
    #expect(nothingPlayingOrRetained.leading == [.playPause])
    #expect(nothingPlayingOrRetained.pausesPlayback == false)
    #expect(thisRowIsPlaying.leading == [.playPause])
    #expect(thisRowIsPlaying.pausesPlayback)
    #expect(thisRowIsPaused.leading == [.playPause])
    #expect(thisRowIsPaused.pausesPlayback == false)
    #expect(somethingElsePlaying.leading.contains(.addToUpNext) == false)
  }

  @Test("trailing actions contain a device entry followed by one progress entry")
  func trailingActionsHaveDeviceThenOneProgressEntry() {
    let cases: [(ItemContextMenuDownloadAction, Bool, [MediaItemAction])] = [
      (.download, true, [.download]),
      (.download, false, []),
      (.remove, true, [.removeDownload]),
      (.unavailable, true, []),
    ]

    for (deviceAction, isAvailableOnServer, deviceEntries) in cases {
      let actions = PodcastEpisodeSwipeActions.actions(
        deviceAction: deviceAction,
        isAvailableOnServer: isAvailableOnServer,
        playbackStatus: nil,
        identity: Self.episodeIdentity,
        nowPlaying: nil, isPlaybackIntended: false)

      #expect(actions.trailing == deviceEntries + [.markAsFinished])
      #expect(actions.trailing.filter { $0 == .markAsFinished || $0 == .resetProgress }.count == 1)
    }
  }

  @Test("the progress capsule uses the first action from the shared three-state policy")
  func progressCapsuleUsesFirstSharedPolicyAction() {
    let untouched = PodcastEpisodeSwipeActions.actions(
      deviceAction: .unavailable,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: nil, isPlaybackIntended: false)
    let inProgress = PodcastEpisodeSwipeActions.actions(
      deviceAction: .unavailable,
      isAvailableOnServer: true,
      playbackStatus: .inProgress,
      identity: Self.episodeIdentity,
      nowPlaying: nil, isPlaybackIntended: false)
    let finished = PodcastEpisodeSwipeActions.actions(
      deviceAction: .unavailable,
      isAvailableOnServer: true,
      playbackStatus: .finished,
      identity: Self.episodeIdentity,
      nowPlaying: nil, isPlaybackIntended: false)

    #expect(untouched.trailing == [.markAsFinished])
    #expect(inProgress.trailing == [.markAsFinished])
    #expect(finished.trailing == [.resetProgress])
  }

  /// The surfaces where a swipe and a menu share a row. `.episodeDetail` is excluded: it has no
  /// swipe, and its menu omits the controls the sheet already presents. A list row's menu carries
  /// them all, so a swipe there must never offer something its menu withholds.
  static let swipingSurfaces: [PodcastMenuSurface] = [.show, .episodeList, .card]

  @Test("every swipe action is offered by the corresponding canonical menu")
  func everySwipeActionIsOfferedByTheCanonicalMenu() {
    for status in Self.allStatuses {
      for isAvailableOnServer in [true, false] {
        let playbackStatuses: [ItemPlaybackStatus?] = [nil, .inProgress, .finished]
        for playbackStatus in playbackStatuses {
          for surface in Self.swipingSurfaces {
            let availability = ListeningQueueActionPolicy.availability(
              for: Self.episodeIdentity,
              nowPlaying: Self.otherIdentity)
            let menu = ListeningQueueActionPolicy.apply(
              availability,
              to: PodcastShowPresentation.episodeActions(
                status: status,
                isAvailableOnServer: isAvailableOnServer,
                surface: surface,
                playbackStatus: playbackStatus))
            let actions = PodcastEpisodeSwipeActions.actions(
              deviceAction: Self.deviceAction(for: status),
              isAvailableOnServer: isAvailableOnServer,
              playbackStatus: playbackStatus,
              identity: Self.episodeIdentity,
              nowPlaying: Self.otherIdentity, isPlaybackIntended: false)

            for action in actions.leading + actions.trailing {
              #expect(menu.contains(action))
            }
          }
        }
      }
    }
  }

  @Test("the swipe device action deliberately diverges from the row primary device action")
  func swipeDeviceActionDeliberatelyDivergesFromPrimaryDeviceAction() {
    let downloading = PodcastEpisodeSwipeActions.actions(
      deviceAction: .remove,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: nil, isPlaybackIntended: false)
    let completed = PodcastEpisodeSwipeActions.actions(
      deviceAction: .remove,
      isAvailableOnServer: true,
      playbackStatus: nil,
      identity: Self.episodeIdentity,
      nowPlaying: nil, isPlaybackIntended: false)

    // This divergence is intended: the swipe collapses device state to remove, rather than
    // agreeing with the fine-grained inline primary device control.
    #expect(
      PodcastShowPresentation.primaryDeviceAction(
        status: .downloading(progressFraction: 0.42), isAvailableOnServer: true)
        == .pauseDownload)
    #expect(downloading.trailing.first == .removeDownload)
    #expect(
      PodcastShowPresentation.primaryDeviceAction(
        status: .completed, isAvailableOnServer: true) == nil)
    #expect(completed.trailing.first == .removeDownload)
  }

  private static let allStatuses: [ItemDownloadStatus] = [
    .notDownloaded,
    .waitingForWiFi,
    .queued,
    .downloading(progressFraction: 0.42),
    .paused,
    .pausedAuth,
    .interrupted,
    .deleting,
    .failed(category: .transport),
    .completed,
  ]

  private static func deviceAction(for status: ItemDownloadStatus)
    -> ItemContextMenuDownloadAction
  {
    switch ItemDownloadPresence.resolve(status) {
    case .none: .download
    case .deleting: .unavailable
    case .partial, .completed: .remove
    }
  }
}
