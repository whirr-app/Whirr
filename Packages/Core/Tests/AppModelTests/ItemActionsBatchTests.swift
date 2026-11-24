import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The multi-select loop shared by Saved for Later, the Home Continue shelves and Library Titles.
@MainActor
@Suite("Item actions batch", .timeLimit(.minutes(1)))
struct ItemActionsBatchTests {
  @Test("targets run in the order given and a failure does not stop the rest")
  func runsInOrderPastAFailure() async {
    let harness = Self.makeHarness(failing: ["b"])
    let targets = ["a", "b", "c"].map { Self.book($0) }

    let outcome = await harness.model.performBatch(
      .markAsFinished, on: targets, playback: harness.playback)

    #expect(await harness.services.calls == [.finish("a"), .finish("b"), .finish("c")])
    #expect(outcome.entries.map(\.target) == targets)
    #expect(outcome.entries.map(\.result) == [.succeeded, .failed, .succeeded])
    #expect(outcome.succeeded == [targets[0], targets[2]])
    #expect(outcome.failed == [targets[1]])
    #expect(outcome.isComplete)
  }

  @Test("the failure message is the one the last failing intent wrote")
  func failureMessageIsTheLastFailure() async {
    let harness = Self.makeHarness(failing: ["a", "c"])

    let outcome = await harness.model.performBatch(
      .addToUpNext, on: ["a", "b", "c"].map { Self.book($0) }, playback: harness.playback)

    #expect(outcome.failureMessage == ListeningQueueCopy.editFailed)
    #expect(harness.model.actionErrorMessage == ListeningQueueCopy.editFailed)
  }

  @Test("an earlier error is dismissed before the run and a clean run reports none")
  func earlierErrorIsDismissedBeforeTheRun() async {
    let harness = Self.makeHarness(failing: ["stale"])
    await harness.model.resetProgress(itemID: "stale")
    #expect(harness.model.actionErrorMessage != nil)

    let outcome = await harness.model.performBatch(
      .resetProgress, on: [Self.book("a")], playback: harness.playback)

    #expect(harness.model.actionErrorMessage == nil)
    #expect(outcome.failureMessage == nil)
    #expect(outcome.failed.isEmpty)
  }

  @Test("a clean run leaves the last item's feedback for the screen to show")
  func successKeepsSingleItemFeedback() async {
    let harness = Self.makeHarness()

    _ = await harness.model.performBatch(
      .addToUpNext, on: [Self.book("a"), Self.book("b")], playback: harness.playback)

    #expect(harness.model.queueFeedbackMessage == ListeningQueueCopy.addedToUpNext)
  }

  @Test("any failure dismisses queue, Saved and Continue Listening feedback")
  func failureDismissesEveryFeedbackChannel() async {
    let harness = Self.makeHarness(failing: ["b"])
    await harness.model.saveForLater(itemID: "saved")
    await harness.model.removeFromContinueListening(itemID: "hidden")
    #expect(harness.model.savedFeedbackMessage != nil)
    #expect(harness.model.continueListeningFeedbackMessage != nil)

    _ = await harness.model.performBatch(
      .addToUpNext, on: [Self.book("a"), Self.book("b")], playback: harness.playback)

    #expect(harness.model.queueFeedbackMessage == nil)
    #expect(harness.model.savedFeedbackMessage == nil)
    #expect(harness.model.continueListeningFeedbackMessage == nil)
  }

  @Test("an empty run returns an empty outcome after dismissing the error")
  func emptyRunReturnsAnEmptyOutcome() async {
    let harness = Self.makeHarness(failing: ["stale"])
    await harness.model.resetProgress(itemID: "stale")

    let outcome = await harness.model.performBatch(
      .markAsFinished, on: [], playback: harness.playback)

    #expect(outcome.entries.isEmpty)
    #expect(outcome.failureMessage == nil)
    #expect(outcome.isComplete)
    #expect(harness.model.actionErrorMessage == nil)
    #expect(await harness.services.calls == [.reset("stale")])
  }

