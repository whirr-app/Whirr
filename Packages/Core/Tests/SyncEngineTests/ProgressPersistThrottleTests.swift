import Foundation
import Testing

@testable import SyncEngine

@Suite struct ProgressPersistThrottleTests {
  private typealias Throttle = ProgressPersistThrottle

  private static func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private static func tick(
    _ currentTime: Double, delta: Double = 0.5, finished: Bool = false,
    item: String = "item", episode: String? = "episode"
  ) -> Throttle.Tick {
    Throttle.Tick(
      itemID: item, episodeID: episode, currentTime: currentTime, listenedDelta: delta,
      isFinished: finished)
  }

  @Test func theFirstTickOfAStreamPersistsAtOnce() {
    var throttle = Throttle(interval: 15)

    let decision = throttle.record(Self.tick(10), isSeek: false, isPlaying: true, now: Self.date(0))

    #expect(decision.writes == [Throttle.Write(tick: Self.tick(10), isSeek: false)])
    #expect(decision.isImmediate)
    #expect(decision.previousFinished == nil)
  }

  @Test func playingTicksInsideTheIntervalMergeIntoOneWrite() {
    var throttle = Throttle(interval: 15)
    _ = throttle.record(Self.tick(10), isSeek: false, isPlaying: true, now: Self.date(0))

    for step in 1...29 {
      let held = throttle.record(
        Self.tick(10 + Double(step) * 0.5), isSeek: false, isPlaying: true,
        now: Self.date(Double(step) * 0.5))
      #expect(held.writes.isEmpty, "tick \(step) is inside the interval")
    }
    let due = throttle.record(Self.tick(25), isSeek: false, isPlaying: true, now: Self.date(15))

    #expect(due.writes == [Throttle.Write(tick: Self.tick(25, delta: 15), isSeek: false)])
    #expect(due.isImmediate == false)
  }

  @Test func aSeekFlushesTheHeldTickAsItsOwnWriteBeforeItself() {
    var throttle = Throttle(interval: 15)
    _ = throttle.record(Self.tick(10), isSeek: false, isPlaying: true, now: Self.date(0))
    _ = throttle.record(Self.tick(12), isSeek: false, isPlaying: true, now: Self.date(2))

    let decision = throttle.record(Self.tick(300), isSeek: true, isPlaying: true, now: Self.date(3))

    #expect(
      decision.writes == [
        Throttle.Write(tick: Self.tick(12), isSeek: false),
        Throttle.Write(tick: Self.tick(300), isSeek: true),
      ])
    #expect(decision.isImmediate)
  }

  @Test func aTickWhileNotPlayingPersistsAtOnce() {
    var throttle = Throttle(interval: 15)
    _ = throttle.record(Self.tick(10), isSeek: false, isPlaying: true, now: Self.date(0))

    let decision = throttle.record(Self.tick(11), isSeek: false, isPlaying: false, now: Self.date(1))

    #expect(decision.writes == [Throttle.Write(tick: Self.tick(11), isSeek: false)])
    #expect(decision.isImmediate)
  }

  @Test func aFinishedTransitionIsABoundaryThatReportsThePreviousFlag() {
    var throttle = Throttle(interval: 15)
    _ = throttle.record(Self.tick(100), isSeek: false, isPlaying: true, now: Self.date(0))

    let decision = throttle.record(
      Self.tick(120, finished: true), isSeek: false, isPlaying: true, now: Self.date(1))

    #expect(decision.writes == [Throttle.Write(tick: Self.tick(120, finished: true), isSeek: false)])
    #expect(decision.isImmediate)
    #expect(decision.previousFinished == false)
  }

  @Test func anotherEpisodeStartsAFreshStreamWithNoContinuity() {
    var throttle = Throttle(interval: 15)
    _ = throttle.record(Self.tick(10), isSeek: false, isPlaying: true, now: Self.date(0))
    _ = throttle.record(Self.tick(11), isSeek: false, isPlaying: true, now: Self.date(1))

    let decision = throttle.record(
      Self.tick(5, episode: "other"), isSeek: false, isPlaying: true, now: Self.date(2))

    #expect(
      decision.writes == [
        Throttle.Write(tick: Self.tick(11), isSeek: false),
        Throttle.Write(tick: Self.tick(5, episode: "other"), isSeek: false),
      ])
    #expect(decision.previousFinished == nil)
  }

  @Test func takingThePendingTickRestartsTheInterval() {
    var throttle = Throttle(interval: 15)
    _ = throttle.record(Self.tick(10), isSeek: false, isPlaying: true, now: Self.date(0))
    _ = throttle.record(Self.tick(14), isSeek: false, isPlaying: true, now: Self.date(10))

    #expect(throttle.takePending(now: Self.date(11)) == Self.tick(14))
    #expect(throttle.takePending(now: Self.date(12)) == nil)
    let held = throttle.record(Self.tick(20), isSeek: false, isPlaying: true, now: Self.date(20))
    #expect(held.writes.isEmpty, "the flush at 11 s restarted the interval")
  }

  @Test func resetForgetsTheStream() {
    var throttle = Throttle(interval: 15)
    _ = throttle.record(Self.tick(10, finished: true), isSeek: false, isPlaying: true, now: Self.date(0))
    throttle.reset()

    let decision = throttle.record(
      Self.tick(10, finished: true), isSeek: false, isPlaying: true, now: Self.date(1))

    #expect(decision.isImmediate)
    #expect(decision.previousFinished == nil)
  }

  @Test func aZeroIntervalPersistsEveryTick() {
    var throttle = Throttle(interval: 0)
    _ = throttle.record(Self.tick(10), isSeek: false, isPlaying: true, now: Self.date(0))

    let decision = throttle.record(Self.tick(10.5), isSeek: false, isPlaying: true, now: Self.date(0.5))

    #expect(decision.writes == [Throttle.Write(tick: Self.tick(10.5), isSeek: false)])
  }
}
