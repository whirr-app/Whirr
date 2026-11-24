import Testing

@testable import Persistence

@Suite struct PlaybackPositionListProjectionTests {
  @Test func floorsPositionsToTheWholeMinute() {
    #expect(PlaybackPositionListProjection.quantizedSeconds(60) == 60)
    #expect(PlaybackPositionListProjection.quantizedSeconds(119.9) == 60)
    #expect(PlaybackPositionListProjection.quantizedSeconds(754.3) == 720)
    #expect(PlaybackPositionListProjection.quantizedSeconds(36_000.5) == 36_000)
  }

  /// A started episode must stay started: rounding a first-minute position down would move it to
  /// "Not played" and out of the show page's in-progress filter.
  @Test func keepsPositionsInsideTheFirstMinuteExact() {
    #expect(PlaybackPositionListProjection.quantizedSeconds(0) == 0)
    #expect(PlaybackPositionListProjection.quantizedSeconds(0.5) == 0.5)
    #expect(PlaybackPositionListProjection.quantizedSeconds(42) == 42)
    #expect(PlaybackPositionListProjection.quantizedSeconds(59.9) == 59.9)
  }

  @Test func passesInvalidPositionsThrough() {
    #expect(PlaybackPositionListProjection.quantizedSeconds(-5) == -5)
    #expect(PlaybackPositionListProjection.quantizedSeconds(.infinity) == .infinity)
    #expect(PlaybackPositionListProjection.quantizedSeconds(.nan).isNaN)
  }
}