  @Test("a download target with no format is refused without reaching the intents")
  func downloadWithoutFormatIsRefused() async {
    let harness = Self.makeHarness()
    let unresolved = Self.book("a", format: nil)
    let audio = Self.book("b", format: .audio)

    let outcome = await harness.model.performBatch(
      .download, on: [unresolved, audio], playback: harness.playback)

    #expect(outcome.entries.map(\.result) == [.refused, .succeeded])
    #expect(outcome.skipped == [unresolved])
    #expect(harness.downloads.calls == [.requestDownload(itemID: "b")])
    #expect(harness.model.actionErrorMessage == nil)
  }

  @Test("cancellation stops between items and leaves the rest not attempted")
  func cancellationLeavesTheRestNotAttempted() async {
    let harness = Self.makeHarness(holding: "b")
    let targets = ["a", "b", "c"].map { Self.book($0) }
    let model = harness.model
    let playback = harness.playback

    let run = Task { await model.performBatch(.resetProgress, on: targets, playback: playback) }
    await harness.services.waitUntilHeld()
    run.cancel()
    await harness.services.release()
    let outcome = await run.value

    #expect(outcome.entries.map(\.result) == [.succeeded, .succeeded, nil])
    #expect(outcome.notAttempted == [targets[2]])
    #expect(outcome.isComplete == false)
    #expect(await harness.services.calls == [.reset("a"), .reset("b")])
  }

