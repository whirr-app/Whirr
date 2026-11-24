import AdSkip
import Foundation
import PlayerCore
import Testing

@testable import AppModel

@Suite struct PauseTrimPlannerTests {
  private func runs(
    below40: [(Double, Double)] = [], below46: [(Double, Double)] = [], duration: Double = 100
  ) -> PauseRuns {
    PauseRuns(
      revision: PauseDetector.revision, duration: duration,
      runsBelow40: below40.map { PauseRun(start: $0.0, end: $0.1) },
      runsBelow46: below46.map { PauseRun(start: $0.0, end: $0.1) })
  }

  private func cuts(_ map: PlayerTrimMap) -> [(Double, Double)] {
    map.cuts.map { ($0.start, $0.end) }
  }

  private func expectCuts(
    _ map: PlayerTrimMap, _ expected: [(Double, Double)],
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(map.cuts.count == expected.count, sourceLocation: sourceLocation)
    for (cut, want) in zip(map.cuts, expected) {
      #expect(abs(cut.start - want.0) < 1e-4, sourceLocation: sourceLocation)
      #expect(abs(cut.end - want.1) < 1e-4, sourceLocation: sourceLocation)
    }
  }

  @Test func strengthCases() {
    #expect(TrimStrength.allCases == [.moderate, .maximum])
    #expect(TrimStrength.moderate.rawValue == "moderate")
    #expect(TrimStrength.maximum.rawValue == "maximum")
  }

  @Test func moderateKeepsHalfASecondTenthOfEachPause() {
    // Pause 10.0-11.0 (1 s): cut 10.075-10.925, leaving 0.15 s of pause.
    let map = PauseTrimPlanner.map(
      for: runs(below40: [(10, 11)], below46: [(10, 11), (20, 20.2)]), strength: .moderate)
    expectCuts(map, [(10.075, 10.925)])
  }

  @Test func moderateIgnoresTheMinusFortySixRuns() {
    let map = PauseTrimPlanner.map(for: runs(below46: [(10, 11)]), strength: .moderate)
    #expect(map.isEmpty)
  }

  @Test func maximumCutsRunsAtMinusFortySixUpToTheLeadIn() {
    // Each cut stops 60 ms short of the speech after it; the pause before it goes whole.
    let map = PauseTrimPlanner.map(
      for: runs(below40: [(5, 6)], below46: [(10, 11), (20, 20.2)]), strength: .maximum)
    expectCuts(map, [(10, 10.94), (20, 20.14)])
  }

  @Test func moderateKeepAlreadyCoversTheLeadIn() {
    #expect(TrimStrength.moderate.keep / 2 >= PauseTrimPlanner.leadIn)
    #expect(PauseTrimPlanner.leadIn >= 2 * 1_152 / 44_100.0)
  }

  @Test func moderateMinimumBoundary() {
    // 30 frames of 10 ms accumulate to slightly off 0.30 in floating point; it still qualifies.
    let thirtyFrames = 30 * 441.0 / 44_100
    let map = PauseTrimPlanner.map(
      for: runs(below40: [(1, 1 + thirtyFrames), (5, 5.29)]), strength: .moderate)
    expectCuts(map, [(1.075, 1.075 + 0.15)])
  }

  @Test func maximumMinimumBoundary() {
    let map = PauseTrimPlanner.map(
      for: runs(below46: [(1, 1.105), (5, 5.1)]), strength: .maximum)
    expectCuts(map, [(1, 1.045)])
  }

  @Test func moderateCutAtTheMinimumIsHalfTheKeepShorter() {
    let map = PauseTrimPlanner.map(for: runs(below40: [(2, 2.3)]), strength: .moderate)
    expectCuts(map, [(2.075, 2.225)])
    #expect(abs(map.totalTrimmed - 0.15) < 1e-4)
  }

