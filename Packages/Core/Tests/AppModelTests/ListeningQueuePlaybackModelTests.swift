import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The one playback state machine consumes the universal queue for both media types.
/// The first test covers an identity that is both Now Playing and queued: without step 3's
/// `acknowledgeStarted` for the completed identity, the peek in step 4 returns the item that just
/// finished and it replays forever.
@Suite(.timeLimit(.minutes(1)))
struct ListeningQueuePlaybackModelTests {
  @MainActor
  @Test("finishing an identity that is also queued consumes its own row and advances to the next")
  func nowPlayingIdentityAlsoQueuedAdvancesToTheNextRow() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await queue.configure(rows: [
      Self.row(1, book1),
      Self.row(2, book2),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    #expect(await queue.identities == [book2], "a manual start consumes its own row")

    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    player.pushProgress(Self.ended(itemID: "book-1"))
    await queue.waitForAcknowledgements(3)

    #expect(model.loadedItemID == "book-2")
    #expect(await queue.identities.isEmpty)
    #expect(
      await queue.acknowledged == [
        book1, book1, book2,
      ],
      "acknowledged on manual start, again on its own completion, then for the new identity")
  }

  @MainActor
  @Test("a completed audiobook closes before advancing to a queued episode")
  func completedAudiobookAdvancesToQueuedEpisode() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-a"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await queue.configure(
      rows: [Self.row(1, episode)],
      syncCalls: { sync.calls })

    sync.stubStartSession(.success(Self.prepared(itemID: "show", episodeID: "episode-a")))
    player.pushProgress(Self.ended(itemID: "book-1"))
    await queue.waitForAcknowledgements(3)

    #expect(model.loadedItemID == "show")
    #expect(model.loadedEpisodeID == "episode-a")
    #expect(await queue.sawCloseBeforePeek, "the former session closes before the queue is peeked")
    #expect(await queue.identities.isEmpty)
  }

  @MainActor
  @Test("a completed episode closes before advancing to a queued audiobook")
  func completedEpisodeAdvancesToQueuedAudiobook() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "show", episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    await queue.configure(rows: [Self.row(1, book1)], syncCalls: { sync.calls })

    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    player.pushProgress(Self.ended(itemID: "show", episodeID: "episode-a"))
    await queue.waitForAcknowledgements(3)

    #expect(model.loadedItemID == "book-1")
    #expect(model.loadedEpisodeID == nil)
    #expect(await queue.sawCloseBeforePeek)
    #expect(await queue.identities.isEmpty)
  }

  @MainActor
  @Test("an empty queue closes and stops without inventing a next identity")
  func emptyQueueStopsCleanly() async {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")

    player.pushProgress(Self.ended(itemID: "book-1"))
    await queue.waitForPeek()

    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.loadedItemID == nil)
    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == 1)
  }

  // MARK: - Preparing a continuation paused (D3, D4, D8)

  @MainActor
  @Test("with nothing queued a paused preparation starts nothing and leaves presence clear")
  func preparedContinuationWithAnEmptyQueueStartsNothing() async throws {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    let queue = RecordingListeningQueue()
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), bookmarkStore: bookmarks, listeningQueue: queue)
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 100, isFinished: true))
    await waitUntil { model.nowPlayingIdentity == nil }
    let intents = player.intents

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.startFailure == nil)
    #expect(player.intents.dropFirst(intents.count).isEmpty, "nothing loads and nothing plays")
    #expect(await queue.peekCount == 1, "the empty queue is peeked once")
    #expect(model.nowPlayingIdentity == nil, "the finished bookmark keeps presence clear")
  }

  @MainActor
  @Test("a live row is prepared paused: it loads, is acknowledged, and never plays")
  func preparedContinuationLoadsTheNextRowWithoutPlaying() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    await queue.configure(rows: [Self.row(1, book2)])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    let intents = player.intents

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    let sent = Array(player.intents.dropFirst(intents.count))
    #expect(sent.contains(.play) == false, "a prepared continuation never plays")
    #expect(sent.contains { if case .load = $0 { true } else { false } })
    #expect(model.activeItemID == "book-2")
    #expect(model.loadedItemID == "book-2")
    #expect(model.startFailure == nil)
    #expect(await queue.identities.isEmpty, "the prepared row is consumed")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "book-2", phase: .ready, currentTime: 0, listenedDelta: 0))
    await waitUntil { model.phase == .paused }
  }

  /// The store's unique indexes allow one row per identity, but the model must not depend on
  /// that: it removes by identity before peeking, so no row it could hold names the finished
  /// title. The fake holds two here to pin the call.
  @MainActor
  @Test("the finished identity's row is removed before the peek")
  func preparationRemovesTheFinishedIdentitysRowFirst() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    await queue.configure(rows: [
      Self.row(1, book1),
      Self.row(2, book2),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    let intents = player.intents

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    #expect(await queue.removed == [book1])
    #expect(await queue.sawRemoveBeforePeek, "the row goes before the peek, never after")
    #expect(
      await queue.identities.isEmpty,
      "the finished title's row and the prepared row are both gone")
    #expect(model.loadedItemID == "book-2", "the peek never returned the finished book")
    #expect(Array(player.intents.dropFirst(intents.count)).contains(.play) == false)
  }

  @MainActor
  @Test("a preparation leaves a title the user has already started alone")
  func preparationLeavesAnActiveTitleAlone() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    let generation = model.playbackGeneration
    await queue.configure(rows: [Self.row(1, book2)])
    let intents = player.intents

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    #expect(await queue.removed.isEmpty)
    #expect(await queue.peekCount == 0)
    #expect(model.activeItemID == "book-1")
    #expect(player.intents == intents)
  }

  /// A Play tapped inside the finish write lands between the row removal and the peek. It must
  /// win: the stale preparation may not steal the row it was about to prepare.
  @MainActor
  @Test("a Play during the gap wins over the paused preparation")
  func playDuringTheGapWins() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    await queue.configure(rows: [Self.row(1, book2)])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    await queue.holdNextRemove()

    let preparation = Task { @MainActor in
      await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)
    }
    await queue.waitForRemove()

    sync.stubStartSession(.success(Self.prepared(itemID: "user-choice")))
    await model.start(itemID: "user-choice")
    await queue.releaseRemove()
    await preparation.value

    #expect(model.activeItemID == "user-choice")
    #expect(model.loadedItemID == "user-choice")
    #expect(await queue.peekCount == 0, "a displaced preparation never peeks")
    #expect(await queue.identities == [book2], "the row stays for the user's own next finish")
  }

  @MainActor
  @Test("a failed preparation start stays in the player for recovery")
  func failedPreparedStartIsRecoverable() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    await queue.configure(rows: [Self.row(1, book2)])
    sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))
    let intents = player.intents

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    #expect(model.phase == .recoverableError)
    #expect(model.activeItemID == "book-2")
    #expect(model.startFailureMessage == PlaybackCopy.genericStartFailure)
    #expect(model.startFailure?.origin == .queueAdvance)
    #expect(model.nowPlayingIdentity == book2, "the prepared row is present so its banner shows")
    #expect(await queue.identities == [book2], "a failed start leaves its row")
    #expect(Array(player.intents.dropFirst(intents.count)).contains(.play) == false)
  }

  /// Before `start` there is no active identity, so presence is `nil` and nothing can render a
  /// failure. The row removal fails here; the scope must stay silent.
  @MainActor
  @Test("a failure before the start sets nothing")
  func failureBeforeTheStartSetsNothing() async throws {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    let queue = RecordingListeningQueue()
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), bookmarkStore: bookmarks, listeningQueue: queue)
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await model.stop()
    let generation = model.playbackGeneration
    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 100, isFinished: true))
    await waitUntil { model.nowPlayingIdentity == nil }
    await queue.configure(rows: [Self.row(1, book2)])
    await queue.failNextRemove()

    await model.prepareContinuationPaused(after: book1, clearing: .everyRow, generation: generation)

    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.startFailure == nil)
    #expect(model.startFailureMessage == nil)
    #expect(await queue.peekCount == 0)
    #expect(await queue.identities == [book2])
    #expect(model.nowPlayingIdentity == nil)
  }

  /// D4: the sleep timer's `endBehavior == .stop` completion still prepares a continuation, and
  /// it must never resume playback the listener asked to end.
  @MainActor
  @Test("an end-of-episode timer with a live row prepares it paused and never plays")
  func sleepTimerCompletionPreparesTheNextRowPaused() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-a"))
    sync.stubStartSession(.success(Self.prepared(itemID: "show", episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    await queue.configure(rows: [Self.row(1, book1)])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    let intents = player.intents

    player.pushProgress(Self.ended(itemID: "show", episodeID: "episode-a", endBehavior: .stop))
    // The episode's own start, its completion consuming its row, then the prepared book's start.
    await queue.waitForAcknowledgements(3)

    let sent = Array(player.intents.dropFirst(intents.count))
    #expect(sent.contains(.play) == false, "the timer asked for silence")
    #expect(model.loadedItemID == "book-1", "the next row is prepared, not played")
    #expect(model.startFailure == nil)
    #expect(await queue.identities.isEmpty)
    #expect(
      await queue.acknowledged.suffix(2) == [episode, book1],
      "the finished episode's own row goes first")
    #expect(await queue.removed.isEmpty, "a played-out title keeps its queued chapter rows")
  }

  @MainActor
  @Test("a countdown expiry at the item end prepares the next row paused too")
  func countdownExpiryAtTheItemEndPreparesPaused() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "show", episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    await queue.configure(rows: [Self.row(1, book1)])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    let intents = player.intents

    player.pushProgress(
      Self.ended(
        itemID: "show", episodeID: "episode-a", endBehavior: .stop, sleepTimerExpiry: .expired))
    await queue.waitForAcknowledgements(3)

    #expect(Array(player.intents.dropFirst(intents.count)).contains(.play) == false)
    #expect(model.loadedItemID == "book-1")
    #expect(await queue.identities.isEmpty)
  }

  @MainActor
  @Test("a sleep-timer completion with nothing queued clears presence")
  func sleepTimerCompletionWithAnEmptyQueueClearsPresence() async throws {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    let queue = RecordingListeningQueue()
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), bookmarkStore: bookmarks, listeningQueue: queue)
    sync.stubStartSession(.success(Self.prepared(itemID: "show", episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    bookmarks.push(
      Self.bookmark(itemID: "show", episodeID: "episode-a", positionSeconds: 100, isFinished: true))
    await waitUntil { model.displayedItem?.isFinished == true }
    let intents = player.intents

    player.pushProgress(Self.ended(itemID: "show", episodeID: "episode-a", endBehavior: .stop))
    await queue.waitForPeek()

    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.nowPlayingIdentity == nil, "the finished bookmark no longer presents")
    #expect(model.startFailure == nil)
    #expect(Array(player.intents.dropFirst(intents.count)).contains(.play) == false)
  }

  @MainActor
  @Test("a tombstoned row is skipped and retained")
  func tombstoneIsSkippedAndRetained() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let gone = try #require(ListeningIdentity.audiobook(itemID: "gone"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await queue.configure(rows: [
      Self.row(1, gone, isTombstone: true),
      Self.row(2, book2),
    ])

    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    player.pushProgress(Self.ended(itemID: "book-1"))
    await queue.waitForAcknowledgements(3)

    #expect(
      await queue.identities == [gone],
      "a skipped tombstone stays queued until the user removes it")
  }

  @MainActor
  @Test("failed preparation of the next row retains it and stays visible for recovery")
  func failedNextPreparationRetainsItsRow() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await queue.configure(rows: [Self.row(1, book2)])
    sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))

    player.pushProgress(Self.ended(itemID: "book-1"))
    await waitUntil { model.startFailureMessage != nil }

    #expect(await queue.identities == [book2])
    #expect(model.phase == .recoverableError)
    #expect(model.activeItemID == "book-2")
    #expect(model.loadedItemID == nil)
    #expect(model.nowPlayingIdentity == book2)
    #expect(model.startFailureMessage == PlaybackCopy.genericStartFailure)
    // Nobody tapped this play. A surface that treats it like a requested one interrupts a listener
    // whose title simply ended while the device was in their pocket.
    #expect(model.startFailure?.origin == .queueAdvance)

    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    model.retry()
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 3
    }
    await queue.waitForAcknowledgements(3)
    #expect(model.loadedItemID == "book-2")
    #expect(await queue.identities.isEmpty)
  }

  @MainActor
  @Test("a selected row leaves Up Next only after preparation succeeds")
  func selectedRowIsRemovedOnlyAfterSuccessfulPreparation() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await queue.configure(rows: [Self.row(1, book1)])
    sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))

    await model.start(itemID: "book-1")
    #expect(await queue.identities == [book1])
    #expect(await queue.acknowledged.isEmpty)

    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    #expect(await queue.identities.isEmpty)
    #expect(await queue.acknowledged == [book1])
  }

  @MainActor
  @Test("a manual play of a queued identity removes only that row from mid-queue")
  func manualPlayRemovesOnlyItsOwnMidQueueRow() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-a"))
    let book3 = try #require(ListeningIdentity.audiobook(itemID: "book-3"))
    await queue.configure(rows: [
      Self.row(1, book1),
      Self.row(2, episode),
      Self.row(3, book3),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "show", episodeID: "episode-a")))

    await model.start(itemID: "show", episodeID: "episode-a")

    #expect(
      await queue.identities == [book1, book3],
      "the other rows keep their relative order")
  }

  @MainActor
  @Test("a manual switch to an unqueued identity preserves every queued row")
  func manualSwitchPreservesQueueOrder() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    let elsewhere = try #require(ListeningIdentity.audiobook(itemID: "elsewhere"))
    await queue.configure(rows: [
      Self.row(1, book1),
      Self.row(2, book2),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "elsewhere")))

    await model.start(itemID: "elsewhere")

    #expect(
      await queue.identities == [book1, book2])
    #expect(await queue.acknowledged == [elsewhere])
  }

  @MainActor
  @Test("a direct native RSS start consumes its own mixed-source queue row")
  func nativeRSSStartConsumesItsQueueRow() async throws {
    let (model, _, sync, queue) = Self.makeModel()
    let rss = try #require(ListeningIdentity.rssEpisode(feedID: 1, episodeID: "episode-a"))
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await queue.configure(rows: [
      Self.row(1, rss), Self.row(2, book1),
    ])
    sync.stubStartSession(.success(Self.prepared(itemID: "rss:1", episodeID: "episode-a")))

    await model.start(itemID: "rss:1", episodeID: "episode-a")

    #expect(await queue.identities == [book1])
    #expect(await queue.acknowledged == [rss])
  }

  @MainActor
  @Test("native RSS completion advances to an ABS row")
  func nativeRSSCompletionAdvancesToABS() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    sync.stubStartSession(.success(Self.prepared(itemID: "rss:1", episodeID: "episode-a")))
    await model.start(itemID: "rss:1", episodeID: "episode-a")
    await queue.configure(rows: [Self.row(1, book1)])
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))

    player.pushProgress(Self.ended(itemID: "rss:1", episodeID: "episode-a"))
    await queue.waitForAcknowledgements(3)

    #expect(model.loadedItemID == "book-1")
    #expect(model.loadedEpisodeID == nil)
    #expect(await queue.identities.isEmpty)
  }

  @MainActor
  @Test("ABS completion advances to a native RSS row")
  func absCompletionAdvancesToNativeRSS() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    let rss = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "native-next"))
    await queue.configure(rows: [Self.row(1, rss)])
    sync.stubStartSession(.success(Self.prepared(itemID: "rss:7", episodeID: "native-next")))

    player.pushProgress(Self.ended(itemID: "book-1"))
    await queue.waitForAcknowledgements(3)

    #expect(model.loadedItemID == "rss:7")
    #expect(model.loadedEpisodeID == "native-next")
    #expect(await queue.identities.isEmpty)
  }

  @MainActor
  @Test("relaunch reconciles a queue row matching the already-prepared playback identity")
  func relaunchReconcilesTheSuccessfulStartCrashWindow() async throws {
    let bookmarks = FakePlaybackBookmarkStoring()
    let queue = RecordingListeningQueue()
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-a"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await queue.configure(rows: [
      Self.row(1, episode),
      Self.row(2, book2),
    ])
    let playback = PlaybackModelHarness(
      bookmarkStore: bookmarks, listeningQueue: queue)
    let model = playback.model
    let sync = playback.sync

    bookmarks.push(
      PlaybackBookmark(
        serverItemId: "show", episodeID: "episode-a", episodeTitle: "Episode A",
        showTitle: "Show", title: "Episode A", author: nil, durationSeconds: 100,
        positionSeconds: 42, isFinished: false))
    await queue.waitForAcknowledgements()

    #expect(
      await queue.acknowledged == [episode])
    #expect(await queue.identities == [book2])
    #expect(
      sync.calls.contains { if case .startSession = $0 { return true } else { return false } }
        == false,
      "reconciliation never starts playback of its own")
    _ = model
  }

  @MainActor
  @Test("relaunching a retained native RSS bookmark reconciles its mixed-source queue row")
  func nativeRSSRelaunchReconcilesQueueRow() async throws {
    let bookmarks = FakePlaybackBookmarkStoring()
    let queue = RecordingListeningQueue()
    let rss = try #require(ListeningIdentity.rssEpisode(feedID: 1, episodeID: "episode-a"))
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await queue.configure(rows: [
      Self.row(1, rss), Self.row(2, book1),
    ])
    let model = PlaybackModelHarness(bookmarkStore: bookmarks, listeningQueue: queue).model

    bookmarks.push(Self.bookmark(itemID: "rss:1", episodeID: "episode-a", positionSeconds: 42))
    await queue.waitForAcknowledgements()

    #expect(await queue.identities == [book1])
    #expect(await queue.acknowledged == [rss])
    _ = model
  }

  /// A finished bookmark is presence-less, so the relaunch reconciliation must not treat it as the
  /// identity whose queue row was acknowledged before the process ended. Removing that row would
  /// silently lose Up Next while nothing is presented.
  @MainActor
  @Test("a cold launch onto a finished bookmark leaves its queued row intact")
  func finishedRelaunchLeavesItsQueueRowIntact() async throws {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    let queue = RecordingListeningQueue()
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await queue.configure(rows: [
      Self.row(1, book1),
      Self.row(2, book2),
    ])
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), bookmarkStore: bookmarks, listeningQueue: queue)

    bookmarks.push(
      Self.bookmark(itemID: "book-1", positionSeconds: 100, isFinished: true))
    await waitUntil { model.displayedItem?.isFinished == true }

    #expect(model.nowPlayingIdentity == nil)
    // A later, unfinished marker proves the observation is live: it reconciles, while the finished
    // title was never acknowledged and keeps its row.
    bookmarks.push(Self.bookmark(itemID: "book-2", positionSeconds: 5))
    await queue.waitForAcknowledgements()

    #expect(await queue.acknowledged == [book2])
    #expect(
      await queue.identities == [book1],
      "the finished title's row survives the reconciliation")
  }

  /// The menu half of the presence rule: once the retained title is finished and presence clears,
  /// every item menu withdraws Play Next / Add to Up Next and falls back to Play.
  @MainActor
  @Test("clearing presence after a finish withdraws the queue menus")
  func aFinishWithdrawsTheQueueMenus() async throws {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), bookmarkStore: bookmarks)
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))

    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 42))
    await waitUntil { model.displayedItem != nil }
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: book2.itemID, episodeID: nil, category: .audiobook,
        nowPlaying: model.nowPlayingIdentity) == .both)

    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 100, isFinished: true))
    await waitUntil { model.nowPlayingIdentity == nil }

    #expect(model.displayedItem?.isFinished == true)
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: book2.itemID, episodeID: nil, category: .audiobook,
        nowPlaying: model.nowPlayingIdentity) == .none)
  }

  /// The mini-player retains the last successful item, so a policy keyed to
  /// `activeItemID` alone would withdraw every queue action the moment playback stopped.
  @MainActor
  @Test("the Now Playing identity survives as the retained item once nothing is active")
  func nowPlayingIdentityIsTheRetainedItemWhenNothingIsActive() async throws {
    let bookmarks = FakePlaybackBookmarkStoring()
    let model = PlaybackModelHarness(bookmarkStore: bookmarks).model
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    #expect(model.nowPlayingIdentity == nil, "nothing has ever played")

    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 42))
    await waitUntil { model.displayedItem != nil }

    #expect(model.activeItemID == nil)
    #expect(model.nowPlayingIdentity == book1)
  }

  @MainActor
  @Test("an active identity wins over the retained one")
  func nowPlayingIdentityPrefersTheActiveIdentity() async throws {
    let bookmarks = FakePlaybackBookmarkStoring()
    let playback = PlaybackModelHarness(bookmarkStore: bookmarks)
    let model = playback.model
    let sync = playback.sync
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-a"))

    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 42))
    await waitUntil { model.displayedItem != nil }

    sync.stubStartSession(.success(Self.prepared(itemID: "show", episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")

    #expect(model.nowPlayingIdentity == episode)

    await model.stop()
    #expect(
      model.nowPlayingIdentity == book1,
      "stopping falls back to the retained projection rather than withdrawing queue actions")
  }

  /// The performance half of the policy: menus read this one property, and the retained position
  /// moves on every save. Neither the bookmark nor anything derived from it may invalidate its
  /// readers unless the identity moved.
  @MainActor
  @Test("a retained position update republishes neither the bookmark nor its Now Playing identity")
  func retainedPositionUpdatesRepublishNeitherTheBookmarkNorNowPlayingIdentity() async throws {
    let bookmarks = FakePlaybackBookmarkStoring()
    let model = PlaybackModelHarness(bookmarkStore: bookmarks).model
    let book1 = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 10))
    await waitUntil { model.displayedItem != nil }

    let displayedItemInvalidations = InvalidationCounter()
    withObservationTracking {
      _ = model.displayedItem
    } onChange: {
      displayedItemInvalidations.count += 1
    }

    let identityInvalidations = InvalidationCounter()
    withObservationTracking {
      _ = model.nowPlayingIdentity
    } onChange: {
      identityInvalidations.count += 1
    }

    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 90))
    await waitUntil { model.displayedItemPositionSeconds == 90 }

    #expect(displayedItemInvalidations.count == 0)
    #expect(identityInvalidations.count == 0)
    #expect(model.nowPlayingIdentity == book1)
  }

  @MainActor
  @Test("a repeated ended callback cannot consume the queue twice")
  func repeatedEndedCallbacksCannotConsumeTwice() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    let book2 = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    let book3 = try #require(ListeningIdentity.audiobook(itemID: "book-3"))
    sync.stubStartSession(.success(Self.prepared(itemID: "book-1")))
    await model.start(itemID: "book-1")
    await queue.configure(rows: [
      Self.row(1, book2),
      Self.row(2, book3),
    ])

    sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    let ended = Self.ended(itemID: "book-1")
    player.pushProgress(ended)
    await queue.waitForAcknowledgements(3)

    player.pushProgress(ended)
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 9, itemId: "book-2", phase: .playing, currentTime: 1, listenedDelta: 1))
    await waitUntil { sync.progressIdentityCalls.last?.itemID == "book-2" }

    #expect(await queue.peekCount == 1)
    #expect(await queue.identities == [book3])
  }

  @MainActor
  private static func makeModel() -> (
    PlaybackModel, FakePlaybackControlling, FakePlaybackSyncing, RecordingListeningQueue
  ) {
    let queue = RecordingListeningQueue()
    let playback = PlaybackModelHarness(listeningQueue: queue)
    return (playback.model, playback.player, playback.sync, queue)
  }

  private static func ended(
    itemID: String, episodeID: String? = nil,
    endBehavior: PlaybackProgressEvent.EndBehavior = .advanceQueue,
    sleepTimerExpiry: PlaybackProgressEvent.SleepTimerExpiry = .none
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: 1, itemId: itemID, episodeID: episodeID, phase: .ended, currentTime: 100,
      listenedDelta: 1, endBehavior: endBehavior, sleepTimerExpiry: sleepTimerExpiry)
  }

  private static func prepared(itemID: String, episodeID: String? = nil) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/audio.mp3")!,
          mimeType: "audio/mpeg", title: itemID)
      ],
      chapters: [])
  }

  private static func bookmark(
    itemID: String, episodeID: String? = nil, positionSeconds: Double,
    isFinished: Bool = false
  ) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: itemID, episodeID: episodeID, episodeTitle: episodeID, showTitle: nil,
      title: itemID, author: nil, durationSeconds: 100, positionSeconds: positionSeconds,
      isFinished: isFinished)
  }

  private static func row(
    _ id: Int64, _ identity: ListeningIdentity, isTombstone: Bool = false,
    chapter: ListeningQueueChapter? = nil
  ) -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: Int(id) - 1, identity: identity, primaryTitle: "Row \(id)",
      secondaryTitle: "Secondary",
      category: identity.episodeID == nil ? .audiobook : .podcast, isTombstone: isTombstone,
      chapter: chapter)
  }
}

