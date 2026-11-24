import AppModel
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// An ad block in the transcript: the header's separate labels, the paragraph's links and the way
/// VoiceOver reads it.
@MainActor
@Suite("Transcript ad block")
struct TranscriptAdBlockTests {

  private func adParagraph(origin: TranscriptAdRange.Origin) -> TranscriptParagraphs.Paragraph {
    let words = ["One.", "Two", "three.", "Four."].enumerated().map { offset, text in
      StoredTranscriptWord(text: text, start: Double(offset), end: Double(offset) + 0.5)
    }
    let ad = TranscriptAdRange(start: 0, end: 92, origin: origin)
    return TranscriptParagraphs(words: words, adRanges: [ad]).paragraphs[0]
  }

  @Test("a skipped ad's header reads Ad, its length and Skipped, with Not an ad to undo it")
  func detectedHeader() {
    for origin in [TranscriptAdRange.Origin.detected, .hostRead] {
      let copy = TranscriptAdBlockCopy(TranscriptAdRange(start: 10, end: 102, origin: origin))

      #expect(copy.labels == ["Ad", "1:32", "Skipped"])
      #expect(copy.actionTitle == "Not an ad")
    }
  }

  @Test("a listener's own mark reads Marked by you, with Remove")
  func listenerHeader() {
    let copy = TranscriptAdBlockCopy(TranscriptAdRange(start: 0, end: 48, origin: .listener))

    #expect(copy.labels == ["Ad", "0:48", "Marked by you"])
    #expect(copy.actionTitle == "Remove")
  }

  @Test("no label or spoken text carries a dot separator")
  func noDotSeparators() {
    for origin in [TranscriptAdRange.Origin.detected, .hostRead, .listener] {
      let copy = TranscriptAdBlockCopy(TranscriptAdRange(start: 0, end: 75, origin: origin))
      for text in copy.labels + [copy.actionTitle, copy.spokenPrefix] {
        #expect(text.contains("·") == false, "\(text)")
      }
    }
  }

  @Test("an ad paragraph keeps one link per sentence and reads as prose")
  func adParagraphKeepsItsLinks() {
    let paragraph = adParagraph(origin: .detected)
    let text = TranscriptParagraphView.text(paragraph, highlight: .init(current: nil, matches: []))
    let links = text.runs.compactMap(\.link)

    #expect(paragraph.ad != nil)
    #expect(links.compactMap(TranscriptParagraphView.sentenceIndex(from:)) == [0, 1, 2])
    #expect(String(text.characters) == "One. Two three. Four.")
  }

  @Test("VoiceOver reads an ad's kind first")
  func accessibilityLabel() {
    #expect(
      TranscriptAdBlock.accessibilityLabel(for: adParagraph(origin: .detected))
        == "Ad, skipped. One. Two three. Four.")
    #expect(
      TranscriptAdBlock.accessibilityLabel(for: adParagraph(origin: .listener))
        == "Ad, marked by you. One. Two three. Four.")
  }

  @Test("a paragraph outside an ad has no ad label")
  func plainParagraphHasNoAdLabel() {
    let words = [StoredTranscriptWord(text: "Hello.", start: 0, end: 1)]
    let paragraph = TranscriptParagraphs(words: words).paragraphs[0]

    #expect(TranscriptAdBlock.accessibilityLabel(for: paragraph) == nil)
  }

  @Test("the progress strip separates its labels without a dot")
  func progressStripHasNoDot() {
    let states: [EpisodeTranscriptModel.State] = [
      .generating(fraction: 0.4), .offer(fraction: 0.4), .held(.queued, fraction: 0.1),
      .held(.paused, fraction: 0.1), .needsAsset(fraction: 0),
    ]
    for state in states {
      let labels = TranscriptProgressStrip.status(for: state)?.labels ?? []
      #expect(labels.isEmpty == false)
      for label in labels { #expect(label.contains("·") == false, "\(label)") }
    }
    #expect(TranscriptProgressStrip.status(for: .generating(fraction: 0.4))?.labels.first == "Transcribing")
  }

  /// One sentence per paragraph: each is its own paragraph by the sentence cap's gap rule.
  private func blocks(adRanges: [TranscriptAdRange]) -> [TranscriptAdBlocks.Block] {
    let words = (0..<6).map { index in
      StoredTranscriptWord(text: "S\(index).", start: Double(index) * 10, end: Double(index) * 10 + 1)
    }
    return TranscriptAdBlocks.blocks(TranscriptParagraphs(words: words, adRanges: adRanges).paragraphs)
  }

  @Test("paragraphs outside an ad are blocks of their own")
  func plainParagraphsStandAlone() {
    let blocks = blocks(adRanges: [])

    #expect(blocks.count == 6)
    #expect(blocks.allSatisfy { $0.ad == nil && $0.entries.count == 1 })
  }

  @Test("the consecutive paragraphs of one ad form one block, keyed by the first")
  func oneAdIsOneBlock() {
    let ad = TranscriptAdRange(start: 9, end: 40, origin: .detected)
    let blocks = blocks(adRanges: [ad])

    #expect(blocks.map(\.entries.count) == [1, 3, 1, 1])
    #expect(blocks[1].ad == ad)
    #expect(blocks[1].entries.map(\.index) == [1, 2, 3])
    #expect(blocks.map(\.id) == [0, 1, 4, 5])
  }

  @Test("two different adjacent ads are two blocks")
  func adjacentAdsStaySeparate() {
    let first = TranscriptAdRange(start: 9, end: 21, origin: .detected)
    let second = TranscriptAdRange(start: 21, end: 41, origin: .listener)
    let blocks = blocks(adRanges: [first, second])

    #expect(blocks.map(\.ad) == [nil, first, second, nil])
    #expect(blocks.map(\.entries.count) == [1, 2, 2, 1])
  }
}
