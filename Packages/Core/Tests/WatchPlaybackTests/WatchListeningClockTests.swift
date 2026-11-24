import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// Listening time is accrued per interval with the playing state at both ends.
@Suite struct WatchListeningClockTests {
  private let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)

  @Test func anIntervalCountsOnlyWhenPlayingAtBothEnds() {
    var clock = WatchListeningClock()
    clock.restart(at: 100, playing: true)
    #expect(clock.take(at: 102, playing: true) == 2)
    #expect(clock.take(at: 104, playing: false) == 0)
    #expect(clock.take(at: 106, playing: true) == 0)
    #expect(clock.take(at: 108, playing: true) == 2)
  }

  @Test func eachIntervalIsTakenOnce() {
    var clock = WatchListeningClock()
    clock.restart(at: 100, playing: true)
    #expect(clock.take(at: 103, playing: true) == 3)
    #expect(clock.take(at: 103, playing: true) == 0)
  }

  @Test func anIntervalIsCappedAndNeverNegative() {
    var clock = WatchListeningClock()
    clock.restart(at: 100, playing: true)
    #expect(clock.take(at: 160, playing: true) == WatchListeningClock.maximumInterval)
    #expect(clock.take(at: 150, playing: true) == 0)
  }

  @Test func nothingIsTakenBeforeTheFirstMark() {
    var clock = WatchListeningClock()
    #expect(clock.take(at: 100, playing: true) == 0)
    #expect(clock.take(at: 101, playing: true) == 1)
  }

  @Test func aRestartDiscardsUntakenTime() {
    var clock = WatchListeningClock()
    clock.restart(at: 100, playing: true)
    clock.restart(at: 104, playing: true)
    #expect(clock.take(at: 105, playing: true) == 1)
  }

  /// S18: "last listened" belongs to a title, and an account change forgets it.
  @Test func lastListenedIsKeyedByTitle() {
    var clock = WatchListeningClock()
    let other = WatchSelection.audiobookshelf(itemID: "other", episodeID: nil)
    clock.noteListening(book, at: Date(timeIntervalSince1970: 5))
    #expect(clock.lastListened(book) == Date(timeIntervalSince1970: 5))
    #expect(clock.lastListened(other) == nil)
    clock.reset()
    #expect(clock.lastListened(book) == nil)
  }
}
