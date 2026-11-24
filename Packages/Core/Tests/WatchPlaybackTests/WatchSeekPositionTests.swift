import Testing

@testable import WatchPlayback

@Suite("Watch seek position")
struct WatchSeekPositionTests {
  @Test("a known duration bounds the whole title")
  func boundsUseTheDuration() {
    #expect(WatchSeekPosition.bounds(duration: 3_600) == 0...3_600)
  }

  @Test("an unknown, zero or indefinite duration is not seekable")
  func unusableDurationsAreNotSeekable() {
    #expect(WatchSeekPosition.isSeekable(duration: nil) == false)
    #expect(WatchSeekPosition.isSeekable(duration: 0) == false)
    #expect(WatchSeekPosition.isSeekable(duration: -10) == false)
    #expect(WatchSeekPosition.isSeekable(duration: .infinity) == false)
    #expect(WatchSeekPosition.isSeekable(duration: .nan) == false)
    // A control still needs a valid range, so the screen does not trap on a zero-length title.
    #expect(WatchSeekPosition.bounds(duration: 0) == 0...1)
  }

  @Test("a chosen position stays inside the title")
  func clampsPositions() {
    #expect(WatchSeekPosition.clamped(120, duration: 3_600) == 120)
    #expect(WatchSeekPosition.clamped(0, duration: 3_600) == 0)
    #expect(WatchSeekPosition.clamped(3_600, duration: 3_600) == 3_600)
    #expect(WatchSeekPosition.clamped(-5, duration: 3_600) == 0)
    #expect(WatchSeekPosition.clamped(4_000, duration: 3_600) == 3_600)
    #expect(WatchSeekPosition.clamped(.nan, duration: 3_600) == 0)
    #expect(WatchSeekPosition.clamped(.infinity, duration: 3_600) == 0)
  }

  @Test("the crown crosses a title in a bounded number of detents")
  func crownStrideScalesWithTheTitle() {
    // An hour in 240 detents is 15 s each; a minute cannot go finer than one second.
    #expect(WatchSeekPosition.crownStride(duration: 3_600) == 15)
    #expect(WatchSeekPosition.crownStride(duration: 60) == 1)
    #expect(WatchSeekPosition.crownStride(duration: nil) == 1)
    #expect(WatchSeekPosition.crownStride(duration: 0) == 1)
  }
}
