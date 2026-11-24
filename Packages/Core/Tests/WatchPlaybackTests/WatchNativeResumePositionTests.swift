import Foundation
import Testing

@testable import WatchPlayback

/// Where a received RSS episode starts: the Watch's own last listen against the position the
/// phone sent with the copy. There is no server read, so these are the only two sources.
struct WatchNativeResumePositionTests {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func neitherSourceStartsFromTheBeginning() {
    #expect(
      WatchNativeResumePosition.resolve(local: nil, phonePosition: nil, phoneLastListenedAt: nil, duration: 100) == 0)
  }

  @Test func theOnlySourceWins() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 40, offset: nil), phonePosition: nil, phoneLastListenedAt: nil, duration: 100) == 40)
    #expect(
      WatchNativeResumePosition.resolve(local: nil, phonePosition: 30, phoneLastListenedAt: nil, duration: 100) == 30)
  }

  @Test func aFinishedWatchListenStartsFromTheBeginning() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 100, offset: 0, finished: true), phonePosition: nil, phoneLastListenedAt: nil, duration: 100)
        == 0)
  }

  @Test func newerPhoneListeningWins() {
    // Outside the 60 s tie window, the newer listen decides even though the Watch is further.
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 900, offset: 0), phonePosition: 120, phoneLastListenedAt: at(600), duration: 1_000) == 120)
  }

  @Test func newerWatchListeningWins() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 300, offset: 600), phonePosition: 900, phoneLastListenedAt: at(0), duration: 1_000) == 300)
  }

  @Test func insideTheTieWindowTheFurtherPositionWins() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 700, offset: 0), phonePosition: 300, phoneLastListenedAt: at(30), duration: 1_000) == 700)
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 300, offset: 30), phonePosition: 700, phoneLastListenedAt: at(0), duration: 1_000) == 700)
  }

  @Test func exactlyTheTieWindowIsStillATie() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 700, offset: 0), phonePosition: 200, phoneLastListenedAt: at(60), duration: 1_000) == 700)
  }

  /// A phone position with no listen time says nothing about which device was used last, so it
  /// never moves the Watch backwards or forwards past its own listen.
  @Test func anUndatedPhonePositionLosesToAnyWatchListen() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 300, offset: nil), phonePosition: 900, phoneLastListenedAt: nil, duration: 1_000) == 300)
  }

  @Test func anUndatedWatchListenLosesToADatedPhonePosition() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 900, offset: nil), phonePosition: 120, phoneLastListenedAt: at(-600), duration: 1_000) == 120)
  }

  /// Within `WatchResumePosition.samePlaceTolerance` the two are at the same place, so a slightly
  /// later phone timestamp does not nudge the Watch by a second or two.
  @Test func theSamePlaceKeepsTheWatchPosition() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 600, offset: 0), phonePosition: 600.5, phoneLastListenedAt: at(100), duration: 1_000) == 600)
  }

  @Test func aFinishedWatchListenThatWinsReplaysFromTheBeginning() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 3_600, offset: 0, finished: true), phonePosition: 100, phoneLastListenedAt: at(-600),
        duration: 3_600) == 0)
  }

  @Test func aNewerPhonePositionBeatsAFinishedWatchListen() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 3_600, offset: 0, finished: true), phonePosition: 120, phoneLastListenedAt: at(600),
        duration: 3_600) == 120)
  }

  @Test func theResultIsClampedToTheDuration() {
    #expect(
      WatchNativeResumePosition.resolve(local: nil, phonePosition: 500, phoneLastListenedAt: nil, duration: 300) == 300)
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 500, offset: 0), phonePosition: 100, phoneLastListenedAt: at(-600), duration: 300) == 300)
    // An unknown duration has nothing to clamp to.
    #expect(
      WatchNativeResumePosition.resolve(local: nil, phonePosition: 500, phoneLastListenedAt: nil, duration: nil) == 500)
  }

  @Test func anUnusablePhonePositionFallsBackToTheWatch() {
    #expect(
      WatchNativeResumePosition.resolve(
        local: listen(at: 40, offset: 0), phonePosition: -5, phoneLastListenedAt: at(600), duration: 100) == 40)
  }

  private func at(_ offset: TimeInterval) -> Date {
    base.addingTimeInterval(offset)
  }

  private func listen(at position: Double, offset: TimeInterval?, finished: Bool = false) -> WatchNativeListen {
    WatchNativeListen(
      position: position, lastListenedAt: offset.map(at), isFinished: finished, duration: 3_600)
  }
}
