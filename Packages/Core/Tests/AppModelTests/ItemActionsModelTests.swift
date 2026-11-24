import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `ItemActionsModel` is one screen's model, not one row's, so rows do not build a model on every
/// throwaway SwiftUI `View.init` just to carry an item id and an error string.
@Suite("Item actions model")
@MainActor
struct ItemActionsModelTests {
  @Test(
    "download action is download only when no local download exists",
    arguments: [
      (ItemDownloadStatus.notDownloaded, ItemContextMenuDownloadAction.download),
      (ItemDownloadStatus.queued, ItemContextMenuDownloadAction.remove),
      (ItemDownloadStatus.downloading(progressFraction: 0.4), ItemContextMenuDownloadAction.remove),
      (ItemDownloadStatus.paused, ItemContextMenuDownloadAction.remove),
      (ItemDownloadStatus.completed, ItemContextMenuDownloadAction.remove),
      (ItemDownloadStatus.deleting, ItemContextMenuDownloadAction.unavailable),
    ])
  func downloadActionTracksPresence(
    status: ItemDownloadStatus,
    expected: ItemContextMenuDownloadAction
  ) {
    #expect(ItemContextMenuDownloadAction.resolve(status) == expected)
  }

  @Test("one model serves every row on the screen and opens no observation")
  func oneModelServesEveryRow() {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    _ = makeModel(downloadStatus: store)

    #expect(reading.presenceSubscriptionCount == 1)
  }

  @Test("reset and finish actions forward the selected item and duration")
  func progressActionsForward() async {
    let progress = FakeItemProgressIntents()
    let model = makeModel(progress: progress)

    await model.resetProgress(itemID: "book-1")
    await model.markAsFinished(itemID: "book-2", duration: 3_600)

    #expect(await progress.actions == [.reset("book-1"), .finish("book-2", 3_600)])
  }

