import Foundation
import Testing

@testable import AdSkip

@Suite struct TranscriptViewsTests {
  @Test func theIndexViewHoldsStageOneWordsOnlyAndTheCoveredViewEverything() {
    let stageOne = Fixture.words("one", count: 40, from: 100)
    let stageTwo = Fixture.words("two", count: 40, from: 20)
    let words = (stageTwo + stageOne)
    let views = TranscriptViews(
      transcript: Transcript(words: words, duration: 300), silences: [],
      coverage: [TimeSpan(start: 20, end: 40), TimeSpan(start: 95, end: 125)],
      stageOne: [TimeSpan(start: 95, end: 125)])
    #expect(views.index.transcript.words == stageOne)
    #expect(views.covered.transcript.words == words)
    #expect(views.index.transcript.duration == 300)
    #expect(views.index.shingles.count == 33)
  }

  @Test func theFirstWordOfEachStretchOpensASentence() {
    // An earlier stretch cut off mid-sentence, then a phrase straight after a sting minutes later.
    func spoken(_ text: String, from start: Double) -> [TranscriptWord] {
      text.split(separator: " ").enumerated().map {
        TranscriptWord(text: String($1), start: start + Double($0) * 0.3, end: start + Double($0) * 0.3 + 0.25)
      }
    }
    let words =
      spoken("the sound of somebody who was born", from: 367)
      + spoken("This segment is brought to you by Cancer Research UK.", from: 978)
      + spoken("Research has come a long way", from: 981.5)
    let views = TranscriptViews(
      transcript: Transcript(words: words, duration: 2071), silences: [],
      coverage: [TimeSpan(start: 81.8, end: 369.5), TimeSpan(start: 976.3, end: 987.3)],
      stageOne: [TimeSpan(start: 81.8, end: 369.5)])
    let opens = views.covered.words.indices.filter { views.covered.words[$0].opensSentence }
    #expect(opens == [0, 7, 17])
    #expect(SponsorPhraseStart.anchors(in: views.covered.words, showTitle: []).map(\.start) == [978])
    // Within one stretch a pause is not a sentence break.
    let paused = TranscriptViews(
      transcript: Transcript(words: words, duration: 2071), silences: [],
      coverage: [TimeSpan(start: 81.8, end: 987.3)], stageOne: nil)
    #expect(SponsorPhraseStart.anchors(in: paused.covered.words, showTitle: []).isEmpty)
  }

  @Test func aWholeTranscriptIsBothViews() {
    let words = Fixture.words("w", count: 20)
    let views = TranscriptViews(
      transcript: Transcript(words: words, duration: 30), silences: [],
      coverage: [TimeSpan(start: 0, end: 30)], stageOne: nil)
    #expect(views.index.transcript == views.covered.transcript)
  }

  @Test func aRangeEndsTheItemOnlyWhenCoverageReachesTheEnd() {
    let range = KeptRange(start: 100, end: 130, meanAdProbability: 0.5, endsItem: true)
    let mid = TranscriptViews(
      transcript: Transcript(words: [], duration: 3600), silences: [],
      coverage: [TimeSpan(start: 70, end: 160)], stageOne: [TimeSpan(start: 70, end: 160)])
    #expect(mid.confirmingEndsItem([range]).first?.endsItem == false)
    let tail = TranscriptViews(
      transcript: Transcript(words: [], duration: 150), silences: [],
      coverage: [TimeSpan(start: 70, end: 177.5)], stageOne: [TimeSpan(start: 70, end: 177.5)])
    #expect(tail.confirmingEndsItem([range]).first?.endsItem == true)
    let notEnding = KeptRange(start: 100, end: 130, meanAdProbability: 0.5, endsItem: false)
    #expect(tail.confirmingEndsItem([notEnding]).first?.endsItem == false)
  }
}
