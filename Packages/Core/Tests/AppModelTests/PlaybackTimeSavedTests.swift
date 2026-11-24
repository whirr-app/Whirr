import Foundation
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Records what `PlaybackModel` adds to each time-saved total, and how often it flushes.
@MainActor
final class FakeTimeSaved: TimeSavedRecording {
  private(set) var added: [(TimeSavedSource, Double)] = []
  private(set) var flushes = 0

  func add(_ seconds: Double, to source: TimeSavedSource) { added.append((source, seconds)) }
  func flush() { flushes += 1 }

  func total(_ source: TimeSavedSource) -> Double {
    added.filter { $0.0 == source }.map(\.1).reduce(0, +)
  }

  func count(_ source: TimeSavedSource) -> Int { added.filter { $0.0 == source }.count }
}

/// Time saved against 1×: speed and silence from every ingested event,
/// ads from each skip and its Undo, whether or not Trim Silences or ad skip is composed.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackTimeSavedTests {
  static let ad = PlayerSkipRange(start: 30, end: 50, endsItem: false)
  static let file = URL(fileURLWithPath: "/downloads/show/episode-a.mp3")

  // MARK: - Speed and silence

  @Test func speedAndSilenceAreRecordedOncePerEventWithoutTrimOrAdSkip() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")

    player.pushProgress(Self.event(sequence: 1, speed: 2, trimmedSource: 1.5))
    player.pushProgress(Self.event(sequence: 2, speed: 0, trimmedSource: 0))
    player.pushProgress(Self.event(sequence: 3, speed: 0.5, trimmedSource: 0))

    #expect(await waitUntil { timeSaved.total(.speed) == 2.5 })
    #expect(timeSaved.count(.speed) == 2)
    #expect(timeSaved.total(.silence) == 1.5)
    #expect(timeSaved.count(.silence) == 1)
    #expect(timeSaved.count(.ads) == 0)
  }

  @Test func anAudiobookRecordsSpeed() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(itemID: "book", episodeID: nil)))
    await model.start(itemID: "book", episodeID: nil)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "book", episodeID: nil, phase: .playing, currentTime: 10,
        listenedDelta: 2, speedSavedDelta: 1))

    #expect(await waitUntil { timeSaved.total(.speed) == 1 })
  }

  @Test func anEventForAnItemNoLongerLoadedRecordsNothing() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-old", phase: .playing, currentTime: 10,
        listenedDelta: 2, speedSavedDelta: 5, trimmedSourceDelta: 5))
    player.pushProgress(Self.event(sequence: 2, speed: 1, trimmedSource: 0))

    #expect(await waitUntil { timeSaved.total(.speed) == 1 })
    #expect(timeSaved.count(.silence) == 0)
  }

  @Test func pausingFlushesTheTotalsAndPlayingDoesNot() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")
    let before = timeSaved.flushes

    player.pushProgress(Self.event(sequence: 1, speed: 1, trimmedSource: 0))
    #expect(await waitUntil { timeSaved.total(.speed) == 1 })
    #expect(timeSaved.flushes == before)

    player.pushProgress(Self.event(sequence: 2, phase: .paused, speed: 1, trimmedSource: 0))
    #expect(await waitUntil { timeSaved.flushes == before + 1 })
    #expect(timeSaved.total(.speed) == 2)
  }

  @Test func stoppingFlushesTheTotals() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(Self.event(sequence: 1, speed: 1, trimmedSource: 0))
    #expect(await waitUntil { timeSaved.total(.speed) == 1 })
    let before = timeSaved.flushes

    await model.stop()

    #expect(timeSaved.flushes > before)
  }

  // MARK: - Ads

  @Test func anUndoneSkipNetsToZero() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel(skipRanges: true)
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")

    player.pushProgress(Self.skip(sequence: 9, range: Self.ad))
    #expect(await waitUntil { model.lastSkip != nil })
    #expect(timeSaved.total(.ads) == 20)

    model.undoLastSkip()

    #expect(timeSaved.added.map(\.1) == [20, -20])
    #expect(timeSaved.total(.ads) == 0)
  }

  @Test func aRewindAndReSkipCountsTwice() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel(skipRanges: true)
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")

    player.pushProgress(Self.skip(sequence: 9, range: Self.ad))
    player.pushProgress(Self.skip(sequence: 12, range: Self.ad))

    #expect(await waitUntil { timeSaved.count(.ads) == 2 })
    #expect(timeSaved.total(.ads) == 40)
  }

  @Test func aSkipIsRecordedWithoutAnAdSkipSource() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")

    player.pushProgress(Self.skip(sequence: 9, range: Self.ad))

    #expect(await waitUntil { timeSaved.total(.ads) == 20 })
  }

  @Test func aRangeThatEndsTheItemIsClampedToItsEnd() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel(skipRanges: true)
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.state.item = Self.item(duration: 95)

    player.pushProgress(
      Self.skip(sequence: 9, phase: .ended, range: PlayerSkipRange(start: 90, end: 100, endsItem: true)))

    #expect(await waitUntil { timeSaved.count(.ads) == 1 })
    #expect(timeSaved.total(.ads) == 5)
  }

  @Test func aRangeThatEndsTheItemIsNeverNegative() async throws {
    let (model, player, sync, timeSaved) = Self.makeModel(skipRanges: true)
    sync.stubStartSession(.success(Self.prepared()))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.state.item = Self.item(duration: 85)

    player.pushProgress(
      Self.skip(sequence: 9, phase: .ended, range: PlayerSkipRange(start: 90, end: 100, endsItem: true)))

    #expect(await waitUntil { timeSaved.count(.ads) == 1 })
    #expect(timeSaved.total(.ads) == 0)
  }

  // MARK: - Helpers

  static func makeModel(skipRanges: Bool = false) -> (
    PlaybackModel, FakePlaybackControlling, FakePlaybackSyncing, FakeTimeSaved
  ) {
    let timeSaved = FakeTimeSaved()
    let playback = PlaybackModelHarness(
      skipRanges: skipRanges ? PlaybackSkipRangeTests.FakeSource() : nil, timeSaved: timeSaved)
    return (playback.model, playback.player, playback.sync, timeSaved)
  }

  static func event(
    sequence: Int, phase: PlayerPhase = .playing, speed: Double, trimmedSource: Double
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: sequence, itemId: "show", episodeID: "episode-a", phase: phase,
      currentTime: Double(sequence) * 10, listenedDelta: 1, speedSavedDelta: speed,
      trimmedSourceDelta: trimmedSource)
  }

  static func skip(
    sequence: Int, phase: PlayerPhase = .seeking, range: PlayerSkipRange
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: sequence, itemId: "show", episodeID: "episode-a", phase: phase,
      currentTime: range.end, listenedDelta: 0, skippedRange: range)
  }

  static func item(duration: Double) -> PlayerItem {
    PlayerItem(
      id: "show", episodeID: "episode-a",
      timeline: try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)]))
  }

  static func prepared(itemID: String = "show", episodeID: String? = "episode-a") -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100, url: file, mimeType: "audio/mpeg",
          title: "episode-a")
      ],
      chapters: [], source: .local)
  }
}