  @Test func cutsShorterThanTwentyMillisecondsAreDropped() {
    // Reachable only when keep eats most of a qualifying run, so exercise the rule directly,
    // without the lead-in.
    let kept = PauseTrimPlanner.cuts(
      from: [PauseRun(start: 1, end: 1.1), PauseRun(start: 3, end: 3.1)], duration: 100,
      minimum: 0.1, keep: 0.09, leadIn: 0)
    #expect(kept.isEmpty)
    let long = PauseTrimPlanner.cuts(
      from: [PauseRun(start: 1, end: 1.1)], duration: 100, minimum: 0.1, keep: 0.06, leadIn: 0)
    #expect(long.count == 1)
    // Exactly 20 ms survives.
    let edge = PauseTrimPlanner.cuts(
      from: [PauseRun(start: 1, end: 1.1)], duration: 100, minimum: 0.1, keep: 0.08, leadIn: 0)
    #expect(edge.count == 1)
  }

  @Test func trailingRunIsNotCut() {
    let atEnd = runs(below40: [(10, 11), (95, 100)], below46: [(10, 11), (95, 100)], duration: 100)
    expectCuts(PauseTrimPlanner.map(for: atEnd, strength: .moderate), [(10.075, 10.925)])
    expectCuts(PauseTrimPlanner.map(for: atEnd, strength: .maximum), [(10, 10.94)])
    // Within half a frame of the end still counts as reaching it.
    let nearEnd = runs(below46: [(95, 99.996)], duration: 100)
    #expect(PauseTrimPlanner.map(for: nearEnd, strength: .maximum).isEmpty)
    // A run that ends clearly before the end is cut.
    let before = runs(below46: [(95, 99.9)], duration: 100)
    #expect(PauseTrimPlanner.map(for: before, strength: .maximum).cuts.count == 1)
  }

  @Test func cutEdgesAreMultiplesOfTheTimescale() {
    let scale = Double(PlayerTrimMap.timescale)
    let map = PauseTrimPlanner.map(
      for: runs(below40: [(1.23456789, 2.34567891), (7.7777777, 8.8888888)]), strength: .moderate)
    #expect(map.cuts.count == 2)
    for cut in map.cuts {
      #expect(abs(cut.start * scale - (cut.start * scale).rounded()) < 1e-6)
      #expect(abs(cut.end * scale - (cut.end * scale).rounded()) < 1e-6)
    }
  }

  @Test func quantisationAndTheTwentyMillisecondRuleAgree() {
    // The cut is measured after quantisation, so what the planner keeps is what the map holds.
    let planned = PauseTrimPlanner.cuts(
      from: [PauseRun(start: 1.0000001, end: 1.1200004)], duration: 100, minimum: 0.1, keep: 0.1, leadIn: 0)
    let map = PlayerTrimMap(cuts: planned)
    #expect(map.cuts.count == planned.count)
    for cut in map.cuts { #expect(cut.end - cut.start >= 0.02 - 1e-9) }
  }

  @Test func emptyInputGivesAnEmptyMap() {
    #expect(PauseTrimPlanner.map(for: runs(), strength: .moderate).isEmpty)
    #expect(PauseTrimPlanner.map(for: runs(), strength: .maximum).isEmpty)
  }

  @Test func detectorOutputFeedsThePlannerAndSurvivesStorage() throws {
    var detector = PauseDetector(sampleRate: 44_100)
    var samples: [Float] = []
    for (seconds, on) in [(1.0, true), (0.6, false), (1.0, true), (0.5, false)] {
      samples += (0..<Int(seconds * 44_100)).map {
        on ? Float(0.1 * sin(2 * Double.pi * 1_000 * Double($0) / 44_100)) : 0
      }
    }
    samples.withUnsafeBufferPointer { detector.consume([$0]) }
    let found = detector.finish()
    let stored = try #require(PauseRuns(encoded: found.encoded()))
    // The 0.6 s pause is cut; the trailing 0.5 s pause reaches the end of the file and is not.
    let map = PauseTrimPlanner.map(for: stored, strength: .moderate)
    expectCuts(map, [(1.075, 1.525)])
  }
}
