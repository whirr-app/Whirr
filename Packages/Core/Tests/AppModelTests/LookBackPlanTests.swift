import AdSkip
import Foundation
import Testing

@testable import AppModel

/// `LookBackPlan`: book time before the playhead onto the loaded files, newest chunk first.
@Suite struct LookBackPlanTests {
  private func url(_ name: String) -> URL { URL(fileURLWithPath: "/book/\(name).mp3") }

  private func track(_ name: String, _ start: Double, _ duration: Double) -> LookBackTrack {
    LookBackTrack(fileURL: url(name), startOffset: start, duration: duration)
  }

  private func span(_ start: Double, _ end: Double) -> TimeSpan { TimeSpan(start: start, end: end) }

  @Test func aWindowInsideOneTrackIsOneSegmentOnTheFilesClock() {
    let tracks = [track("a", 0, 1_000), track("b", 1_000, 5_000)]
    let segments = LookBackPlan.segments(window: span(2_000, 2_900), tracks: tracks)
    #expect(segments == [LookBackSegment(fileURL: url("b"), localWindow: span(1_000, 1_900), startOffset: 1_000)])
    #expect(segments[0].bookWindow == span(2_000, 2_900))
  }

  @Test func aBoundaryInsideTheWindowSplitsItEarliestFirst() {
    let tracks = [track("b", 1_000, 5_000), track("a", 0, 1_000)]
    let segments = LookBackPlan.segments(window: span(400, 1_300), tracks: tracks)
    #expect(segments.map(\.fileURL) == [url("a"), url("b")])
    #expect(segments.map(\.localWindow) == [span(400, 1_000), span(0, 300)])
  }

  @Test func aWindowBeforeTheFirstTracksEndStaysInIt() {
    let segments = LookBackPlan.segments(
      window: span(0, 200), tracks: [track("a", 0, 1_000), track("b", 1_000, 1_000)])
    #expect(segments.map(\.localWindow) == [span(0, 200)])
  }

  @Test func tracksShorterThanTheWindowEachGiveTheirWholeLength() {
    let tracks = [track("a", 0, 100), track("b", 100, 60), track("c", 160, 40), track("d", 200, 500)]
    let segments = LookBackPlan.segments(window: span(50, 250), tracks: tracks)
    #expect(segments.map(\.fileURL) == [url("a"), url("b"), url("c"), url("d")])
    #expect(segments.map(\.localWindow) == [span(50, 100), span(0, 60), span(0, 40), span(0, 50)])
  }

  @Test func aTrackIsClampedByItsDeclaredDuration() {
    // Declared lengths leave a gap the player never plays; nothing is asked of it.
    let tracks = [track("a", 0, 90), track("b", 100, 100)]
    let segments = LookBackPlan.segments(window: span(80, 120), tracks: tracks)
    #expect(segments.map(\.localWindow) == [span(80, 90), span(0, 20)])
  }

  @Test(arguments: [LookBackPlan.initialReach, 900, LookBackPlan.maximumReach])
  func eachLengthIsCutIntoChunksBackFromThePlayhead(length: Double) {
    let chunks = LookBackPlan.chunks(
      playhead: 10_000, length: length, tracks: [track("a", 0, 20_000)])
    #expect(chunks.count == Int(length / LookBackPlan.chunkSeconds))
    #expect(chunks.first?.localWindow == span(9_850, 10_000))
    #expect(chunks.last?.localWindow.start == 10_000 - length)
    for (newer, older) in zip(chunks, chunks.dropFirst()) {
      #expect(older.localWindow.end == newer.localWindow.start)
    }
  }

  @Test func aPlayheadUnderTheLengthStartsAtZero() {
    let chunks = LookBackPlan.chunks(playhead: 200, length: 900, tracks: [track("a", 0, 1_000)])
    #expect(chunks.map(\.localWindow) == [span(50, 200), span(0, 50)])
  }

  @Test func aPlayheadAtZeroPlansNothing() {
    #expect(LookBackPlan.chunks(playhead: 0, length: 900, tracks: [track("a", 0, 1_000)]).isEmpty)
  }

  @Test func aChunkAcrossATrackBoundaryIsOneCallPerFileNewestFirst() {
    let tracks = [track("a", 0, 1_000), track("b", 1_000, 1_000)]
    let chunks = LookBackPlan.chunks(playhead: 1_100, length: 300, tracks: tracks)
    #expect(chunks.map(\.fileURL) == [url("b"), url("a"), url("a")])
    #expect(chunks.map(\.bookWindow) == [span(1_000, 1_100), span(950, 1_000), span(800, 950)])
    #expect(chunks.map(\.localWindow) == [span(0, 100), span(950, 1_000), span(800, 950)])
  }

  @Test func extendingFiveToFifteenPlansOnlyTheOlderChunks() {
    let tracks = [track("a", 0, 5_000)]
    let five = LookBackPlan.chunks(playhead: 3_000, length: 300, tracks: tracks)
    let fifteen = LookBackPlan.chunks(playhead: 3_000, length: 900, tracks: tracks)
    let extended = LookBackPlan.chunks(
      playhead: 3_000, length: 900, alreadyCovered: 300, tracks: tracks)
    #expect(Array(fifteen.prefix(five.count)) == five)
    #expect(extended == Array(fifteen.dropFirst(five.count)))
    #expect(extended.first?.localWindow == span(2_550, 2_700))
  }

  @Test func extendingPastTheStartOfTheBookPlansNothingMore() {
    let tracks = [track("a", 0, 5_000)]
    #expect(
      LookBackPlan.chunks(playhead: 200, length: 1_800, alreadyCovered: 300, tracks: tracks)
        .isEmpty)
  }
}
