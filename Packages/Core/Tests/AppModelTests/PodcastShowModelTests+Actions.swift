import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension PodcastShowModelTests {
  @MainActor
  @Test("episode and refresh intents forward exactly once")
  func intentsForwardOnce() async {
    let reading = FakePodcastReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let refresh = FakePodcastRefreshing()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, refreshing: refresh,
      episodeIntents: episodeIntents)

    await model.episodeTapped("episode-1")
    await model.addToUpNext("episode-1")
    await model.download("episode-1")
    await model.pauseDownload("episode-1")
    await model.resumeDownload("episode-1")
    await model.removeDownload("episode-1")
    await model.refresh()

    #expect(
      await episodeIntents.calls == [
        .play("show-1", "episode-1"),
        .addToUpNext("show-1", "episode-1"),
        .download("show-1", "episode-1"),
        .pauseDownload("show-1", "episode-1"),
        .resumeDownload("show-1", "episode-1"),
        .removeDownload("show-1", "episode-1"),
      ])
    #expect(refresh.calls.count == 1)
  }

  @MainActor
  @Test("progress intents carry the episode's own cached duration, never the show's")
  func progressIntentsResolveTheEpisodeDuration() async {
    let reading = FakePodcastReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: episodeIntents)
    reading.pushEpisodes([Self.episode(id: "episode-1")], itemID: "show-1")
    await waitUntil { model.episodes.isEmpty == false }

    await model.markAsFinished("episode-1")
    await model.resetProgress("episode-1")

    #expect(
      await episodeIntents.calls == [
        .markAsFinished("show-1", "episode-1", 120),
        .resetProgress("show-1", "episode-1"),
      ])
  }

  /// An episode acted on before its row has arrived (or one that has since been tombstoned) has no
  /// cached duration. Recording none is right, and matches the item-level path.
  @MainActor
  @Test("marking an uncached episode finished records no duration rather than guessing one")
  func markingAnUncachedEpisodeCarriesNoDuration() async {
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: episodeIntents)

    await model.markAsFinished("episode-missing")

    #expect(await episodeIntents.calls == [.markAsFinished("show-1", "episode-missing", nil)])
  }

  @MainActor
  @Test("intent failure uses centralized recoverable copy")
  func intentFailureCopy() async {
    let intents = PodcastShowFixtureEpisodeIntents()
    await intents.failNext()
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: intents)
    await model.download("episode-1")
    #expect(model.actionErrorMessage == PodcastCopy.actionFailed)
  }

  @MainActor
  @Test("unfollow stops matching playback before deleting the feed")
  func unfollowStopsPlaybackBeforeDeletingTheFeed() async throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    let sequence = UnfollowSequence()
    let model = PodcastShowModel(
      itemID: itemID, reading: FakePodcastReading(), nativeFeedManaging: sequence,
      stopPlaybackForUnfollow: { try await sequence.stopPlayback(itemID: $0) })

    #expect(await model.unsubscribe())
    #expect(await sequence.calls == [.stop(itemID), .unsubscribe(7)])
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("a playback stop failure aborts feed deletion with actionable copy")
  func unfollowStopFailureAbortsDeletion() async throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    let sequence = UnfollowSequence(stopError: PodcastFixtureError.offline)
    let model = PodcastShowModel(
      itemID: itemID, reading: FakePodcastReading(), nativeFeedManaging: sequence,
      stopPlaybackForUnfollow: { try await sequence.stopPlayback(itemID: $0) })

    #expect(await model.unsubscribe() == false)
    #expect(await sequence.calls == [.stop(itemID)])
    #expect(model.actionErrorMessage == PodcastCopy.unsubscribePlaybackStopFailed)
  }

  @MainActor
  @Test("cancelling unfollow while playback stop is held never begins deletion")
  func cancelledUnfollowNeverBeginsDeletion() async throws {
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    let sequence = UnfollowSequence(holdsStop: true)
    let model = PodcastShowModel(
      itemID: itemID, reading: FakePodcastReading(), nativeFeedManaging: sequence,
      stopPlaybackForUnfollow: { try await sequence.stopPlayback(itemID: $0) })

    let unfollow = Task { @MainActor in await model.unsubscribe() }
    await sequence.waitUntilStopCalled()
    unfollow.cancel()
    await sequence.releaseStop()

    #expect(await unfollow.value == false)
    #expect(await sequence.calls == [.stop(itemID)])
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("an intent failure that carries its own message is shown verbatim")
  func intentFailureMessageOutranksGenericCopy() async {
    let intents = PodcastShowFixtureEpisodeIntents()
    await intents.failNext(with: PodcastEpisodeIntentFailure(message: "Specific reason."))
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: intents)
    await model.episodeTapped("episode-1")
    #expect(model.actionErrorMessage == "Specific reason.")
  }

  @MainActor
  @Test("a failed episode tap leaves the shared playback failure for the shell")
  func failedEpisodeTapLeavesSharedPlaybackFailureForShell() async {
    let sync = FakePlaybackSyncing()
    sync.stubStartSession(.failure(PodcastFixtureError.offline))
    let playback = PlaybackModelHarness(sync: sync).model
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      episodeIntents: PlaybackPodcastEpisodeIntents(
        playback: playback, queue: NoOpListeningQueueStore(),
        downloadIntents: NoOpDownloadIntents(),
        progress: ABSEpisodeProgressBackend(progressIntents: NoOpItemProgressIntents()),
        savedShelf: NoOpSavedShelfStore()))

    await model.episodeTapped("episode-1")

    #expect(playback.activeItemID == nil, "no phantom mini-player")
    #expect(playback.startFailureMessage != nil)
    #expect(model.actionErrorMessage == nil, "the shell owns the one playback failure alert")
  }

  @MainActor
  @Test("a successful episode tap leaves no stale error on the show screen")
  func successfulEpisodeTapClearsTheError() async {
    let sync = FakePlaybackSyncing()
    sync.stubStartSession(
      .success(
        PreparedPlayback(
          itemID: "show-1", episodeID: "episode-1", startPosition: 0, duration: 100,
          tracks: [
            PreparedPlaybackTrack(
              index: 0, startOffset: 0, duration: 100,
              url: URL(string: "https://example.test/episode.mp3")!,
              mimeType: "audio/mpeg", title: "episode-1")
          ], chapters: [])))
    let playback = PlaybackModelHarness(sync: sync).model
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      episodeIntents: PlaybackPodcastEpisodeIntents(
        playback: playback, queue: NoOpListeningQueueStore(),
        downloadIntents: NoOpDownloadIntents(),
        progress: ABSEpisodeProgressBackend(progressIntents: NoOpItemProgressIntents()),
        savedShelf: NoOpSavedShelfStore()))

    await model.episodeTapped("episode-1")

    #expect(playback.startFailureMessage == nil)
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("a successful Play Next sets the queue feedback message")
  func successfulPlayNextSetsQueueFeedback() async {
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: PodcastShowFixtureEpisodeIntents())

    await model.playNext("episode-1")

    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)
  }

  @MainActor
  @Test("a successful Add to Up Next sets the queue feedback message")
  func successfulAddToUpNextSetsQueueFeedback() async {
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: PodcastShowFixtureEpisodeIntents())

    await model.addToUpNext("episode-1")

    #expect(model.queueFeedbackMessage == ListeningQueueCopy.addedToUpNext)
  }

  @MainActor
  @Test("a successful non-queue action clears stale queue feedback")
  func successfulNonQueueActionClearsQueueFeedback() async {
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: PodcastShowFixtureEpisodeIntents())

    await model.playNext("episode-1")
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)

    await model.download("episode-1")

    #expect(model.queueFeedbackMessage == nil)
  }

  @MainActor
  @Test("a successful save sets saved feedback and a following queue action clears it")
  func savedFeedbackIsSupersededByQueueFeedback() async {
    let shelf = FakeSavedShelfStoring()
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      episodeIntents: PlaybackPodcastEpisodeIntents(
        playback: Self.idlePlayback(),
        queue: NoOpListeningQueueStore(),
        downloadIntents: NoOpDownloadIntents(),
        progress: ABSEpisodeProgressBackend(progressIntents: NoOpItemProgressIntents()),
        savedShelf: shelf))

    await model.performAction(.saveForLater, episodeID: "episode-1")

    #expect(model.savedFeedbackMessage == SavedForLaterCopy.saved)
    #expect(model.queueFeedbackMessage == nil)
    #expect(
      shelf.calls == [.save(.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))])

    await model.performAction(.removeFromSaved, episodeID: "episode-1")

    #expect(model.savedFeedbackMessage == SavedForLaterCopy.removed)
    #expect(
      shelf.calls == [
        .save(.podcastEpisode(itemID: "show-1", episodeID: "episode-1")),
        .remove(.podcastEpisode(itemID: "show-1", episodeID: "episode-1")),
      ])

    await model.playNext("episode-1")

    #expect(model.savedFeedbackMessage == nil)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)
  }

  @MainActor
  @Test("a duplicate save uses already-saved copy")
  func duplicateSaveUsesAlreadySavedCopy() async {
    let shelf = FakeSavedShelfStoring(saveOutcome: .alreadySaved)
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      episodeIntents: PlaybackPodcastEpisodeIntents(
        playback: Self.idlePlayback(),
        queue: NoOpListeningQueueStore(),
        downloadIntents: NoOpDownloadIntents(),
        progress: ABSEpisodeProgressBackend(progressIntents: NoOpItemProgressIntents()),
        savedShelf: shelf))

    await model.performAction(.saveForLater, episodeID: "episode-1")

    #expect(model.savedFeedbackMessage == SavedForLaterCopy.alreadySaved)
  }

  @MainActor
  @Test("saved intent failures use operation-specific copy through the executor")
  func savedIntentFailuresUseOperationSpecificCopy() async {
    let shelf = FakeSavedShelfStoring()
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      episodeIntents: PlaybackPodcastEpisodeIntents(
        playback: Self.idlePlayback(),
        queue: NoOpListeningQueueStore(),
        downloadIntents: NoOpDownloadIntents(),
        progress: ABSEpisodeProgressBackend(progressIntents: NoOpItemProgressIntents()),
        savedShelf: shelf))

    shelf.failNext(PodcastFixtureError.offline)
    await model.performAction(.saveForLater, episodeID: "episode-1")
    #expect(model.actionErrorMessage == SavedForLaterCopy.saveFailed)
    #expect(model.savedFeedbackMessage == nil)

    shelf.failNext(PodcastFixtureError.offline)
    await model.performAction(.removeFromSaved, episodeID: "episode-1")
    #expect(model.actionErrorMessage == SavedForLaterCopy.removeFailed)
    #expect(model.savedFeedbackMessage == nil)
  }

  @MainActor
  @Test("a failed Play Next sets the action error without queue feedback")
  func failedPlayNextSetsErrorWithoutQueueFeedback() async {
    let intents = PodcastShowFixtureEpisodeIntents()
    await intents.failNext()
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: intents)

    await model.playNext("episode-1")

    #expect(model.actionErrorMessage == PodcastCopy.actionFailed)
    #expect(model.queueFeedbackMessage == nil)
  }

  @MainActor
  @Test("dismissing queue feedback clears the message")
  func dismissQueueFeedbackClearsMessage() async {
    let model = PodcastShowModel(
      itemID: "show-1", reading: FakePodcastReading(), episodeIntents: PodcastShowFixtureEpisodeIntents())

    await model.playNext("episode-1")
    model.dismissQueueFeedback()

    #expect(model.queueFeedbackMessage == nil)
  }

  /// "Play Next" and "Add to Up Next" are separate actions, so both ends of the queue are
  /// reachable (`insertNext` for the front).
  @MainActor
  @Test func playNextInsertsAtFront() async throws {
    let queue = FakeListeningQueueStoring()
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      episodeIntents: PlaybackPodcastEpisodeIntents(
        playback: Self.idlePlayback(), queue: queue,
        downloadIntents: NoOpDownloadIntents(),
        progress: ABSEpisodeProgressBackend(progressIntents: NoOpItemProgressIntents()),
        savedShelf: NoOpSavedShelfStore()))

    await model.playNext("episode-1")

    #expect(queue.calls == [.insertNext(episode)])
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test func addToQueueAppends() async throws {
    let queue = FakeListeningQueueStoring()
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    let model = PodcastShowModel(
      itemID: "show-1",
      reading: FakePodcastReading(),
      episodeIntents: PlaybackPodcastEpisodeIntents(
        playback: Self.idlePlayback(), queue: queue,
        downloadIntents: NoOpDownloadIntents(),
        progress: ABSEpisodeProgressBackend(progressIntents: NoOpItemProgressIntents()),
        savedShelf: NoOpSavedShelfStore()))

    await model.addToUpNext("episode-1")

    #expect(queue.calls == [.append(episode)])
  }
}
