import Testing

@testable import PlayerCore

/// The compact form is display-only and narrow: anything it cannot read with
/// confidence must come back exactly as given, because a missed match costs nothing and a wrong
/// one mislabels the listener's place in the book.
@Suite struct ChapterTitleFormattingTests {

  @Test(arguments: [
    // The three reported shapes.
    ("Chapter Nineteen: The East India Docks", "19: The East India Docks"),
    ("Chapter 01: Ruh-roh", "1: Ruh-roh"),
    ("Chapter Twenty: The Clock-Tower", "20: The Clock-Tower"),
    // Separators normalise to a colon.
    ("Chapter 3 - The Bridge", "3: The Bridge"),
    ("Chapter 3 – The Bridge", "3: The Bridge"),
    ("Chapter 3 — The Bridge", "3: The Bridge"),
    ("Chapter 3. The Bridge", "3: The Bridge"),
    ("Chapter 3:The Bridge", "3: The Bridge"),
    // Digits.
    ("Chapter 007: Licence", "7: Licence"),
    ("Chapter 112: Late", "112: Late"),
    ("Chapter 0: Before", "0: Before"),
    // Spelled-out numbers.
    ("Chapter One: Start", "1: Start"),
    ("Chapter Twelve: Midday", "12: Midday"),
    ("Chapter Twenty-One: Coming of Age", "21: Coming of Age"),
    ("Chapter Twenty One: Coming of Age", "21: Coming of Age"),
    ("Chapter Ninety-Nine: Nearly", "99: Nearly"),
    // Case and surrounding whitespace.
    ("CHAPTER NINETEEN: LOUD", "19: LOUD"),
    ("chapter nineteen: quiet", "19: quiet"),
    ("  Chapter 4:   Padded  ", "4: Padded"),
    // A name that itself contains separators keeps them.
    ("Chapter 21 - Mission 3 - House of the Owl", "21: Mission 3 - House of the Owl"),
  ])
  func compactsNumberedChapterTitles(title: String, expected: String) {
    #expect(ChapterTitleFormatting.compact(title) == expected)
  }

  @Test(arguments: [
    // No name after the number: a bare number would say less than the original.
    "Chapter 1",
    "Chapter Nineteen",
    "Chapter 1:",
    "Chapter 1 -  ",
    // Unnumbered entries.
    "Prologue",
    "Opening Credits",
    "End Credits",
    // Not a leading "Chapter".
    "Part One, Chapter Three: Arrival",
    "21 - Mission 3 - House of the Owl",
    "The Chapter 3 Problem: A Story",
    // Other prefixes are left alone.
    "Ch. 3: The Bridge",
    "Chap. 3: The Bridge",
    "Chapters 3: The Bridge",
    // Roman numerals pass through.
    "Chapter XIX: The East India Docks",
    "Chapter I: Beginnings",
    // Unreadable or out-of-range numbers.
    "Chapter One Hundred: Too Far",
    "Chapter Twenty-Zero: Nonsense",
    "Chapter Ten-One: Nonsense",
    "Chapter 1.5: Interlude",
    "Chapter 3 The Bridge",
    // Other languages.
    "Kapitel 3: Die Brücke",
    "Capítulo 3: El Puente",
    "",
  ])
  func leavesOtherTitlesUnchanged(title: String) {
    #expect(ChapterTitleFormatting.compact(title) == title)
  }
}
