import Testing

@testable import AdSkip

/// A candidate the arbiter dropped is served when one alignment with another show's episode covers
/// at least 15 s of it.
@Suite struct CrossShowEvidenceTests {
  /// The Rest Is History 718's promo: the arbiter dropped 44:10.4 to 44:52.2.
  private static let promo = CandidateRange(start: 2650.4, end: 2692.2)
  private static let ad = CandidateRange(start: 100, end: 130)
  private static let keptAd = KeptRange(start: 100, end: 130, meanAdProbability: 0.9, endsItem: false)

  @Test func oneAlignmentOfFifteenSecondsReadmitsADroppedCandidate() {
    let readmitted = CrossShowEvidence.readmitted(
      [Self.ad, Self.promo], kept: [Self.keptAd],
      alignments: [TimeSpan(start: 2641.0, end: 2669.2)])
    // 18.8 s of the promo lies in the alignment.
    #expect(readmitted == [Self.promo])
  }

  @Test func exactlyFifteenSecondsIsEnoughAndJustUnderIsNot() {
    let at15 = TimeSpan(start: 2640, end: 2665.4)
    #expect(CrossShowEvidence.readmitted([Self.promo], kept: [], alignments: [at15]) == [Self.promo])
    let at14 = TimeSpan(start: 2640, end: 2664.4)
    #expect(CrossShowEvidence.readmitted([Self.promo], kept: [], alignments: [at14]).isEmpty)
  }

  @Test func shortAlignmentsAreNotAddedTogether() {
    // Three idents' worth, 30 s together, none 15 s alone.
    let alignments = [
      TimeSpan(start: 2650, end: 2660), TimeSpan(start: 2660, end: 2670), TimeSpan(start: 2670, end: 2680),
    ]
    #expect(CrossShowEvidence.readmitted([Self.promo], kept: [], alignments: alignments).isEmpty)
  }

  @Test func aKeptCandidateIsNotReadmitted() {
    let alignments = [TimeSpan(start: 90, end: 140)]
    #expect(CrossShowEvidence.readmitted([Self.ad], kept: [Self.keptAd], alignments: alignments).isEmpty)
  }

  @Test func aMoveIsCoveredOnlyWhenOneAlignmentHoldsAllOfIt() {
    let alignments = [TimeSpan(start: 2641, end: 2669.2), TimeSpan(start: 2669.2, end: 2700)]
    #expect(CrossShowEvidence.covers(TimeSpan(start: 2641, end: 2650.4), alignments: alignments))
    #expect(CrossShowEvidence.covers(TimeSpan(start: 2640, end: 2650.4), alignments: alignments) == false)
    // Two alignments that meet do not make one.
    #expect(CrossShowEvidence.covers(TimeSpan(start: 2660, end: 2680), alignments: alignments) == false)
    #expect(CrossShowEvidence.covers(TimeSpan(start: 2660, end: 2680), alignments: []) == false)
  }
}
