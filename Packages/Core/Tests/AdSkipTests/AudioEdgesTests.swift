import Testing

@testable import AdSkip

/// Kept-range edges moved onto where another episode's audio starts and stops lining up.
@Suite struct AudioEdgesTests {
  private static func kept(_ start: Double, _ end: Double) -> KeptRange {
    KeptRange(start: start, end: end, meanAdProbability: 0.5, endsItem: false)
  }

  private static func spans(_ pairs: [(Double, Double)]) -> [TimeSpan] {
    pairs.map { TimeSpan(start: $0.0, end: $0.1) }
  }

  private static func edges(
    _ kept: [(Double, Double)], _ evidence: [(Double, Double)]
  ) -> [AudioEdges.Edges] {
    AudioEdges.edges(for: kept.map { Self.kept($0.0, $0.1) }, evidence: spans(evidence))
  }

  @Test func theStartMovesToTheLatestAlignmentReachingIntoTheRange() {
    // Both start before the range and reach 2 s into it; the later, tighter one wins.
    let edges = Self.edges([(100, 140)], [(92, 120), (96, 103), (80, 99)])
    #expect(edges == [AudioEdges.Edges(start: 96, end: nil)])
  }

  @Test func theEndMovesToTheEarliestAlignmentEndingPastTheRange() {
    let edges = Self.edges([(100, 140)], [(120, 150), (137, 146), (141, 160)])
    #expect(edges == [AudioEdges.Edges(start: nil, end: 146)])
  }

  @Test func anAlignmentMustReachTwoSecondsIntoTheRange() {
    #expect(Self.edges([(100, 140)], [(90, 101.9)]) == [AudioEdges.Edges(start: nil, end: nil)])
    #expect(Self.edges([(100, 140)], [(138.1, 150)]) == [AudioEdges.Edges(start: nil, end: nil)])
    // A range shorter than 2 s needs the alignment to span it.
    #expect(Self.edges([(100, 101)], [(95, 101)]) == [AudioEdges.Edges(start: 95, end: nil)])
  }

  @Test func aMoveUnderHalfASecondIsNoMove() {
    #expect(Self.edges([(100, 140)], [(99.6, 120), (130, 140.4)]) == [AudioEdges.Edges(start: nil, end: nil)])
  }

  @Test func aMoveIsCappedAtFifteenSeconds() {
    #expect(Self.edges([(100, 140)], [(60, 160)]) == [AudioEdges.Edges(start: 85, end: 155)])
  }

  @Test func aMoveStopsAtTheNeighbouringRanges() {
    // The first range's end stops at the second's start; the second's start stops at the first
    // range's moved end.
    let edges = Self.edges([(100, 130), (136, 160)], [(110, 150)])
    #expect(edges == [AudioEdges.Edges(start: nil, end: 136), AudioEdges.Edges(start: nil, end: nil)])
    let starts = Self.edges([(100, 130), (136, 160)], [(125, 150)])
    #expect(starts == [AudioEdges.Edges(start: nil, end: 136), AudioEdges.Edges(start: nil, end: nil)])
    let gap = Self.edges([(100, 130), (140, 160)], [(133, 150)])
    #expect(gap == [AudioEdges.Edges(start: nil, end: nil), AudioEdges.Edges(start: 133, end: nil)])
  }

  @Test func noEvidenceMovesNothing() {
    let none = AudioEdges.Edges(start: nil, end: nil)
    #expect(Self.edges([(100, 140), (200, 210)], []) == [none, none])
    #expect(Self.edges([], [(1, 2)]).isEmpty)
  }

  private struct Case {
    let kept: [(Double, Double)]
    let evidence: [(Double, Double)]
    let expected: [(Double, Double)]
  }

  /// Hold-out 4's shipped ranges and cross-show alignments, times only, with the ranges the
  /// research harness (`Scripts/research/audioedge/edges.py`, variant `l-c15-e-x`) gave: every
  /// copy it changed and one it left alone.
  private static let harnessCases: [Case] = [
    Case(
      kept: [(0.6106, 72.5706), (1204.9247, 1244.4047)],
      evidence: [(31.4194, 32.3599), (1200.6038, 1231.1524), (1200.6038, 1231.1872)],
      expected: [(0.6106, 72.5706), (1200.6038, 1244.4047)]),
    Case(
      kept: [
        (0.6106, 19.4693),
        (2241.7839, 2259.1152),
        (3196.8176, 3211.9386),
        (3232.0003, 3257.3803),
        (3269.6803, 3297.4003),
      ],
      evidence: [(2241.3004, 2272.1974), (2241.3701, 2271.9071)],
      expected: [
        (0.6106, 19.4693),
        (2241.7839, 2271.9071),
        (3196.8176, 3211.9386),
        (3232.0003, 3257.3803),
        (3269.6803, 3297.4003),
      ]),
    Case(
      kept: [
        (0, 71.52),
        (71.76, 122.94),
        (1487.5367, 1659.5567),
        (2343.2405, 2372.9436),
        (2816.9574, 2894.0664),
      ],
      evidence: [(2342.8041, 2373.6778), (2342.8157, 2373.2366)],
      expected: [
        (0, 71.52),
        (71.76, 122.94),
        (1487.5367, 1659.5567),
        (2343.2405, 2373.6778),
        (2816.9574, 2894.0664),
      ]),
    Case(
      kept: [(295.3272, 376.6873), (1681.4744, 1733.2544), (3659.9021, 3708.0821)],
      evidence: [(347.7504, 378.2293), (3482.2293, 3483.0653)],
      expected: [(295.3272, 378.2293), (1681.4744, 1733.2544), (3659.9021, 3708.0821)]),
    Case(
      kept: [
        (139.1337, 195.5937),
        (206.7537, 222.1137),
        (1303.3543, 1355.1319),
        (2722.3811, 2770.468),
      ],
      evidence: [(191.8723, 222.479)],
      expected: [
        (139.1337, 206.7537),
        (206.7537, 222.1137),
        (1303.3543, 1355.1319),
        (2722.3811, 2770.468),
      ]),
    Case(
      kept: [(0.06, 51.96), (2940.6165, 2968.9404)],
      evidence: [(2893.2366, 2893.9797)],
      expected: [(0.06, 51.96), (2940.6165, 2968.9404)]),
  ]

  @Test func reproducesTheHarness() {
    for (index, test) in Self.harnessCases.enumerated() {
      let edges = Self.edges(test.kept, test.evidence)
      let moved = zip(test.kept, edges).map { kept, edge in
        (edge.start ?? kept.0, edge.end ?? kept.1)
      }
      #expect(moved.count == test.expected.count, "case \(index)")
      for (got, want) in zip(moved, test.expected) {
        #expect(abs(got.0 - want.0) < 1e-9 && abs(got.1 - want.1) < 1e-9, "case \(index)")
      }
    }
  }
}
