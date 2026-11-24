import Foundation

/// The edit-distance comparison behind Search's close-match fallback. Pure: `SchemaV1`'s
/// `searchFuzzyDistance` SQL function and `DefaultSearchReading`'s query builder both call through
/// here, so the budget a query is built with and a row is judged by cannot disagree.
///
/// Distance is restricted Damerau-Levenshtein (optimal string alignment): substitution, insertion,
/// deletion and adjacent transposition each cost 1. Transposition is the commonest phone-keyboard
/// slip (`gaimna`); plain Levenshtein would charge 2 and reject it at a budget of 1.
///
/// Lengths count Unicode scalars, on text already in `SearchQueryNormalizer.canonicalize` form,
/// where folding has removed the combining marks that would make scalars and characters differ.
public enum FuzzyTokenMatch {
  /// Edits allowed for a query token of `length` scalars. A token of three or fewer must match a
  /// word exactly: at distance 1, `cat` is as close to `car`, `bat`, `cap`, `at`, and `cast` as to
  /// whatever was meant, so tolerance there admits noise rather than rescuing a typo.
  public static func budget(forTokenLength length: Int) -> Int {
    switch length {
    case ...3: return 0
    case 4...6: return 1
    default: return 2
    }
  }

  /// `budget(forTokenLength:)` for `token`, measured in the same unit `bestDistance` compares in.
  public static func budget(for token: String) -> Int {
    budget(forTokenLength: token.unicodeScalars.count)
  }

  /// The smallest distance from `token` to any word of `text`, or `nil` when no word is within
  /// `budget`. `token` must already be one canonical query token (an element of
  /// `SearchQueryNormalizer.tokens(SearchQueryNormalizer.canonicalize(query))`); `text` is any
  /// stored value, canonicalized here so initials and apostrophes compare the way the strict
  /// canonical path compares them.
  public static func bestDistance(token: String, in text: String, budget: Int) -> Int? {
    guard budget >= 0, token.isEmpty == false else { return nil }
    let tokenScalars = token.unicodeScalars.map(\.value)
    var best: Int?

    for word in SearchQueryNormalizer.canonicalize(text).split(separator: " ") {
      // Only a strictly closer word is worth computing once something has matched.
      let wordBudget = best.map { $0 - 1 } ?? budget
      guard wordBudget >= 0 else { break }
      let wordScalars = word.unicodeScalars
      // Length-difference prune: a word more than `wordBudget` scalars longer or shorter cannot be
      // within it, so it is skipped before anything is allocated.
      guard abs(wordScalars.count - tokenScalars.count) <= wordBudget else { continue }
      if let distance = Self.distance(tokenScalars, wordScalars.map(\.value), budget: wordBudget) {
        best = distance
        if distance == 0 { return 0 }
      }
    }
    return best
  }

  /// Bounded optimal-string-alignment distance, or `nil` once it must exceed `budget`.
  static func distance(_ source: [UInt32], _ target: [UInt32], budget: Int) -> Int? {
    let sourceCount = source.count
    let targetCount = target.count
    guard abs(sourceCount - targetCount) <= budget else { return nil }
    if budget == 0 { return source == target ? 0 : nil }
    if sourceCount == 0 { return targetCount }
    if targetCount == 0 { return sourceCount }

    // Three rolling rows: transposition reads the row two above.
    var twoRowsUp = [Int](repeating: 0, count: targetCount + 1)
    var previous = Array(0...targetCount)
    var current = [Int](repeating: 0, count: targetCount + 1)

    for i in 1...sourceCount {
      current[0] = i
      var rowMinimum = i
      for j in 1...targetCount {
        let substitutionCost = source[i - 1] == target[j - 1] ? 0 : 1
        var value = Swift.min(
          previous[j] + 1, current[j - 1] + 1, previous[j - 1] + substitutionCost)
        if i > 1, j > 1, source[i - 1] == target[j - 2], source[i - 2] == target[j - 1] {
          value = Swift.min(value, twoRowsUp[j - 2] + 1)
        }
        current[j] = value
        rowMinimum = Swift.min(rowMinimum, value)
      }
      // Band early-exit: no later cell can fall below this row's minimum (every route into the
      // next row adds a non-negative cost to a cell of this one, and the transposition term is
      // bounded below by this row's diagonal), so once it is over budget the answer is too.
      if rowMinimum > budget { return nil }
      (twoRowsUp, previous, current) = (previous, current, twoRowsUp)
    }

    let distance = previous[targetCount]
    return distance <= budget ? distance : nil
  }
}
