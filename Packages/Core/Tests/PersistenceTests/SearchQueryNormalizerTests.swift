import Foundation
import Testing

@testable import Persistence

/// The pure query normalizer every search path (local `LIKE`/FTS, the FTS5 index) must agree with.
/// Folding and tokenizing are pinned against a fixed locale so a device's region or language
/// settings can never change what a query matches.
@Suite("Search query normalizer")
struct SearchQueryNormalizerTests {

  @Test("folds case and diacritics so accented and plain spellings agree")
  func foldsCaseAndDiacritics() {
    #expect(SearchQueryNormalizer.normalize("Émile") == SearchQueryNormalizer.normalize("emile"))
    #expect(SearchQueryNormalizer.normalize("Émile") == "emile")
  }

  @Test("Turkish dotted/dotless I folds the same regardless of device locale")
  func foldsTurkishI() {
    // U+0130 LATIN CAPITAL LETTER I WITH DOT ABOVE. A Turkish-locale lowercase would keep the
    // dot (producing "istanbul" only under `tr`); folding against a fixed locale must not.
    #expect(SearchQueryNormalizer.normalize("İstanbul") == "istanbul")
    #expect(SearchQueryNormalizer.normalize("İstanbul") == SearchQueryNormalizer.normalize("Istanbul"))
  }

  @Test("German sharp-s folds under full case folding, pinned explicitly")
  func foldsGermanSharpS() {
    #expect(SearchQueryNormalizer.normalize("straße") == "strasse")
    #expect(SearchQueryNormalizer.normalize("STRASSE") == "strasse")
    #expect(SearchQueryNormalizer.normalize("straße") == SearchQueryNormalizer.normalize("STRASSE"))
  }

  @Test("tokenizes on whitespace and punctuation, dropping empties")
  func tokenizesOnWhitespaceAndPunctuation() {
    #expect(SearchQueryNormalizer.tokens("gaiman, neil") == ["gaiman", "neil"])
  }

  @Test("canonical spelling equates initials, apostrophes, and hyphens")
  func canonicalSpellingEquatesPresentationVariants() {
    let initials = ["James S.A. Corey", "James S. A. Corey", "James SA Corey"]
    #expect(Set(initials.map(SearchQueryNormalizer.canonicalize)) == ["james sa corey"])
    #expect(SearchQueryNormalizer.canonicalize("O'Brien") == "obrien")
    #expect(SearchQueryNormalizer.canonicalize("Jean-Luc") == "jean luc")
    #expect(SearchQueryNormalizer.canonicalize("Jean Luc") == "jean luc")
  }

  @Test("canonical spelling is idempotent")
  func canonicalSpellingIsIdempotent() {
    let inputs = ["James S. A. Corey", "O'Brien", "Jean-Luc", "  S.   A.  "]
    for input in inputs {
      let once = SearchQueryNormalizer.canonicalize(input)
      #expect(SearchQueryNormalizer.canonicalize(once) == once)
    }
  }

  @Test("collapses runs of whitespace and trims")
  func collapsesRunsOfWhitespace() {
    #expect(SearchQueryNormalizer.normalize("  gaiman   neil  ") == "gaiman neil")
    #expect(SearchQueryNormalizer.tokens("  gaiman   neil  ") == ["gaiman", "neil"])
  }

  @Test("a query of only punctuation normalizes to zero tokens")
  func punctuationOnlyQueryHasNoTokens() {
    #expect(SearchQueryNormalizer.tokens("!!!") == [])
    #expect(SearchQueryNormalizer.tokens("   ") == [])
  }

  @Test("normalize is idempotent")
  func normalizeIsIdempotent() {
    let inputs = ["Émile", "İstanbul", "straße", "  Neil  Gaiman  ", "!!!", "gaiman, neil"]
    for input in inputs {
      let once = SearchQueryNormalizer.normalize(input)
      let twice = SearchQueryNormalizer.normalize(once)
      #expect(once == twice, "not idempotent for \(input.debugDescription)")
    }
  }

  @Test("normalize is pure: repeated calls on the same input agree")
  func normalizeIsPure() {
    #expect(SearchQueryNormalizer.normalize("Neil Gaiman") == SearchQueryNormalizer.normalize("Neil Gaiman"))
    #expect(SearchQueryNormalizer.tokens("Neil Gaiman") == SearchQueryNormalizer.tokens("Neil Gaiman"))
  }
}
