import Testing

@testable import AdSkip

@Suite struct PreparedTranscriptTests {
  @Test func normaliseLowercasesAndStripsPunctuation() {
    #expect(PreparedTranscript.normalise("Hello,") == "hello")
    #expect(PreparedTranscript.normalise("It's") == "its")
    #expect(PreparedTranscript.normalise("A1-B2!") == "a1b2")
  }

  @Test func normaliseDropsNonAsciiLetters() {
    #expect(PreparedTranscript.normalise("café") == "caf")
    #expect(PreparedTranscript.normalise("ÅÉ") == "")
    #expect(PreparedTranscript.normalise("日本") == "")
  }

  @Test func emptyNormalisedWordsAreDroppedButStayInTheTranscript() {
    let raw = [
      TranscriptWord(text: "alpha", start: 0, end: 0.4),
      TranscriptWord(text: "--", start: 0.5, end: 0.9),
      TranscriptWord(text: "bravo", start: 1.0, end: 1.4),
    ]
    let prepared = Fixture.prepared(raw)
    #expect(prepared.words.map(\.text) == ["alpha", "bravo"])
    #expect(prepared.transcript.words.count == 3)
  }

  @Test func fnvPinsKnownValues() {
    #expect(ShingleHash.hash([String]()) == 0xcbf2_9ce4_8422_2325)
    #expect(ShingleHash.hash(["a"]) == 0xaf63_dc4c_8601_ec8c)
  }

  @Test func hashJoinsWordsWithSingleSpaces() {
    // FNV-1a of "a b" is the fold of 'a', ' ', 'b'.
    var expected: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in "a b".utf8 { expected = (expected ^ UInt64(byte)) &* 0x100_0000_01b3 }
    #expect(ShingleHash.hash(["a", "b"]) == expected)
    #expect(ShingleHash.hash(["ab"]) != expected)
  }

  @Test func gapOfExactlyTwoSecondsSplitsASegment() {
    let words = [
      TranscriptWord(text: "alpha", start: 0, end: 1),
      TranscriptWord(text: "bravo", start: 3, end: 4),
    ]
    #expect(Fixture.prepared(words).segments == [0..<1, 1..<2])
  }

  @Test func gapOfJustUnderTwoSecondsDoesNotSplit() {
    let words = [
      TranscriptWord(text: "alpha", start: 0, end: 1),
      TranscriptWord(text: "bravo", start: 2.99, end: 4),
    ]
    #expect(Fixture.prepared(words).segments == [0..<2])
  }

  @Test func gapIsMeasuredBetweenNormalisedWordsOnly() {
    let words = [
      TranscriptWord(text: "alpha", start: 0, end: 1),
      TranscriptWord(text: "!!", start: 1.5, end: 2.5),
      TranscriptWord(text: "bravo", start: 3, end: 4),
    ]
    #expect(Fixture.prepared(words).segments == [0..<1, 1..<2])
  }

  @Test func shinglesAreEightWordWindows() {
    let prepared = Fixture.prepared(Fixture.words("w", count: 10))
    #expect(prepared.shingles.count == 3)
    let first = prepared.shingles[0]
    #expect(first.start == 0)
    #expect(first.end == 3.5 + 0.4)
    #expect(first.firstWord == 0)
    #expect(first.segment == 0)
    let expected = ShingleHash.hash((0..<8).map { "w\($0)" })
    #expect(first.hash == expected)
    #expect(prepared.shingleHashes.count == 3)
  }

  @Test func shorterThanEightWordsHasNoShingles() {
    #expect(Fixture.prepared(Fixture.words("w", count: 7)).shingles.isEmpty)
  }

  @Test func shinglesNeverCrossSegments() {
    let a = Fixture.words("a", count: 9)
    let b = Fixture.words("b", count: 9, from: 4.5 + 2.0)
    let prepared = Fixture.prepared(a + b)
    #expect(prepared.segments.count == 2)
    #expect(prepared.shingles.count == 4)
    for shingle in prepared.shingles {
      let segment = prepared.segments[shingle.segment]
      #expect(segment.contains(shingle.firstWord))
      #expect(shingle.firstWord + 8 <= segment.upperBound)
    }
    #expect(prepared.shingles.map(\.segment) == [0, 0, 1, 1])
  }
  @Test func aWordOpensASentenceAfterTerminalPunctuation() {
    let words = ["So", "that's", "it.", "Thanks", "—", "really!", "\u{201C}Next?\u{201D}", ".", "then", "on"]
      .enumerated().map { i, text in
        TranscriptWord(text: text, start: Double(i), end: Double(i) + 0.5)
      }
    let prepared = Fixture.prepared(words)
    #expect(prepared.words.map(\.text) == ["so", "thats", "it", "thanks", "really", "next", "then", "on"])
    // The first word opens; a closing quote after "?" still ends the sentence; a lone "." token
    // ends one too, and a dash does not.
    #expect(prepared.words.map(\.opensSentence) == [true, false, false, true, false, true, true, false])
  }
}
