import AppModel
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// The transcript paragraph's text: one link per sentence, so tapping a sentence plays it, and a
/// current-sentence highlight that does not rely on colour alone.
@MainActor
@Suite("Transcript paragraph text")
struct TranscriptParagraphViewTests {

  private let paragraph: TranscriptParagraphs.Paragraph = {
    let words = ["One.", "Two", "three.", "Four."].enumerated().map { offset, text in
      StoredTranscriptWord(text: text, start: Double(offset), end: Double(offset) + 0.5)
    }
    return TranscriptParagraphs(words: words).paragraphs[0]
  }()

  private func runs(_ highlight: TranscriptParagraphView.Highlight) -> [AttributedString.Runs.Run] {
    Array(TranscriptParagraphView.text(paragraph, highlight: highlight).runs)
  }

  @Test("each sentence links to its own index, and the link reads back")
  func eachSentenceLinksToItsIndex() {
    let links = runs(.init(current: nil, matches: [])).compactMap(\.link)

    #expect(links.compactMap(TranscriptParagraphView.sentenceIndex(from:)) == [0, 1, 2])
    #expect(TranscriptParagraphView.sentenceIndex(from: URL(string: "https://example.com/1")!) == nil)
  }

  @Test("the paragraph reads as prose")
  func theParagraphReadsAsProse() {
    let text = TranscriptParagraphView.text(paragraph, highlight: .init(current: nil, matches: []))

    #expect(String(text.characters) == "One. Two three. Four.")
  }

  @Test("the current sentence is bold, not only tinted")
  func theCurrentSentenceIsBold() {
    let emphasised = runs(.init(current: 1, matches: []))
      .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
      .compactMap(\.link)

    #expect(emphasised.compactMap(TranscriptParagraphView.sentenceIndex(from:)) == [1])
  }

  @Test("highlights compare by value, so an unchanged paragraph is not redrawn")
  func highlightsCompareByValue() {
    #expect(
      TranscriptParagraphView.Highlight(current: 1, matches: [2])
        == TranscriptParagraphView.Highlight(current: 1, matches: [2]))
    #expect(
      TranscriptParagraphView.Highlight(current: 1, matches: [])
        != TranscriptParagraphView.Highlight(current: 2, matches: []))
  }

  @Test("a paragraph's timestamp shows hours only when the episode reaches them")
  func timestampsShowHoursOnlyWhenNeeded() {
    #expect(TranscriptTimestamp.text(5.9) == "0:05")
    #expect(TranscriptTimestamp.text(754) == "12:34")
    #expect(TranscriptTimestamp.text(3723) == "1:02:03")
    #expect(TranscriptTimestamp.text(-1) == "0:00")
  }
}
