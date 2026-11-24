import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension PodcastShowModelTests {
  /// The outbox writes one row per episode and drains them individually, so an unbounded "mark
  /// all" on a 400-episode show would be 400 PATCHes. The visible filter is the bound, which
  /// matches the real use of marking all from the Unplayed filter.
  @MainActor
  @Test func markAllAppliesToFilteredEpisodesOnly() async {
    let reading = PodcastShowFixtureReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: episodeIntents)
    reading.push(
      [
        Self.episode(id: "unplayed-1"),
        Self.episode(id: "played-1", isPlayed: true),
        Self.episode(id: "unplayed-2"),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 3 }

    model.filter = .unplayed
    await model.markAllAsPlayed()

    #expect(
      await episodeIntents.calls == [
        .markAll(
          "show-1",
          [
            EpisodeProgressChange(episodeID: "unplayed-1", currentTime: 120),
            EpisodeProgressChange(episodeID: "unplayed-2", currentTime: 120),
          ],
          true)
      ],
      "the played episode was filtered out of view, so it is out of scope")
  }

  /// Nothing to do is not an action. A batch that would re-finish already-finished episodes burns
  /// outbox rows and server round trips to change nothing.
  @MainActor
  @Test func markAllSkipsAlreadyFinished() async {
    let reading = PodcastShowFixtureReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: episodeIntents)
    reading.push(
      [Self.episode(id: "done", isFinished: true), Self.episode(id: "todo")], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }

    await model.markAllAsPlayed()

    #expect(
      await episodeIntents.calls == [
        .markAll("show-1", [EpisodeProgressChange(episodeID: "todo", currentTime: 120)], true)
      ])

    // And the mirror image: un-marking skips the ones that were never finished.
    await episodeIntents.reset()
    await model.markAllAsUnplayed()
    #expect(
      await episodeIntents.calls == [
        .markAll("show-1", [EpisodeProgressChange(episodeID: "done", currentTime: 0)], false)
      ])
  }

  @MainActor
  @Test("a mark-all with nothing left to change performs no intent at all")
  func markAllWithNothingToDoIsANoOp() async {
    let reading = PodcastShowFixtureReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: episodeIntents)
    reading.push([Self.episode(id: "done", isFinished: true)], itemID: "show-1")
    await waitUntil { model.episodes.count == 1 }

    await model.markAllAsPlayed()

    #expect(await episodeIntents.calls.isEmpty)
  }

  /// An episode the server has no stored audio for cannot be fetched, and asking anyway would
  /// queue a transfer that can only fail. `.download` is withheld from its own menu for the same
  /// reason.
  @MainActor
  @Test func downloadAllUnplayedSkipsUnavailableOnServer() async {
    let reading = PodcastShowFixtureReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: episodeIntents)
    reading.push(
      [
        Self.episode(id: "fetchable"),
        Self.episode(id: "no-audio", isAvailableOnServer: false),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }
    model.filter = .unplayed

    await model.downloadAllInFilter()

    #expect(await episodeIntents.calls == [.download("show-1", "fetchable")])
  }

  /// Downloads already on the device, in flight, or queued are left alone. Re-requesting them
  /// would churn the transfer queue to arrive exactly where it started.
  @MainActor
  @Test func downloadAllUnplayedSkipsAlreadyDownloaded() async {
    let reading = PodcastShowFixtureReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: episodeIntents)
    reading.push(
      [
        Self.episode(id: "done", downloadStatus: .completed),
        Self.episode(id: "in-flight", downloadStatus: .downloading(progressFraction: 0.3)),
        Self.episode(id: "queued", downloadStatus: .queued),
        Self.episode(id: "held", downloadStatus: .waitingForWiFi),
        Self.episode(id: "todo"),
        // A failed or paused transfer is resumable, not re-requestable. The episode's own
        // control offers Resume, and a bulk download must not fight it.
        Self.episode(id: "stalled", downloadStatus: .paused),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 6 }
    model.filter = .unplayed

    await model.downloadAllInFilter()

    #expect(await episodeIntents.calls == [.download("show-1", "todo")])
  }

  /// The mirror image: only episodes with something actually on the device are purged, and an
  /// already-deleting one is left to finish.
  @MainActor
  @Test func removeAllDownloadsCoversOnlyEpisodesWithSomethingOnTheDevice() async {
    let reading = PodcastShowFixtureReading()
    let episodeIntents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: episodeIntents)
    reading.push(
      [
        Self.episode(id: "done", downloadStatus: .completed),
        Self.episode(id: "in-flight", downloadStatus: .downloading(progressFraction: 0.3)),
        Self.episode(id: "nothing-here"),
        Self.episode(id: "already-going", downloadStatus: .deleting),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 4 }

    await model.removeAllDownloadsInFilter()

    #expect(
      await episodeIntents.calls == [
        .removeDownload("show-1", "done"), .removeDownload("show-1", "in-flight"),
      ])
  }

  @MainActor
  @Test func selectedActionsRespectSelectionEligibilityAndFilter() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push(
      [
        Self.episode(id: "wanted"),
        Self.episode(id: "unselected"),
        Self.episode(id: "downloaded", downloadStatus: .completed),
        Self.episode(id: "unavailable", isAvailableOnServer: false),
        Self.episode(id: "finished", isPlayed: true, isFinished: true),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 5 }
    model.filter = .unplayed
    let selected: Set<String> = ["wanted", "downloaded", "unavailable", "finished", "missing"]
    await model.performSelectedAction(.download, episodeIDs: selected)
    #expect(await intents.calls == [.download("show-1", "wanted")])
    await intents.reset()
    await model.performSelectedAction(.markAsFinished, episodeIDs: selected)
    #expect(
      await intents.calls == [
        .markAll(
          "show-1",
          [
            EpisodeProgressChange(episodeID: "wanted", currentTime: 120),
            EpisodeProgressChange(episodeID: "downloaded", currentTime: 120),
            EpisodeProgressChange(episodeID: "unavailable", currentTime: 120),
          ], true)
      ])
    await intents.reset()
    await model.performSelectedAction(.removeDownload, episodeIDs: selected)
    #expect(await intents.calls == [.removeDownload("show-1", "downloaded")])
    await intents.reset()
    await model.performSelectedAction(.download, episodeIDs: [])
    await model.performSelectedAction(.playPause, episodeIDs: selected)
    #expect(await intents.calls.isEmpty)
  }

  @MainActor
  @Test func selectedBatchRetainsFailureAfterLaterSuccess() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push([Self.episode(id: "first"), Self.episode(id: "second")], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }
    await intents.failNext()
    await model.performSelectedAction(.download, episodeIDs: ["first", "second"])
    #expect(await intents.calls == [.download("show-1", "second")])
    #expect(model.actionErrorMessage != nil)
    await model.performSelectedAction(.download, episodeIDs: ["no-longer-visible"])
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test func selectedQueueRespectsNowPlayingAndPreservesListOrder() async throws {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push([Self.episode(id: "first"), Self.episode(id: "current"), Self.episode(id: "last")], itemID: "show-1")
    await waitUntil { model.episodes.count == 3 }
    let ids: Set<String> = ["last", "current", "first"]
    await model.performSelectedAction(.addToUpNext, episodeIDs: ids)
    #expect(await intents.calls.isEmpty)
    let current = try #require(ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "current"))
    await model.performSelectedAction(.addToUpNext, episodeIDs: ids, nowPlaying: current)
    #expect(await intents.calls == [.addToUpNext("show-1", "first"), .addToUpNext("show-1", "last")])
  }

  @MainActor
  @Test func selectedResetIncludesPartialProgressAndSkipsUntouchedEpisodes() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push(
      [
        Self.episode(id: "partial", isPlayed: true), Self.episode(id: "done", isFinished: true),
        Self.episode(id: "new"),
      ], itemID: "show-1")
    await waitUntil { model.episodes.count == 3 }
    await model.performSelectedAction(.resetProgress, episodeIDs: ["partial", "done", "new"])
    #expect(
      await intents.calls == [
        .markAll(
          "show-1",
          [
            EpisodeProgressChange(episodeID: "partial", currentTime: 0),
            EpisodeProgressChange(episodeID: "done", currentTime: 0),
          ], false)
      ])
  }

  @MainActor
  @Test func selectedSaveWaitsForMembershipAndSkipsAlreadySavedEpisodes() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let savedReading = FakeSavedShelfReading()
    let status = SavedStatusStore(savedShelf: savedReading)
    let model = PodcastShowModel(
      itemID: "show-1", reading: reading, episodeIntents: intents, savedStatus: status)
    reading.push([Self.episode(id: "saved"), Self.episode(id: "new")], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }
    await model.performSelectedAction(.saveForLater, episodeIDs: ["saved", "new"])
    #expect(await intents.calls.isEmpty)
    savedReading.pushSavedIdentities([.podcastEpisode(itemID: "show-1", episodeID: "saved")])
    await waitUntil { model.isSaved(episodeID: "saved") == true }
    await model.performSelectedAction(.saveForLater, episodeIDs: ["saved", "new"])
    #expect(await intents.calls == [.saveForLater("show-1", "new")])
  }

  // MARK: Which episodes a selected batch reports as succeeded

  @MainActor
  @Test func selectedLoopReportsOnlyTheEpisodesThatSucceeded() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push(
      [Self.episode(id: "first"), Self.episode(id: "middle"), Self.episode(id: "last")], itemID: "show-1")
    await waitUntil { model.episodes.count == 3 }
    await intents.fail(episodeIDs: ["middle"])
    let succeeded = await model.performSelectedAction(.download, episodeIDs: ["first", "middle", "last"])
    #expect(succeeded == ["first", "last"])
    // The loop carried on past the failure, and the failure's copy outlived the later success.
    #expect(await intents.calls == [.download("show-1", "first"), .download("show-1", "last")])
    #expect(model.actionErrorMessage != nil)
  }

  @MainActor
  @Test func selectedLoopReportsEveryEpisodeWhenNothingFails() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push([Self.episode(id: "first"), Self.episode(id: "second")], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }
    let succeeded = await model.performSelectedAction(.download, episodeIDs: ["first", "second"])
    #expect(succeeded == ["first", "second"])
    #expect(model.actionErrorMessage == nil)
  }

  /// Marking is one bulk call, so every target succeeds or none does.
  @MainActor
  @Test func selectedBulkMarkReportsAllOrNothing() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push([Self.episode(id: "first"), Self.episode(id: "second")], itemID: "show-1")
    await waitUntil { model.episodes.count == 2 }
    let marked = await model.performSelectedAction(.markAsFinished, episodeIDs: ["first", "second"])
    #expect(marked == ["first", "second"])

    // The fixture's episodes stay unplayed, so they are still eligible for a second mark.
    await intents.failNext()
    let failed = await model.performSelectedAction(.markAsFinished, episodeIDs: ["first", "second"])
    #expect(await intents.calls.count == 1)
    #expect(failed.isEmpty)
    #expect(model.actionErrorMessage != nil)
  }

  @MainActor
  @Test func selectedBatchWithNothingToRunReportsNothing() async {
    let reading = PodcastShowFixtureReading()
    let intents = PodcastShowFixtureEpisodeIntents()
    let model = PodcastShowModel(itemID: "show-1", reading: reading, episodeIntents: intents)
    reading.push([Self.episode(id: "first", downloadStatus: .completed)], itemID: "show-1")
    await waitUntil { model.episodes.count == 1 }
    #expect(await model.performSelectedAction(.download, episodeIDs: []).isEmpty)
    #expect(await model.performSelectedAction(.download, episodeIDs: ["first"]).isEmpty)
    #expect(await model.performSelectedAction(.playPause, episodeIDs: ["first"]).isEmpty)
    #expect(await model.performSelectedAction(.saveToServer, episodeIDs: ["first"]).isEmpty)
    #expect(await intents.calls.isEmpty)
  }
}