  @Test("Continue Listening removal forwards the visibility intent and confirms success")
  func continueListeningRemovalSucceeds() async {
    let progress = FakeItemProgressIntents()
    let model = makeModel(progress: progress)

    await model.removeFromContinueListening(itemID: "show-1", episodeID: "ep-1")

    #expect(
      await progress.actions
        == [.continueListeningVisibility("show-1", "ep-1", true)])
    #expect(model.continueListeningFeedbackMessage == ContinueListeningCopy.removed)
  }

  @Test("a failed Continue Listening removal uses the settled failure copy")
  func continueListeningRemovalFails() async {
    let progress = FakeItemProgressIntents(fails: true)
    let model = makeModel(progress: progress)

    await model.removeFromContinueListening(itemID: "book-1")

    #expect(model.actionErrorMessage == ContinueListeningCopy.removeFailed)
    #expect(model.continueListeningFeedbackMessage == nil)
  }

  @Test("an ebook reset uses the ebook progress intent")
  func ebookResetUsesEbookProgressIntent() async {
    let progress = FakeItemProgressIntents()
    let model = makeModel(progress: progress)

    await model.resetProgress(itemID: "ebook-1", category: .ebook)

    #expect(await progress.actions == [.resetEbook("ebook-1")])
  }

  @Test("an episode-scoped reset or finish carries the episode through to the intents")
  func episodeProgressActionsForwardTheEpisode() async {
    let progress = FakeItemProgressIntents()
    let model = makeModel(progress: progress)

    await model.resetProgress(itemID: "show-1", episodeID: "ep-1")
    await model.markAsFinished(itemID: "show-1", episodeID: "ep-2", duration: 2_400)

    #expect(
      await progress.actions == [
        .reset("show-1", "ep-1"), .finish("show-1", "ep-2", 2_400),
      ])
  }

  @Test("an episode download routes to the episode intents, not the whole show's")
  func episodeDownloadIntentsAreEpisodeScoped() async {
    let intents = FakeDownloadIntents()
    let model = makeModel(downloadIntents: intents)

    await model.requestDownload(itemID: "show-1", episodeID: "ep-1")
    await model.removeDownload(itemID: "show-1", episodeID: "ep-1")

    #expect(
      intents.calls == [
        .requestEpisodeDownload(itemID: "show-1", episodeID: "ep-1"),
        .purgeEpisodeDownload(
          itemID: "show-1", episodeID: "ep-1", source: .contextMenu),
      ])
  }

  @Test("an ebook download uses the ebook intent, never the audio intent")
  func ebookFormatRequestDownloadUsesEbookIntent() async {
    let intents = FakeDownloadIntents()
    let model = makeModel(downloadIntents: intents)

    await model.requestDownload(itemID: "book-1", format: .ebook)

    #expect(intents.calls == [.requestEbookDownload(itemID: "book-1")])
  }

  @Test("an audio download keeps using the audio intent")
  func audioFormatRequestDownloadUsesAudioIntent() async {
    let intents = FakeDownloadIntents()
    let model = makeModel(downloadIntents: intents)

    await model.requestDownload(itemID: "book-1", format: .audio)

    #expect(intents.calls == [.requestDownload(itemID: "book-1")])
  }

  /// A mixed audiobook + EPUB is `.audiobook` by `ItemMediaCategory`, so deciding by category
  /// would fetch audio alone. Both surfaces expand the same `ItemDownloadFormat` through the same
  /// `DownloadIntents` helper.
  @Test("both manual download surfaces fetch both media for a mixed audiobook + EPUB")
  func mixedItemFetchesBothMediaFromEitherSurface() async {
    #expect(
      ItemMediaCapability.derive(category: .audiobook, hasReadableEbook: true) == .audioAndEbook)

    let rowMenuIntents = FakeDownloadIntents()
    await makeModel(downloadIntents: rowMenuIntents)
      .requestDownload(itemID: "book-1", format: .both)

    let reading = FakeDownloadReading()
    let bubbleIntents = FakeDownloadIntents()
    let bubble = ItemDownloadModel(
      itemID: "book-1", downloadReading: reading, downloadIntents: bubbleIntents)
    reading.pushStatus(.notDownloaded, itemId: "book-1")
    await waitUntil { bubble.status == .notDownloaded }
    await bubble.requestDownload(format: .both)

    for calls in [rowMenuIntents.calls, bubbleIntents.calls] {
      #expect(calls.count == 2)
      #expect(calls.contains(.requestDownload(itemID: "book-1")))
      #expect(calls.contains(.requestEbookDownload(itemID: "book-1")))
    }
  }

  @Test("an episode download intent is refused while that episode is mid-removal")
  func episodeDownloadIntentsAreGatedOnTheEpisodesOwnPresence() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    let intents = FakeDownloadIntents()
    let model = makeModel(downloadStatus: store, downloadIntents: intents)

    reading.pushEpisodePresence([
      EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-1"): .deleting
    ])
    await waitUntil { store.presence(for: "show-1", episodeID: "ep-1") == .deleting }

    await model.requestDownload(itemID: "show-1", episodeID: "ep-1")
    await model.removeDownload(itemID: "show-1", episodeID: "ep-1")
    // A sibling episode is unaffected: the gate reads the acted-on episode's own state.
    await model.requestDownload(itemID: "show-1", episodeID: "ep-2")

    #expect(intents.calls == [.requestEpisodeDownload(itemID: "show-1", episodeID: "ep-2")])
  }

  @Test("only an episode whose download has finished counts as downloaded")
  func episodeDownloadIsCompleteOnlyWhenEveryRowIs() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    let model = makeModel(downloadStatus: store)

    reading.pushEpisodePresence([
      EpisodeDownloadKey(itemID: "show-1", episodeID: "done"): .completed,
      EpisodeDownloadKey(itemID: "show-1", episodeID: "queued"): .partial,
      EpisodeDownloadKey(itemID: "show-1", episodeID: "going"): .deleting,
    ])
    await waitUntil { store.presence(for: "show-1", episodeID: "done") == .completed }

    #expect(model.isDownloadComplete(itemID: "show-1", episodeID: "done"))
    #expect(model.isDownloadComplete(itemID: "show-1", episodeID: "queued") == false)
    #expect(model.isDownloadComplete(itemID: "show-1", episodeID: "going") == false)
    #expect(model.isDownloadComplete(itemID: "show-1", episodeID: "absent") == false)
  }

  @Test("narrator metadata is lazy, per item, and fetched at most once per item")
  func narratorIsLazyPerItemAndFetchedOnce() async {
    let extras = FakeItemDetailExtrasAccess(
      result: ItemDetailExtras(seriesName: "Series", narrator: "Julia Whelan", chapters: []))
    let model = makeModel(extras: extras)

    #expect(extras.callCount == 0)
    #expect(model.narrator(for: "book-1") == nil)

    await model.loadExtrasIfNeeded(itemID: "book-1")
    await model.loadExtrasIfNeeded(itemID: "book-1")
    #expect(model.narrator(for: "book-1") == "Julia Whelan")
    #expect(extras.callCount == 1)

    // A second item is a separate cache entry, not a shared one.
    await model.loadExtrasIfNeeded(itemID: "book-2")
    #expect(model.narrator(for: "book-2") == "Julia Whelan")
    #expect(model.narrator(for: "book-3") == nil)
    #expect(extras.callCount == 2)
  }

  @Test("a narrator action joins the preview's in-flight extras request")
  func narratorActionJoinsPreviewRequest() async {
    let extras = FakeItemDetailExtrasAccess()
    extras.gate.hold()
    let model = makeModel(extras: extras)

    let preview = Task { await model.loadExtrasIfNeeded(itemID: "book-1") }
    await extras.gate.waitUntilParked()
    let action = Task { await model.loadExtrasIfNeeded(itemID: "book-1") }
    extras.gate.release(
      ItemDetailExtras(seriesName: "Series", narrator: "Joined Narrator", chapters: []))
    await preview.value
    await action.value
    #expect(extras.callCount == 1)
    #expect(model.narrator(for: "book-1") == "Joined Narrator")
  }

  @Test("a download intent is refused while the item is mid-removal")
  func downloadIntentsAreGatedOnActionability() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    let intents = FakeDownloadIntents()
    let model = makeModel(downloadStatus: store, downloadIntents: intents)

    reading.pushPresence(["book-1": .deleting])
    await waitUntil { store.presence(for: "book-1") == .deleting }

    await model.requestDownload(itemID: "book-1")
    await model.removeDownload(itemID: "book-1")

    #expect(intents.calls.isEmpty)
  }

  @Test("a failed progress intent surfaces one dismissible message")
  func failedProgressIntentSurfacesAMessage() async {
    let progress = FakeItemProgressIntents(fails: true)
    let model = makeModel(progress: progress)

    #expect(model.actionErrorMessage == nil)
    await model.resetProgress(itemID: "book-1")
    #expect(model.actionErrorMessage != nil)

    model.dismissActionError()
    #expect(model.actionErrorMessage == nil)
  }

  /// The error belongs to the screen, not to a row: a row that has scrolled away (or been recycled
  /// onto a different item) must not take the message with it.
  @Test("an error raised by one item stays visible while another item is acted on")
  func errorSurvivesActingOnADifferentRow() async {
    let progress = FakeItemProgressIntents(fails: true)
    let model = makeModel(progress: progress)

    await model.resetProgress(itemID: "book-1")
    #expect(model.actionErrorMessage != nil)

    await model.markAsFinished(itemID: "book-2", duration: nil)
    #expect(model.actionErrorMessage != nil)
  }

  // MARK: - Queue intents

  /// An audiobook has no episode id, so the intent must not bail out silently on the missing
  /// episode.
  @Test("an audiobook play-next reaches the front of the universal queue")
  func audiobookPlayNextMovesToTheFrontOfTheQueue() async throws {
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    await model.playNext(itemID: "book-1", episodeID: nil)

    #expect(await queue.calls == [.insertNext(identity)])
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)
    #expect(model.actionErrorMessage == nil)
  }

  @Test("an audiobook add reaches the end of the universal queue")
  func audiobookAddToUpNextAppends() async throws {
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    await model.addToUpNext(itemID: "book-1", episodeID: nil)

    #expect(await queue.calls == [.append(identity)])
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.addedToUpNext)
  }

  /// Appending an identity already queued is an idempotent no-op in the store. The feedback must
  /// say so rather than claim a mutation that never happened.
  @Test("adding an identity already in the queue reports it without claiming a mutation")
  func addingAnAlreadyQueuedIdentityDoesNotClaimAMutation() async throws {
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    await model.addToUpNext(itemID: "book-1", episodeID: nil)
    await model.addToUpNext(itemID: "book-1", episodeID: nil)

    #expect(model.queueFeedbackMessage == ListeningQueueCopy.alreadyInUpNext)
    #expect(await queue.identities == [identity], "not duplicated")
  }

  @Test("a chapter add queues the book with that chapter and says a chapter was added")
  func chapterAddToUpNextCarriesTheChapter() async throws {
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let chapter = ListeningQueueChapter(start: 100, end: 200, title: "Two")

    await model.addToUpNext(itemID: "book-1", chapter: chapter)

    #expect(await queue.calls == [.append(identity)])
    #expect(await queue.chapters[identity] == chapter)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.chapterAddedToUpNext)

    await model.addToUpNext(itemID: "book-1", chapter: chapter)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.alreadyInUpNext)
  }

  @Test("a queued book that takes a different extent is reported as updated, not added")
  func aReplacedExtentIsReportedAsUpdated() async throws {
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let two = ListeningQueueChapter(start: 100, end: 200, title: "Two")
    let three = ListeningQueueChapter(start: 200, end: 300, title: "Three")

    await model.addToUpNext(itemID: "book-1", chapter: two)
    await model.addToUpNext(itemID: "book-1", chapter: three)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.upNextUpdated)
    #expect(await queue.chapters[identity] == three)

    await model.addToUpNext(itemID: "book-1", episodeID: nil)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.upNextUpdated)
    #expect(await queue.chapters[identity] == nil)
    #expect(await queue.identities == [identity], "one row per book")
  }

  @Test("a chapter play-next moves the book to the front with that chapter")
  func chapterPlayNextCarriesTheChapter() async throws {
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let chapter = ListeningQueueChapter(start: 100, end: 200, title: "Two")

    await model.playNext(itemID: "book-1", chapter: chapter)

    #expect(await queue.calls == [.insertNext(identity)])
    #expect(await queue.chapters[identity] == chapter)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.playingNext)
  }

  @Test("a chapter add the store refuses reports the edit failure and no confirmation")
  func aRefusedChapterAddReportsTheFailure() async {
    let queue = FakeListeningQueue(fails: true)
    let model = makeModel(listeningQueue: queue)

    let result = await model.addToUpNext(
      itemID: "book-1", chapter: ListeningQueueChapter(start: 0, end: 10, title: nil))

    #expect(result == .failed)
    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)
    #expect(model.queueFeedbackMessage == nil)
  }

  @Test("episode queue intents still carry the episode through unchanged")
  func episodeQueueIntentsStillCarryTheEpisode() async throws {
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue)
    let episode1 = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "ep-1"))
    let episode2 = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "ep-2"))

    await model.playNext(itemID: "show-1", episodeID: "ep-1")
    await model.addToUpNext(itemID: "show-1", episodeID: "ep-2")

    #expect(
      await queue.calls == [
        .insertNext(episode1),
        .append(episode2),
      ])
  }

  @Test("a failed queue intent surfaces one dismissible message and no success feedback")
  func failedQueueIntentSurfacesAMessage() async {
    let queue = FakeListeningQueue(fails: true)
    let model = makeModel(listeningQueue: queue)

    await model.playNext(itemID: "book-1", episodeID: nil)

    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)
    #expect(model.queueFeedbackMessage == nil)
  }

  @Test("native RSS episode actions use the typed episode router for every mutable surface")
  func rssEpisodeActionsAreRouted() async {
    let episode = FakePodcastEpisodeIntents()
    let queue = FakeListeningQueue()
    let downloads = FakeDownloadIntents()
    let progress = FakeItemProgressIntents()
    let saved = FakeSavedShelfStoring()
    let model = makeModel(
      progress: progress, downloadIntents: downloads, listeningQueue: queue,
      episodeIntents: episode, savedShelf: saved)

    await model.playNext(itemID: "rss:7", episodeID: "ep-1")
    await model.addToUpNext(itemID: "rss:7", episodeID: "ep-1")
    await model.saveForLater(itemID: "rss:7", episodeID: "ep-1")
    await model.removeFromSaved(itemID: "rss:7", episodeID: "ep-1")
    await model.requestDownload(itemID: "rss:7", episodeID: "ep-1")
    await model.removeDownload(itemID: "rss:7", episodeID: "ep-1")
    await model.resetProgress(itemID: "rss:7", episodeID: "ep-1")
    await model.markAsFinished(itemID: "rss:7", episodeID: "ep-1", duration: 42)
    await model.removeFromContinueListening(itemID: "rss:7", episodeID: "ep-1")

    #expect(
      episode.calls == [
        .playNext("rss:7", "ep-1"),
        .addToUpNext("rss:7", "ep-1"),
        .saveForLater("rss:7", "ep-1"),
        .removeFromSaved("rss:7", "ep-1"),
        .download("rss:7", "ep-1"),
        .removeDownload("rss:7", "ep-1"),
        .resetProgress("rss:7", "ep-1"),
        .markAsFinished("rss:7", "ep-1", 42),
        .removeFromContinueListening("rss:7", "ep-1"),
      ])
    #expect(await queue.calls.isEmpty)
    #expect(downloads.calls.isEmpty)
    #expect(await progress.actions.isEmpty)
    #expect(saved.calls.isEmpty)
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.removed)
    #expect(model.continueListeningFeedbackMessage == ContinueListeningCopy.removed)
  }

  @Test("ABS identifiers retain their services while malformed reserved identifiers fail")
  func nonRSSIdsAreNotRouted() async throws {
    let episode = FakePodcastEpisodeIntents()
    let queue = FakeListeningQueue()
    let downloads = FakeDownloadIntents()
    let model = makeModel(
      downloadIntents: downloads, listeningQueue: queue, episodeIntents: episode)
    let absEpisode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "li_abc", episodeID: "ep-1"))

    await model.playNext(itemID: "li_abc", episodeID: "ep-1")
    await model.requestDownload(itemID: "li_abc")
    await model.playNext(itemID: "rss:007", episodeID: "ep-1")

    #expect(episode.calls.isEmpty)
    #expect(await queue.calls == [.insertNext(absEpisode)])
    #expect(downloads.calls == [.requestDownload(itemID: "li_abc")])
    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)
  }

  @Test("native RSS actions without an episode fail without falling back to ABS services")
  func rssNilEpisodeFailsWithoutFallback() async {
    let episode = FakePodcastEpisodeIntents()
    let queue = FakeListeningQueue()
    let downloads = FakeDownloadIntents()
    let progress = FakeItemProgressIntents()
    let saved = FakeSavedShelfStoring()
    let model = makeModel(
      progress: progress, downloadIntents: downloads, listeningQueue: queue,
      episodeIntents: episode, savedShelf: saved)

    await model.playNext(itemID: "rss:7", episodeID: nil)
    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)
    model.dismissActionError()
    await model.saveForLater(itemID: "rss:7")
    #expect(model.actionErrorMessage == SavedForLaterCopy.saveFailed)
    model.dismissActionError()
    await model.requestDownload(itemID: "rss:7")
    #expect(
      model.actionErrorMessage
        == ItemDownloadCopy.actionFailed(
          .download, error: PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed)))
    model.dismissActionError()
    await model.resetProgress(itemID: "rss:7")
    #expect(model.actionErrorMessage == "Couldn't update progress. Try again.")
    model.dismissActionError()
    await model.removeFromContinueListening(itemID: "rss:7")
    #expect(model.actionErrorMessage == ContinueListeningCopy.removeFailed)
    #expect(episode.calls.isEmpty)
    #expect(await queue.calls.isEmpty)
    #expect(downloads.calls.isEmpty)
    #expect(await progress.actions.isEmpty)
    #expect(saved.calls.isEmpty)
  }

  @Test("several chapters queue in the order given with one confirmation")
  func chapterBatchQueuesInOrderWithOneMessage() async throws {
    let queue = makeScriptedQueue(outcomes: [.appended, .appended, .alreadyQueued])
    let model = makeModel(listeningQueue: queue)
    let chapters = [
      ListeningQueueChapter(start: 300, end: 400, title: "Four"),
      ListeningQueueChapter(start: 0, end: 100, title: "One"),
      ListeningQueueChapter(start: 100, end: 200, title: "Two"),
    ]

    #expect(await model.addToUpNext(itemID: "book-1", chapters: chapters) == .succeeded)

    #expect(appendedChapters(queue).map(\.start) == [300, 0, 100])
    #expect(model.queueFeedbackMessage == "2 chapters added to Up Next")
  }

  @Test("a chapter batch onto a book queued whole says Up Next changed; a repeat says already")
  func chapterBatchReportsReplacementAndRepeat() async throws {
    let chapters = [
      ListeningQueueChapter(start: 0, end: 100, title: "One"),
      ListeningQueueChapter(start: 100, end: 200, title: "Two"),
    ]
    let replacing = makeModel(listeningQueue: makeScriptedQueue(outcomes: [.replaced, .appended]))
    await replacing.addToUpNext(itemID: "book-1", chapters: chapters)
    #expect(replacing.queueFeedbackMessage == ListeningQueueCopy.upNextUpdated)

    let repeating = makeModel(
      listeningQueue: makeScriptedQueue(outcomes: [.alreadyQueued, .alreadyQueued]))
    await repeating.addToUpNext(itemID: "book-1", chapters: chapters)
    #expect(repeating.queueFeedbackMessage == ListeningQueueCopy.alreadyInUpNext)

    let single = makeModel(listeningQueue: makeScriptedQueue(outcomes: [.appended]))
    await single.addToUpNext(itemID: "book-1", chapters: [chapters[0]])
    #expect(single.queueFeedbackMessage == ListeningQueueCopy.chapterAddedToUpNext)
  }

  @Test("a failed chapter batch raises the edit error and no confirmation")
  func chapterBatchFailure() async throws {
    let model = makeModel(listeningQueue: makeScriptedQueue(outcomes: [.appended], failsAfter: 1))
    let chapters = [
      ListeningQueueChapter(start: 0, end: 100, title: "One"),
      ListeningQueueChapter(start: 100, end: 200, title: "Two"),
    ]

    #expect(await model.addToUpNext(itemID: "book-1", chapters: chapters) == .failed)
    #expect(model.queueFeedbackMessage == nil)
    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)
  }

  // MARK: - Saved for Later intents

  @Test("a successful save uses the dedicated Saved for Later feedback channel")
  func saveForLaterShowsSuccessFeedback() async {
    let shelf = FakeSavedShelfStoring()
    let model = makeModel(savedShelf: shelf)

    await model.saveForLater(itemID: "book-1")

    #expect(shelf.calls == [.save(.item(itemID: "book-1"))])
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.saved)
    #expect(model.queueFeedbackMessage == nil)
  }

  @Test("a duplicate save reports Already Saved rather than a mutation")
  func duplicateSaveUsesNonMutationFeedback() async {
    let shelf = FakeSavedShelfStoring()
    shelf.stubSaveOutcomes([.saved, .alreadySaved])
    let model = makeModel(savedShelf: shelf)

    await model.saveForLater(itemID: "book-1")
    await model.saveForLater(itemID: "book-1")

    #expect(model.savedFeedbackMessage == SavedForLaterCopy.alreadySaved)
    #expect(model.savedFeedbackMessage != SavedForLaterCopy.saved)
    #expect(
      shelf.calls == [
        .save(.item(itemID: "book-1")), .save(.item(itemID: "book-1")),
      ])
  }

  @Test("a successful remove uses the dedicated Saved for Later feedback channel")
  func removeFromSavedShowsSuccessFeedback() async {
    let shelf = FakeSavedShelfStoring()
    let model = makeModel(savedShelf: shelf)

    await model.saveForLater(itemID: "book-1")
    await model.removeFromSaved(itemID: "book-1")

    #expect(model.savedFeedbackMessage == SavedForLaterCopy.removed)
    #expect(
      shelf.calls == [
        .save(.item(itemID: "book-1")), .remove(.item(itemID: "book-1")),
      ])
  }

  @Test("a failed save uses the error channel and clears Saved for Later feedback")
  func failedSaveSurfacesOperationSpecificMessage() async {
    let shelf = makeFailingSavedShelf()
    let model = makeModel(savedShelf: shelf)

    await model.saveForLater(itemID: "book-1")

    #expect(model.actionErrorMessage == SavedForLaterCopy.saveFailed)
    #expect(model.savedFeedbackMessage == nil)
  }

  @Test("a failed remove uses its operation-specific error copy")
  func failedRemoveSurfacesOperationSpecificMessage() async {
    let shelf = makeFailingSavedShelf()
    let model = makeModel(savedShelf: shelf)

    await model.removeFromSaved(itemID: "book-1")

    #expect(model.actionErrorMessage == SavedForLaterCopy.removeFailed)
    #expect(model.savedFeedbackMessage == nil)
  }

  @Test("Saved for Later and queue feedback channels do not clear each other")
  func savedAndQueueFeedbackAreIndependent() async {
    let shelf = FakeSavedShelfStoring()
    let queue = FakeListeningQueue()
    let model = makeModel(listeningQueue: queue, savedShelf: shelf)

    await model.addToUpNext(itemID: "book-1", episodeID: nil)
    await model.saveForLater(itemID: "book-1")
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.addedToUpNext)
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.saved)

    await model.removeFromSaved(itemID: "book-1")
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.addedToUpNext)
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.removed)

    await model.addToUpNext(itemID: "book-1", episodeID: nil)
    #expect(model.queueFeedbackMessage == ListeningQueueCopy.alreadyInUpNext)
    #expect(model.savedFeedbackMessage == SavedForLaterCopy.removed)
  }

  @Test("saved membership passthrough distinguishes whole items and episodes")
  func savedMembershipReflectsInjectedStatusStore() async {
    let reading = FakeSavedShelfReading()
    let status = SavedStatusStore(savedShelf: reading)
    let model = makeModel(savedStatus: status)
    let item = SavedShelfIdentity.item(itemID: "book-1")
    let episode = SavedShelfIdentity.podcastEpisode(itemID: "show-1", episodeID: "ep-1")

    reading.pushSavedIdentities([item, episode])
    #expect(await waitUntil { model.hasResolvedSavedMembership })
    #expect(model.isSaved(itemID: "book-1"))
    #expect(model.isSaved(itemID: "show-1", episodeID: "ep-1"))
    #expect(model.isSaved(itemID: "book-1", episodeID: "ep-1") == false)
    #expect(model.isSaved(itemID: "show-1") == false)
  }

  @Test("hidden Continue Listening membership passthrough distinguishes items and episodes")
  func hiddenContinueListeningMembershipReflectsInjectedStore() throws {
    let audiobook = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "ep-1"))
    let store = ContinueListeningVisibilityStore(hidden: [audiobook, episode])
    let model = makeModel(continueListeningVisibility: store)

    #expect(model.isHiddenFromContinueListening(itemID: "book-1"))
    #expect(model.isHiddenFromContinueListening(itemID: "show-1", episodeID: "ep-1"))
    #expect(model.isHiddenFromContinueListening(itemID: "show-1") == false)
    #expect(model.isHiddenFromContinueListening(itemID: "book-2") == false)
    #expect(makeModel().isHiddenFromContinueListening(itemID: "book-1") == false)
  }

  @Test("an episode save reaches the Saved for Later store as an episode identity")
  func episodeSaveUsesPodcastEpisodeIdentity() async {
    let shelf = FakeSavedShelfStoring()
    let model = makeModel(savedShelf: shelf)

    await model.saveForLater(itemID: "show-1", episodeID: "ep-1")

    #expect(
      shelf.calls
        == [.save(.podcastEpisode(itemID: "show-1", episodeID: "ep-1"))])
  }

  @Test("an ABS whole-item save and remove reach the Saved for Later store as an item identity")
  func absItemSaveAndRemoveUseItemIdentity() async {
    let shelf = FakeSavedShelfStoring()
    let episode = FakePodcastEpisodeIntents()
    let model = makeModel(episodeIntents: episode, savedShelf: shelf)

    await model.saveForLater(itemID: "book-1")
    await model.removeFromSaved(itemID: "book-1")

    #expect(
      shelf.calls == [.save(.item(itemID: "book-1")), .remove(.item(itemID: "book-1"))])
    #expect(episode.calls.isEmpty)
  }

  @Test("an ABS episode remove reaches the Saved for Later store as an episode identity")
  func absEpisodeRemoveUsesPodcastEpisodeIdentity() async {
    let shelf = FakeSavedShelfStoring()
    let episode = FakePodcastEpisodeIntents()
    let model = makeModel(episodeIntents: episode, savedShelf: shelf)

    await model.removeFromSaved(itemID: "show-1", episodeID: "ep-1")

    #expect(
      shelf.calls == [.remove(.podcastEpisode(itemID: "show-1", episodeID: "ep-1"))])
    #expect(episode.calls.isEmpty)
  }

  @Test("a native RSS episode save and remove route to the episode intents, not the ABS shelf")
  func rssEpisodeSaveAndRemoveBypassTheShelf() async {
    let shelf = FakeSavedShelfStoring()
    let episode = FakePodcastEpisodeIntents()
    let model = makeModel(episodeIntents: episode, savedShelf: shelf)

    await model.saveForLater(itemID: "rss:7", episodeID: "ep-1")
    await model.removeFromSaved(itemID: "rss:7", episodeID: "ep-1")

    #expect(
      episode.calls == [
        .saveForLater("rss:7", "ep-1"),
        .removeFromSaved("rss:7", "ep-1"),
      ])
    #expect(shelf.calls.isEmpty)
  }

  @Test("a native RSS remove without an episode fails without touching either service")
  func rssRemoveWithoutEpisodeFails() async {
    let shelf = FakeSavedShelfStoring()
    let episode = FakePodcastEpisodeIntents()
    let model = makeModel(episodeIntents: episode, savedShelf: shelf)

    await model.removeFromSaved(itemID: "rss:7")

    #expect(model.actionErrorMessage == SavedForLaterCopy.removeFailed)
    #expect(model.savedFeedbackMessage == nil)
    #expect(episode.calls.isEmpty)
    #expect(shelf.calls.isEmpty)
  }

  @Test("saved membership passthrough reads native episodes by their RSS identity")
  func savedMembershipReadsNativeEpisodes() async {
    let reading = FakeSavedShelfReading()
    let status = SavedStatusStore(savedShelf: reading)
    let model = makeModel(savedStatus: status)

    reading.pushSavedIdentities([.rssEpisode(itemID: "rss:7", episodeID: "ep-1")])
    #expect(await waitUntil { model.hasResolvedSavedMembership })
    #expect(model.isSaved(itemID: "rss:7", episodeID: "ep-1"))
    #expect(model.isSaved(itemID: "rss:7") == false)
  }

  // MARK: - Intent results

  /// The batch reads these instead of the single error slot, which cannot say which item failed
  /// and stays silent for a refused download.
  @Test("progress intents report success and failure")
  func progressIntentResults() async {
    let model = makeModel(progress: FakeItemProgressIntents())
    #expect(await model.resetProgress(itemID: "book-1") == .succeeded)
    #expect(await model.markAsFinished(itemID: "book-1", duration: nil) == .succeeded)

    let failing = makeModel(progress: FakeItemProgressIntents(fails: true))
    #expect(await failing.resetProgress(itemID: "book-1") == .failed)
    #expect(await failing.markAsFinished(itemID: "book-1", duration: nil) == .failed)
  }

  @Test("download intents report success, failure, and a refusal while mid-removal")
  func downloadIntentResults() async {
    let reading = FakeDownloadReading()
    let store = DownloadStatusStore(downloadReading: reading)
    let intents = FakeDownloadIntents()
    let model = makeModel(downloadStatus: store, downloadIntents: intents)

    #expect(await model.requestDownload(itemID: "book-1") == .succeeded)
    #expect(await model.removeDownload(itemID: "book-1") == .succeeded)

    intents.stubNextCall(throwing: DownloadIntentFailure())
    #expect(await model.requestDownload(itemID: "book-2") == .failed)
    #expect(await model.removeDownload(itemID: "book-2") == .failed)
    intents.stubNextCall(throwing: nil)

    reading.pushPresence(["book-3": .deleting])
    await waitUntil { store.presence(for: "book-3") == .deleting }
    model.dismissActionError()
    #expect(await model.requestDownload(itemID: "book-3") == .refused)
    #expect(await model.removeDownload(itemID: "book-3") == .refused)
    #expect(model.actionErrorMessage == nil)
  }

  @Test("an already-queued add succeeds, and a failed add reports failure")
  func queueIntentResults() async {
    let model = makeModel(listeningQueue: FakeListeningQueue())
    #expect(await model.addToUpNext(itemID: "book-1", episodeID: nil) == .succeeded)
    #expect(await model.addToUpNext(itemID: "book-1", episodeID: nil) == .succeeded)

    let failing = makeModel(listeningQueue: FakeListeningQueue(fails: true))
    #expect(await failing.addToUpNext(itemID: "book-1", episodeID: nil) == .failed)
  }

  @Test("Saved for Later intents report success and failure")
  func savedIntentResults() async {
    let model = makeModel(savedShelf: FakeSavedShelfStoring())
    #expect(await model.saveForLater(itemID: "book-1") == .succeeded)
    #expect(await model.saveForLater(itemID: "book-1") == .succeeded)
    #expect(await model.removeFromSaved(itemID: "book-1") == .succeeded)

    let failing = makeModel(savedShelf: makeFailingSavedShelf())
    #expect(await failing.saveForLater(itemID: "book-1") == .failed)
    #expect(await failing.removeFromSaved(itemID: "book-1") == .failed)
  }

  @Test("Continue Listening removal reports success and failure")
  func continueListeningIntentResults() async {
    let model = makeModel(progress: FakeItemProgressIntents())
    #expect(await model.removeFromContinueListening(itemID: "book-1") == .succeeded)

    let failing = makeModel(progress: FakeItemProgressIntents(fails: true))
    #expect(await failing.removeFromContinueListening(itemID: "book-1") == .failed)
  }

  @Test("a native RSS intent without an episode reports failure")
  func missingRSSEpisodeReportsFailure() async {
    let model = makeModel()
    #expect(await model.markAsFinished(itemID: "rss:7", duration: nil) == .failed)
    #expect(await model.requestDownload(itemID: "rss:7") == .failed)
    #expect(await model.addToUpNext(itemID: "rss:7", episodeID: nil) == .failed)
  }

  private func makeModel(
    progress: any ItemProgressIntents = NoOpItemProgressIntents(),
    extras: any ItemDetailExtrasAccess = NoOpItemDetailExtrasAccess(),
    downloadStatus: DownloadStatusStore? = nil,
    downloadIntents: any DownloadIntents = NoOpDownloadIntents(),
    listeningQueue: any ListeningQueueStoring = NoOpListeningQueueStore(),
    episodeIntents: any PodcastEpisodeIntents = NoOpPodcastEpisodeIntents(),
    savedShelf: any SavedShelfStoring = NoOpSavedShelfStore(),
    savedStatus: SavedStatusStore? = nil,
    continueListeningVisibility: ContinueListeningVisibilityStore? = nil
  ) -> ItemActionsModel {
    ItemActionsModel(
      downloadStatus: downloadStatus ?? DownloadStatusStore(downloadReading: NoOpDownloadReading()),
      downloadIntents: downloadIntents,
      progressIntents: progress,
      extrasAccess: extras,
      listeningQueue: listeningQueue,
      episodeIntents: episodeIntents,
      savedShelf: savedShelf,
      savedStatus: savedStatus,
      continueListeningVisibility: continueListeningVisibility)
  }
}

