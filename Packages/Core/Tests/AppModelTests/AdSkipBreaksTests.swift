import AdSkip
import Foundation
import Persistence
import Testing

@testable import AppModel

/// What the player will skip from a set of served rows, and how much time that takes off the
/// remainder after a given playhead.
@Suite struct AdSkipBreaksTests {
  private func row(
    _ start: Double, _ end: Double, endsItem: Bool = false, revision: Int = AdSkipRules.revision
  ) -> AdSkipRange {
    AdSkipRange(
      startTime: start, endTime: end, meanAdProbability: 0.9, rulesRevision: revision,
      fromStore: true, endsItem: endsItem)
  }

  @Test func rangesWithinThePlayersJoinAreOneBreakIncludingTheGap() {
    #expect(AdSkipBreaks(servedRows: []).count == 0)
    #expect(AdSkipBreaks(servedRows: [row(30, 50)]).count == 1)

    let joined = AdSkipBreaks(servedRows: [row(30, 50), row(59, 80)])
    #expect(joined.count == 1)
    #expect(joined.breaks == [.init(start: 30, end: 80, endsItem: false)])

    #expect(AdSkipBreaks(servedRows: [row(30, 50), row(59.5, 80)]).count == 2)
  }

  @Test func aRangeInsideTheEnvelopeAndTheNextJoinedRangeStillMakeOneBreak() {
    let breaks = AdSkipBreaks(
      servedRows: [row(0, 100), row(10, 20), row(105, 130)])
    #expect(breaks.breaks == [.init(start: 0, end: 130, endsItem: false)])
  }

  @Test func aRangeNearTheItemStartIsSnappedToZero() {
    let breaks = AdSkipBreaks(servedRows: [row(3, 20)])
    #expect(breaks.breaks == [.init(start: 0, end: 20, endsItem: false)])
  }

  @Test func twoRangesSnappedToZeroTakeTheShorterEnd() {
    // The player's sort is not stable and does not join two equal starts, so the card must never
    // promise the longer one.
    let breaks = AdSkipBreaks(servedRows: [row(3, 20), row(4, 40)])
    #expect(breaks.breaks == [.init(start: 0, end: 20, endsItem: false)])
  }

  @Test func endsItemComesFromTheLastJoinedRange() {
    let breaks = AdSkipBreaks(
      servedRows: [row(30, 50), row(55, 80, endsItem: true)])
    #expect(breaks.breaks == [.init(start: 30, end: 80, endsItem: true)])
  }

  @Test func aBreakCountsOnlyWhenItsStartIsAheadOfThePlayhead() {
    let breaks = AdSkipBreaks(servedRows: [row(30, 50)])

    #expect(breaks.skippedSeconds(resumingAt: 0, duration: 100) == 20)
    #expect(breaks.skippedSeconds(resumingAt: 25, duration: 100) == 20)
    // At the start a load skips it; inside it, a resume plays it.
    #expect(breaks.skippedSeconds(resumingAt: 30, duration: 100) == 20)
    #expect(breaks.skippedSeconds(resumingAt: 40, duration: 100) == 0)
    #expect(breaks.skippedSeconds(resumingAt: 60, duration: 100) == 0)
  }

  @Test func aBreakThatEndsTheItemRunsToTheItemEnd() {
    let breaks = AdSkipBreaks(servedRows: [row(30, 50, endsItem: true)])
    #expect(breaks.skippedSeconds(resumingAt: 0, duration: 60) == 30)
  }

  @Test func theTotalNeverExceedsTheMediaLeft() {
    let breaks = AdSkipBreaks(servedRows: [row(30, 80)])
    // The break's own length is 50, but only 60 s of media follow the playhead.
    #expect(breaks.skippedSeconds(resumingAt: 0, duration: 60) == 30)
    // Two breaks are summed.
    let two = AdSkipBreaks(servedRows: [row(10, 20), row(30, 40)])
    #expect(two.skippedSeconds(resumingAt: 0, duration: 100) == 20)
  }

  @Test func severalBreaksAreSummedAndAllBehindThePlayheadAreIgnored() {
    let breaks = AdSkipBreaks(servedRows: [row(10, 20), row(30, 40), row(60, 70)])
    #expect(breaks.skippedSeconds(resumingAt: 0, duration: 100) == 30)
    #expect(breaks.skippedSeconds(resumingAt: 25, duration: 100) == 20)
    #expect(breaks.skippedSeconds(resumingAt: 65, duration: 100) == 0)
  }

  @Test func unknownZeroOrInvalidDurationsSkipNothing() {
    let breaks = AdSkipBreaks(servedRows: [row(30, 50)])
    for duration in [0, -1, Double.nan, .infinity, -.infinity] {
      #expect(breaks.skippedSeconds(resumingAt: 0, duration: duration) == 0)
    }
    #expect(breaks.skippedSeconds(resumingAt: .nan, duration: 100) == 0)
  }
}
