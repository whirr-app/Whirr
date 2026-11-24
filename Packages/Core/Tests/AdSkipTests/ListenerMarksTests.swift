import Foundation
import Testing

@testable import AdSkip

@Suite struct ListenerMarksTests {
  private func span(_ start: Double, _ end: Double) -> TimeSpan { TimeSpan(start: start, end: end) }

  private func laid(
    _ marks: [TimeSpan], over ranges: [(start: Double, end: Double, endsItem: Bool)]
  ) -> [(Double, Double, Bool, Int?)] {
    ListenerMarks.laying(marks, over: ranges).map { ($0.start, $0.end, $0.endsItem, $0.source) }
  }

  @Test func aRangeNoMarkTouchesIsReturnedAsItWas() {
    let pieces = laid([span(100, 120)], over: [(10, 40, true), (120, 150, false)])
    #expect(pieces.map(\.0) == [10, 100, 120])
    #expect(pieces[0] == (10, 40, true, 0))
    #expect(pieces[2] == (120, 150, false, 1))
  }

  @Test func aMarkIsServedWholeAndCutsTheRangeAroundIt() {
    let pieces = laid([span(30, 50)], over: [(10, 90, false)])
    #expect(pieces.count == 3)
    #expect(pieces[0] == (10, 30, false, 0))
    #expect(pieces[1] == (30, 50, false, nil))
    #expect(pieces[2] == (50, 90, false, 0))
  }

  @Test func aMarkOfFiveSecondsOrMoreIsLongEnoughAnywhere() {
    #expect(ListenerMarks.isLongEnough(start: 100, end: 105, beside: []))
    #expect(ListenerMarks.isLongEnough(start: 100, end: 104.9, beside: []) == false)
  }

  @Test func aShortMarkBesideAnAdIsLongEnoughWithinTheJoinGap() {
    let ad = [span(200, 224)]
    // Directly before, within the gap before, and exactly at it.
    #expect(ListenerMarks.isLongEnough(start: 197, end: 200, beside: ad))
    #expect(ListenerMarks.isLongEnough(start: 190, end: 191, beside: ad))
    #expect(ListenerMarks.isLongEnough(start: 185, end: 188, beside: ad) == false)
    // After it, on the same terms, and overlapping it.
    #expect(ListenerMarks.isLongEnough(start: 224, end: 227, beside: ad))
    #expect(ListenerMarks.isLongEnough(start: 233, end: 234, beside: ad))
    #expect(ListenerMarks.isLongEnough(start: 233.5, end: 235, beside: ad) == false)
    #expect(ListenerMarks.isLongEnough(start: 198, end: 202, beside: ad))
    // Beside any one of several.
    #expect(ListenerMarks.isLongEnough(start: 300, end: 302, beside: [span(10, 20)] + ad) == false)
    #expect(ListenerMarks.isLongEnough(start: 300, end: 302, beside: ad + [span(302, 310)]))
  }

  // MARK: - Teaching span

