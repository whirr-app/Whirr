/// Display-only shortening for chapter names on single-line surfaces (the expanded player's
/// chapter row, Now Playing, the regular-width mini player, and the Watch).
///
/// The number comes from the title, never the chapter's position: front matter such as "Opening
/// Credits" often precedes "Chapter 01". Anything the matcher cannot read with confidence is
/// returned unchanged (a miss costs a few characters, a wrong match mislabels the listener's
/// place), including Roman numerals and prefixes other than "Chapter".
public enum ChapterTitleFormatting {
  /// "Chapter Nineteen: The East India Docks" → "19: The East India Docks".
  public static func compact(_ title: String) -> String {
    var rest = Substring(title).trimmingWhitespace()
    guard rest.consumeKeyword("chapter"), rest.consumeWhitespace() else { return title }
    guard let number = rest.consumeNumber(), rest.consumeSeparator() else { return title }
    let name = rest.trimmingWhitespace()
    guard name.isEmpty == false else { return title }
    return "\(number): \(name)"
  }

  fileprivate static let units: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9,
  ]

  fileprivate static let standalone: [String: Int] = units.merging([
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
  ]) { $1 }

  fileprivate static let tens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
    "eighty": 80, "ninety": 90,
  ]
}

extension Substring {
  fileprivate func trimmingWhitespace() -> Substring {
    guard let first = firstIndex(where: { $0.isWhitespace == false }),
      let last = lastIndex(where: { $0.isWhitespace == false })
    else { return self[endIndex...] }
    return self[first...last]
  }

  /// Consumes `keyword` only as a whole word, so "Chapters" does not match "chapter".
  fileprivate mutating func consumeKeyword(_ keyword: String) -> Bool {
    let word = prefix { $0.isLetter }
    guard word.lowercased() == keyword else { return false }
    removeFirst(word.count)
    return true
  }

  fileprivate mutating func consumeWhitespace() -> Bool {
    let run = prefix { $0.isWhitespace }
    removeFirst(run.count)
    return run.isEmpty == false
  }

  /// Digits ("01", "112") or an English number word from one to ninety-nine, written either
  /// "Twenty-One" or "Twenty One". Leaves `self` untouched on failure.
  fileprivate mutating func consumeNumber() -> Int? {
    let digits = prefix { $0.isASCII && $0.isNumber }
    if digits.isEmpty == false {
      guard let value = Int(digits) else { return nil }
      removeFirst(digits.count)
      return value
    }
    let word = prefix { $0.isLetter }
    let lowered = word.lowercased()
    if let value = ChapterTitleFormatting.standalone[lowered] {
      removeFirst(word.count)
      return value
    }
    guard let tens = ChapterTitleFormatting.tens[lowered] else { return nil }
    removeFirst(word.count)
    if let joiner = first, joiner == "-" || joiner == " " {
      let afterJoiner = dropFirst()
      let unitWord = afterJoiner.prefix { $0.isLetter }
      if let unit = ChapterTitleFormatting.units[unitWord.lowercased()] {
        self = afterJoiner.dropFirst(unitWord.count)
        return tens + unit
      }
    }
    return tens
  }

  /// ":" (spacing optional), a spaced hyphen or dash, or "." followed by whitespace. The last
  /// stops "1.5" being read as chapter one.
  fileprivate mutating func consumeSeparator() -> Bool {
    var candidate = self
    let leadingSpace = candidate.consumeWhitespace()
    switch candidate.first {
    case ":":
      candidate.removeFirst()
    case "-", "–", "—":
      candidate.removeFirst()
      guard leadingSpace, candidate.consumeWhitespace() else { return false }
    case "." where leadingSpace == false:
      candidate.removeFirst()
      guard candidate.consumeWhitespace() else { return false }
    default:
      return false
    }
    self = candidate
    return true
  }
}
