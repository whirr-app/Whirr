import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension PlaybackModelTests {
  // MARK: - Retained displayed item: independent of the active session

  @Test func successfulStartWritesTheBookmarkOnlyAfterPreparationSucceeds() async {
    let (model, _, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    sync.holdStartSession()

    let task = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-1", episodeID: nil)) }
    #expect(bookmarkStore.setBookmarkCalls.isEmpty, "must not write before startSession resolves")

    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 0)))
    await task.value

    #expect(bookmarkStore.setBookmarkCalls == ["item-1"])
  }

  @Test func failedStartLeavesThePreviousBookmarkIntact() async {
    let (model, _, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    #expect(bookmarkStore.setBookmarkCalls == ["item-1"])

    // The `startSession` throw path (`:144`).
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-2")))
    await model.start(itemID: "item-2")
    #expect(
      bookmarkStore.setBookmarkCalls == ["item-1"],
      "a failed start must never write over the retained bookmark")

    // The cancelled/invalid-manifest path (`:156`): the session opens durably but the driving
    // task is cancelled before the player is ever handed the item: closed rather than orphaned,
    // and no bookmark write for a session that was never actually loaded.
    sync.holdStartSession()
    let task = Task { await model.start(itemID: "item-3") }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-3", episodeID: nil)) }
    task.cancel()
    sync.releaseStartSession(with: .success(Self.preparedPlayback(itemID: "item-3", startPosition: 0)))
    await task.value

    #expect(
      bookmarkStore.setBookmarkCalls == ["item-1"],
      "a cancelled start must never write a bookmark either")
  }

  @Test func stopClearsTheActiveSessionButKeepsTheRetainedItem() async {
    let (model, _, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    await model.stop()

    #expect(model.activeItemID == nil)
    #expect(model.phase == .idle)
    #expect(model.displayedItem == bookmark, "stop must not clear the retained item projection")
  }

  @Test func endedItemStaysRetainedWithFinishedStatus() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    let bookmark = Self.bookmark(itemID: "item-1", isFinished: true)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .ended, currentTime: 100, listenedDelta: 1))
    await Self.waitForDisplayState(model) { $0.phase == .ended }
    // `.ended` is the ingest phase; completion clears the session asynchronously after it.
    await Self.waitForDisplayState(model) { $0.activeItemID == nil }

    #expect(model.displayedItem == bookmark)
    #expect(model.displayedItem?.isFinished == true)
    #expect(
      model.nowPlayingIdentity == nil,
      "a finished retained item supplies metadata only; it is never presented as now playing")
  }

  @Test func anUnfinishedRetainedBookmarkIsPresented() async throws {
    let (model, _, _, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let expected = try #require(ListeningIdentity.audiobook(itemID: "item-1"))
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    #expect(model.activeItemID == nil)
    #expect(model.nowPlayingIdentity == expected)
  }

  @Test func aFinishedRetainedBookmarkIsNeverPresented() async {
    let (model, _, _, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1", isFinished: true)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    #expect(model.activeItemID == nil)
    #expect(model.displayedItem == bookmark, "the retained bookmark still supplies metadata")
    #expect(model.displayedItem?.isFinished == true)
    #expect(model.nowPlayingIdentity == nil)
  }

  @Test func aFinishEmissionClearsPresenceAndAResetRestoresIt() async throws {
    let (model, _, _, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let expected = try #require(ListeningIdentity.audiobook(itemID: "item-1"))
    let unfinished = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(unfinished)
    await Self.waitForDisplayState(model) { $0.displayedItem == unfinished }
    #expect(model.nowPlayingIdentity == expected)

    bookmarkStore.push(Self.bookmark(itemID: "item-1", isFinished: true, positionSeconds: 100))
    await Self.waitForDisplayState(model) { $0.nowPlayingIdentity == nil }
    #expect(model.displayedItem?.isFinished == true)

    bookmarkStore.push(Self.bookmark(itemID: "item-1"))
    await Self.waitForDisplayState(model) {
      $0.displayedItem?.isFinished == false && $0.nowPlayingIdentity == expected
    }
    #expect(model.displayedItem?.isFinished == false)
  }

  @Test func anActiveTitleIsPresentedRegardlessOfItsFinishedFlag() async throws {
    let (model, _, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let expected = try #require(ListeningIdentity.audiobook(itemID: "item-1"))
    let bookmark = Self.bookmark(itemID: "item-1", isFinished: true)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))

    await model.start(itemID: "item-1")

    #expect(model.nowPlayingIdentity == expected)
  }

  /// Mark as Finished stops first and writes the finished progress after: the stop falls back to
  /// the same, still-unfinished bookmark, so the mini player must not blink through an empty
  /// identity between the two.
  @Test func markAsFinishedNeverPublishesAnIntermediateIdentity() async throws {
    let (model, _, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let expected = try #require(ListeningIdentity.audiobook(itemID: "item-1"))
    let unfinished = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(unfinished)
    await Self.waitForDisplayState(model) { $0.displayedItem == unfinished }
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    #expect(model.nowPlayingIdentity == expected)

    let changes = ChangeCounter()
    withObservationTracking {
      _ = model.nowPlayingIdentity
    } onChange: {
      changes.mark()
    }

    await model.stop()
    #expect(
      model.nowPlayingIdentity == expected,
      "stopping falls back to the same, still-unfinished bookmark")
    #expect(changes.count == 0, "stopping must not publish an intermediate empty identity")

    bookmarkStore.push(Self.bookmark(itemID: "item-1", isFinished: true))
    await Self.waitForDisplayState(model) { $0.nowPlayingIdentity == nil }
    #expect(changes.count == 1)
  }

  @Test func coldRestoreProjectsTheRetainedItemWithoutStartingPlayback() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)

    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    #expect(model.activeItemID == nil)
    #expect(model.phase == .idle)
    #expect(player.intents.isEmpty)
    #expect(
      sync.calls.contains { if case .startSession = $0 { return true } else { return false } } == false,
      "observing the retained item must never itself start a session")
  }

  @Test func logoutClearsRetainedItemAndBookmark() async throws {
    let (model, _, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    try await model.logout()

    #expect(model.displayedItem == nil)

    // Confirms the bookmark-observation task was actually cancelled, not merely that it hadn't
    // fired yet: a late emission after logout must never resurrect the retained item.
    bookmarkStore.push(bookmark)
    #expect(model.displayedItem == nil)
  }

  @Test func missingOrSoftDeletedRetainedItemIsNotDisplayed() async {
    let (model, _, _, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    bookmarkStore.push(nil)
    await Self.waitForDisplayState(model) { $0.displayedItem == nil }

    #expect(model.displayedItem == nil)
  }

  // MARK: - Retained-item intents: play/skip a not-yet-active retained item

  /// The branch every transport surface shares: an active, loaded item toggles (pauses); it never
  /// restarts a session just because Play was tapped.
  @Test func togglePlayPauseOrPlayTogglesTheActiveLoadedItem() async {
    let (model, player, _, _, _) = await Self.makeStartedModel()
    let intentsBefore = player.intents

    await model.togglePlayPauseOrPlay(itemID: "item-1", episodeID: nil)

    #expect(Array(player.intents.dropFirst(intentsBefore.count)) == [.toggle])
  }

  @Test func togglePlayPauseOrPlayStartsARetainedInactiveItem() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-1", startPosition: 0)))

    await model.togglePlayPauseOrPlay(itemID: bookmark.serverItemId, episodeID: bookmark.episodeID)

    #expect(sync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)))
    #expect(player.intents.contains(.toggle) == false)
  }

  @Test func retainedPlayPreparesThenResumesFromTheSavedPosition() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))

    await model.play(itemID: bookmark.serverItemId)

    #expect(sync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)))
    #expect(model.activeItemID == "item-1")
    #expect(
      player.intents.last == .seek(toGlobalOffset: bookmark.positionSeconds),
      "resumes from the saved position, not wherever startSession's own manifest starts")
  }

  @Test func retainedForwardPreparesThenSeeksThirtySecondsPastTheSavedPosition() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))

    await model.skip(itemID: bookmark.serverItemId, by: Self.skipInterval)

    #expect(sync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)))
    #expect(player.intents.last == .seek(toGlobalOffset: bookmark.positionSeconds + Self.skipInterval))
  }

  @Test func retainedRewindClampsAtZero() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")  // positionSeconds: 10, less than one skip interval
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))

    await model.skip(itemID: bookmark.serverItemId, by: -Self.skipInterval)

    #expect(player.intents.last == .seek(toGlobalOffset: 0))
  }

  @Test func activeItemSkipsSynchronouslyWithoutPreparing() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    let startCallCountBefore = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }.count

    await model.skip(itemID: bookmark.serverItemId, by: Self.skipInterval)

    let startCallCountAfter = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }.count
    #expect(startCallCountAfter == startCallCountBefore, "the already-active item never re-prepares")
    #expect(player.intents.last == .skip(by: Self.skipInterval))
  }

  /// `play` resumes with an absolute seek, never the relative skip intent. A stored position can
  /// sit past the declared duration when that duration under-ran the real audio (the podcast
  /// case the duration correction covers). Routed as a skip, resuming such an episode would
  /// finish it and consume an Up Next row instead of playing it.
  @Test func resumingAPositionPastTheDeclaredDurationSeeksRatherThanFinishing() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1", positionSeconds: 118)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-1", startPosition: 0)))

    await model.play(itemID: "item-1", episodeID: nil)

    #expect(player.intents.last == .seek(toGlobalOffset: 118))
    #expect(player.intents.contains { if case .skip = $0 { return true } else { return false } } == false)
  }

  /// The other entry point that carries a stored position: a history row, or a chapter row whose
  /// start was recorded against the pre-correction timeline. Same rule as `play`: absolute, so a
  /// position past the declared end is a place to resume, never a request to be finished.
  @Test func startOrSeekToAPositionPastTheDeclaredDurationNeverFinishesTheItem() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-1", startPosition: 0)))

    await model.startOrSeek(itemID: "item-1", toGlobalOffset: 118)

    #expect(player.intents.last == .seek(toGlobalOffset: 118))
    #expect(player.intents.contains { if case .skip = $0 { return true } else { return false } } == false)
  }

  @Test func activePodcastSkipTargetsTheDisplayedEpisodeWhenBookmarkLagsOnASibling() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let staleBookmark = Self.bookmark(itemID: "show-1", episodeID: "episode-a")
    bookmarkStore.push(staleBookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == staleBookmark }
    sync.stubStartSession(
      .success(Self.preparedPlayback(itemID: "show-1", episodeID: "episode-b", startPosition: 0)))
    await model.start(itemID: "show-1", episodeID: "episode-b")
    let startCount = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }.count

    await model.skip(
      itemID: "show-1", episodeID: "episode-b", by: Self.skipInterval)

    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == startCount)
    #expect(player.intents.last == .skip(by: Self.skipInterval))
  }

  @Test func activeAudiobookSkipIgnoresAStalePodcastBookmarkForTheSameItem() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let staleBookmark = Self.bookmark(itemID: "item-1", episodeID: "old-episode")
    bookmarkStore.push(staleBookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == staleBookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-1", startPosition: 0)))
    await model.start(itemID: "item-1", episodeID: nil)

    await model.skip(
      itemID: "item-1", episodeID: nil, by: Self.skipInterval)

    #expect(player.intents.last == .skip(by: Self.skipInterval))
  }

  @Test func skipTargetsTheDisplayedItemWhileADifferentPlayerItemIsStillLoaded() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-a", startPosition: 0)))
    await model.start(itemID: "item-a")
    let bookmarkA = Self.bookmark(itemID: "item-a")
    bookmarkStore.push(bookmarkA)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmarkA }

    sync.holdStartSession()
    let startB = Task { await model.start(itemID: "item-b") }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-b", episodeID: nil)) }

    #expect(model.activeItemID == "item-b", "the shell should already be displaying B")
    #expect(model.loadedItemID == "item-a", "PlayerCore still owns A until B preparation resolves")
    let intentsBeforeSkip = player.intents

    await model.skip(itemID: "item-b", by: Self.skipInterval)

    #expect(player.intents == intentsBeforeSkip, "a B skip must never seek or resume loaded item A")
    let startsForA = sync.calls.filter { $0 == .startSession(itemID: "item-a", episodeID: nil) }
    #expect(startsForA.count == 1, "the retained A bookmark must never cause A to restart")

    sync.releaseStartSession(with: .success(Self.preparedPlayback(itemID: "item-b", startPosition: 0)))
    await startB.value
    #expect(model.loadedItemID == "item-b")
  }

  /// Three rapid forward taps on a retained (not yet active) item must fold into exactly
  /// one `startSession` call and one seek of the accumulated total (+90), never three of either.
  @Test func repeatedTapsDuringPreparationCoalesceIntoOnePreparationAndOneAccumulatedSeek() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.holdStartSession()

    let taskA = Task { await model.skip(itemID: bookmark.serverItemId, by: Self.skipInterval) }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-1", episodeID: nil)) }

    let taskB = Task { await model.skip(itemID: bookmark.serverItemId, by: Self.skipInterval) }
    let taskC = Task { await model.skip(itemID: bookmark.serverItemId, by: Self.skipInterval) }
    await waitUntil {
      sync.calls.filter { if case .startSession = $0 { return true } else { return false } }.count == 1
    }

    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 0)))
    await taskA.value
    await taskB.value
    await taskC.value

    let startCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
    #expect(startCalls.count == 1, "three coalesced taps must prepare exactly once")
    let seekIntents = player.intents.filter {
      if case .seek = $0 { return true }
      return false
    }
    #expect(seekIntents == [.seek(toGlobalOffset: bookmark.positionSeconds + 3 * Self.skipInterval)])
  }

  @Test func failedPreparationLeavesTheRetainedItemAndReportsTheFailureOnce() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.holdStartSession()

    let taskA = Task { await model.skip(itemID: bookmark.serverItemId, by: Self.skipInterval) }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-1", episodeID: nil)) }
    let taskB = Task { await model.skip(itemID: bookmark.serverItemId, by: Self.skipInterval) }
    await waitUntil {
      sync.calls.filter { if case .startSession = $0 { return true } else { return false } }.count == 1
    }

    sync.releaseStartSession(with: .failure(PlaybackCoordinatorError.unknownItem("item-1")))
    await taskA.value
    await taskB.value

    let startCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
    #expect(startCalls.count == 1, "a failed preparation must not be retried per coalesced tap")
    #expect(model.displayedItem == bookmark, "the retained item must survive a failed preparation")
    #expect(model.startFailureMessage != nil, "the failure is reported")
    #expect(
      player.intents.contains { if case .seek = $0 { return true } else { return false } } == false,
      "no seek may reach the player for a session that never opened")
  }
}