// Kept: `FakeListeningQueueStoring` records `append` and `insertNext` but does not model the
// queue (one row per identity, chapter replacement, play-next to the front), which these tests
// read back through `identities` and `chapters`.
/// Real append semantics: a second append of the same identity is the store's idempotent no-op,
/// reported as `.alreadyQueued` so the caller cannot mistake it for an insertion.
private actor FakeListeningQueue: ListeningQueueStoring {
  enum Call: Equatable {
    case insertNext(ListeningIdentity)
    case append(ListeningIdentity)
  }

  private(set) var calls: [Call] = []
  private(set) var identities: [ListeningIdentity] = []
  /// The chapter each queued identity carries; absent for a whole title.
  private(set) var chapters: [ListeningIdentity: ListeningQueueChapter] = [:]
  private let fails: Bool

  init(fails: Bool = false) {
    self.fails = fails
  }

  private struct Failure: Error {}

  @discardableResult
  func append(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws -> ListeningQueueAppendOutcome
  {
    calls.append(.append(identity))
    if fails { throw Failure() }
    guard identities.contains(identity) == false else {
      guard chapters[identity] != chapter else { return .alreadyQueued }
      chapters[identity] = chapter
      return .replaced
    }
    identities.append(identity)
    chapters[identity] = chapter
    return .appended
  }

  func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {
    calls.append(.insertNext(identity))
    if fails { throw Failure() }
    identities.removeAll { $0 == identity }
    identities.insert(identity, at: 0)
    chapters[identity] = chapter
  }
  @discardableResult
  func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] { [] }

  func remove(identity: ListeningIdentity) async throws {}
  func remove(rowID: Int64) async throws {}
  func move(rowID: Int64, to position: Int) async throws {}
  func clear() async throws -> ListeningQueueRestoreToken {
    try await NoOpListeningQueueStore().clear()
  }
  func restore(token: ListeningQueueRestoreToken) async throws {}
  func peekNextLive() async -> ListeningQueueItem? { nil }
  func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {}
  func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool { false }
}

