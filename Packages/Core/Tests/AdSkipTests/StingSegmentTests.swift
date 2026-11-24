import Testing

@testable import AdSkip

/// A sponsor phrase straight after a short recurring sting opens a segment from the sting to the
/// next kept range or sting.
@Suite struct StingSegmentTests {
  /// The Rest Is Science layout: a 6.3 s sting at 971.0 s, the phrase at 978.0 s, a
  /// one-off read, and the next kept range from 1287.1 s.
  private static let sting = TimeSpan(start: 971.0, end: 977.3)
  private static let kept = KeptRange(start: 1287.1, end: 1388.1, meanAdProbability: 0.9, endsItem: false)

  /// `text`'s words, 0.3 s apart, from `start`.
  private static func spoken(_ text: String, from start: Double) -> [TranscriptWord] {
    text.split(separator: " ").enumerated().map { i, word in
      TranscriptWord(text: String(word), start: start + Double(i) * 0.3, end: start + Double(i) * 0.3 + 0.25)
    }
  }

  /// Programme before the sting, the phrase at `at`, and ten seconds of the read after it: what the
  /// after-sting window transcribes.
  private static func transcript(
    _ phrase: String = "This segment is brought to you by Cancer Research UK.", at start: Double = 978.0
  ) -> PreparedTranscript {
    Fixture.prepared(
      Fixture.words("talk", count: 20, from: 955) + spoken("And that's that.", from: 966)
        + spoken(phrase, from: start)
        + Fixture.words("read", count: 16, from: start + 3),
      duration: 3000)
  }

  private static func segments(
    _ transcript: PreparedTranscript = transcript(), stings: [TimeSpan] = [sting],
    kept: [KeptRange] = [kept], showTitle: String? = nil,
    isTombstoned: (UInt64) -> Bool = { _ in false }
  ) -> [StingSegment.Segment] {
    StingSegment.segments(
      stings: stings, kept: kept, in: transcript, showTitle: showTitle, isTombstoned: isTombstoned)
  }

  @Test func aPhraseAfterAStingRunsFromTheStingToTheNextKeptRange() {
    #expect(Self.segments() == [.init(start: 971.0, end: 1287.1, keptIndex: 0)])
  }

  @Test(arguments: [976.3, 977.3, 979.3])
  func thePhraseMayStartUpToTwoSecondsEitherSideOfTheStingsEnd(at start: Double) {
    #expect(Self.segments(Self.transcript(at: start)).count == 1)
  }

  @Test(arguments: [975.2, 979.4])
  func aPhraseFurtherFromTheStingsEndDoesNotAnchor(at start: Double) {
    #expect(Self.segments(Self.transcript(at: start)).isEmpty)
  }

  @Test func theNextStingEndsTheSegmentWhenItComesFirst() {
    let next = TimeSpan(start: 1100.0, end: 1106.0)
    #expect(
      Self.segments(stings: [Self.sting, next]) == [.init(start: 971.0, end: 1100.0, keptIndex: nil)])
  }

  @Test func noEndWithinTheCapGivesNoSegment() {
    // The kept range starts 360 s after the phrase: a phrase gives a start but no end.
    let late = KeptRange(start: 978.0 + 360, end: 1400, meanAdProbability: 0.9, endsItem: false)
    #expect(Self.segments(kept: [late]).isEmpty)
    #expect(Self.segments(kept: []).isEmpty)
  }

  @Test func aPhraseInsideAKeptRangeIsTheRangesBusiness() {
    let covering = KeptRange(start: 960, end: 1000, meanAdProbability: 0.9, endsItem: false)
    #expect(Self.segments(kept: [covering, Self.kept]).isEmpty)
  }

  @Test func aStingWithNoPhraseOpensNothing() {
    #expect(Self.segments(Self.transcript("And the next question is about owls.")).isEmpty)
  }

  @Test func aMidSentencePhraseDoesNotAnchor() {
    // Strict mode, as `SponsorPhraseStart`: a host's segue is not an opener.
    #expect(Self.segments(Self.transcript("and it's brought to you by our friends at Acme.")).isEmpty)
  }

  @Test func theShowsNameMayBeTheSubject() {
    let phrase = "The Rest Is Money is powered by Octopus Energy."
    #expect(Self.segments(Self.transcript(phrase)).isEmpty)
    #expect(Self.segments(Self.transcript(phrase), showTitle: "The Rest Is Money").count == 1)
  }

  @Test func aTombstonedSegmentIsNotRebuilt() {
    let transcript = Self.transcript()
    let undone = Set(transcript.shingles.filter { $0.start >= 978 }.map(\.hash))
    #expect(Self.segments(transcript, isTombstoned: { undone.contains($0) }).isEmpty)
  }

  @Test func aStingInsideAKeptRangeStartsTheSegmentWhereTheRangeEnds() {
    let earlier = KeptRange(start: 900, end: 973.0, meanAdProbability: 0.9, endsItem: false)
    #expect(
      Self.segments(kept: [earlier, Self.kept]) == [.init(start: 973.0, end: 1287.1, keptIndex: 1)])
  }

  @Test func twoPhrasesAfterOneStingMakeOneSegment() {
    let words =
      Fixture.words("talk", count: 20, from: 955) + Self.spoken("And that's that.", from: 966)
      + Self.spoken("This episode is brought to you by Acme.", from: 977.5)
      + Self.spoken("This episode is also brought to you by Beta.", from: 979.0)
      + Fixture.words("read", count: 16, from: 982)
    #expect(Self.segments(Fixture.prepared(words, duration: 3000)).count == 1)
  }

  @Test func stingsAreMergedRecurrenceShorterThanTheFloor() {
    // Audio-edge spans merge across gaps under 5 s; a merged run of 15 s or more is an ad, not a
    // sting.
    let edges = [
      TimeSpan(start: 100, end: 103), TimeSpan(start: 102, end: 106),
      TimeSpan(start: 200, end: 208), TimeSpan(start: 211, end: 220),
      TimeSpan(start: 400, end: 405.9),
    ]
    #expect(
      StingSegment.stings(audioEdges: edges)
        == [TimeSpan(start: 100, end: 106), TimeSpan(start: 400, end: 405.9)])
  }

  @Test func aKeptRangeStartingInsideThePhraseIsTheRangesBusiness() {
    // The matched sponsor's shingles can begin partway through its own opener.
    let sponsor = KeptRange(start: 979.5, end: 1010, meanAdProbability: 0.9, endsItem: false)
    #expect(Self.segments(kept: [sponsor, Self.kept]).isEmpty)
  }

  @Test func aKeptRangeAndAStingStartingTogetherEndItAtTheRange() {
    let next = TimeSpan(start: 1287.1, end: 1293.0)
    #expect(
      Self.segments(stings: [Self.sting, next]) == [.init(start: 971.0, end: 1287.1, keptIndex: 0)])
  }
}
