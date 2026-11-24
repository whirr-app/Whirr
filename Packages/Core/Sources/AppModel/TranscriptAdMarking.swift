import AdSkip
import Foundation

/// Whether the transcript can offer to mark an ad, and the pure rules of the marking selection.
public enum TranscriptAdMarking {

  public enum Availability: Sendable, Equatable {
    /// Ad skip is off or not composed: the transcript does not mention marking.
    case hidden
    /// Ad skip is on but cannot take a mark yet.
    case unavailable(Reason)
    case available
  }

  public enum Reason: Sendable, Equatable {
    /// Ad skip has not analysed the episode, or its file has changed since.
    case notAnalysed
  }

  /// The longest mark saved without asking, in seconds.
  public static let confirmationSeconds: Double = 300

  /// The selected sentences, as a range of sentence indices. It is stored by sentence, not by
  /// paragraph, so it survives the transcript being re-paragraphed (ad edges split paragraphs).
  struct Selection: Equatable {
    private(set) var range: ClosedRange<Int>?

    var isEmpty: Bool { range == nil }

    /// A tap selects by paragraph, with sentence precision only at the selection's edges.
    /// `paragraph` gives the displayed paragraph's first and last sentence index for any sentence.
    ///
    /// - No selection: the tapped paragraph.
    /// - A paragraph wholly outside the selection: the selection grows to cover it.
    /// - The paragraph holding the start (or the end) of a multi-paragraph selection: that end
    ///   moves to the tapped sentence, trimming or restoring it.
    /// - Within a single paragraph: the nearer end moves to the sentence; a tie moves the end.
    /// - An interior paragraph: the nearer end moves to cover it as the edge paragraph.
    mutating func tap(sentence: Int, paragraph: (Int) -> ClosedRange<Int>) {
      let tapped = paragraph(sentence)
      guard let current = range else {
        range = tapped
        return
      }
      let lo = current.lowerBound
      let hi = current.upperBound
      let first = paragraph(lo)
      let last = paragraph(hi)
      if first == last && tapped == first {
        if sentence < lo {
          range = sentence...hi
        } else if sentence > hi {
          range = lo...sentence
        } else if sentence - lo < hi - sentence {
          range = sentence...hi
        } else {
          range = lo...sentence
        }
      } else if tapped == first && first != last {
        range = sentence...hi
      } else if tapped == last && first != last {
        range = lo...sentence
      } else if tapped.upperBound < lo || tapped.lowerBound > hi {
        range = min(lo, tapped.lowerBound)...max(hi, tapped.upperBound)
      } else if tapped.lowerBound - lo < hi - tapped.upperBound {
        range = tapped.lowerBound...hi
      } else {
        range = lo...tapped.upperBound
      }
    }

    /// A tap on a paragraph with no sentence precision (the row, not a sentence link). The
    /// paragraph holding the selection's start or end restores that end whole; otherwise as `tap`.
    mutating func tap(paragraph tapped: ClosedRange<Int>, paragraphOf: (Int) -> ClosedRange<Int>) {
      guard let current = range else {
        range = tapped
        return
      }
      let lo = current.lowerBound
      let hi = current.upperBound
      let first = paragraphOf(lo)
      let last = paragraphOf(hi)
      if first == last && tapped == first {
        range = tapped
      } else if tapped == first {
        range = tapped.lowerBound...hi
      } else if tapped == last {
        range = lo...tapped.upperBound
      } else if tapped.upperBound < lo || tapped.lowerBound > hi {
        range = min(lo, tapped.lowerBound)...max(hi, tapped.upperBound)
      } else if tapped.lowerBound - lo < hi - tapped.upperBound {
        range = tapped.lowerBound...hi
      } else {
        range = lo...tapped.upperBound
      }
    }

    /// Sets the start: the first sentence moves to `index`, or the selection restarts there when
    /// the ad would begin after its end.
    mutating func setStart(_ index: Int) {
      if let range, index <= range.upperBound {
        self.range = index...range.upperBound
      } else {
        range = index...index
      }
    }

    /// Sets the end: the last sentence moves to `index`, or the selection restarts there when the
    /// ad would end before its start.
    mutating func setEnd(_ index: Int) {
      if let range, index >= range.lowerBound {
        self.range = range.lowerBound...index
      } else {
        range = index...index
      }
    }
  }
}
