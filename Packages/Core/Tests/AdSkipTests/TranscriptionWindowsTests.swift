import Foundation
import Testing

@testable import AdSkip

@Suite struct TranscriptionWindowsTests {
  private func span(_ start: Double, _ end: Double) -> TimeSpan { TimeSpan(start: start, end: end) }

  @Test func stageOneMergesOptimisticallyThenAppliesTheFloorAndMargin() {
    // 10-20 and 24-30 merge (gap 4 < 5) into 10-30; 40-50 alone is under 15 s; 100-120 survives.
    let windows = TranscriptionWindows.stageOne(runs: [span(10, 20), span(24, 30), span(40, 50), span(100, 120)])
    #expect(windows == [span(-17.5, 57.5), span(72.5, 147.5)])
    // A gap of exactly 5 s does not merge.
    #expect(TranscriptionWindows.stageOne(runs: [span(0, 10), span(15, 20)]).isEmpty)
    // Windows that touch after the margin join.
    #expect(TranscriptionWindows.stageOne(runs: [span(0, 15), span(70, 85)]) == [span(-27.5, 112.5)])
  }

  @Test func stageTwoLooksBackFromKeptStartsAndAnchors() {
    #expect(
      TranscriptionWindows.stageTwo(keptStarts: [200], anchors: [150])
        == [span(108, 200), span(122.5, 150)])
  }

  @Test func stageTwoListensJustAfterEachSting() {
    // From 1 s before the sting's end, where an opener's head can start, to 10 s after it.
    #expect(
      TranscriptionWindows.stageTwo(keptStarts: [], anchors: [], stingEnds: [300])
        == [span(299, 310)])
  }

  @Test func missingLeavesOutCoverageAndSlivers() {
    let missing = TranscriptionWindows.missing(
      [span(0, 100), span(200, 210)], covered: [span(10, 20), span(50, 99.8), span(195, 205)])
    #expect(missing == [span(0, 10), span(20, 50), span(205, 210)])
    #expect(TranscriptionWindows.missing([span(0, 10)], covered: [span(-5, 20)]).isEmpty)
  }

  @Test func slicesArePaddedAndClamped() {
    #expect(TranscriptionWindows.slice(for: span(2, 30), duration: 32) == span(0, 32))
    #expect(TranscriptionWindows.slice(for: span(50, 60), duration: 100) == span(45, 65))
    #expect(TranscriptionWindows.seconds([span(-10, 10), span(5, 20), span(95, 120)], duration: 100) == 25)
  }

  @Test func theSliceRuleKeepsWordsByMidpoint() {
    let words = [
      TranscriptWord(text: "a", start: 9.5, end: 10.3),  // midpoint 9.9: out
      TranscriptWord(text: "b", start: 9.8, end: 10.4),  // 10.1: in
      TranscriptWord(text: "c", start: 19.8, end: 20.0),  // 19.9: in
      TranscriptWord(text: "d", start: 19.9, end: 20.1),  // 20.0: out, the end is open
    ]
    #expect(TranscriptionWindows.words(words, keptBy: span(10, 20)).map(\.text) == ["b", "c"])
  }

  @Test func theIndexRuleKeepsWordsWhollyInside() {
    let words = [
      TranscriptWord(text: "a", start: 9.9, end: 10.2),
      TranscriptWord(text: "b", start: 10, end: 10.2),
      TranscriptWord(text: "c", start: 19.8, end: 20),
      TranscriptWord(text: "d", start: 19.9, end: 20.1),
    ]
    #expect(TranscriptionWindows.indexWords(words, stageOne: [span(10, 20)]).map(\.text) == ["b", "c"])
  }

  @Test func coverageReachesTheEndOnlyWithoutAGap() {
    #expect(TranscriptionWindows.covers([span(50, 99.8)], from: 60, toEndOf: 100))
    #expect(TranscriptionWindows.covers([span(50, 80)], from: 60, toEndOf: 100) == false)
    #expect(TranscriptionWindows.covers([span(50, 70), span(75, 100)], from: 60, toEndOf: 100) == false)
  }

  // MARK: - Post-roll tail trigger

  private func silence(_ start: Double, _ end: Double) -> Silence { Silence(start: start, end: end) }

  @Test func theTailTriggerFiresOnAnEpisodeShapedLikeEmpire122() {
    // The outro sting's same-show alignments end inside the stitch silence, before the stretch.
    let found = TranscriptionWindows.tailSilence(
      silences: [silence(2_400, 2_401), silence(3_067.36, 3_069.08)], duration: 3_099.14,
      sameShow: [span(3_062.5, 3_068.4)])
    #expect(found == silence(3_067.36, 3_069.08))
    let window = TranscriptionWindows.tailWindow(after: silence(3_067.36, 3_069.08), duration: 3_099.14)
    #expect(abs(window.start - 3_054.86) < 1e-9)
    #expect(window.end == 3_099.14)
  }

  @Test func theTailTriggerNeedsAStitchLongSilenceInTheSearch() {
    let duration = 1_000.0
    // 0.49 s is short of the stitch; 0.5 s is enough.
    #expect(TranscriptionWindows.tailSilence(silences: [silence(950, 950.49)], duration: duration, sameShow: []) == nil)
    #expect(
      TranscriptionWindows.tailSilence(silences: [silence(950, 950.5)], duration: duration, sameShow: [])
        == silence(950, 950.5))
    // A silence that starts before the last 120 s is outside the search, whatever its length.
    #expect(TranscriptionWindows.tailSilence(silences: [silence(879.9, 911)], duration: duration, sameShow: []) == nil)
    #expect(
      TranscriptionWindows.tailSilence(silences: [silence(880, 911)], duration: duration, sameShow: [])
        == silence(880, 911))
  }

  @Test func theTailTriggerBoundsTheStretchToTheEnd() {
    let duration = 1_000.0
    // The stretch from the silence's end to the end of the file is 10-90 s, inclusive.
    #expect(TranscriptionWindows.tailSilence(silences: [silence(989, 990.01)], duration: duration, sameShow: []) == nil)
    #expect(
      TranscriptionWindows.tailSilence(silences: [silence(989, 990)], duration: duration, sameShow: [])
        == silence(989, 990))
    #expect(TranscriptionWindows.tailSilence(silences: [silence(905, 909.99)], duration: duration, sameShow: []) == nil)
    #expect(
      TranscriptionWindows.tailSilence(silences: [silence(905, 910)], duration: duration, sameShow: [])
        == silence(905, 910))
  }

  @Test func theTailTriggerTakesTheLastQualifyingSilence() {
    // 995 s leaves too short a stretch, so the last that qualifies is 960 s, not 920 s.
    let found = TranscriptionWindows.tailSilence(
      silences: [silence(920, 921), silence(960, 961), silence(995, 996)], duration: 1_000,
      sameShow: [])
    #expect(found == silence(960, 961))
  }

  @Test func theShowsOwnAudioInTheStretchSuppressesTheTrigger() {
    // Credits the show plays in another episode run past the silence: the stretch is programme.
    #expect(
      TranscriptionWindows.tailSilence(
        silences: [silence(960, 961)], duration: 1_000, sameShow: [span(955, 975)]) == nil)
    // An earlier silence does not help: its stretch holds the credits too.
    #expect(
      TranscriptionWindows.tailSilence(
        silences: [silence(930, 931), silence(960, 961)], duration: 1_000,
        sameShow: [span(955, 975)]) == nil)
    // Up to 0.5 s of overlap is the alignment's own edge.
    #expect(
      TranscriptionWindows.tailSilence(
        silences: [silence(960, 961)], duration: 1_000, sameShow: [span(950, 961.5)])
        == silence(960, 961))
    #expect(
      TranscriptionWindows.tailSilence(
        silences: [silence(960, 961)], duration: 1_000, sameShow: [span(950, 961.51)]) == nil)
  }
}
