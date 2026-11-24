import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ColdChapterPlaybackTests {
  @Test func coldJumpReachesTheEngineSilentlyAndPublishesItsPosition() async {
    let engine = ChapterNavigationEngine()
    let player = PlayerController(engine: engine, clock: SystemPlaybackClock())
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), bookmarkStore: bookmarks)
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(start: 0, end: 30),
      PlaybackChapter(start: 30, end: 60),
      PlaybackChapter(start: 60, end: 100),
    ])
    bookmarks.push(
      PlaybackBookmark(
        serverItemId: "book", title: "Book", author: nil,
        durationSeconds: 100, positionSeconds: 10, isFinished: false))
    await waitUntil { model.displayedItem?.serverItemId == "book" }
    sync.stubStartSession(
      .success(
        PreparedPlayback(
          itemID: "book", episodeID: nil, startPosition: 90, duration: 100,
          tracks: [
            PreparedPlaybackTrack(
              index: 0, startOffset: 0, duration: 100,
              url: URL(string: "https://example.test/book.mp3")!,
              mimeType: "audio/mpeg", title: "Book")
          ],
          chapters: chapters.chapters.enumerated().map { index, chapter in
            PreparedPlaybackChapter(
              id: index, start: chapter.start, end: chapter.end, title: "Chapter")
          }, source: .streaming)))

    await model.navigateChapter(itemID: "book", forward: true, fallbackChapterMap: chapters)
    #expect(engine.loadedOffset == 30, "Resolve from the displayed position, not the manifest's 90s")
    #expect(engine.playCount == 0)
    engine.ready()
    await waitUntil { model.phase == .paused && model.currentTime == 30 }
    #expect(player.isPlaybackIntended == false)
    #expect(engine.playCount == 0)

    // A loaded-but-never-played player must also seek without turning playback on.
    await model.navigateChapter(itemID: "book", forward: true, fallbackChapterMap: chapters)
    #expect(engine.seekOffset == 60)
    engine.ready()
    await waitUntil { model.phase == .paused && model.currentTime == 60 }
    #expect(engine.playCount == 0)
    #expect(
      sync.calls.allSatisfy { call in
        if case .recordProgressTick(_, _, let listenedDelta, _, _) = call {
          return listenedDelta == 0
        }
        return true
      })

    // Once Play is explicitly requested, chapter navigation preserves that intent.
    model.togglePlayPause(itemID: "book")
    #expect(player.isPlaybackIntended)
    await model.navigateChapter(itemID: "book", forward: false, fallbackChapterMap: chapters)
    #expect(engine.seekOffset == 30)
    engine.ready()
    await waitUntil { model.phase == .playing && model.currentTime == 30 }
    #expect(player.isPlaybackIntended)
    await model.stop()
  }
}

@MainActor
private final class ChapterNavigationEngine: AudioEngine {
  let events: AsyncStream<AudioEngineEvent>
  private let continuation: AsyncStream<AudioEngineEvent>.Continuation
  private var generation = 0
  private(set) var loadedOffset: Double?
  private(set) var seekOffset: Double?
  private(set) var playCount = 0

  init() {
    let stream = AsyncStream<AudioEngineEvent>.makeStream()
    events = stream.stream
    continuation = stream.continuation
  }

  func load(track: PlaybackTrack, localOffset: Double, rate: Double, generation: Int, trim: PlayerTrimMap?) {
    self.generation = generation
    loadedOffset = localOffset
  }
  func ready() { continuation.yield(.ready(generation: generation)) }
  func play() { playCount += 1 }
  func pause() {}
  func seek(toLocalOffset offset: Double) { seekOffset = offset }
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Double) {}
  func setBoundary(atLocalOffset offset: Double?) {}
  func stop() {}
}