  @Test("each action reaches its own intent with the target's identity")
  func actionsRouteToTheirIntents() async {
    let harness = Self.makeHarness()
    let episode = ItemBatchTarget(
      itemID: "show", episodeID: "ep", category: .podcast, durationSeconds: 90,
      downloadFormat: .audio)
    let book = Self.book("book", format: .ebook)
    let ebook = ItemBatchTarget(
      itemID: "reader", episodeID: nil, category: .ebook, durationSeconds: nil, downloadFormat: nil)

    for action in [ItemBatchAction.saveForLater, .removeFromSaved, .removeFromContinueListening] {
      _ = await harness.model.performBatch(action, on: [episode], playback: harness.playback)
    }
    _ = await harness.model.performBatch(.markAsFinished, on: [episode], playback: harness.playback)
    _ = await harness.model.performBatch(.resetProgress, on: [ebook], playback: harness.playback)
    _ = await harness.model.performBatch(.download, on: [book], playback: harness.playback)
    _ = await harness.model.performBatch(.removeDownload, on: [episode], playback: harness.playback)

    #expect(
      await harness.services.calls == [
        .save(.podcastEpisode(itemID: "show", episodeID: "ep")),
        .remove(.podcastEpisode(itemID: "show", episodeID: "ep")),
        .hide("show", "ep"),
        .finish("show", "ep", 90),
        .resetEbook("reader"),
      ])
    #expect(
      harness.downloads.calls == [
        .requestEbookDownload(itemID: "book"),
        .purgeEpisodeDownload(itemID: "show", episodeID: "ep", source: .contextMenu),
      ])
  }

  // MARK: - Playback interlocks

  @Test("finishing the active book stops playback before the progress write")
  func finishingTheActiveBookStopsFirst() async {
    let harness = Self.makeHarness()
    await harness.start(itemID: "a", episodeID: nil)

    _ = await harness.model.performBatch(
      .markAsFinished, on: [Self.book("a")], playback: harness.playback)

    #expect(await harness.services.playerIntentsAtWrite.last == .stop)
  }

  @Test("resetting the active episode seeks after the progress write")
  func resettingTheActiveEpisodeSeeksAfter() async {
    let harness = Self.makeHarness()
    await harness.start(itemID: "show", episodeID: "ep")
    let baseline = harness.player.intents
    let target = ItemBatchTarget(
      itemID: "show", episodeID: "ep", category: .podcast, durationSeconds: nil,
      downloadFormat: nil)

    _ = await harness.model.performBatch(.resetProgress, on: [target], playback: harness.playback)

    #expect(await harness.services.playerIntentsAtWrite == baseline)
    #expect(harness.player.intents.last == .seek(toGlobalOffset: 0))
  }

  @Test("a sibling of the active episode neither stops nor seeks playback")
  func siblingLeavesPlaybackAlone() async {
    let harness = Self.makeHarness()
    await harness.start(itemID: "show", episodeID: "ep")
    let baseline = harness.player.intents
    let sibling = ItemBatchTarget(
      itemID: "show", episodeID: "other", category: .podcast, durationSeconds: nil,
      downloadFormat: nil)

    _ = await harness.model.performBatch(.markAsFinished, on: [sibling], playback: harness.playback)
    _ = await harness.model.performBatch(.resetProgress, on: [sibling], playback: harness.playback)

    #expect(harness.player.intents == baseline)
  }

  @Test("a batch including the active title prepares one continuation after the loop")
  func batchPreparesOneContinuationAfterTheLoop() async throws {
    let harness = Self.makeHarness()
    await harness.start(itemID: "a", episodeID: nil)
    let next = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await harness.queue.configure(rows: [Self.queueRow(1, next)])
    harness.sync.stubStartSession(
      .success(
        PreparedPlayback(
          itemID: "book-2", episodeID: nil, startPosition: 0, duration: 100,
          tracks: [
            PreparedPlaybackTrack(
              index: 0, startOffset: 0, duration: 100,
              url: URL(string: "https://example.test/audio.mp3")!, mimeType: "audio/mpeg",
              title: "book-2")
          ], chapters: [])))
    let baseline = harness.player.intents

    _ = await harness.model.performBatch(
      .markAsFinished, on: [Self.book("a"), Self.book("c")], playback: harness.playback)

    #expect(await harness.queue.peekCount == 1, "one preparation for the whole batch")
    #expect(await harness.queue.identities.isEmpty, "the prepared row is consumed once")
    #expect(harness.playback.loadedItemID == "book-2")
    #expect(
      Array(harness.player.intents.dropFirst(baseline.count)).contains(.play) == false,
      "a batch finish never resumes playback")
    #expect(await harness.services.calls == [.finish("a"), .finish("c")])
  }

  @Test("a batch that also finishes the queued next row does not prepare that row")
  func batchDoesNotPrepareARowItAlsoFinished() async throws {
    let harness = Self.makeHarness()
    await harness.start(itemID: "a", episodeID: nil)
    let next = try #require(ListeningIdentity.audiobook(itemID: "b"))
    await harness.queue.configure(rows: [Self.queueRow(1, next)])
    let targets = [Self.book("a"), Self.book("b")]

    _ = await harness.model.performBatch(
      .markAsFinished, on: targets, playback: harness.playback)

    #expect(
      Set(await harness.queue.removed) == [try #require(ListeningIdentity.audiobook(itemID: "a")), next],
      "the finished title's own row and the row the batch finished both go")
    #expect(await harness.queue.removed.count == 2)
    #expect(await harness.queue.peekCount == 1)
    #expect(harness.playback.activeItemID == nil)
    #expect(harness.playback.loadedItemID == nil, "a title the same batch finished is not prepared")
    #expect(harness.playback.startFailure == nil)
  }

  // MARK: - Harness

  private static func queueRow(_ id: Int64, _ identity: ListeningIdentity) -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: Int(id) - 1, identity: identity, primaryTitle: "Row \(id)",
      secondaryTitle: "Secondary",
      category: identity.episodeID == nil ? .audiobook : .podcast, isTombstone: false,
      chapter: nil)
  }

  private static func book(_ itemID: String, format: ItemDownloadFormat? = .audio) -> ItemBatchTarget {
    ItemBatchTarget(
      itemID: itemID, episodeID: nil, category: .audiobook, durationSeconds: nil,
      downloadFormat: format)
  }

  private static func makeHarness(failing: Set<String> = [], holding: String? = nil) -> Harness {
    let queue = RecordingListeningQueue()
    let playbackHarness = PlaybackModelHarness(listeningQueue: queue)
    let player = playbackHarness.player
    let sync = playbackHarness.sync
    let playback = playbackHarness.model
    let services = BatchServices(player: player, failing: failing, holding: holding)
    let downloads = FakeDownloadIntents()
    let model = ItemActionsModel(
      downloadStatus: DownloadStatusStore(downloadReading: NoOpDownloadReading()),
      downloadIntents: downloads, progressIntents: services,
      extrasAccess: NoOpItemDetailExtrasAccess(), listeningQueue: services, savedShelf: services)
    return Harness(
      model: model, playback: playback, player: player, sync: sync, services: services,
      downloads: downloads, queue: queue)
  }

  private struct Harness {
    let model: ItemActionsModel
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let services: BatchServices
    let downloads: FakeDownloadIntents
    let queue: RecordingListeningQueue

    func start(itemID: String, episodeID: String?) async {
      sync.stubStartSession(
        .success(
          PreparedPlayback(
            itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
            tracks: [
              PreparedPlaybackTrack(
                index: 0, startOffset: 0, duration: 100,
                url: URL(string: "https://example.test/audio.mp3")!,
                mimeType: "audio/mpeg", title: itemID)
            ], chapters: [])))
      await playback.start(itemID: itemID, episodeID: episodeID)
    }
  }
}

