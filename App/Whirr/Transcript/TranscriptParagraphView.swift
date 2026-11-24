import AppModel
import SwiftUI

/// One paragraph as one text element, so it wraps as prose. Each sentence is a link the sheet
/// handles as "play from here"; the current sentence is bold as well as tinted, so the highlight
/// does not rely on colour alone.
struct TranscriptParagraphView: View, Equatable {
  struct Highlight: Equatable {
    var current: Int?
    var matches: Set<Int>
    var selectedMatch: Int?
    /// The sentences chosen as an ad's edges and between, within this paragraph.
    var selection: ClosedRange<Int>?
    /// Whether taps choose edges, which changes the VoiceOver actions.
    var isMarking = false
  }

  static let scheme = "whirr-transcript"

  let paragraph: TranscriptParagraphs.Paragraph
  let highlight: Highlight
  var accent: Color = .accentColor
  /// A tap on a sentence: the model plays from it, or selects it while marking.
  let onTap: (Int) -> Void
  /// A tap on the row while marking, with the paragraph's first sentence.
  var onRowTap: (Int) -> Void = { _ in }
  var onStartAd: (Int) -> Void = { _ in }
  var onEndAd: (Int) -> Void = { _ in }
  /// Takes the range so the closure holds no paragraph state, which `==` would not see change.
  var onUndo: (TranscriptAdRange) -> Void = { _ in }

  @State private var tapFunnel = TranscriptTapFunnel()

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.paragraph == rhs.paragraph && lhs.highlight == rhs.highlight
  }

  var body: some View {
    Text(Self.text(paragraph, highlight: highlight, accent: accent))
      .font(.body)
      .lineSpacing(3)
      .tint(paragraph.ad == nil ? Color.primary : TranscriptAdBlock.ink)
      .foregroundStyle(paragraph.ad == nil ? Color.primary : TranscriptAdBlock.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .environment(
        \.openURL,
        OpenURLAction { url in
          guard let index = Self.sentenceIndex(from: url) else { return .systemAction }
          tapFunnel.link(index, deferred: highlight.isMarking, apply: onTap)
          return .handled
        }
      )
      .transcriptRowTap(
        isMarking: highlight.isMarking, funnel: tapFunnel,
        firstSentence: paragraph.firstSentenceIndex, onRowTap: onRowTap
      )
      .transcriptTapActions(
        isMarking: highlight.isMarking, paragraph: paragraph, onPlay: onTap, onStart: onStartAd,
        onEnd: onEndAd
      )
      .transcriptAdAccessibility(paragraph, onUndo: onUndo)
  }

  static func text(
    _ paragraph: TranscriptParagraphs.Paragraph, highlight: Highlight, accent: Color = .accentColor
  ) -> AttributedString {
    var result = AttributedString()
    for (offset, sentence) in paragraph.sentences.enumerated() {
      let index = paragraph.firstSentenceIndex + offset
      if offset > 0 {
        var space = AttributedString(" ")
        // The gap between two chosen sentences carries the selection too, so it reads as one block.
        if highlight.selection?.contains(index - 1) == true,
          highlight.selection?.contains(index) == true
        {
          space.backgroundColor = accent.opacity(0.4)
        }
        result += space
      }
      var run = AttributedString(sentence.text)
      run.link = URL(string: "\(scheme):\(index)")
      if index == highlight.current {
        run.inlinePresentationIntent = .stronglyEmphasized
        run.backgroundColor = accent.opacity(0.28)
      }
      if highlight.selection?.contains(index) == true {
        run.backgroundColor = accent.opacity(0.4)
      }
      if index == highlight.selectedMatch {
        run.backgroundColor = Color.yellow.opacity(0.55)
      } else if highlight.matches.contains(index) {
        run.backgroundColor = Color.yellow.opacity(0.25)
      }
      result += run
    }
    return result
  }

  static func sentenceIndex(from url: URL) -> Int? {
    guard url.scheme == scheme else { return nil }
    return Int(url.absoluteString.dropFirst(scheme.count + 1))
  }
}
