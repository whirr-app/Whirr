import Testing

@testable import Persistence

@Suite struct FeedHTMLTests {
  @Test("the stored line is plain text cut at a grapheme boundary")
  func lineStripsAndCutsAtAGraphemeBoundary() {
    #expect(FeedHTML.line("<p>Tom &amp; Jerry</p>") == "Tom & Jerry")
    #expect(FeedHTML.line("<p></p>") == nil)
    #expect(FeedHTML.line(nil) == nil)

    let flag = "🇬🇧"  // two scalars, one grapheme cluster
    let kept = String(repeating: "a", count: FeedHTML.lineLength - 1) + flag
    #expect(FeedHTML.line(kept + " and a tail") == kept)
    let exact = String(repeating: "b", count: FeedHTML.lineLength)
    #expect(FeedHTML.line(exact) == exact)
  }

  @Test("block-tag boundaries become paragraph breaks")
  func paragraphsPreserveBlockBreaks() {
    let html = "<p>First paragraph.</p><p>Second paragraph.</p>"
    #expect(FeedHTML.paragraphs(html) == "First paragraph.\n\nSecond paragraph.")
  }

  @Test("whitespace collapses within a paragraph only, breaks between paragraphs survive")
  func paragraphsCollapseWhitespaceWithinParagraphOnly() {
    let html = "<p>Line one\n   has   extra    spaces.</p><p>Second   paragraph.</p>"
    #expect(
      FeedHTML.paragraphs(html)
        == "Line one has extra spaces.\n\nSecond paragraph.")
  }

  @Test("entities decode identically to plainText")
  func paragraphsDecodeEntities() {
    let html = "<p>Cats &amp; dogs &mdash; friends.</p><p>Caf&#233; culture.</p>"
    #expect(
      FeedHTML.paragraphs(html)
        == "Cats & dogs — friends.\n\nCafé culture.")
  }

  @Test("runs of consecutive blank paragraphs collapse to one break")
  func paragraphsCollapseBlankRuns() {
    let html = "<p>First paragraph.</p><p></p><p>   </p><p>Second paragraph.</p>"
    #expect(FeedHTML.paragraphs(html) == "First paragraph.\n\nSecond paragraph.")
  }

  @Test("plain-text notes keep their blank-line paragraphs")
  func paragraphsKeepPlainTextBlankLines() {
    // Megaphone's `<description>`: no tags at all, paragraphs separated by blank lines (sometimes
    // several, sometimes with trailing spaces on the "blank" line).
    let text = " First paragraph.\n\n\n\nSecond   paragraph.\n  \nThird.\n"
    #expect(FeedHTML.paragraphs(text) == "First paragraph.\n\nSecond paragraph.\n\nThird.")
  }

  @Test("plain-text notes keep single line breaks as line breaks")
  func paragraphsKeepPlainTextLineBreaks() {
    let text = "Instagram: @show\nTwitter: @show\r\nEmail: hi@example.com\n\nProducer: Someone"
    #expect(
      FeedHTML.paragraphs(text)
        == "Instagram: @show\nTwitter: @show\nEmail: hi@example.com\n\nProducer: Someone")
  }

  @Test("inline tags alone do not switch plain-text notes to HTML rules")
  func paragraphsInlineTagsStayPlainText() {
    let text = "Visit <a href=\"https://example.com\">our site</a>.\n\nSecond <em>paragraph</em>."
    #expect(FeedHTML.paragraphs(text) == "Visit our site.\n\nSecond paragraph.")
  }

  @Test("source newlines inside block-tagged HTML stay insignificant")
  func paragraphsHTMLIgnoresSourceNewlines() {
    let html = "<p>One\n\ntwo.</p>\n\n<p>Three</p>"
    #expect(FeedHTML.paragraphs(html) == "One two.\n\nThree")
  }

  @Test("nil input, empty input, and tags-only input all yield nil, never an empty string")
  func paragraphsNilWhenEmpty() {
    #expect(FeedHTML.paragraphs(nil) == nil)
    #expect(FeedHTML.paragraphs("") == nil)
    #expect(FeedHTML.paragraphs("<p>   </p><br><div></div>") == nil)
  }

  @Test("plainText's output is untouched by adding paragraphs")
  func plainTextUnchangedByParagraphsAddition() {
    #expect(
      FeedHTML.plainText("<p>Hello <em>world</em></p><p>Second para.</p>")
        == "Hello world Second para.")
    // An unterminated `<` (no later `>` at all) is never treated as a tag.
    #expect(FeedHTML.plainText("5 < 6") == "5 < 6")
    #expect(FeedHTML.plainText("One<br>Two") == "One Two")
    #expect(FeedHTML.plainText("<em>fractures</em>, healed.") == "fractures, healed.")
    #expect(
      FeedHTML.plainText("Cats &amp; dogs &mdash; &#233;clair &unknownentity; done.")
        == "Cats & dogs — éclair &unknownentity; done.")
    #expect(
      FeedHTML.plainText("   leading and trailing whitespace   ")
        == "leading and trailing whitespace")
    #expect(FeedHTML.plainText("") == nil)
    #expect(FeedHTML.plainText("<p>   </p><br><div></div>") == nil)
  }
}
