import Testing

@testable import AppModel

/// `TranscriptAdBreaks`: ad ranges grouped into the breaks the transcript steps between.
@Suite struct TranscriptAdBreaksTests {
  private func ad(_ start: Double, _ end: Double, _ origin: TranscriptAdRange.Origin = .detected)
    -> TranscriptAdRange
  {
    TranscriptAdRange(start: start, end: end, origin: origin)
  }

  @Test func rangesWithinTheGapAreOneBreakWhateverTheirOrigin() {
    let breaks = TranscriptAdBreaks.breaks([
      ad(600, 630), ad(100, 130), ad(140, 170, .listener), ad(230, 250, .hostRead),
    ])
    #expect(breaks == [TranscriptAdBreak(start: 100, end: 250), TranscriptAdBreak(start: 600, end: 630)])
  }

  @Test func theGapIsMeasuredFromTheBreakSoFarNotTheLastRange() {
    // The long ad's end, not the short one inside it, is where the break reaches.
    let breaks = TranscriptAdBreaks.breaks([ad(0, 200), ad(10, 20), ad(250, 260)])
    #expect(breaks == [TranscriptAdBreak(start: 0, end: 260)])
  }

  @Test func exactlyTheGapApartJoinsAndFurtherDoesNot() {
    let gap = TranscriptAdBreaks.joinGap
    #expect(TranscriptAdBreaks.breaks([ad(0, 10), ad(10 + gap, 80)]).count == 1)
    #expect(TranscriptAdBreaks.breaks([ad(0, 10), ad(10 + gap + 1, 80)]).count == 2)
  }

  @Test func breaksBeyondTheTextAreNotCounted() {
    let breaks = TranscriptAdBreaks.breaks([ad(100, 130), ad(900, 930)], before: 500)
    #expect(breaks == [TranscriptAdBreak(start: 100, end: 130)])
    #expect(TranscriptAdBreaks.breaks([]).isEmpty)
  }
}
