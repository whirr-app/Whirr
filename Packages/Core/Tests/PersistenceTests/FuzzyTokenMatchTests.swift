import Testing

@testable import Persistence

/// The close-match fallback's pure comparison. `DefaultSearchReading`'s SQL only asks this type;
/// the worked examples against a database live in `SearchReadingTests`.
@Suite struct FuzzyTokenMatchTests {

  // MARK: - Edit budget

  @Test("the budget is 0 through three characters, 1 from four to six, and 2 from seven")
  func budgetTableAndItsBoundaries() {
    #expect(FuzzyTokenMatch.budget(forTokenLength: 1) == 0)
    #expect(FuzzyTokenMatch.budget(forTokenLength: 3) == 0)
    #expect(FuzzyTokenMatch.budget(forTokenLength: 4) == 1)
    #expect(FuzzyTokenMatch.budget(forTokenLength: 6) == 1)
    #expect(FuzzyTokenMatch.budget(forTokenLength: 7) == 2)
    #expect(FuzzyTokenMatch.budget(forTokenLength: 12) == 2)
    #expect(FuzzyTokenMatch.budget(for: "teh") == 0)
    #expect(FuzzyTokenMatch.budget(for: "gaimn") == 1)
    #expect(FuzzyTokenMatch.budget(for: "tchaikovsky") == 2)
  }

  // MARK: - Edit operations

  @Test("a substitution, a missing character, and an extra character each cost 1")
  func eachEditOperationCostsOne() {
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimen", in: "Neil Gaiman", budget: 1) == 1)
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimn", in: "Neil Gaiman", budget: 1) == 1)
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimann", in: "Neil Gaiman", budget: 2) == 1)
  }

  /// The test that fails if someone substitutes plain Levenshtein, which charges a swap 2 and so
  /// rejects it at the budget a six-character token gets.
  @Test("an adjacent transposition costs 1, not 2")
  func adjacentTranspositionCostsOne() {
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimna", in: "Neil Gaiman", budget: 1) == 1)
    #expect(FuzzyTokenMatch.bestDistance(token: "hobibt", in: "The Hobbit", budget: 1) == 1)
    #expect(FuzzyTokenMatch.distance(scalars("abcdefhg"), scalars("abcdefgh"), budget: 2) == 1)
  }

  /// Optimal string alignment never edits a substring twice, so `ca` → `abc` is 3, where
  /// unrestricted Damerau-Levenshtein would say 2. Pinned so the variant is a choice, not an
  /// accident.
  @Test("the distance is the restricted (optimal string alignment) variant")
  func distanceIsTheRestrictedVariant() {
    #expect(FuzzyTokenMatch.distance(scalars("ca"), scalars("abc"), budget: 3) == 3)
  }

  @Test("a word beyond the budget is no match at all")
  func beyondBudgetIsNil() {
    #expect(FuzzyTokenMatch.bestDistance(token: "gimn", in: "Neil Gaiman", budget: 1) == nil)
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimn", in: "Tchaikovsky", budget: 1) == nil)
    #expect(FuzzyTokenMatch.distance(scalars("abcdefgh"), scalars("xbcdefgy"), budget: 2) == 2)
    #expect(FuzzyTokenMatch.distance(scalars("abcdefgh"), scalars("xycdefgz"), budget: 2) == nil)
  }

  @Test("a budget of 0 admits only the identical word")
  func zeroBudgetIsExactWordEquality() {
    #expect(FuzzyTokenMatch.bestDistance(token: "the", in: "The Hobbit", budget: 0) == 0)
    #expect(FuzzyTokenMatch.bestDistance(token: "teh", in: "The Hobbit", budget: 0) == nil)
    // A word, not a substring: `hob` is inside `hobbit` but is not one of its words.
    #expect(FuzzyTokenMatch.bestDistance(token: "hob", in: "The Hobbit", budget: 0) == nil)
  }

  @Test("the closest word in the text wins")
  func closestWordWins() {
    #expect(FuzzyTokenMatch.bestDistance(token: "gaiman", in: "Gaimen Gaiman", budget: 1) == 0)
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimn", in: "Gamin Gaiman", budget: 1) == 1)
  }

  @Test("empty text matches nothing")
  func emptyTextMatchesNothing() {
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimn", in: "", budget: 1) == nil)
    #expect(FuzzyTokenMatch.bestDistance(token: "gaimn", in: " - ", budget: 1) == nil)
  }

  // MARK: - Canonical composition

  @Test("text is compared in canonical form: folded, with initials and apostrophes collapsed")
  func textIsComparedCanonically() {
    #expect(FuzzyTokenMatch.bestDistance(token: "gaiman", in: "GAÏMAN", budget: 1) == 0)
    #expect(FuzzyTokenMatch.bestDistance(token: "sa", in: "James S. A. Corey", budget: 0) == 0)
    #expect(FuzzyTokenMatch.bestDistance(token: "corei", in: "James S. A. Corey", budget: 1) == 1)
    #expect(FuzzyTokenMatch.bestDistance(token: "obrian", in: "Tim O'Brien", budget: 1) == 1)
  }

  private func scalars(_ value: String) -> [UInt32] {
    value.unicodeScalars.map(\.value)
  }
}
