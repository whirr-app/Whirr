import AppModel
import SwiftUI
import UIKit

/// What an ad block says about itself, in the header and to VoiceOver. The header's labels are
/// separate texts with no separator character between them.
struct TranscriptAdBlockCopy: Equatable {
  let labels: [String]
  let actionTitle: String
  /// What VoiceOver reads before the paragraph's text.
  let spokenPrefix: String

  init(_ range: TranscriptAdRange) {
    let length = TranscriptTimestamp.text(max(0, range.end - range.start))
    switch range.origin {
    case .detected, .hostRead:
      labels = ["Ad", length, "Skipped"]
      actionTitle = "Not an ad"
      spokenPrefix = "Ad, skipped"
    case .listener:
      labels = ["Ad", length, "Marked by you"]
      actionTitle = "Remove"
      spokenPrefix = "Ad, marked by you"
    }
  }
}

/// The transcript's paragraphs grouped for drawing: a paragraph outside an ad alone, or all the
/// consecutive paragraphs of one ad together.
enum TranscriptAdBlocks {
  struct Entry: Equatable {
    /// The paragraph's offset in the transcript, which chapter headings are keyed by.
    let index: Int
    let paragraph: TranscriptParagraphs.Paragraph
  }

  struct Block: Equatable {
    let ad: TranscriptAdRange?
    let entries: [Entry]
    /// The first paragraph's id, which holds across a re-split.
    var id: Int { entries[0].paragraph.id }
  }

  static func blocks(_ paragraphs: [TranscriptParagraphs.Paragraph]) -> [Block] {
    var result: [Block] = []
    for (index, paragraph) in paragraphs.enumerated() {
      let entry = Entry(index: index, paragraph: paragraph)
      if let ad = paragraph.ad, let last = result.last, last.ad == ad, paragraph.startsAd == false {
        result[result.count - 1] = Block(ad: ad, entries: last.entries + [entry])
      } else {
        result.append(Block(ad: paragraph.ad, entries: [entry]))
      }
    }
    return result
  }
}

enum TranscriptAdBlock {
  /// Concrete, not `.secondary`: over the half detent's glass a hierarchical style is drawn
  /// vibrant, so the text changed weight as the sheet grew opaque.
  static let ink = Color(uiColor: .secondaryLabel)

  /// The paragraph's text as VoiceOver reads it for an ad, or nil outside one.
  static func accessibilityLabel(for paragraph: TranscriptParagraphs.Paragraph) -> String? {
    guard let ad = paragraph.ad else { return nil }
    let prose = paragraph.sentences.map(\.text).joined(separator: " ")
    return "\(TranscriptAdBlockCopy(ad).spokenPrefix). \(prose)"
  }
}

/// The row above an ad's first paragraph: what it is, how long, why it is skipped, and the way
/// to undo it.
struct TranscriptAdHeader: View {
  let range: TranscriptAdRange
  let onUndo: (TranscriptAdRange) -> Void

  var body: some View {
    let copy = TranscriptAdBlockCopy(range)
    HStack(spacing: 12) {
      HStack(spacing: 12) {
        ForEach(Array(copy.labels.enumerated()), id: \.offset) { index, label in
          Text(label)
            .font(.caption.monospacedDigit().weight(index == 0 ? .bold : .medium))
            .foregroundStyle(TranscriptAdBlock.ink)
        }
      }
      // The paragraph below carries the same words in its own label.
      .accessibilityHidden(true)
      Spacer(minLength: 0)
      Button(copy.actionTitle) { onUndo(range) }
        .font(.caption.weight(.semibold))
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.primary)
    }
  }
}

extension View {
  /// One accent rule down the leading edge of a whole ad group, header to last paragraph.
  func transcriptAdRule(accent: Color) -> some View {
    padding(.leading, 14)
      .overlay(alignment: .leading) {
        Capsule()
          .fill(accent)
          .frame(width: 3)
          .accessibilityHidden(true)
      }
  }

  /// An ad's spoken label and its undo action; other paragraphs are left as they are.
  @ViewBuilder
  func transcriptAdAccessibility(
    _ paragraph: TranscriptParagraphs.Paragraph, onUndo: @escaping (TranscriptAdRange) -> Void
  ) -> some View {
    if let ad = paragraph.ad, let label = TranscriptAdBlock.accessibilityLabel(for: paragraph) {
      accessibilityLabel(label)
        .accessibilityAction(named: Text(verbatim: TranscriptAdBlockCopy(ad).actionTitle)) {
          onUndo(ad)
        }
    } else {
      self
    }
  }
}
