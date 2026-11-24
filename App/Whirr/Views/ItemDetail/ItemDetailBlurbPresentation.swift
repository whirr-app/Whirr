import SwiftUI

/// How the detail page's blurb opens and closes.
///
/// SwiftUI animates the disclosure's height change only when the toggle is in a transaction;
/// otherwise `lineLimit` swaps in one frame and the page jumps. Kept here so the collapsed
/// measure, label and Reduce Motion contract are testable, like `ItemDetailPlayButtonPresentation`.
enum ItemDetailBlurbPresentation {
  /// Enough of the blurb to tell whether it is worth opening, short enough that the controls and
  /// chapters below it stay on the first screen.
  static let collapsedLineLimit = 3

  static func lineLimit(isExpanded: Bool) -> Int? {
    isExpanded ? nil : collapsedLineLimit
  }

  /// Reduce Motion suppresses the growth (ARCHITECTURE §6): `nil` makes it instant, not slower.
  /// `.snappy` at the play control's duration, so the page's two disclosures settle together.
  static func motion(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.28)
  }

  /// The label names what the tap does next, not the state it is in.
  static func toggleLabel(isExpanded: Bool) -> String {
    isExpanded ? "Less" : "More"
  }

  static func toggleHint(isExpanded: Bool) -> String {
    isExpanded ? "Shows less of the description" : "Shows the full description"
  }
}
