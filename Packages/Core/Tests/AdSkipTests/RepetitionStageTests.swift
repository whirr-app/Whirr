import Testing

@testable import AdSkip

@Suite struct RepetitionStageTests {
  /// Hits every shingle whose first word lies in `indices` (by word index).
  private func candidates(
    _ prepared: PreparedTranscript, hitFirstWords: Set<Int>
  ) -> [CandidateRange] {
    let hits = Set(prepared.shingles.filter { hitFirstWords.contains($0.firstWord) }.map(\.hash))
    return RepetitionStage.candidates(in: prepared) { hits.contains($0) }
  }

  // 0.5 s cadence, 0.4 s words: shingle i spans [0.5 i, 0.5 i + 3.9].
  @Test func consecutiveHitsFormOneRunAndShortRunsAreDropped() {
    let prepared = Fixture.prepared(Fixture.words("w", count: 60))
    // Shingles 0...22 end at 14.9: below 15 s.
    #expect(candidates(prepared, hitFirstWords: Set(0...22)).isEmpty)
    // Shingles 0...23 end at the 31st word's end, 15.4.
    let kept = candidates(prepared, hitFirstWords: Set(0...23))
    #expect(kept == [CandidateRange(start: 0, end: prepared.shingles[23].end)])
    #expect(prepared.shingles[23].end > 15)
  }

  @Test func exactlyFifteenSecondsIsKept() {
    // One shingle spanning exactly [0, 15].
    let exact = (0..<8).map {
      TranscriptWord(
        text: "w\($0)", start: Double($0) * 1.9, end: $0 == 7 ? 15 : Double($0) * 1.9 + 1.0)
    }
    let kept = RepetitionStage.candidates(in: Fixture.prepared(exact)) { _ in true }
    #expect(kept == [CandidateRange(start: 0, end: 15)])
    let short = exact.dropLast() + [TranscriptWord(text: "w7", start: 13.3, end: 14.99)]
    #expect(RepetitionStage.candidates(in: Fixture.prepared(Array(short))) { _ in true }.isEmpty)
  }

  /// Two disjoint hit shingles, [0, 15] and [15 + gap, 30 + gap]. No word starts inside the gap, so
  /// the result is one range whether run formation (0.05 s tolerance) or the merge stage fuses them.
  @Test(arguments: [0.05, 0.06])
  func adjacentShinglesEndAsOneRange(gap: Double) {
    var words: [TranscriptWord] = []
    for i in 0..<7 { words.append(.init(text: "p\(i)", start: Double(i) * 2, end: Double(i) * 2 + 1)) }
    words.append(.init(text: "p7", start: 14, end: 15))
    for i in 0..<8 {
      let s = 15 + gap + Double(i) * 2
      words.append(.init(text: "q\(i)", start: s, end: s + 1))
    }
    let prepared = Fixture.prepared(words)
    let hits = Set([prepared.shingles[0].hash, prepared.shingles[8].hash])
    let ranges = RepetitionStage.candidates(in: prepared) { hits.contains($0) }
    #expect(ranges == [CandidateRange(start: 0, end: prepared.shingles[8].end)])
  }