private actor FakeItemProgressIntents: ItemProgressIntents {
  enum Action: Equatable {
    case reset(String, String?)
    case resetEbook(String)
    case finish(String, String?, Double?)
    case continueListeningVisibility(String, String?, Bool)

    static func reset(_ itemID: String) -> Action { .reset(itemID, nil) }
    static func finish(_ itemID: String, _ duration: Double?) -> Action {
      .finish(itemID, nil, duration)
    }
  }

  private(set) var actions: [Action] = []
  private let fails: Bool

  init(fails: Bool = false) {
    self.fails = fails
  }

  private struct Failure: Error {}

  func resetProgress(itemID: String, episodeID: String?) async throws {
    actions.append(.reset(itemID, episodeID))
    if fails { throw Failure() }
  }

  func setContinueListeningVisibility(
    itemID: String, episodeID: String?, isHidden: Bool
  ) async throws {
    actions.append(.continueListeningVisibility(itemID, episodeID, isHidden))
    if fails { throw Failure() }
  }

  func resetEbookProgress(itemID: String) async throws {
    actions.append(.resetEbook(itemID))
    if fails { throw Failure() }
  }

  func markAsFinished(itemID: String, episodeID: String?, duration: Double?) async throws {
    actions.append(.finish(itemID, episodeID, duration))
    if fails { throw Failure() }
  }

  func setEpisodesFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {}
}

private struct DownloadIntentFailure: Error {}

private func makeFailingSavedShelf() -> FakeSavedShelfStoring {
  let shelf = FakeSavedShelfStoring()
  shelf.stubFailure(FakeSavedShelfStoring.Failure())
  return shelf
}

/// Answers each append with the next scripted outcome; `failsAfter` lets that many appends
/// succeed and then fails the rest.
private func makeScriptedQueue(
  outcomes: [ListeningQueueAppendOutcome], failsAfter: Int? = nil
) -> FakeListeningQueueStoring {
  let queue = FakeListeningQueueStoring()
  queue.stubAppendOutcomes(outcomes)
  if let failsAfter {
    queue.stubFailure(FakeListeningQueueStoring.Failure(), afterCalls: failsAfter)
  }
  return queue
}

/// The chapters appended to `queue`, in call order; a whole-title append has none.
private func appendedChapters(_ queue: FakeListeningQueueStoring) -> [ListeningQueueChapter] {
  queue.calls.compactMap { call -> ListeningQueueChapter? in
    if case .append(_, let chapter) = call { return chapter }
    return nil
  }
}
