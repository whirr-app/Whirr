import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// What `PlaybackModel` keeps for Look Back, and its pause and play-from-here transport.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackLookBackTests {
  private struct Harness {
    let model: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let downloadReading: FakeDownloadReading
  }

  private func makeHarness() -> Harness {
    let downloadReading = FakeDownloadReading()
    let playback = PlaybackModelHarness(downloadReading: downloadReading)
    return Harness(
      model: playback.model, player: playback.player, sync: playback.sync,
      downloadReading: downloadReading)
  }

  private func prepared(
    itemID: String, episodeID: String? = nil, source: PreparedPlaybackSource
  ) -> PreparedPlayback {
    let tracks = (0..<2).map { index in
      PlaybackFixture.track(
        index: index, startOffset: Double(index) * 600, duration: 600,
        url: source == .local
          ? URL(fileURLWithPath: "/downloads/\(itemID)/\(index).mp3")
          : URL(string: "https://example.test/\(itemID)/\(index).mp3")!,
        mimeType: "audio/mpeg", title: nil)
    }
    return PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 1_200, tracks: tracks,
      chapters: [
        PreparedPlaybackChapter(id: 0, start: 0, end: 500, title: "Opening"),
        PreparedPlaybackChapter(id: 1, start: 500, end: 1_200, title: nil),
      ],
      source: source)
  }

  private func start(_ harness: Harness, _ prepared: PreparedPlayback) async {
    harness.sync.stubStartSession(.success(prepared))
    await harness.model.start(itemID: prepared.itemID, episodeID: prepared.episodeID)
  }

  @Test func aDownloadedBookKeepsItsTracksAndChapters() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "book", source: .local))

    let lookBack = harness.model.loadedLookBack
    #expect(lookBack?.itemID == "book")
    #expect(
      lookBack?.tracks == [
        LookBackTrack(fileURL: URL(fileURLWithPath: "/downloads/book/0.mp3"), startOffset: 0, duration: 600),
        LookBackTrack(fileURL: URL(fileURLWithPath: "/downloads/book/1.mp3"), startOffset: 600, duration: 600),
      ])
    #expect(lookBack?.chapters == [.init(start: 0, title: "Opening"), .init(start: 500, title: "")])
  }

  /// A cold launch shows the restored book without loading it. Look Back is offered for it and
  /// loads it paused, as a chapter skip does, so the sheet has files and a playhead.
  @Test func aRestoredBookLoadsPausedForLookBack() async {
    let bookmarks = FakePlaybackBookmarkStoring()
    let playback = PlaybackModelHarness(bookmarkStore: bookmarks)
    let model = playback.model
    let player = playback.player
    let sync = playback.sync
    #expect(model.isRestoredAudiobook(itemID: "book") == false)
    bookmarks.push(
      PlaybackBookmark(
        serverItemId: "book", title: "Book", author: nil,
        durationSeconds: 1_200, positionSeconds: 700, isFinished: false))
    await waitUntil { model.displayedItem?.serverItemId == "book" }
    #expect(model.isRestoredAudiobook(itemID: "book"))
    #expect(model.isRestoredAudiobook(itemID: "other") == false)
    #expect(await model.loadForLookBack(itemID: "other") == false)

    sync.stubStartSession(.success(prepared(itemID: "book", source: .local)))
    #expect(await model.loadForLookBack(itemID: "book"))

    #expect(model.loadedLookBack?.itemID == "book")
    #expect(model.isRestoredAudiobook(itemID: "book") == false)
    #expect(player.intents.contains { if case .play = $0 { true } else { false } } == false)
    // Already loaded: no second start.
    #expect(await model.loadForLookBack(itemID: "book"))
    #expect(sync.calls.filter { if case .startSession = $0 { true } else { false } }.count == 1)
  }

  /// A finished book is retained for its metadata but no longer shown, so Look Back is not offered
  /// for it and `loadForLookBack` must not load it on demand.
  @Test func aFinishedRestoredBookIsNotOfferedLookBack() async {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), bookmarkStore: bookmarks)
    bookmarks.push(
      PlaybackBookmark(
        serverItemId: "book", title: "Book", author: nil,
        durationSeconds: 1_200, positionSeconds: 1_200, isFinished: true))
    await waitUntil { model.displayedItem?.serverItemId == "book" }

    #expect(model.displayedItem?.isFinished == true)
    #expect(model.isRestoredAudiobook(itemID: "book") == false)
    #expect(await model.loadForLookBack(itemID: "book") == false)
    #expect(
      sync.calls.contains { if case .startSession = $0 { true } else { false } } == false,
      "a finished book must not be loaded for Look Back")
  }

  /// The Look Back tip's trigger: a sleep timer pausing a book, streamed or downloaded, and never
  /// an episode, which has Transcript instead.
  @Test func aSleepTimerPausingABookIsReported() async {
    let harness = makeHarness()
    var pauses = 0
    harness.model.onBookSleepTimerPause = { pauses += 1 }

    await start(harness, prepared(itemID: "show", episodeID: "episode", source: .local))
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode", phase: .paused, currentTime: 10,
        listenedDelta: 0, sleepTimerExpiry: .expired))
    await harness.sync.waitForCalls { calls in
      calls.contains(.sleepTimerExpiry(itemID: "show", episodeID: "episode"))
    }
    #expect(pauses == 0)

    await start(harness, prepared(itemID: "book", source: .streaming))
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "book", episodeID: nil, phase: .paused, currentTime: 10,
        listenedDelta: 0, sleepTimerExpiry: .expired))
    await harness.sync.waitForCalls { calls in
      calls.contains(.sleepTimerExpiry(itemID: "book", episodeID: nil))
    }
    await waitUntil { pauses == 1 }
    #expect(pauses == 1)
  }

  @Test func aStreamedBookHasNone() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "book", source: .streaming))
    #expect(harness.model.loadedLookBack == nil)
  }

  @Test func aDownloadedEpisodeHasNone() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "show", episodeID: "episode", source: .local))
    #expect(harness.model.loadedLookBack == nil)
  }

  @Test func aBookPromotedToItsDownloadGainsIt() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "book", source: .streaming))
    harness.player.isPlaybackIntended = true
    harness.player.state.globalPosition = 10
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: harness.player.intents.count + 1, itemId: "book", episodeID: nil,
        phase: .playing, currentTime: 10, listenedDelta: 0))
    await waitUntil { harness.model.phase == .playing }
    harness.sync.stubPromoteStreamingSessionToLocalDownload(prepared(itemID: "book", source: .local))

    harness.downloadReading.pushStatus(.completed, itemId: "book")
    await waitUntil { harness.model.isStreamingSource == false }
    #expect(harness.model.loadedLookBack?.tracks.count == 2)
  }

  @Test func loadingSomethingElseClearsIt() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "book", source: .local))
    #expect(harness.model.loadedLookBack != nil)
    await start(harness, prepared(itemID: "other", source: .streaming))
    #expect(harness.model.loadedLookBack == nil)
  }

  @Test func pauseSendsNothingWhenAlreadyPaused() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "book", source: .local))
    harness.player.isPlaybackIntended = false
    let before = harness.player.intents.count
    harness.model.pause()
    #expect(harness.player.intents.count == before)

    harness.player.isPlaybackIntended = true
    harness.model.pause()
    #expect(harness.player.intents.last == .pause)
  }

  @Test func pausingForLookBackPausesAndReturnsThePlayhead() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "book", source: .local))
    harness.player.isPlaybackIntended = true
    let playhead = harness.model.pauseForLookBack()
    #expect(harness.player.intents.last == .pause)
    #expect(playhead == harness.model.currentTime)
  }

  @Test func playFromAnOffsetSeeksThenPlays() async {
    let harness = makeHarness()
    await start(harness, prepared(itemID: "book", source: .local))
    harness.player.isPlaybackIntended = false
    let before = harness.player.intents.count

    harness.model.play(fromGlobalOffset: 321)
    #expect(Array(harness.player.intents.dropFirst(before)) == [.seek(toGlobalOffset: 321), .play])

    harness.player.isPlaybackIntended = true
    harness.model.play(fromGlobalOffset: 100)
    #expect(harness.player.intents.last == .seek(toGlobalOffset: 100))
  }
}