  @Test func mergesAcrossLessThanFiveSecondsUnlessAWordIntervenes() {
    // Run A: words 0-7 (shingle [0, 15]); a lone non-hit word group in between; run B later.
    func build(withGapWord: Bool) -> [CandidateRange] {
      var words: [TranscriptWord] = []
      for i in 0..<8 { words.append(.init(text: "a\(i)", start: Double(i) * 2, end: Double(i) * 2 + 1)) }
      if withGapWord { words.append(.init(text: "gap", start: 16, end: 16.5)) }
      let startB = 19.0
      for i in 0..<8 {
        let s = startB + Double(i) * 2
        words.append(.init(text: "b\(i)", start: s, end: s + 1))
      }
      let prepared = Fixture.prepared(words)
      let hits = Set(
        prepared.shingles.filter { $0.firstWord == 0 || $0.firstWord == (withGapWord ? 9 : 8) }
          .map(\.hash))
      return RepetitionStage.candidates(in: prepared) { hits.contains($0) }
    }
    // Gap 15 -> 19 = 4 s < 5.
    #expect(build(withGapWord: false) == [CandidateRange(start: 0, end: 34)])
    #expect(
      build(withGapWord: true) == [
        CandidateRange(start: 0, end: 15), CandidateRange(start: 19, end: 34),
      ])
  }

  @Test func fiveSecondGapDoesNotMerge() {
    var words: [TranscriptWord] = []
    for i in 0..<8 { words.append(.init(text: "a\(i)", start: Double(i) * 2, end: Double(i) * 2 + 1)) }
    // Gap of exactly 5 s between 15 and 20 (segment seam is >= 2 s, so these are two segments).
    for i in 0..<8 {
      let s = 20 + Double(i) * 2
      words.append(.init(text: "b\(i)", start: s, end: s + 1))
    }
    let prepared = Fixture.prepared(words)
    #expect(prepared.segments.count == 2)
    let ranges = RepetitionStage.candidates(in: prepared) { _ in true }
    #expect(ranges == [CandidateRange(start: 0, end: 15), CandidateRange(start: 20, end: 35)])
  }

  @Test func mergeJoinsRunsAcrossASegmentSeam() {
    // Shingles never cross a seam, but the merge stage may: a wordless gap of 2-5 s between runs
    // in different segments still merges them, as `repeatall.py` does.
    var words: [TranscriptWord] = []
    for i in 0..<8 { words.append(.init(text: "a\(i)", start: Double(i) * 2, end: Double(i) * 2 + 0.9)) }
    for i in 0..<8 {
      let s = 16.9 + 2 + Double(i) * 2
      words.append(.init(text: "b\(i)", start: s, end: s + 0.9))
    }
    let prepared = Fixture.prepared(words)
    #expect(prepared.segments.count == 2)
    let ranges = RepetitionStage.candidates(in: prepared) { _ in true }
    #expect(ranges.count == 1)
  }

  // MARK: edge extension

  /// 8 words spanning [10, 26], single shingle hit.
  private func edgeFixture(
    silences: [Silence], extraWords: [TranscriptWord] = []
  ) -> [CandidateRange] {
    var words = (0..<8).map {
      TranscriptWord(text: "w\($0)", start: 10 + Double($0) * 2, end: 10 + Double($0) * 2 + 1.0)
    }
    words[7] = TranscriptWord(text: "w7", start: 24, end: 26)
    words += extraWords
    words.sort { $0.start < $1.start }
    let prepared = Fixture.prepared(words, silences: silences, duration: 100)
    let ownHashes = ShingleHash.hash((0..<8).map { "w\($0)" })
    return RepetitionStage.candidates(in: prepared) { $0 == ownHashes }
  }

  @Test func extendsToSilenceBeforeAndAfter() {
    let result = edgeFixture(silences: [Silence(start: 5, end: 8), Silence(start: 27, end: 28)])
    // before: s.end <= 10.5 and 10 - s.end <= 15 -> end 8; after: s.start >= 25.5 -> start 27.
    #expect(result == [CandidateRange(start: 8, end: 27)])
  }

  @Test func silenceOverlappingTheStartWithinHalfASecondCounts() {
    let result = edgeFixture(silences: [Silence(start: 9, end: 10.5)])
    #expect(result == [CandidateRange(start: 10.5, end: 26)])
  }

  @Test func silenceTooFarOrOnTheWrongSideDoesNotExtend() {
    let result = edgeFixture(silences: [
      Silence(start: 43, end: 44),  // starts 17 s after the end
      Silence(start: -10, end: -6),  // ends 16 s before the start
      Silence(start: 15, end: 16),  // inside the run
    ])
    #expect(result == [CandidateRange(start: 10, end: 26)])
  }

  @Test func fifteenSecondLimitIsInclusive() {
    #expect(
      edgeFixture(silences: [Silence(start: 41, end: 42)]) == [CandidateRange(start: 10, end: 41)])
    #expect(
      edgeFixture(silences: [Silence(start: 41.5, end: 42)]) == [CandidateRange(start: 10, end: 26)])
    #expect(
      edgeFixture(silences: [Silence(start: -6, end: -5)]) == [CandidateRange(start: -5, end: 26)])
    #expect(
      edgeFixture(silences: [Silence(start: -6, end: -5.5)]) == [CandidateRange(start: 10, end: 26)])
  }

  @Test func extensionBlockedByAWordInBetween() {
    let before = TranscriptWord(text: "pre", start: 8.5, end: 9)
    let result = edgeFixture(
      silences: [Silence(start: 5, end: 8)], extraWords: [before])
    #expect(result == [CandidateRange(start: 10, end: 26)])
    let after = TranscriptWord(text: "post", start: 26.5, end: 26.9)
    let r2 = edgeFixture(silences: [Silence(start: 28, end: 29)], extraWords: [after])
    #expect(r2 == [CandidateRange(start: 10, end: 26)])
  }

  @Test func usesTheLastSilenceBeforeAndTheFirstAfterInListOrder() {
    let result = edgeFixture(silences: [
      Silence(start: 1, end: 3), Silence(start: 6, end: 7),  // before: last in list is end 7
      Silence(start: 27, end: 27.5), Silence(start: 30, end: 31),  // after: first is start 27
    ])
    #expect(result == [CandidateRange(start: 7, end: 27)])
    let reversed = edgeFixture(silences: [
      Silence(start: 6, end: 7), Silence(start: 1, end: 3),
      Silence(start: 30, end: 31), Silence(start: 27, end: 27.5),
    ])
    #expect(reversed == [CandidateRange(start: 3, end: 30)])
  }

  @Test func noRunsMeansNoCandidates() {
    let prepared = Fixture.prepared(Fixture.words("w", count: 30))
    #expect(RepetitionStage.candidates(in: prepared) { _ in false }.isEmpty)
  }
}
