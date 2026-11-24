import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// A queued chapter starts at its chapter, stops at its end, and hands over to the next Up Next
/// row without finishing the book or closing its session.
@Suite(.timeLimit(.minutes(1)))
struct ListeningQueueChapterPlaybackTests {
  private static let chapterTwo = ListeningQueueChapter(start: 1_000, end: 2_000, title: "Two")
  private static let chapterThree = ListeningQueueChapter(start: 2_000, end: 2_500, title: "Three")

  @MainActor
  @Test("a chapter row loads at the chapter's start and arms its end before play")
  func chapterRowLoadsAtItsStartAndArmsItsEnd() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await queue.configure(rows: [Self.row(1, book, chapter: Self.chapterTwo)])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1", startPosition: 250)))

    await model.start(queueItem: Self.row(1, book, chapter: Self.chapterTwo))

    #expect(Self.loadPosition(player.intents) == 1_000)
    #expect(player.intents.suffix(2) == [.setSegment(start: 1_000, end: 2_000), .play])
    #expect(model.currentTime == 1_000)
    #expect(await queue.identities.isEmpty, "the started chapter row is consumed")
  }

  @MainActor
  @Test("a whole-book row resumes where the book stood and clears any chapter stop")
  func wholeBookRowResumesAndClearsTheStop() async throws {
    let (model, player, sync, _) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1", startPosition: 250)))

    await model.start(queueItem: Self.row(1, book))

    #expect(Self.loadPosition(player.intents) == 250)
    #expect(player.intents.suffix(2) == [.clearSegment, .play])
  }

  @MainActor
  @Test("an authorized resume position loses to the chapter's start; a denial still refuses")
  func authorizationPositionLosesAndDenialWins() async throws {
    let (model, player, sync, _) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    model.authorizePlaybackStart = { _, _ in .allowed(position: 400) }
    await model.start(identity: book, queuedChapter: Self.queued(Self.chapterTwo))
    #expect(Self.loadPosition(player.intents) == 1_000)

    let (denied, deniedPlayer, _, _) = Self.makeModel()
    denied.authorizePlaybackStart = { _, _ in .denied(message: "No") }
    await denied.start(identity: book, queuedChapter: Self.queued(Self.chapterTwo))
    #expect(denied.startFailure?.message == "No")
    #expect(deniedPlayer.intents.isEmpty)
  }

  @MainActor
  @Test("a chapter of the loaded book seeks in place, without a second session")
  func chapterOfTheLoadedBookSeeksInPlace() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    player.pushProgress(Self.progress(sequence: 1, phase: .paused, at: 300))
    await waitUntil("the pause is applied") { model.phase == .paused }
    await queue.configure(rows: [Self.row(1, book, chapter: Self.chapterTwo)])

    await model.start(queueItem: Self.row(1, book, chapter: Self.chapterTwo))

    #expect(
      player.intents.suffix(3) == [
        .seek(toGlobalOffset: 1_000), .setSegment(start: 1_000, end: 2_000), .play,
      ])
    #expect(Self.startSessionCount(sync) == 1)
    #expect(await queue.identities.isEmpty, "the row is consumed, or it would start again at its end")
  }

  @MainActor
  @Test("reaching a chapter's end starts the next row without closing or finishing the book")
  func segmentEndAdvancesToTheNextRow() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(identity: book1, queuedChapter: Self.queued(Self.chapterTwo))
    await queue.configure(rows: [Self.row(2, book2)])

    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    player.pushProgress(Self.progress(sequence: 1, phase: .paused, at: 2_000, segmentEnd: .reached))
    await queue.waitForAcknowledgements(2)

    #expect(model.loadedItemID == "book-2")
    #expect(await queue.identities.isEmpty)
    #expect(sync.calls.contains(.stopSession) == false, "the book is not finished; nothing closes it here")
    let finishedTicks = sync.calls.filter {
      if case .recordProgressTick(_, _, _, let isFinished, _) = $0 { isFinished } else { false }
    }
    #expect(finishedTicks.isEmpty)
  }

  @MainActor
  @Test("the next row being a chapter of the same book plays on in place")
  func nextChapterOfTheSameBookPlaysOnInPlace() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(identity: book, queuedChapter: Self.queued(Self.chapterTwo))
    await queue.configure(rows: [Self.row(1, book, chapter: Self.chapterThree)])

    player.pushProgress(Self.progress(sequence: 1, phase: .paused, at: 2_000, segmentEnd: .reached))
    await queue.waitForAcknowledgements(2)

    #expect(
      player.intents.suffix(3) == [
        .seek(toGlobalOffset: 2_000), .setSegment(start: 2_000, end: 2_500), .play,
      ])
    #expect(Self.startSessionCount(sync) == 1)
    #expect(model.loadedItemID == "book-1")
  }

  @MainActor
  @Test("with nothing queued the book stays loaded and paused at the chapter's end")
  func emptyQueueLeavesTheBookPausedAtTheChapterEnd() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(identity: book, queuedChapter: Self.queued(Self.chapterTwo))
    let intents = player.intents

    player.pushProgress(Self.progress(sequence: 1, phase: .paused, at: 2_000, segmentEnd: .reached))
    await queue.waitForPeek()

    #expect(model.phase == .paused)
    #expect(model.loadedItemID == "book-1")
    #expect(model.activeItemID == "book-1")
    #expect(player.intents == intents)
    #expect(Self.startSessionCount(sync) == 1)
  }

  @MainActor
  @Test("a finished title hands the next row's chapter to its start")
  func completionStartsTheNextRowAtItsChapter() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await queue.configure(rows: [Self.row(2, book2, chapter: Self.chapterTwo)])

    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "book-1", phase: .ended, currentTime: 3_000, listenedDelta: 1))
    await queue.waitForAcknowledgements(3)

    #expect(model.loadedItemID == "book-2")
    #expect(Self.loadPosition(player.intents) == 1_000)
    #expect(player.intents.suffix(2) == [.setSegment(start: 1_000, end: 2_000), .play])
  }

  @MainActor
  @Test("a prepared continuation keeps a chapter row's extent and never plays")
  func preparedContinuationKeepsTheChapterExtent() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    await queue.configure(rows: [Self.row(2, book2, chapter: Self.chapterTwo)])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-2", startPosition: 250)))
    let intents = player.intents

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    let sent = Array(player.intents.dropFirst(intents.count))
    #expect(Self.loadPosition(sent) == 1_000, "the chapter row starts where its chapter does")
    #expect(
      sent.suffix(1) == [.setSegment(start: 1_000, end: 2_000)],
      "the chapter's end is armed and nothing is played")
    #expect(sent.contains(.play) == false)
    #expect(await queue.identities.isEmpty, "the prepared row is consumed")
  }

  // MARK: - Several chapter rows of one book

  @MainActor
  @Test("starting one chapter row consumes that row and leaves the book's other chapters")
  func startingAChapterRowConsumesOnlyIt() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let rows = [Self.row(1, book, chapter: Self.chapterTwo), Self.row(2, book, chapter: Self.chapterThree)]
    await queue.configure(rows: rows)
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))

    await model.start(queueItem: rows[0])

    #expect(await queue.acknowledgedRowIDs == [1])
    #expect(await queue.rowIDs == [2])
  }

  @MainActor
  @Test("a start from outside Up Next leaves the book's chapter rows queued")
  func outsideStartLeavesChapterRows() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await queue.configure(rows: [
      Self.row(1, book, chapter: Self.chapterTwo), Self.row(2, book, chapter: Self.chapterThree),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))

    await model.start(itemID: "book-1")

    #expect(await queue.acknowledgedRowIDs == [nil])
    #expect(await queue.rowIDs == [1, 2])
  }

  @MainActor
  @Test("a book that plays to its end keeps its queued chapter rows")
  func naturalFinishKeepsChapterRows() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await queue.configure(rows: [Self.row(1, book2), Self.row(2, book1, chapter: Self.chapterTwo)])

    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "book-1", phase: .ended, currentTime: 3_000, listenedDelta: 1))
    await queue.waitForAcknowledgements(3)

    #expect(model.loadedItemID == "book-2")
    #expect(await queue.rowIDs == [2], "book-1's chapter row outlives the book's finish")
  }

  @MainActor
  @Test("Mark as Finished clears every row of the book before the next row is prepared")
  func markAsFinishedClearsEveryRow() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    await queue.configure(rows: [
      Self.row(1, book1, chapter: Self.chapterTwo), Self.row(2, book2),
      Self.row(3, book1, chapter: Self.chapterThree),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    #expect(await queue.removed == [book1])
    #expect(model.loadedItemID == "book-2")
    #expect(await queue.rowIDs.isEmpty)
  }

  @MainActor
  @Test("a played-out book's paused continuation keeps its chapter rows and prepares the first")
  func playedOutContinuationKeepsChapterRows() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    await queue.configure(rows: [
      Self.row(1, book1, chapter: Self.chapterTwo), Self.row(2, book1, chapter: Self.chapterThree),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))

    await model.prepareContinuationPaused(
      after: book1, clearing: .wholeBookRow, generation: generation)

    #expect(await queue.removed.isEmpty)
    #expect(Self.loadPosition(player.intents) == 1_000)
    #expect(await queue.rowIDs == [2], "only the prepared chapter row is consumed")
  }

  @MainActor
  @Test("retrying a failed chapter start replays the chapter and consumes its row")
  func retryReplaysTheChapter() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let rows = [Self.row(1, book, chapter: Self.chapterTwo), Self.row(2, book, chapter: Self.chapterThree)]
    await queue.configure(rows: rows)
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("book-1")))

    await model.start(queueItem: rows[0])
    #expect(model.startFailure != nil)
    #expect(await queue.rowIDs == [1, 2], "a failed start consumes nothing")

    sync.stubStartSession(.success(Self.prepared(itemID: "book-1", startPosition: 250)))
    #expect(model.retry())
    await queue.waitForAcknowledgements(1)

    #expect(Self.loadPosition(player.intents) == 1_000)
    #expect(player.intents.contains(.setSegment(start: 1_000, end: 2_000)))
    #expect(await queue.acknowledgedRowIDs == [1])
    #expect(await queue.rowIDs == [2])
  }

  // MARK: - Fixtures

  @MainActor
  private static func makeModel() -> (
    PlaybackModel, FakePlaybackControlling, FakePlaybackSyncing, RecordingListeningQueue
  ) {
    let queue = RecordingListeningQueue()
    let playback = PlaybackModelHarness(listeningQueue: queue)
    return (playback.model, playback.player, playback.sync, queue)
  }

  /// The position of the most recent load.
  private static func loadPosition(_ intents: [PlayerIntent]) -> Double? {
    for intent in intents.reversed() {
      if case .load(_, let position, _, _) = intent { return position }
    }
    return nil
  }

  private static func startSessionCount(_ sync: FakePlaybackSyncing) -> Int {
    sync.calls.filter {
      if case .startSession = $0 { true } else { false }
    }.count
  }

  private static func progress(
    sequence: Int, phase: PlayerPhase, at position: Double,
    segmentEnd: PlaybackProgressEvent.SegmentEnd = .none
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: sequence, itemId: "book-1", phase: phase, currentTime: position, listenedDelta: 1,
      segmentEnd: segmentEnd)
  }

  private static func prepared(itemID: String, startPosition: Double = 0) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: nil, startPosition: startPosition, duration: 3_000,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 3_000,
          url: URL(string: "https://example.test/audio.mp3")!,
          mimeType: "audio/mpeg", title: itemID)
      ],
      chapters: [])
  }

  /// A chapter row the test never configures in the fake queue, so starting it consumes nothing.
  private static func queued(_ chapter: ListeningQueueChapter) -> ListeningQueueRowChapter {
    ListeningQueueRowChapter(rowID: 99, chapter: chapter)
  }

  private static func row(
    _ id: Int64, _ identity: ListeningIdentity, chapter: ListeningQueueChapter? = nil
  ) -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: Int(id) - 1, identity: identity, primaryTitle: "Row \(id)",
      secondaryTitle: "Secondary", category: .audiobook, isTombstone: false, chapter: chapter)
  }
}
