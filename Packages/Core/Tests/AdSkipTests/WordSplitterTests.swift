import Testing

@testable import AdSkip

@Suite struct WordSplitterTests {
  @Test func aOneWordRunKeepsItsRange() {
    let words = WordSplitter.words(from: [TimedRun(text: "hello", start: 1, end: 2)])
    #expect(words == [TranscriptWord(text: "hello", start: 1, end: 2)])
  }

  @Test func aSharedRunIsDividedByCharacterLength() {
    // 3 + 1 characters over 4 s: "abc" takes 3 s and "d" takes 1 s.
    let words = WordSplitter.words(from: [TimedRun(text: " abc\td ", start: 10, end: 14)])
    #expect(
      words == [
        TranscriptWord(text: "abc", start: 10, end: 13),
        TranscriptWord(text: "d", start: 13, end: 14),
      ])
  }

  @Test func lengthCountsCharactersNotScalars() {
    // "é" written as e + combining acute is one Character, as in the harness.
    let words = WordSplitter.words(from: [TimedRun(text: "e\u{301} ab", start: 0, end: 3)])
    #expect(words.map(\.end) == [1, 3])
  }

  @Test func blankRunsAreSkipped() {
    let words = WordSplitter.words(from: [
      TimedRun(text: "  ", start: 0, end: 1), TimedRun(text: "", start: 1, end: 2),
    ])
    #expect(words.isEmpty)
  }

  @Test func wordsAreOrderedByStart() {
    let words = WordSplitter.words(from: [
      TimedRun(text: "later", start: 5, end: 6), TimedRun(text: "sooner", start: 1, end: 2),
    ])
    #expect(words.map(\.text) == ["sooner", "later"])
  }

  @Test func aZeroLengthRunGivesZeroLengthWords() {
    let words = WordSplitter.words(from: [TimedRun(text: "a b", start: 4, end: 4)])
    #expect(words == [TranscriptWord(text: "a", start: 4, end: 4), TranscriptWord(text: "b", start: 4, end: 4)])
  }
}
