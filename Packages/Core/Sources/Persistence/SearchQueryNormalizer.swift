import Foundation

/// The pure text normalizer every search path agrees with: the ranked `LIKE` implementation and
/// the FTS5 index both fold and tokenize through here, so queries and stored values compare alike.
///
/// Folding is pinned to a fixed locale, not the device's: a Turkish device folding `"İstanbul"`
/// must match an `en_US` one.
public enum SearchQueryNormalizer {
  private static let foldingLocale = Locale(identifier: "en_US_POSIX")
  private static let foldingOptions: String.CompareOptions = [
    .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
  ]

  /// Case- and diacritic-folded, with whitespace runs collapsed to a single space and the result
  /// trimmed. Punctuation is preserved (only `tokens` strips it), so this stays a faithful
  /// normalization of the whole query rather than a bag of words.
  public static func normalize(_ input: String) -> String {
    input.folding(options: foldingOptions, locale: foldingLocale)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  /// The same folding, split on whitespace and punctuation, with empty pieces dropped. A query of
  /// only punctuation (or only whitespace) yields `[]`.
  public static func tokens(_ input: String) -> [String] {
    input.folding(options: foldingOptions, locale: foldingLocale)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.isEmpty == false }
  }

  /// A comparison-only spelling that removes presentational punctuation. Apostrophes and full
  /// stops disappear inside a word, other separators become word boundaries, and runs of two or
  /// more single-letter words become one initialism. Thus `S.A.`, `S. A.` and `SA` agree, as do
  /// `O'Brien`/`OBrien` and `Jean-Luc`/`Jean Luc`.
  ///
  /// `normalize` stays the faithful whole-string fold for literal ranking, so Search can rank a
  /// literal spelling above a canonical-only match.
  public static func canonicalize(_ input: String) -> String {
    let folded = input.folding(options: foldingOptions, locale: foldingLocale)
    var separated = ""
    separated.reserveCapacity(folded.count)

    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        separated.unicodeScalars.append(scalar)
      } else if apostropheOrFullStopScalars.contains(scalar.value) {
        continue
      } else {
        separated.append(" ")
      }
    }

    let words = separated.split(whereSeparator: \.isWhitespace).map(String.init)
    var result: [String] = []
    var initials: [String] = []

    func flushInitials() {
      guard initials.isEmpty == false else { return }
      result.append(initials.joined())
      initials.removeAll(keepingCapacity: true)
    }

    for word in words {
      if isSingleLetter(word) {
        initials.append(word)
      } else {
        flushInitials()
        result.append(word)
      }
    }
    flushInitials()
    return result.joined(separator: " ")
  }

  private static let apostropheOrFullStopScalars: Set<UInt32> = [
    0x0027,  // APOSTROPHE
    0x002E,  // FULL STOP
    0x02BC,  // MODIFIER LETTER APOSTROPHE
    0x2019,  // RIGHT SINGLE QUOTATION MARK
    0xFF07,  // FULLWIDTH APOSTROPHE
    0xFF0E,  // FULLWIDTH FULL STOP
  ]

  private static func isSingleLetter(_ value: String) -> Bool {
    value.count == 1 && value.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
  }
}