  @Test func aMarkOfFourSecondsOrMoreTeachesItsOwnSpanWhateverIsBeside() {
    #expect(ListenerMarks.teachingSpan(start: 100, end: 104, beside: []) == span(100, 104))
    #expect(ListenerMarks.teachingSpan(start: 100, end: 115, beside: []) == span(100, 115))
    #expect(
      ListenerMarks.teachingSpan(start: 100, end: 120, beside: [span(90, 140)]) == span(100, 120))
  }

  @Test func aShortMarkIsJoinedToTheAdItAbuts() {
    #expect(ListenerMarks.teachingSpan(start: 197, end: 200, beside: [span(200, 224)]) == span(197, 224))
    #expect(ListenerMarks.teachingSpan(start: 224, end: 227, beside: [span(200, 224)]) == span(200, 227))
    // Within the gap, and overlapping.
    #expect(ListenerMarks.teachingSpan(start: 190, end: 192, beside: [span(200, 224)]) == span(190, 224))
    #expect(ListenerMarks.teachingSpan(start: 198, end: 201, beside: [span(200, 224)]) == span(198, 224))
    // A mark inside the ad adds nothing.
    #expect(ListenerMarks.teachingSpan(start: 205, end: 208, beside: [span(200, 224)]) == span(200, 224))
  }

  @Test func aShortMarkTeachesNothingWithNoAdWithinTheJoinGap() {
    #expect(ListenerMarks.teachingSpan(start: 100, end: 103, beside: []) == nil)
    #expect(ListenerMarks.teachingSpan(start: 185, end: 188, beside: [span(200, 224)]) == nil)
    #expect(ListenerMarks.teachingSpan(start: 233.5, end: 235, beside: [span(200, 224)]) == nil)
  }

  @Test func theNearestAdIsTheOneJoined() {
    let rows = [span(10, 40), span(200, 224), span(240, 270)]
    #expect(ListenerMarks.teachingSpan(start: 230, end: 233, beside: rows) == span(200, 233))
    #expect(ListenerMarks.teachingSpan(start: 227, end: 229, beside: rows) == span(200, 229))
    #expect(ListenerMarks.teachingSpan(start: 232, end: 234, beside: rows) == span(232, 270))
  }

  @Test func onATieTheLaterAdIsJoined() {
    let rows = [span(200, 224), span(228, 260)]
    #expect(ListenerMarks.teachingSpan(start: 225, end: 227, beside: rows) == span(225, 260))
    #expect(ListenerMarks.teachingSpan(start: 225, end: 227, beside: rows.reversed()) == span(225, 260))
  }

  @Test func aJoinedSpanStillUnderFourSecondsTeachesNothing() {
    #expect(ListenerMarks.teachingSpan(start: 199, end: 200, beside: [span(200, 202.5)]) == nil)
    #expect(ListenerMarks.teachingSpan(start: 199, end: 200, beside: [span(200, 203)]) == span(199, 203))
  }

  @Test func aMarkWithNoPositiveLengthTeachesNothing() {
    #expect(ListenerMarks.teachingSpan(start: 200, end: 200, beside: [span(200, 224)]) == nil)
  }

  @Test func aMarkWithNoPositiveLengthIsNeverLongEnough() {
    let ad = [span(200, 224)]
    #expect(ListenerMarks.isLongEnough(start: 200, end: 200, beside: ad) == false)
    #expect(ListenerMarks.isLongEnough(start: 210, end: 205, beside: ad) == false)
    #expect(ListenerMarks.isLongEnough(start: 100, end: 90, beside: []) == false)
  }

  @Test func aRemnantUnderFiveSecondsIsDropped() {
    let pieces = laid([span(14, 80)], over: [(10, 90, false)])
    #expect(pieces.map(\.3) == [nil, 0])
    #expect(pieces[0].0 == 14 && pieces[0].1 == 80)
    let both = laid([span(14, 86)], over: [(10, 90, false)])
    #expect(both.map(\.3) == [nil])
    // Exactly five seconds is kept.
    #expect(laid([span(15, 80)], over: [(10, 90, false)]).map(\.3) == [0, nil, 0])
  }

  @Test func aRangeKeepsEndsItemOnlyWhileItsRemnantReachesItsEnd() {
    let tail = laid([span(30, 50)], over: [(10, 90, true)])
    #expect(tail.map(\.2) == [false, false, true])
    let head = laid([span(60, 90)], over: [(10, 90, true)])
    #expect(head.map(\.2) == [false, false])
    #expect(head.map(\.3) == [0, nil])
  }

  @Test func aMarkCoveringARangeRemovesIt() {
    let pieces = laid([span(0, 100)], over: [(10, 90, true)])
    #expect(pieces.map(\.3) == [nil])
    #expect(pieces[0].2 == false)
  }

  @Test func marksThatOverlapAreServedAsOne() {
    let pieces = laid([span(30, 60), span(50, 80), span(200, 230)], over: [])
    #expect(pieces.map(\.0) == [30, 200])
    #expect(pieces.map(\.1) == [80, 230])
  }

  @Test func aMarkBetweenTwoRangesCutsBoth() {
    let pieces = laid([span(40, 70)], over: [(10, 50, false), (60, 100, true)])
    #expect(pieces.map(\.3) == [0, nil, 1])
    #expect(pieces.map(\.0) == [10, 40, 70])
    #expect(pieces.map(\.2) == [false, false, true])
  }

  // MARK: - What a mark teaches

  private func transcript() -> PreparedTranscript {
    // 100 words at 0.5 s: shingles through the whole of 50 s.
    Fixture.prepared(Fixture.words("w", count: 100, step: 0.5, length: 0.4))
  }

  @Test func aMarkTeachesAConfirmedLearnedCreativeFromTheShinglesInsideIt() throws {
    let teachers: Set<EpisodeKey> = [EpisodeKey("a"), EpisodeKey("a2")]
    let creative = try #require(
      ListenerMarks.creative(from: transcript(), start: 5, end: 35, teachers: teachers))
    #expect(creative.kind == .learned)
    #expect(creative.confirmed)
    #expect(creative.teachers == teachers)
    #expect((creative.start, creative.end) == (5, 35))
    let inside = Set(
      transcript().shingles.filter { 5 <= $0.start && $0.end <= 35 }.map(\.hash))
    #expect(creative.hashes == inside)
    #expect(inside.isEmpty == false)
  }

  @Test func aMarkUnderFourSecondsTeachesNothing() {
    #expect(ListenerMarks.creative(from: transcript(), start: 5, end: 8.9, teachers: []) == nil)
    #expect(ListenerMarks.creative(from: transcript(), start: 5, end: 9, teachers: []) != nil)
  }

  /// Its audio print, added by the caller, is what reaches other episodes.
  @Test func aMarkHoldingNoShingleStillTeachesAConfirmedCreative() throws {
    let creative = try #require(
      ListenerMarks.creative(from: transcript(), start: 200, end: 230, teachers: []))
    #expect(creative.hashes.isEmpty)
    #expect(creative.confirmed)
  }
}
