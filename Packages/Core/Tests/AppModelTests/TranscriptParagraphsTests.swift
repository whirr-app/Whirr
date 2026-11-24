import Persistence
import Testing

@testable import AppModel

/// Words to sentences to paragraphs, and finding the sentence at a time.
@Suite struct TranscriptParagraphsTests {

  /// Words one second apart, each lasting half a second, from `start`.
  private func words(_ text: String, from start: Double = 0) -> [StoredTranscriptWord] {
    text.split(separator: " ").enumerated().map { offset, word in
      let wordStart = start + Double(offset)
      return StoredTranscriptWord(text: String(word), start: wordStart, end: wordStart + 0.5)
    }
  }

  @Test func sentencesEndAtFullStopsQuestionAndExclamationMarksAndEllipses() {
    let transcript = TranscriptParagraphs(
      words: words("One two. Three? Four! Five\u{2026} Six"))

    #expect(
      transcript.sentences.map(\.text) == ["One two.", "Three?", "Four!", "Five\u{2026}", "Six"])
  }

  @Test func aSentenceEndLooksPastClosingQuotesAndBrackets() {
    let transcript = TranscriptParagraphs(
      words: words("He said \u{201C}stop.\u{201D} Then (quietly.) left"))

    #expect(
      transcript.sentences.map(\.text) == [
        "He said \u{201C}stop.\u{201D}", "Then (quietly.)", "left",
      ])
  }

  @Test func aCommaDoesNotEndASentence() {
    let transcript = TranscriptParagraphs(words: words("Well, yes, quite."))

    #expect(transcript.sentences.map(\.text) == ["Well, yes, quite."])
  }

  @Test func punctuationEmittedAsItsOwnWordJoinsWithoutASpace() {
    let transcript = TranscriptParagraphs(words: words("Hello , world ."))

    #expect(transcript.sentences.map(\.text) == ["Hello, world."])
  }

  @Test func eachSentenceSpansItsFirstWordsStartToItsLastWordsEnd() {
    let transcript = TranscriptParagraphs(words: words("One two. Three", from: 10))

    #expect(transcript.sentences.map(\.start) == [10, 12])
    #expect(transcript.sentences.map(\.end) == [11.5, 12.5])
  }

  @Test func aGapOfTwoSecondsStartsANewParagraph() {
    let transcript = TranscriptParagraphs(
      words: words("One. Two.") + words("Three. Four.", from: 3.5))

    #expect(transcript.paragraphs.map { $0.sentences.map(\.text) } == [["One.", "Two."], ["Three.", "Four."]])
  }

  @Test func aShorterGapKeepsTheParagraph() {
    let transcript = TranscriptParagraphs(
      words: words("One. Two.") + words("Three.", from: 3.4))

    #expect(transcript.paragraphs.count == 1)
  }

  @Test func aMonologueBreaksAfterAFixedNumberOfSentences() {
    let count = TranscriptParagraphs.maximumSentencesPerParagraph
    let text = (1...(count + 1)).map { "S\($0)." }.joined(separator: " ")
    let transcript = TranscriptParagraphs(words: words(text))

    #expect(transcript.paragraphs.map(\.sentences.count) == [count, 1])
  }

  @Test func paragraphsRecordWhereTheirSentencesSitInTheFlatList() {
    let transcript = TranscriptParagraphs(
      words: words("One. Two.") + words("Three.", from: 5))

    #expect(transcript.paragraphs.map(\.firstSentenceIndex) == [0, 2])
  }

  @Test func noWordsIsNoSentences() {
    let transcript = TranscriptParagraphs(words: [])

    #expect(transcript.sentences.isEmpty)
    #expect(transcript.paragraphs.isEmpty)
    #expect(transcript.sentenceIndex(at: 3) == nil)
  }

  @Test func theSentenceAtATimeIsTheLastOneStartedByThen() {
    let transcript = TranscriptParagraphs(words: words("One two. Three four. Five"))

    #expect(transcript.sentenceIndex(at: 0) == 0)
    #expect(transcript.sentenceIndex(at: 1.9) == 0)
    #expect(transcript.sentenceIndex(at: 2) == 1)
    #expect(transcript.sentenceIndex(at: 3.7) == 1)
    #expect(transcript.sentenceIndex(at: 4) == 2)
    #expect(transcript.sentenceIndex(at: 400) == 2)
  }

  @Test func beforeTheFirstSentenceThereIsNone() {
    let transcript = TranscriptParagraphs(words: words("One.", from: 5))

    #expect(transcript.sentenceIndex(at: 4.9) == nil)
  }

  @Test func theParagraphHoldingASentenceIsFound() {
    let transcript = TranscriptParagraphs(
      words: words("One. Two.") + words("Three. Four.", from: 5) + words("Five.", from: 10))

    #expect((0...4).map { transcript.paragraphIndex(containingSentence: $0) } == [0, 0, 1, 1, 2])
    #expect(transcript.paragraphIndex(containingSentence: 5) == nil)
    #expect(transcript.paragraphIndex(containingSentence: -1) == nil)
  }

  @Test func aParagraphStartsWhenItsFirstSentenceDoes() {
    let transcript = TranscriptParagraphs(words: words("One. Two.") + words("Three.", from: 5))

    #expect(transcript.paragraphs.map(\.start) == [0, 5])
  }

  @Test func eachChapterHeadsTheFirstParagraphThatStartsInIt() {
    let transcript = TranscriptParagraphs(
      words: words("One.") + words("Two.", from: 5) + words("Three.", from: 10)
        + words("Four.", from: 15))

    let headings = transcript.chapterHeadings([
      (start: 0, title: "Intro"), (start: 9, title: "Part One"),
    ])

    #expect(headings == [0: "Intro", 2: "Part One"])
  }

  @Test func aParagraphJustBeforeAChapterMarkCountsAsInsideIt() {
    let transcript = TranscriptParagraphs(words: words("One.") + words("Two.", from: 9.5))

    #expect(transcript.chapterHeadings([(start: 10, title: "Part One")]) == [1: "Part One"])
  }

  @Test func untitledChaptersAndChaptersWithNoTextHeadNothing() {
    let transcript = TranscriptParagraphs(words: words("One.") + words("Two.", from: 20))

    let headings = transcript.chapterHeadings([
      (start: 0, title: "  "), (start: 5, title: "Skipped"), (start: 8, title: "Kept"),
    ])

    #expect(headings == [1: "Kept"])
  }
}