enum ListeningQueueFixtureFailure: Error { case failed }

/// `withObservationTracking`'s `onChange` is `@Sendable`, but it fires synchronously on the thread
/// that performed the mutation (here always the main actor), so a plain box is enough.
private final class InvalidationCounter: @unchecked Sendable {
  var count = 0
}

/// A fake with real removal semantics: `acknowledgeStarted` actually drops the matching row, so a
/// later `peekNextLive` cannot return the identity that just finished.
// Kept: shared across many other test files, and it probes the sync fake's calls at peek time
// (`sawCloseBeforePeek`), which `FakeListeningQueueStoring` has no seam for.
actor RecordingListeningQueue: ListeningQueueStoring {
  private var rows: [ListeningQueueItem] = []
  private(set) var acknowledged: [ListeningIdentity] = []
  private(set) var acknowledgedRowIDs: [Int64?] = []
  private(set) var removed: [ListeningIdentity] = []
  /// The titles swaps returned to the front, in order.
  private(set) var returned: [ListeningIdentity] = []
  private(set) var peekCount = 0
  private(set) var sawCloseBeforePeek = false
  private(set) var sawRemoveBeforePeek = false
  private var syncCalls: @Sendable () -> [FakePlaybackSyncing.RecordedCall] = { [] }
  private nonisolated let peeks = TestCountRecorder(label: "RecordingListeningQueue peeks")
  private nonisolated let acknowledgements = TestCountRecorder(
    label: "RecordingListeningQueue acknowledgements")
  private nonisolated let removals = TestCountRecorder(label: "RecordingListeningQueue removals")
  private var failsNextRemove = false
  private var holdsNextRemove = false
  // A held removal runs to completion regardless of cancellation, as the store's does.
  private nonisolated let removeGate = TestGate<Void>(
    label: "RecordingListeningQueue remove", ignoresCancellation: true)

  var identities: [ListeningIdentity] { rows.map(\.identity) }
  var rowIDs: [Int64] { rows.map(\.id) }

  func configure(
    rows: [ListeningQueueItem],
    syncCalls: @escaping @Sendable () -> [FakePlaybackSyncing.RecordedCall] = { [] }
  ) {
    self.rows = rows
    self.syncCalls = syncCalls
  }

  @discardableResult
  func append(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws -> ListeningQueueAppendOutcome
  { .appended }
  func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {}
  @discardableResult
  func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] { [] }
  /// The deferred removal a preparation takes: every row of the title, as the store does. The
  /// gate and the failure seam let a test interleave a user's own Play, or a failed removal.
  func remove(identity: ListeningIdentity) async throws {
    removed.append(identity)
    removals.record()
    if failsNextRemove {
      failsNextRemove = false
      throw ListeningQueueFixtureFailure.failed
    }
    rows.removeAll { $0.identity == identity }
    guard holdsNextRemove else { return }
    holdsNextRemove = false
    await removeGate.pass()
  }

  /// Holds the next `remove` until `releaseRemove`, so a test can land a user's own Play in the
  /// gap between the removal and the peek.
  func holdNextRemove() {
    holdsNextRemove = true
    removeGate.hold()
  }

  /// Returns once a removal has arrived and, when it is held, once it is parked.
  func waitForRemove() async {
    await removals.waitUntil(count: 1)
    if removeGate.isHeld { await removeGate.waitUntilParked() }
  }

  func releaseRemove() {
    removeGate.release()
  }

  func failNextRemove() { failsNextRemove = true }
  func remove(rowID: Int64) async throws {}
  func move(rowID: Int64, to position: Int) async throws {}
  func clear() async throws -> ListeningQueueRestoreToken {
    try await NoOpListeningQueueStore().clear()
  }
  func restore(token: ListeningQueueRestoreToken) async throws {}

  func peekNextLive() async -> ListeningQueueItem? {
    peekCount += 1
    sawCloseBeforePeek = sawCloseBeforePeek || syncCalls().contains(.stopSession)
    sawRemoveBeforePeek = sawRemoveBeforePeek || removed.isEmpty == false
    peeks.record()
    return rows.first { $0.isTombstone == false }
  }

  /// The store's narrowed consumption: the title's whole-book or episode row, and the chapter row
  /// `rowID` names. The book's other chapter rows stay.
  func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {
    acknowledged.append(identity)
    acknowledgedRowIDs.append(rowID)
    rows.removeAll { $0.identity == identity && ($0.chapter == nil || $0.id == rowID) }
    acknowledgements.record()
  }

  /// The store's swap: the started rows go, as `acknowledgeStarted` takes them, and the displaced
  /// title takes the front as a whole row.
  func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool {
    returned.append(displaced)
    rows.removeAll { $0.identity == identity && ($0.chapter == nil || $0.id == rowID) }
    rows.removeAll { $0.identity == displaced && $0.chapter == nil }
    let id = (rows.map(\.id).max() ?? 0) + 1
    rows.insert(
      ListeningQueueItem(
        id: id, position: 0, identity: displaced, primaryTitle: "Returned",
        secondaryTitle: "Secondary",
        category: displaced.episodeID == nil ? .audiobook : .podcast, isTombstone: false,
        chapter: nil),
      at: 0)
    acknowledgements.record()
    return true
  }

  func waitForPeek() async {
    await peeks.waitUntil(count: 1)
  }

  /// `acknowledgeStarted` is the last thing a successful `start` does, so waiting on the session
  /// call alone would observe the queue mid-consumption.
  func waitForAcknowledgements(_ count: Int = 1) async {
    await acknowledgements.waitUntil(count: count)
  }
}