/// Progress, queue and Saved for Later in one recorder, so a test reads one ordered call list.
/// Every write fails for an item ID in `failing`; a write for `holding` suspends until released.
// Kept (queue and Saved for Later): one ordered call log across three protocols, with a hold seam.
// Separate shared fakes would give three logs and lose the cross-protocol order the tests assert.
private actor BatchServices: ItemProgressIntents, ListeningQueueStoring, SavedShelfStoring {
  enum Call: Equatable {
    case finish(String, String?, Double?)
    case reset(String, String?)
    case resetEbook(String)
    case hide(String, String?)
    case append(ListeningIdentity)
    case save(SavedShelfIdentity)
    case remove(SavedShelfIdentity)

    static func finish(_ itemID: String) -> Call { .finish(itemID, nil, nil) }
    static func reset(_ itemID: String) -> Call { .reset(itemID, nil) }
  }

  private struct Failure: Error {}

  private(set) var calls: [Call] = []
  private(set) var playerIntentsAtWrite: [PlayerIntent] = []
  private let player: FakePlaybackControlling
  private let failing: Set<String>
  private let holding: String?
  // A held write runs to completion regardless of cancellation, as the real one does.
  private nonisolated let gate = TestGate<Void>(
    label: "BatchServices held write", ignoresCancellation: true)

  init(player: FakePlaybackControlling, failing: Set<String>, holding: String?) {
    self.player = player
    self.failing = failing
    self.holding = holding
    if holding != nil { gate.hold() }
  }

  func waitUntilHeld() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.releaseParked()
  }

  private func record(_ call: Call, itemID: String) async throws {
    calls.append(call)
    playerIntentsAtWrite = player.intents
    if itemID == holding {
      await gate.pass()
    }
    if failing.contains(itemID) { throw Failure() }
  }

  func markAsFinished(itemID: String, episodeID: String?, duration: Double?) async throws {
    try await record(.finish(itemID, episodeID, duration), itemID: itemID)
  }

  func resetProgress(itemID: String, episodeID: String?) async throws {
    try await record(.reset(itemID, episodeID), itemID: itemID)
  }

  func resetEbookProgress(itemID: String) async throws {
    try await record(.resetEbook(itemID), itemID: itemID)
  }

  func setContinueListeningVisibility(
    itemID: String, episodeID: String?, isHidden: Bool
  ) async throws {
    try await record(.hide(itemID, episodeID), itemID: itemID)
  }

  func setEpisodesFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {}

  @discardableResult
  func append(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws -> ListeningQueueAppendOutcome
  {
    try await record(.append(identity), itemID: identity.itemID)
    return .appended
  }

  func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {}
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

  @discardableResult
  func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome {
    try await record(.save(identity), itemID: identity.itemID)
    return .saved
  }

  func remove(_ identity: SavedShelfIdentity) async throws {
    try await record(.remove(identity), itemID: identity.itemID)
  }
}
