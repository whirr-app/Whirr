import AppModel
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// The marking mode's view side: the bar's copy and enabled rules, the menu's presence, and the
/// highlight that carries the selection.
@MainActor
@Suite("Transcript ad marking")
struct TranscriptAdMarkingTests {

  private func paragraph() -> TranscriptParagraphs.Paragraph {
    let words = ["One.", "Two.", "Three."].enumerated().map { offset, text in
      StoredTranscriptWord(text: text, start: Double(offset), end: Double(offset) + 0.5)
    }
    return TranscriptParagraphs(words: words, adRanges: []).paragraphs[0]
  }

  // MARK: - Bar

  @Test("the bar asks for a paragraph, then shows the length")
  func barPrompts() {
    let none = TranscriptAdMarkingBarState(seconds: nil, canSave: false)
    #expect(none.prompt == TranscriptAdMarkingCopy.prompt)
    #expect(none.length == nil)

    let some = TranscriptAdMarkingBarState(seconds: 370, canSave: true)
    #expect(some.prompt == nil)
    #expect(some.length == "6:10")
  }

  @Test("the subtitle is the prompt, then the length with no separator character")
  func subtitle() {
    #expect(
      TranscriptAdMarkingBarState(seconds: nil, canSave: false).subtitle
        == TranscriptAdMarkingCopy.prompt)
    #expect(
      TranscriptAdMarkingBarState(seconds: 20, canSave: true).subtitle
        == "Length 0:20")
  }

  @Test("a mark that would skip only here says so after its length")
  func localOnly() {
    #expect(
      TranscriptAdMarkingBarState(seconds: 3, canSave: true, teaches: false).subtitle
        == "Length 0:03 This episode only")
    #expect(
      TranscriptAdMarkingBarState(seconds: 3, canSave: true, teaches: true).subtitle
        == "Length 0:03")
    #expect(
      TranscriptAdMarkingBarState(seconds: nil, canSave: false, teaches: false).subtitle
        == TranscriptAdMarkingCopy.prompt)
  }

  @Test("the space between two chosen sentences is highlighted, the edges are not")
  func selectionBridgesTheGap() {
    let text = TranscriptParagraphView.text(
      paragraph(), highlight: .init(current: nil, matches: [], selection: 0...1))
    let chars = text.characters
    let firstSpace = chars.index(chars.startIndex, offsetBy: 4)
    let secondSpace = chars.index(chars.startIndex, offsetBy: 9)

    #expect(text[firstSpace..<chars.index(after: firstSpace)].backgroundColor != nil)
    #expect(text[secondSpace..<chars.index(after: secondSpace)].backgroundColor == nil)
  }

  @Test("Mark as ad is enabled only with a selection long enough")
  func barEnabling() {
    #expect(TranscriptAdMarkingBarState(seconds: nil, canSave: false).canSave == false)
    #expect(TranscriptAdMarkingBarState(seconds: nil, canSave: true).canSave == false)
    #expect(TranscriptAdMarkingBarState(seconds: 3.5, canSave: false).canSave == false)
    #expect(TranscriptAdMarkingBarState(seconds: 5.5, canSave: true).canSave)
  }

  @Test("no bar text, button, action or confirmation carries a dot separator")
  func noDotSeparators() {
    let states = [
      TranscriptAdMarkingBarState(seconds: nil, canSave: false),
      TranscriptAdMarkingBarState(seconds: nil, canSave: false),
      TranscriptAdMarkingBarState(seconds: 75, canSave: true),
      TranscriptAdMarkingBarState(seconds: 3, canSave: true, teaches: false),
    ]
    var texts = [
      TranscriptAdMarkingCopy.menuTitle, TranscriptAdMarkingCopy.unavailableReason,
      TranscriptAdMarkingCopy.lengthLabel, TranscriptAdMarkingCopy.markTitle,
      TranscriptAdMarkingCopy.cancelTitle, TranscriptAdMarkingCopy.confirmTitle,
      TranscriptAdMarkingCopy.startAction, TranscriptAdMarkingCopy.endAction,
      TranscriptAdMarkingCopy.localOnly,
      TranscriptAdMarkingCopy.confirmationTitle(seconds: 370),
    ]
    texts += states.flatMap { [$0.prompt, $0.length, $0.subtitle].compactMap { $0 } }
    for text in texts {
      #expect(text.contains("·") == false, "\(text)")
      #expect(text.contains("•") == false, "\(text)")
    }
  }

  @Test("the long-mark confirmation names the length")
  func confirmationTitle() {
    #expect(TranscriptAdMarkingCopy.confirmationTitle(seconds: 370) == "Mark 6:10 as an ad?")
  }

  // MARK: - Menu

  @Test("the menu is absent unless the transcript is ready and ad skip is on")
  func menuPresence() {
    func presentation(
      _ availability: TranscriptAdMarking.Availability, ready: Bool = true, marking: Bool = false
    ) -> TranscriptAdMarkingMenu.Presentation {
      TranscriptAdMarkingMenu.presentation(
        availability: availability, isReady: ready, isMarking: marking)
    }
    #expect(presentation(.hidden) == .absent)
    #expect(presentation(.available) == .enabled)
    #expect(
      presentation(.unavailable(.notAnalysed))
        == .disabled(reason: "Ad skip has not analysed this episode yet"))
    #expect(presentation(.available, ready: false) == .absent)
    #expect(presentation(.unavailable(.notAnalysed), ready: false) == .absent)
    #expect(presentation(.available, marking: true) == .absent)
  }

  // MARK: - Highlight

  @Test("the highlight's equality includes the selection and the mode")
  func highlightEquality() {
    let base = TranscriptParagraphView.Highlight(current: nil, matches: [])
    var selected = base
    selected.selection = 1...2
    var marking = base
    marking.isMarking = true
    #expect(base == TranscriptParagraphView.Highlight(current: nil, matches: []))
    #expect(selected != base)
    #expect(marking != base)
    var moved = selected
    moved.selection = 1...3
    #expect(moved != selected)
  }

  @Test("the selected sentences are drawn in the accent tint and the others are not")
  func selectionIsTinted() {
    var highlight = TranscriptParagraphView.Highlight(current: nil, matches: [])
    highlight.selection = 1...1
    let runs = Array(
      TranscriptParagraphView.text(paragraph(), highlight: highlight, accent: .red).runs)
    let tinted = runs.filter { $0.backgroundColor != nil }
    #expect(tinted.compactMap { $0.link }.compactMap(TranscriptParagraphView.sentenceIndex(from:)) == [1])
  }

  // MARK: - Tap funnel

  private func nextTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test("a link and a row tap in the same turn apply only the link, in either order")
  func funnelAppliesOneTouchOnce() async {
    var applied: [String] = []
    let funnel = TranscriptTapFunnel()
    funnel.link(3, deferred: true) { applied.append("link \($0)") }
    funnel.row { applied.append("row") }
    await nextTurn()
    #expect(applied == ["link 3"])

    applied = []
    funnel.row { applied.append("row") }
    funnel.link(4, deferred: true) { applied.append("link \($0)") }
    await nextTurn()
    #expect(applied == ["link 4"])
  }

  @Test("a row tap alone applies once, and a link outside marking applies at once")
  func funnelRowAloneAndUndeferredLink() async {
    var applied: [String] = []
    let funnel = TranscriptTapFunnel()
    funnel.row { applied.append("row") }
    #expect(applied.isEmpty)
    await nextTurn()
    #expect(applied == ["row"])

    funnel.link(2, deferred: false) { applied.append("link \($0)") }
    #expect(applied == ["row", "link 2"])
  }
}
