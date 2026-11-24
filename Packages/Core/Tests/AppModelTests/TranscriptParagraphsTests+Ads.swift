import Persistence
import Testing

@testable import AppModel

/// Paragraphs break at the edges of an ad, so an ad is whole paragraphs.
extension TranscriptParagraphsTests {

  /// Sentences of two words, one per two seconds: sentence `n` spans `2n` to `2n + 1.5`.
  private func spoken(sentences count: Int) -> [StoredTranscriptWord] {
    (0..<count).flatMap { index -> [StoredTranscriptWord] in
      let start = Double(index) * 2
      return [
        StoredTranscriptWord(text: "Word\(index)", start: start, end: start + 0.5),
        StoredTranscriptWord(text: "end\(index).", start: start + 1, end: start + 1.5),
      ]
    }
  }

  @Test func noAdsLeaveTheParagraphsAsTheyWere() {
    let words = spoken(sentences: 14)
    #expect(
      TranscriptParagraphs(words: words, adRanges: []) == TranscriptParagraphs(words: words))
    #expect(TranscriptParagraphs(words: words).paragraphs.allSatisfy { $0.ad == nil && !$0.startsAd })
  }

  @Test func aParagraphBreaksAtEachAdEdge() {
    let ad = TranscriptAdRange(start: 6, end: 12, origin: .detected)  // sentences 3, 4, 5
    let transcript = TranscriptParagraphs(words: spoken(sentences: 9), adRanges: [ad])

    #expect(transcript.paragraphs.map(\.firstSentenceIndex) == [0, 3, 6])
    #expect(transcript.paragraphs.map(\.ad) == [nil, ad, nil])
    #expect(transcript.paragraphs.map(\.startsAd) == [false, true, false])
  }

  @Test func aSentenceIsInAnAdWhenItsMidpointIs() {
    // Sentence 2 spans 4 to 5.5, midpoint 4.75; sentence 3 spans 6 to 7.5, midpoint 6.75.
    let ad = TranscriptAdRange(start: 4.8, end: 6.8, origin: .hostRead)
    let transcript = TranscriptParagraphs(words: spoken(sentences: 5), adRanges: [ad])

    #expect(transcript.paragraphs.map(\.firstSentenceIndex) == [0, 3, 4])
    #expect(transcript.paragraphs.map(\.ad) == [nil, ad, nil])
  }

  @Test func anAdLongerThanAParagraphIsSeveralParagraphsAndOnlyTheFirstStartsIt() {
    let ad = TranscriptAdRange(start: 0, end: 100, origin: .detected)
    let transcript = TranscriptParagraphs(words: spoken(sentences: 14), adRanges: [ad])

    #expect(transcript.paragraphs.count == 3)
    #expect(transcript.paragraphs.allSatisfy { $0.ad == ad })
    #expect(transcript.paragraphs.map(\.startsAd) == [true, false, false])
  }

  @Test func adjacentAdsAreSeparateBlocks() {
    let first = TranscriptAdRange(start: 0, end: 4, origin: .detected)
    let second = TranscriptAdRange(start: 4, end: 8, origin: .hostRead)
    let transcript = TranscriptParagraphs(words: spoken(sentences: 4), adRanges: [first, second])

    #expect(transcript.paragraphs.map(\.firstSentenceIndex) == [0, 2])
    #expect(transcript.paragraphs.map(\.startsAd) == [true, true])
  }

  @Test func paragraphIDsHoldAcrossAReSplit() {
    let words = spoken(sentences: 9)
    let plain = TranscriptParagraphs(words: words)
    let ad = TranscriptAdRange(start: 6, end: 12, origin: .detected)
    let split = TranscriptParagraphs(words: words, adRanges: [ad])

    #expect(plain.paragraphs.map(\.id) == [0, 6])
    #expect(split.paragraphs.map(\.id) == [0, 3, 6])
    #expect(split.paragraphs.map(\.id) == split.paragraphs.map(\.firstSentenceIndex))
    // The sentences, and so the ids of everything before the ad, are the same.
    #expect(split.sentences == plain.sentences)
  }
}
