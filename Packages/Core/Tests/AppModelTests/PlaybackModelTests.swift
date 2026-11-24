import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `PlaybackModel` is the only AppModel type that sees both `PlaybackSyncing` (SyncEngine) and
/// `PlaybackControlling` (PlayerCore). These tests drive it through fakes for both
/// (`FakePlaybackSyncing`/`FakePlaybackControlling`), so nothing touches a real network, database
/// or AVFoundation.
///
/// Every wait is event-driven (`FakePlaybackSyncing.waitForCalls`), never a poll with a deadline:
/// in a full parallel `swift test` all `@MainActor` suites contend for one main actor, so a useful
/// deadline is a missable one. `.timeLimit` turns an unsatisfiable wait (a real regression) into a
/// clean failure instead of a hang.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PlaybackModelTests {
  static let skipInterval: Double = 30
  // MARK: - Start / resume

  @Test func startsIdleWithNoActiveItem() {
    let model = Self.makeModel().model
    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.isStreamingSource == false)
  }

  @Test("playback model exposes the player's restored playback rate")
  func playbackRateStartsFromPlayerState() {
    let player = FakePlaybackControlling()
    player.state.rate = 1.15
    let model = PlaybackModel(
      sync: FakePlaybackSyncing(), player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle())

    #expect(model.playbackRate == 1.15)
  }

  @Test("playback model republishes a rate change from the player")
  func playbackRateUpdatesWhenPlayerRateChanges() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    player.state.rate = 1.15
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", episodeID: nil, phase: .paused,
        currentTime: 10, listenedDelta: 0))

    await waitUntil { model.playbackRate == 1.15 }
    #expect(model.playbackRate == 1.15)
  }

  @Test("playback model only invalidates playback rate when the rate changes")
  func playbackRateOnlyInvalidatesWhenRateChanges() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    let changes = ChangeCounter()

    withObservationTracking {
      _ = model.playbackRate
    } onChange: {
      changes.mark()
    }

    player.state.rate = 1.0
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", episodeID: nil, phase: .paused,
        currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .paused }
    #expect(changes.count == 0)

    player.state.rate = 1.25
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", episodeID: nil, phase: .paused,
        currentTime: 20, listenedDelta: 0))
    await waitUntil { model.playbackRate == 1.25 }
    #expect(changes.count == 1)
  }

  @Test("position ticks only invalidate playback phase when its mapped value changes")
  func playbackPhaseOnlyInvalidatesWhenMappedValueChanges() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", episodeID: nil, phase: .playing,
        currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .playing }

    let changes = ChangeCounter()
    withObservationTracking {
      _ = model.phase
    } onChange: {
      changes.mark()
    }

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", episodeID: nil, phase: .playing,
        currentTime: 11, listenedDelta: 1))
    await waitUntil { model.currentTime == 11 }
    #expect(changes.count == 0)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 3, itemId: "item-1", episodeID: nil, phase: .paused,
        currentTime: 11, listenedDelta: 0))
    await waitUntil { model.phase == .paused }
    #expect(changes.count == 1)
  }

  /// The play/pause affordances render intent, not `phase`: transient buffering/seeking phases
  /// on a real stream must never flip the control.
  @Test func isPlaybackIntendedMirrorsThePlayerState() {
    let (model, player, _, _, _) = Self.makeModel()
    #expect(model.isPlaybackIntended == false)

    player.state.isPlaybackIntended = true
    #expect(model.isPlaybackIntended)

    player.state.isPlaybackIntended = false
    #expect(model.isPlaybackIntended == false)
  }

  /// It must read the player's dedicated intent property, never its whole `state`.
  /// `PlayerState` carries the playhead and is republished on every engine tick, so a SwiftUI
  /// surface keyed to it rebuilds twice a second and makes a presented context menu re-render.
  /// The fake disagrees with itself, so only a reader of the dedicated property sees `true`.
  @Test func isPlaybackIntendedReadsThePlayersIntentPropertyNotItsState() {
    let (model, player, _, _, _) = Self.makeModel()

    player.isPlaybackIntended = true

    #expect(player.state.isPlaybackIntended == false, "the fake's `state` deliberately disagrees")
    #expect(model.isPlaybackIntended)
  }

  @Test func startBeginsANewSessionAndLoadsThePlayerWithTheMappedItem() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 15)))

    await model.start(itemID: "item-1")

    // `sync.calls` also carries the launch-recovery call every `PlaybackModel` issues at
    // construction (see `launchRecoveryRunsBeforeAnyStartCallIsAccepted`). Irrelevant here.
    #expect(sync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)))
    let expectedItem = PlayerItem(
      id: "item-1",
      timeline: try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, startOffset: 0, duration: 100)]),
      chapters: PlaybackChapterMap(chapters: [PlaybackChapter(id: "1", title: "Ch1", start: 0, end: 100)]),
      isStreaming: true
    )
    #expect(player.intents == [.load(item: expectedItem, initialGlobalPosition: 15, rate: 1.0), .play])
    #expect(model.activeItemID == "item-1")
    #expect(model.loadedItemID == "item-1")
    #expect(model.isStreamingSource)
  }

  /// The detail page's playhead readers switch from the persisted progress to `currentTime` the
  /// instant `loadedItemID` matches, so a model that publishes the load without the position it
  /// loaded at reads as a playhead of zero until the engine's first tick. That withdraws the
  /// progress bar and bounces the play capsule, visible only on the first, cold tap.
  @Test("a fresh start publishes the position it loaded at, not a zero playhead")
  func startPublishesItsLoadPositionImmediately() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 15)))

    await model.start(itemID: "item-1")

    #expect(model.loadedItemID == "item-1")
    #expect(model.currentTime == 15)
  }

  @Test("cold chapter navigation prepares at the target without starting playback")
  func coldChapterNavigationLoadsPausedAtTheNextChapter() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1")
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(
      .success(
        Self.preparedPlayback(
          startPosition: bookmark.positionSeconds,
          chapters: [
            PreparedPlaybackChapter(id: 1, start: 0, end: 20, title: "First"),
            PreparedPlaybackChapter(id: 2, start: 20, end: 100, title: "Second"),
          ])))

    await model.navigateChapter(
      itemID: "item-1", forward: true,
      fallbackChapterMap: PlaybackChapterMap(chapters: [
        PlaybackChapter(start: 0, end: 20), PlaybackChapter(start: 20, end: 100),
      ]))

    #expect(
      player.intents.contains { intent in
        if case .load(_, let position, _, _) = intent { return position == 20 }
        return false
      })
    #expect(player.intents.contains(.play) == false)
    #expect(sync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)))
  }

  @Test("loaded chapter navigation uses PlayerCore's existing chapter intent")
  func loadedChapterNavigationForwardsTheDirection() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 10)))
    await model.start(itemID: "item-1")
    let startsBefore = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }.count

    await model.navigateChapter(
      itemID: "item-1", forward: true,
      fallbackChapterMap: PlaybackChapterMap(chapters: [PlaybackChapter(start: 0, end: 100)]))

    #expect(player.intents.last == PlayerIntent.nextChapter)
    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == startsBefore)
  }

  @Test("cold previous chapter navigation follows the three-second restart rule", arguments: [1.0, 32.0, 33.0, 34.0])
  func coldPreviousChapterNavigationUsesExpectedTarget(position: Double) async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1", positionSeconds: position)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))

    await model.navigateChapter(
      itemID: "item-1", forward: false,
      fallbackChapterMap: PlaybackChapterMap(chapters: [
        PlaybackChapter(start: 0, end: 30), PlaybackChapter(start: 30, end: 60),
      ]))

    let loadPosition = player.intents.compactMap { intent -> Double? in
      if case .load(_, let position, _, _) = intent { return position }
      return nil
    }.last
    #expect(loadPosition == (position > 33 ? 30 : 0))
    #expect(player.intents.contains(.play) == false)
  }

  @Test("cold chapter navigation no-ops at the final chapter and without matching metadata")
  func coldChapterNavigationRejectsNoTargetAndWrongBookmark() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1", positionSeconds: 90)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    let map = PlaybackChapterMap(chapters: [PlaybackChapter(start: 0, end: 100)])

    await model.navigateChapter(itemID: "item-1", forward: true, fallbackChapterMap: map)
    await model.navigateChapter(
      itemID: "missing", forward: false, fallbackChapterMap: map)
    await model.navigateChapter(
      itemID: "item-1", forward: true, fallbackChapterMap: PlaybackChapterMap(chapters: []))

    #expect(sync.calls.contains { if case .startSession = $0 { return true } else { return false } } == false)
    #expect(player.intents.isEmpty)
  }

  @Test("repeated cold chapter taps share one preparation")
  func repeatedColdChapterNavigationUsesOnePreparation() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1", positionSeconds: 10)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.holdStartSession()
    let map = PlaybackChapterMap(chapters: [
      PlaybackChapter(start: 0, end: 20), PlaybackChapter(start: 20, end: 100),
    ])

    let first = Task { await model.navigateChapter(itemID: "item-1", forward: true, fallbackChapterMap: map) }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-1", episodeID: nil)) }
    await model.navigateChapter(itemID: "item-1", forward: true, fallbackChapterMap: map)
    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 0)))
    await first.value

    #expect(sync.calls.filter { if case .startSession = $0 { return true } else { return false } }.count == 1)
    #expect(player.intents.filter { if case .load = $0 { return true } else { return false } }.count == 1)
    #expect(player.intents.contains(.play) == false)
  }

  @Test("stopping a cold chapter preparation prevents its late load")
  func stoppedColdChapterNavigationCannotInstallLateSession() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1", positionSeconds: 10)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.holdStartSession()
    let map = PlaybackChapterMap(chapters: [
      PlaybackChapter(start: 0, end: 20), PlaybackChapter(start: 20, end: 100),
    ])
    let navigation = Task {
      await model.navigateChapter(itemID: "item-1", forward: true, fallbackChapterMap: map)
    }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-1", episodeID: nil)) }

    await model.stop()
    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 0)))
    await navigation.value

    #expect(player.intents.contains { if case .load = $0 { return true } else { return false } } == false)
    #expect(player.intents.contains(.play) == false)
  }

  @Test("failed cold chapter preparation sends neither load nor play")
  func failedColdChapterNavigationDoesNotTouchPlayer() async {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let bookmark = Self.bookmark(itemID: "item-1", positionSeconds: 10)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    await model.navigateChapter(
      itemID: "item-1", forward: true,
      fallbackChapterMap: PlaybackChapterMap(chapters: [
        PlaybackChapter(start: 0, end: 20), PlaybackChapter(start: 20, end: 100),
      ]))

    #expect(player.intents.isEmpty)
  }

  @Test("starting from the beginning overrides the server resume position")
  func startFromBeginningLoadsAtZero() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 15)))

    await model.start(itemID: "item-1", fromStart: true)

    #expect(
      player.intents.contains(
        .load(
          item: try! PlaybackModel.makePlayerItem(
            itemID: "item-1", prepared: Self.preparedPlayback(startPosition: 15)),
          initialGlobalPosition: 0, rate: 1.0)))
    #expect(player.intents.last == .play)
  }

  @Test("starting an active paused item from the beginning seeks and plays")
  func activePausedItemStartsFromBeginning() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .paused, currentTime: 80, listenedDelta: 0))
    await waitUntil { model.phase == .paused }

    await model.start(itemID: "item-1", fromStart: true)

    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == 1)
    #expect(player.intents.suffix(2) == [.seek(toGlobalOffset: 0), .play])
  }

  @Test func freshStartReportsBufferingBeforeAwaitingSessionPreparation() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.holdStartSession()

    let starting = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls {
      $0.contains(.startSession(itemID: "item-1", episodeID: nil))
    }

    let bufferingIndex = sync.calls.firstIndex(of: .notifyPlaybackPhase(.buffering))
    let startIndex = sync.calls.firstIndex(of: .startSession(itemID: "item-1", episodeID: nil))

    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 0)))
    await starting.value

    #expect(bufferingIndex != nil)
    #expect(bufferingIndex != nil && startIndex != nil && bufferingIndex! < startIndex!)
  }

  @Test func freshStartAnnouncesItsItemBeforeSessionPreparation() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.holdStartSession()

    let starting = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls { $0.contains(.notifyPlaybackPhase(.buffering)) }

    #expect(sync.willStartPlaybackItemIDs == ["item-1"])

    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 0)))
    await starting.value
  }

  @Test func requestedIdentityPublishesBeforePreparationCompletes() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.holdStartSession()

    let starting = Task {
      await model.start(itemID: "show", episodeID: "episode-a")
    }
    await sync.waitForCalls {
      $0.contains(.startSession(itemID: "show", episodeID: "episode-a"))
    }

    #expect(
      model.nowPlayingIdentity == .podcastEpisode(itemID: "show", episodeID: "episode-a"))
    #expect(model.loadedItemID == nil)

    sync.releaseStartSession(
      with: .success(Self.preparedPlayback(itemID: "show", episodeID: "episode-a", startPosition: 0)))
    await starting.value

    #expect(model.loadedItemID == "show")
    #expect(model.loadedEpisodeID == "episode-a")
  }

  @Test func startFailureLeavesNoPhantomMiniPlayer() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    await model.start(itemID: "item-1")

    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.startFailureMessage != nil)
    #expect(player.intents.isEmpty, "no .load/.play may ever reach the player for a session that never opened")
  }

  /// A collection's Play queues the rest only behind a start that happened.
  @Test func startReportingSuccessIsFalseForAFailedStart() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    #expect(await model.startReportingSuccess(itemID: "item-1", episodeID: nil) == false)
  }

  @Test func startReportingSuccessIsTrueForAStartedEpisode() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(
      .success(Self.preparedPlayback(itemID: "show", episodeID: "episode-a", startPosition: 0)))

    #expect(await model.startReportingSuccess(itemID: "show", episodeID: "episode-a"))
  }

  @Test func failedStartRestoresAnIdleCadencePhase() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    await model.start(itemID: "item-1")

    #expect(sync.notifyPlaybackPhaseCalls == [.buffering, .idle])
  }

  /// A play the user tapped and an automatic continuation both land here with the same words. The
  /// origin is what lets a surface interrupt the first without interrupting the second, so it has
  /// to be recorded where the failure is, not inferred later from the phase.
  @Test("a refused start the user asked for is recorded as requested")
  func refusedStartIsRecordedAsRequested() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    await model.start(itemID: "item-1")

    #expect(model.startFailure?.origin == .requested)
    #expect(model.startFailure?.message == model.startFailureMessage)
  }

  @Test("dismissing a start failure changes no other playback state")
  func dismissingStartFailureChangesNoOtherPlaybackState() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    await model.start(itemID: "item-1")

    let phase = model.phase
    let activeItemID = model.activeItemID
    let activeEpisodeID = model.activeEpisodeID
    let loadedItemID = model.loadedItemID
    let loadedEpisodeID = model.loadedEpisodeID
    let isStreamingSource = model.isStreamingSource
    let currentTime = model.currentTime
    let playbackRate = model.playbackRate
    let displayedItem = model.displayedItem
    let nowPlayingIdentity = model.nowPlayingIdentity
    let isPlaybackIntended = model.isPlaybackIntended
    let isQuiescedForLogout = model.isQuiescedForLogout
    let playerState = player.state
    let playerIntents = player.intents

    model.dismissStartFailure()

    #expect(model.startFailureMessage == nil)
    #expect(model.phase == phase)
    #expect(model.activeItemID == activeItemID)
    #expect(model.activeEpisodeID == activeEpisodeID)
    #expect(model.loadedItemID == loadedItemID)
    #expect(model.loadedEpisodeID == loadedEpisodeID)
    #expect(model.isStreamingSource == isStreamingSource)
    #expect(model.currentTime == currentTime)
    #expect(model.playbackRate == playbackRate)
    #expect(model.displayedItem == displayedItem)
    #expect(model.nowPlayingIdentity == nowPlayingIdentity)
    #expect(model.isPlaybackIntended == isPlaybackIntended)
    #expect(model.isQuiescedForLogout == isQuiescedForLogout)
    #expect(player.state == playerState)
    #expect(player.intents == playerIntents)
  }

  @Test func aLateFailureFromASupersededStartCannotEraseTheNewerStart() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.holdStartSession()

    let olderStart = Task { await model.start(itemID: "item-a") }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-a", episodeID: nil)) }

    let newerStart = Task { await model.start(itemID: "item-b") }
    await waitUntil { model.activeItemID == "item-b" }

    sync.releaseNextStartSession(
      with: .failure(PlaybackCoordinatorError.unknownItem("item-a")))
    await olderStart.value

    #expect(model.activeItemID == "item-b", "the older failure must not clear the newer request")
    #expect(model.phase == .preparing)
    #expect(model.startFailureMessage == nil, "the displaced request's failure is no longer user-facing")

    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }
    sync.releaseStartSession(
      with: .success(Self.preparedPlayback(itemID: "item-b", startPosition: 0)))
    await newerStart.value

    #expect(model.activeItemID == "item-b")
    #expect(model.loadedItemID == "item-b")
    #expect(player.intents.count == 2, "only the surviving request may load and play")
  }

  @Test func aLateSuccessFromASupersededStartClosesBeforeTheNewerStartBegins() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.holdStartSession()

    let olderStart = Task { await model.start(itemID: "item-a") }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-a", episodeID: nil)) }

    let newerStart = Task { await model.start(itemID: "item-b") }
    await waitUntil { model.activeItemID == "item-b" }

    sync.releaseNextStartSession(
      with: .success(Self.preparedPlayback(itemID: "item-a", startPosition: 0)))
    await olderStart.value
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }

    let sessionCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return $0 == .stopSession
    }
    #expect(
      sessionCalls == [
        .startSession(itemID: "item-a", episodeID: nil),
        .stopSession,
        .startSession(itemID: "item-b", episodeID: nil),
      ],
      "the displaced durable session must close before its successor is allowed to open")
    #expect(player.intents.isEmpty, "the displaced success must never reach PlayerCore")

    sync.releaseStartSession(
      with: .success(Self.preparedPlayback(itemID: "item-b", startPosition: 0)))
    await newerStart.value

    #expect(model.activeItemID == "item-b")
    #expect(model.loadedItemID == "item-b")
  }

  @Test func resumingTheAlreadyActiveItemSkipsAnotherStartSessionCall() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    await model.start(itemID: "item-1")

    let startCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
    #expect(startCalls.count == 1, "resuming the already-active item must never re-call startSession")
    #expect(player.intents.last == .play)
  }

  @Test func resumingTheAlreadyActiveItemReportsBufferingWithThePlayIntent() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    let phaseCountBeforeResume = sync.notifyPlaybackPhaseCalls.count
    await model.start(itemID: "item-1")

    #expect(sync.notifyPlaybackPhaseCalls.count == phaseCountBeforeResume + 1)
    #expect(sync.notifyPlaybackPhaseCalls.last == .buffering)
    #expect(player.intents.last == .play)
  }

  @Test func aPlayIntentOnAnAlreadyPlayingItemNeverCancelsItsCadence() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", episodeID: nil, phase: .playing,
        currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .playing }
    await sync.waitForCalls { $0.contains(.notifyPlaybackPhase(.playing)) }

    let phaseCallsBeforeResume = sync.notifyPlaybackPhaseCalls
    await model.start(itemID: "item-1")

    // An eager `.buffering` here would cancel the live cadence deadline, and `forward` only
    // reports phase changes. The engine keeps emitting `.playing`, so nothing would ever
    // reschedule it.
    #expect(sync.notifyPlaybackPhaseCalls == phaseCallsBeforeResume)
    #expect(player.intents.last == .play)
  }

  @Test func aStalledActiveItemUsesFreshPreparationForAPlayIntent() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubResumeInPlace()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 12, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 12 } }
    #expect(model.phase == .stalled)

    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 12)))
    await model.start(itemID: "item-1")

    #expect(
      sync.calls.filter { if case .startSession = $0 { return true } else { return false } }.count == 2,
      "a stalled player must re-prepare instead of sending a bare `.play`")
    #expect(Self.loadedItems(from: player.intents).count == 2)
    let loadPositions = player.intents.compactMap { intent -> Double? in
      if case .load(_, let initialGlobalPosition, _, _) = intent { return initialGlobalPosition }
      return nil
    }
    #expect(loadPositions == [0, 12], "a fresh session must not resume the cached stalled preparation")
    #expect(player.intents.last == .play)
  }

  @Test func retryFromStalledRepreparesAtTheReturnedManifestPosition() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    player.isPlaybackIntended = true

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 42, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 42 } }

    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 37)))
    #expect(model.retry())
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }
    #expect(await waitUntil { Self.loadedItems(from: player.intents).count == 2 })

    let loadPositions = player.intents.compactMap { intent -> Double? in
      if case .load(_, let initialGlobalPosition, _, _) = intent { return initialGlobalPosition }
      return nil
    }
    #expect(loadPositions == [0, 37])
    // Intent itself belongs to the reducer, which this fake player does not run: the play intent
    // reaching the player is what this level can honestly observe about the recovery.
    #expect(player.intents.last == .play)
  }

  /// The coordinator resumes an already-active session in place, handing back the preparation it
  /// cached when that session opened (the stalled stream's dead URL, positioned where the listen
  /// began). Recovery therefore has to retire the session before asking for a new one.
  @Test func retryFromStalledClosesTheStalledSessionBeforeOpeningItsSuccessor() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 42, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 42 } }

    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 42)))
    #expect(model.retry())
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }

    let sessionCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return $0 == .stopSession
    }
    #expect(
      sessionCalls == [
        .startSession(itemID: "item-1", episodeID: nil),
        .stopSession,
        .startSession(itemID: "item-1", episodeID: nil),
      ])
  }

  @Test func retryFromStalledFailureReportsTheErrorAndDoesNotClaimPlayback() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 12, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 12 } }

    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))
    model.retry()
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }
    #expect(await waitUntil { model.startFailureMessage != nil })

    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.phase != .playing)
    #expect(Self.loadedItems(from: player.intents).count == 1)
  }

  @Test func retryFromBufferingRepreparesTheStreamingSession() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubResumeInPlace()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 19, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 19 } }

    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 19)))
    #expect(model.retry())
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }
    await waitUntil { Self.loadedItems(from: player.intents).count == 2 }

    #expect(player.intents.contains(.retry) == false)
    #expect(Self.loadedItems(from: player.intents).count == 2)
    let sessionCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return $0 == .stopSession
    }
    #expect(
      sessionCalls == [
        .startSession(itemID: "item-1", episodeID: nil),
        .stopSession,
        .startSession(itemID: "item-1", episodeID: nil),
      ])
  }

  @Test func retryFromAStartFailureStartsTheFailedItemAgain() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))
    await model.start(itemID: "item-1")

    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 7)))
    #expect(model.retry())
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }

    #expect(model.startFailure == nil)
    #expect(model.loadedItemID == "item-1")
    #expect(Self.loadedItems(from: player.intents).count == 1)
  }

  @Test func stalledRecoveryCannotOverrideANewerStart() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubResumeInPlace()
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-1", startPosition: 0)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 22, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 22 } }

    sync.holdStopSession()
    model.retry()
    await sync.waitForCalls { $0.contains(.stopSession) }

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-2", startPosition: 3)))
    let newerStart = Task { await model.start(itemID: "item-2") }
    sync.releaseStopSession()
    await newerStart.value
    _ = await awaitCondition(
      "the newer start's player load to be recorded",
      observing: { "\(Self.loadedItems(from: player.intents).map { $0.id })" },
      until: { Self.loadedItems(from: player.intents).map { $0.id } == ["item-1", "item-2"] })

    #expect(model.activeItemID == "item-2")
    #expect(model.loadedItemID == "item-2")
    let startCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
    #expect(
      startCalls == [
        .startSession(itemID: "item-1", episodeID: nil),
        .startSession(itemID: "item-2", episodeID: nil),
      ])
    #expect(Self.loadedItems(from: player.intents).map(\.id) == ["item-1", "item-2"])
  }

  @Test func twoStalledRetryTapsShareOneInFlightPreparation() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 12, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 12 } }

    sync.holdStartSession()
    model.retry()
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }

    model.retry()
    #expect(
      sync.calls.filter { if case .startSession = $0 { return true } else { return false } }.count == 2)

    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 37)))
    #expect(await waitUntil { Self.loadedItems(from: player.intents).count == 2 })
  }

  @Test func aDifferentItemStartsAFreshSession() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-2", startPosition: 0)))
    await model.start(itemID: "item-2")

    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == 2)
    #expect(model.activeItemID == "item-2")
  }

  @Test("starting a title resolves its own rate instead of the previous title's rate")
  func startResolvesTheRequestedTitleInsteadOfThePreviousPlayersRate() async {
    let (model, player, sync, rateCoordinator) = Self.makeRateModel()
    rateCoordinator.setOverride(1.8, itemID: "item-a")
    await rateCoordinator.waitForPendingWrites()

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-a", startPosition: 0)))
    await model.start(itemID: "item-a")

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-b", startPosition: 0)))
    await model.start(itemID: "item-b")

    #expect(Self.loadRates(player.intents) == [1.8, 1.25])
  }

  @Test("starting a title with its own override loads at that override")
  func startResolvesTheSecondTitlesOverride() async {
    let (model, player, sync, rateCoordinator) = Self.makeRateModel()
    rateCoordinator.setOverride(1.8, itemID: "item-a")
    rateCoordinator.setOverride(1.4, itemID: "item-b")
    await rateCoordinator.waitForPendingWrites()

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-a", startPosition: 0)))
    await model.start(itemID: "item-a")

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-b", startPosition: 0)))
    await model.start(itemID: "item-b")

    #expect(Self.loadRates(player.intents) == [1.8, 1.4])
  }

  @Test("clearing an active override makes the next load use the global default")
  func clearingAnActiveOverrideFallsBackToTheGlobalDefault() async {
    let (model, player, sync, rateCoordinator) = Self.makeRateModel()
    rateCoordinator.setOverride(1.8, itemID: "item-a")
    await rateCoordinator.waitForPendingWrites()

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-a", startPosition: 0)))
    await model.start(itemID: "item-a")

    rateCoordinator.clearOverride(itemID: "item-a")
    await rateCoordinator.waitForPendingWrites()
    #expect(Self.setRateCalls(player.intents) == [1.25])

    await model.stop()
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-a", startPosition: 0)))
    await model.start(itemID: "item-a")

    #expect(Self.loadRates(player.intents) == [1.8, 1.25])
  }

  // MARK: - Retry / stop / toggle / seek

  @Test func retryFromRecoverableErrorForwardsToThePlayerWithoutStartingASession() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    let intentsBeforeFailure = player.intents
    let startCountBeforeFailure = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }.count
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1",
        phase: .failed(AudioEngineFailure(isRecoverable: true, message: "transient")),
        currentTime: 12, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).isEmpty == false }

    model.retry()
    #expect(Array(player.intents.dropFirst(intentsBeforeFailure.count)) == [.retry])
    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == startCountBeforeFailure)
  }

  @Test func togglePlayPauseForwardsToThePlayer() {
    let (model, player, _, _, _) = Self.makeModel()
    model.togglePlayPause()
    #expect(player.intents == [.toggle])
  }

  @Test func seekForwardsToThePlayerWithTheGivenOffset() {
    let (model, player, _, _, _) = Self.makeModel()
    model.seek(toGlobalOffset: 30)
    #expect(player.intents == [.seek(toGlobalOffset: 30)])
  }

  @Test func stopSendsTheStopIntentClosesTheSessionAndClearsTheMiniPlayer() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    await model.stop()

    #expect(player.intents.contains(.stop))
    #expect(sync.calls.contains(.stopSession))
    #expect(sync.calls.contains(.notifyImmediateSyncTrigger(.closing)))
    #expect(model.activeItemID == nil)
    #expect(model.phase == .idle)
  }

  @Test("disabling native subscriptions persists the live RSS position before teardown")
  func nativeSubscriptionDisableFlushesRSSPositionAndClearsRetainedPresentation() async throws {
    let (model, player, sync, bookmarkStore, _, _) = Self.makeModelWithBookmarkStore()
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    let episodeID = "episode-7"
    model.setActive(itemID: itemID, episodeID: episodeID)
    model.setLoaded(itemID: itemID, episodeID: episodeID, isStreaming: true)
    player.state.globalPosition = 42
    let bookmark = Self.bookmark(itemID: itemID, episodeID: episodeID)
    bookmarkStore.push(bookmark)
    await Self.waitForDisplayState(model) { $0.displayedItem == bookmark }

    await model.stopForNativeSubscriptionsDisable()

    let tickIndex = sync.calls.firstIndex {
      if case .recordProgressTick(itemID: itemID, currentTime: 42, _, _, _) = $0 { return true }
      return false
    }
    let stopIndex = sync.calls.firstIndex(of: .stopSession)
    #expect(tickIndex != nil && stopIndex != nil && tickIndex! < stopIndex!)
    #expect(model.activeItemID == nil)
    #expect(model.loadedItemID == nil)
    #expect(model.displayedItem == nil)
    #expect(model.nowPlayingIdentity == nil)
  }

  @Test("disabling native subscriptions cancels an RSS start still preparing")
  func nativeSubscriptionDisableStopsPreparingRSSWithoutInventingProgress() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: itemID, episodeID: "episode-7")

    #expect(model.isActiveNativePodcastPlayback)
    await model.stopForNativeSubscriptionsDisable()

    #expect(sync.calls.contains(.stopSession))
    #expect(
      sync.calls.contains { call in
        if case .recordProgressTick = call { return true }
        return false
      } == false)
    #expect(player.intents.contains(.stop))
    #expect(model.activeItemID == nil)
  }

  @Test("a native-subscription stop cannot close playback started while its final RSS tick waits")
  func nativeSubscriptionDisableCannotStopANewerStart() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: rssItemID, episodeID: "episode-7")
    model.setLoaded(itemID: rssItemID, episodeID: "episode-7", isStreaming: true)
    player.state.globalPosition = 42
    sync.holdRecordProgressTicks()

    let disabling = Task { await model.stopForNativeSubscriptionsDisable() }
    await sync.waitForCalls {
      $0.contains {
        if case .recordProgressTick(itemID: rssItemID, currentTime: 42, _, _, _) = $0 {
          return true
        }
        return false
      }
    }

    sync.stubStartSession(
      .success(Self.preparedPlayback(itemID: "new-abs-item", startPosition: 0)))
    await model.start(itemID: "new-abs-item")
    sync.releaseRecordProgressTicks()
    await disabling.value

    let startIndex = sync.calls.firstIndex(
      of: .startSession(itemID: "new-abs-item", episodeID: nil))
    let stopIndex = sync.calls.firstIndex(of: .stopSession)
    #expect(startIndex != nil)
    #expect(stopIndex == nil || stopIndex! < startIndex!)
    #expect(model.activeItemID == "new-abs-item")
    #expect(model.loadedItemID == "new-abs-item")
  }

  @Test("disabling native subscriptions leaves ABS playback untouched")
  func nativeSubscriptionDisableDoesNothingForABS() async {
    let (model, player, sync, _, _) = Self.makeModel()
    model.setActive(itemID: "book", episodeID: nil)
    model.setLoaded(itemID: "book", episodeID: nil, isStreaming: true)
    player.state.globalPosition = 42

    await model.stopForNativeSubscriptionsDisable()

    #expect(player.intents.isEmpty)
    #expect(sync.calls.isEmpty)
    #expect(model.activeItemID == "book")
    #expect(model.loadedItemID == "book")
  }

  @Test("stopping after the player reached the end re-reports the episode as finished")
  func stopAfterPlayerEndedKeepsRSSEpisodeFinished() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: itemID, episodeID: "episode-7")
    model.setLoaded(itemID: itemID, episodeID: "episode-7", isStreaming: true)
    player.state.globalPosition = 120
    player.state.phase = .ended

    await model.stop()

    let ticks = Self.tickCalls(sync.calls).filter { $0.itemID == itemID }
    #expect(ticks.count == 1)
    #expect(ticks.first?.isFinished == true)
  }

  @Test("stopping mid-episode never claims the episode finished")
  func stopMidEpisodeDoesNotReportFinished() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: itemID, episodeID: "episode-7")
    model.setLoaded(itemID: itemID, episodeID: "episode-7", isStreaming: true)
    player.state.globalPosition = 42
    player.state.phase = .playing

    await model.stop()

    let ticks = Self.tickCalls(sync.calls).filter { $0.itemID == itemID }
    #expect(ticks.map(\.isFinished) == [false])
  }

  @Test("unfollowing an active native feed stops its exact playback before returning")
  func nativeFeedUnfollowStopsMatchingPlayback() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: itemID, episodeID: "episode-7")
    model.setLoaded(itemID: itemID, episodeID: "episode-7", isStreaming: true)
    player.state.globalPosition = 42

    try await model.stopForNativeFeedUnfollow(itemID: itemID)

    let tickIndex = sync.calls.firstIndex {
      if case .recordProgressTick(itemID: itemID, currentTime: 42, _, _, _) = $0 { return true }
      return false
    }
    let stopIndex = sync.calls.firstIndex(of: .stopSession)
    #expect(tickIndex != nil && stopIndex != nil && tickIndex! < stopIndex!)
    #expect(player.intents.contains(.stop))
    #expect(model.activeItemID == nil)
    #expect(model.loadedItemID == nil)
    #expect(model.phase == .idle)
  }

  @Test("unfollowing one feed preserves unrelated native and server playback")
  func nativeFeedUnfollowPreservesUnrelatedPlayback() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    let requestedItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    let otherItemID = try #require(PodcastSourceIdentity.rss(feedId: 8)).itemId
    model.setActive(itemID: otherItemID, episodeID: "episode-8")
    model.setLoaded(itemID: otherItemID, episodeID: "episode-8", isStreaming: true)

    try await model.stopForNativeFeedUnfollow(itemID: requestedItemID)

    #expect(player.intents.isEmpty)
    #expect(sync.calls.isEmpty)
    #expect(model.activeItemID == otherItemID)
    #expect(model.loadedItemID == otherItemID)

    model.setActive(itemID: "book", episodeID: nil)
    model.setLoaded(itemID: "book", episodeID: nil, isStreaming: true)
    try await model.stopForNativeFeedUnfollow(itemID: requestedItemID)

    #expect(player.intents.isEmpty)
    #expect(sync.calls.isEmpty)
    #expect(model.activeItemID == "book")
    #expect(model.loadedItemID == "book")
  }

  @Test("a failed native feed stop remains retryable and propagates")
  func nativeFeedUnfollowStopFailureIsRetryable() async throws {
    struct StopFailure: Error {}

    let (model, player, sync, _, _) = Self.makeModel()
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: itemID, episodeID: "episode-7")
    model.setLoaded(itemID: itemID, episodeID: "episode-7", isStreaming: true)
    sync.stubStopSession(throwing: StopFailure())

    await #expect(throws: StopFailure.self) {
      try await model.stopForNativeFeedUnfollow(itemID: itemID)
    }

    #expect(player.intents.contains(.stop) == false)
    #expect(model.activeItemID == itemID)
    #expect(model.loadedItemID == itemID)
    #expect(model.loadedPlaybackGeneration == model.playbackGeneration)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: itemID, episodeID: "episode-7", phase: .playing,
        currentTime: 43, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 43 } }
    #expect(model.currentTime == 43)

    sync.stubStopSession(throwing: nil)
    await #expect(throws: Never.self) {
      try await model.stopForNativeFeedUnfollow(itemID: itemID)
    }
    #expect(player.intents.contains(.stop))
    #expect(model.activeItemID == nil)
    #expect(model.loadedItemID == nil)
  }

  @Test("an overlapping replacement aborts unfollow stop without clearing the replacement")
  func nativeFeedUnfollowStopCannotClearANewerStart() async throws {
    let (model, _, sync, _, _) = Self.makeModel()
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: itemID, episodeID: "episode-7")
    model.setLoaded(itemID: itemID, episodeID: "episode-7", isStreaming: true)
    sync.holdStopSession()

    let stopping = Task { try await model.stopForNativeFeedUnfollow(itemID: itemID) }
    await sync.waitForCalls { $0.contains(.stopSession) }

    sync.stubStartSession(
      .success(Self.preparedPlayback(itemID: "new-book", startPosition: 0)))
    await model.start(itemID: "new-book")
    sync.releaseStopSession()

    await #expect(throws: CancellationError.self) { try await stopping.value }
    #expect(model.activeItemID == "new-book")
    #expect(model.loadedItemID == "new-book")
  }

  @Test("unfollow waits for a replacement to retire the still-loaded target feed")
  func nativeFeedUnfollowWaitsForReplacementOfLoadedTarget() async throws {
    let (model, _, sync, _, _) = Self.makeModel()
    let targetItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: targetItemID, episodeID: "episode-7")
    model.setLoaded(itemID: targetItemID, episodeID: "episode-7", isStreaming: true)
    sync.holdStartSession()

    let replacement = Task { await model.start(itemID: "new-book") }
    await sync.waitForCalls {
      $0.contains(.startSession(itemID: "new-book", episodeID: nil))
    }
    #expect(model.activeItemID == "new-book")
    #expect(model.loadedItemID == targetItemID)

    let stopping = Task {
      try await model.stopForNativeFeedUnfollow(itemID: targetItemID)
      return model.loadedItemID
    }
    sync.releaseStartSession(
      with: .success(Self.preparedPlayback(itemID: "new-book", startPosition: 0)))

    await replacement.value
    let loadedWhenUnfollowStopReturned = try await stopping.value
    #expect(loadedWhenUnfollowStopReturned == "new-book")
    #expect(model.activeItemID == "new-book")
    #expect(model.loadedItemID == "new-book")
  }

  @Test("unfollow cancels a target preparation without stopping the unrelated loaded item")
  func nativeFeedUnfollowCancelsTargetPreparationAndPreservesLoadedItem() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    let targetItemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    model.setActive(itemID: "old-book", episodeID: nil)
    model.setLoaded(itemID: "old-book", episodeID: nil, isStreaming: true)
    model.setPhase(.playing)
    player.state = PlayerState(
      phase: .playing, item: nil, currentTrackIndex: 0, globalPosition: 18, rate: 1,
      isPlaybackIntended: true)
    sync.holdStartSession()

    let targetStart = Task {
      await model.start(itemID: targetItemID, episodeID: "episode-7")
    }
    await sync.waitForCalls {
      $0.contains(.startSession(itemID: targetItemID, episodeID: "episode-7"))
    }
    #expect(model.activeItemID == targetItemID)
    #expect(model.loadedItemID == "old-book")

    let stopping = Task { try await model.stopForNativeFeedUnfollow(itemID: targetItemID) }
    sync.releaseStartSession(
      with: .success(
        Self.preparedPlayback(
          itemID: targetItemID, episodeID: "episode-7", startPosition: 0)))

    await targetStart.value
    try await stopping.value
    #expect(player.intents.contains(.stop) == false)
    #expect(Self.loadedItems(from: player.intents).contains { $0.id == targetItemID } == false)
    #expect(model.activeItemID == "old-book")
    #expect(model.loadedItemID == "old-book")
    #expect(model.phase == .playing)
  }

  // MARK: - Completed seek triggers exactly one immediate sync (API-CONVENTIONS rule 7)

  @Test func aCompletedSeekTriggersExactlyOneImmediateSync() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .seeking, currentTime: 10, listenedDelta: 0))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .playing, currentTime: 50, listenedDelta: 0))

    // Phase reporting is eager, so use the trigger itself as the completion
    // marker: unlike the phase call, it remains after the completed event's tick.
    await sync.waitForCalls { Self.seekCompletedTriggerCount($0) >= 1 }

    #expect(
      Self.seekCompletedTriggerCount(sync.calls) == 1,
      "the seek-start event itself (still .seeking) must not count as the completion trigger")
  }

  @Test func aSeekResolvingToPausedAlsoTriggersExactlyOneImmediateSync() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .seeking, currentTime: 10, listenedDelta: 0))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 50, listenedDelta: 0))

    await sync.waitForCalls { Self.seekCompletedTriggerCount($0) >= 1 }
    #expect(Self.seekCompletedTriggerCount(sync.calls) == 1)
  }

  @Test func seekCompletedTriggerWaitsForTheCompletedTick() async throws {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .seeking, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 1 }

    // Release the seek-start event, then park the completion event's tick independently.
    sync.releaseRecordProgressTicks()
    sync.holdRecordProgressTicks()
    defer { sync.releaseRecordProgressTicks() }
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .playing, currentTime: 50, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }

    #expect(
      Self.seekCompletedTriggerCount(sync.calls) == 0,
      "the completed-seek trigger must wait while the completed event's tick is held")

    sync.releaseRecordProgressTicks()
    await sync.waitForCalls { Self.seekCompletedTriggerCount($0) == 1 }

    let calls = sync.calls
    let tickIndices = calls.enumerated().compactMap { index, call in
      if case .recordProgressTick = call { return index }
      return nil
    }
    let completedTickIndex = try #require(tickIndices.dropFirst().first)
    let triggerIndex = try #require(
      calls.firstIndex(of: .notifyImmediateSyncTrigger(.seekCompleted)))
    #expect(completedTickIndex < triggerIndex)
  }

  @Test func anOrdinaryPhaseTransitionNeverFiresASeekCompletedTrigger() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 1, listenedDelta: 1))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 2, listenedDelta: 1))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 3, itemId: "item-1", phase: .playing, currentTime: 3, listenedDelta: 1))

    // Each of the three events reports a distinct cadence phase, and that report is the last
    // call `handle(progressEvent:)` makes per event. After the third, all three events'
    // trigger decisions are complete and the zero below is conclusive.
    await sync.waitForCalls { Self.cadencePhaseCalls($0).count >= 3 }
    #expect(Self.seekCompletedTriggerCount(sync.calls) == 0, "pause/resume alone is never a completed seek")
  }

  @Test func anEndedTickIsMarkedAsFinished() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .ended, currentTime: 3600, listenedDelta: 4))

    await sync.waitForCalls { Self.tickCalls($0).isEmpty == false }
    #expect(Self.tickCalls(sync.calls).first?.isFinished == true)
  }

  // MARK: - Start-or-seek (chapter/history "jump to a position")

  @Test func startOrSeekOnTheAlreadyActiveItemSeeksDirectlyWithoutRestartingTheSession() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    await model.startOrSeek(itemID: "item-1", toGlobalOffset: 500)

    let startCalls = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
    #expect(startCalls.count == 1, "the already-active item must not re-open a session")
    #expect(player.intents.last == .seek(toGlobalOffset: 500))
  }

  @Test func startOrSeekOnADifferentItemStartsThenSeeks() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 15)))

    await model.startOrSeek(itemID: "item-1", toGlobalOffset: 500)

    #expect(sync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)))
    #expect(player.intents.count == 3, "load, play, then the requested seek")
    #expect(player.intents.last == .seek(toGlobalOffset: 500))
    #expect(model.activeItemID == "item-1")
  }

  @Test func chapterTapWhileTheSameItemIsPreparingSeeksAfterItsLoadCompletes() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.holdStartSession()

    let startTask = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-1", episodeID: nil)) }

    await model.startOrSeek(itemID: "item-1", toGlobalOffset: 500)
    #expect(
      player.intents.isEmpty,
      "the chapter target must wait rather than seeking the stale previously-loaded player item")

    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 180)))
    await startTask.value

    #expect(player.intents.count == 3, "load, play, then the chapter seek")
    #expect(player.intents.last == .seek(toGlobalOffset: 500))
  }

  @Test func startOrSeekNeverSendsASeekWhenTheUnderlyingStartFails() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    await model.startOrSeek(itemID: "item-1", toGlobalOffset: 500)

    #expect(player.intents.isEmpty, "no seek may reach the player when the session never opened")
    #expect(model.activeItemID == nil)
  }

  // MARK: - Model cancellation does not orphan a session

  @Test func cancellingTheStartTaskAfterTheSessionOpenedClosesItRatherThanOrphaningIt() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.holdStartSession()

    let task = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls { $0.contains(.startSession(itemID: "item-1", episodeID: nil)) }
    task.cancel()
    sync.releaseStartSession(with: .success(Self.preparedPlayback(startPosition: 0)))
    await task.value

    #expect(player.intents.isEmpty, "a cancelled start must never hand a stale session to the player")
    #expect(sync.calls.contains(.stopSession), "the durably-opened session must be closed, not orphaned")
    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
  }

  // MARK: - Launch recovery gates play

  @Test func launchRecoveryRunsBeforeAnyStartCallIsAccepted() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.holdRecoverOpenSessions()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))

    let task = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls { $0.contains(.recoverOpenSessions) }
    #expect(
      sync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)) == false,
      "start must wait for launch recovery to finish first")

    sync.releaseRecoverOpenSessions()
    await task.value

    #expect(
      sync.calls == [
        .recoverOpenSessions,
        .notifyPlaybackPhase(.buffering),
        .startSession(itemID: "item-1", episodeID: nil),
      ])
  }

  @Test func logoutWhileLaunchRecoveryIsHeldPreventsTheWaitingStartFromResuming() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.holdRecoverOpenSessions()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))

    let start = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls { $0.contains(.recoverOpenSessions) }

    await model.prepareForLogout()
    sync.releaseRecoverOpenSessions()
    await start.value

    #expect(model.isQuiescedForLogout)
    #expect(model.activeItemID == nil)
    #expect(model.loadedItemID == nil)
    #expect(model.phase == .idle)
    #expect(
      sync.calls.contains { if case .startSession = $0 { return true } else { return false } } == false,
      "a start waiting at the recovery gate must recheck logout before opening a session")
    #expect(
      player.intents.filter { $0 != .stop }.isEmpty,
      "logout's stop is the only player intent allowed after the recovery gate opens")
  }

  // MARK: - Logout preflight

  @Test func logoutQuiescesPlaybackMakesTheBoundedCloseAttemptThenInvokesAccountLogout() async throws {
    let (model, player, sync, account, appLifecycle) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    try await model.logout()

    #expect(player.intents.contains(.stop))
    #expect(sync.calls.contains(.quiesceForLogout))
    #expect(account.logoutCallCount == 1)
    #expect(appLifecycle.backgroundTaskBeginCount == 1)
    #expect(appLifecycle.backgroundTaskEndCount == 1)
    #expect(model.isQuiescedForLogout)
    #expect(model.activeItemID == nil)
    #expect(model.phase == .idle)
  }

  @Test func prepareForLogoutRunsPlaybackCleanupWithoutCallingAccountLogout() async {
    let (model, player, sync, account, appLifecycle) = Self.makeModel()

    await model.prepareForLogout()

    #expect(player.intents.contains(.stop))
    #expect(sync.calls.contains(.quiesceForLogout))
    #expect(account.logoutCallCount == 0)
    #expect(appLifecycle.backgroundTaskBeginCount == 1)
    #expect(model.isQuiescedForLogout)
    #expect(model.activeItemID == nil)
    #expect(model.phase == .idle)
  }

  @Test func aFailedServerSideLogoutConfirmationStillLeavesThePreflightAlreadyDone() async {
    struct LogoutConfirmationFailed: Error {}
    let (model, player, sync, account, appLifecycle) = Self.makeModel()
    account.stubLogout(throwing: LogoutConfirmationFailed())

    await #expect(throws: LogoutConfirmationFailed.self) {
      try await model.logout()
    }

    // The preflight (quiesce + bounded close attempt) already fully ran before the throw
    // surfaced. A failed server-side confirmation must not skip or undo it.
    #expect(player.intents.contains(.stop))
    #expect(sync.calls.contains(.quiesceForLogout))
    #expect(appLifecycle.backgroundTaskBeginCount == 1)
    #expect(appLifecycle.backgroundTaskEndCount == 1)
    #expect(account.logoutCallCount == 1, "the destructive logout call itself was still made")
  }

  @Test func newIntentsAreRejectedAfterLogout() async throws {
    let (model, _, sync, _, _) = Self.makeModel()
    try await model.logout()

    await model.start(itemID: "item-1")

    #expect(
      sync.calls.contains { if case .startSession = $0 { return true } else { return false } } == false,
      "no new playback work may start once logout has begun")
    #expect(model.activeItemID == nil)
  }
}
