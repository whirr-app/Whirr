import Foundation

/// Podcast feeds carry episode and show descriptions as HTML written for a web page. This turns
/// one into a single line of plain text.
///
/// Hand-rolled because an `NSAttributedString` HTML import is `@MainActor`-only, spins up WebKit
/// and costs milliseconds per string, too slow per row on a scrolling list.
///
/// Lives in `Persistence` because the search index uses `plainText` too
/// (`SchemaV1.searchPlainTextFunction` wraps it for the FTS triggers and `DefaultSearchReading`),
/// so a query for `href` cannot match markup. One implementation serves row, show notes and index.
public enum FeedHTML {
  /// Tags out, entities decoded, whitespace collapsed to single spaces, trimmed. Returns `nil`
  /// rather than an empty string when nothing survives, so callers can omit the line entirely
  /// instead of drawing a blank one.
  public static func plainText(_ value: String?) -> String? {
    guard let value, value.isEmpty == false else { return nil }
    let withoutTags = stripTags(value)
    let decoded = decodeEntities(withoutTags)
    let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
  }

  /// The most plain text a list row is ever asked to draw. 240 grapheme clusters clears the
  /// row's line limit at every Dynamic Type size, so the stored line never shows a cut the full
  /// text would not have shown.
  public static let lineLength = 240

  /// `plainText` cut to `lineLength` grapheme clusters, so a stored line never ends inside a
  /// cluster. Written to the episode row at refresh time; see `PodcastEpisodeSummary.synopsisLine`.
  public static func line(_ value: String?) -> String? {
    guard let text = plainText(value) else { return nil }
    return String(text.prefix(lineLength))
  }

  /// Entities decode as in `plainText`. Block-tag boundaries become a paragraph break (`\n\n`),
  /// whitespace collapses to single spaces within a paragraph only, and runs of blank paragraphs
  /// collapse to one break with none leading or trailing. Returns `nil` when nothing survives.
  ///
  /// Many feeds send plain text laid out with newlines and no block tags. Then the newlines are
  /// the only structure: a blank line is a paragraph break and a single newline a line break
  /// (`\n`). Once any block tag is present it is HTML and source newlines are insignificant, as in
  /// a browser. Inline tags such as `<a>` or `<em>` alone do not make it HTML.
  public static func paragraphs(_ value: String?) -> String? {
    guard let value, value.isEmpty == false else { return nil }
    let withoutTags = stripTags(value, blockBreak: String(paragraphSentinel))
    let newlinesAreStructure = withoutTags.contains(paragraphSentinel) == false
    let decoded = decodeEntities(withoutTags)

    // A paragraph break is any run of separator characters (whitespace and/or sentinels) that
    // contains a sentinel (or, for plain text, two or more newlines). A run with one plain-text
    // newline is a line break; any other run is intra-paragraph whitespace and becomes a space.
    // Runs are maximal, so block-tag boundaries separated only by whitespace or empty tags merge
    // into one break, which collapses blank paragraphs to a single `\n\n`.
    enum Break {
      case space, line, paragraph
    }
    enum Token {
      case content(String)
      case separator(Break)
    }

    var tokens: [Token] = []
    var currentContent = ""
    var inSeparator = false
    var currentSeparatorHasBreak = false
    var currentSeparatorNewlines = 0

    func flushContent() {
      guard currentContent.isEmpty == false else { return }
      tokens.append(.content(currentContent))
      currentContent = ""
    }
    func flushSeparator() {
      guard inSeparator else { return }
      let kind: Break =
        currentSeparatorHasBreak || currentSeparatorNewlines >= 2
        ? .paragraph : currentSeparatorNewlines == 1 ? .line : .space
      tokens.append(.separator(kind))
      inSeparator = false
      currentSeparatorHasBreak = false
      currentSeparatorNewlines = 0
    }

    for character in decoded {
      if character == paragraphSentinel {
        flushContent()
        inSeparator = true
        currentSeparatorHasBreak = true
      } else if character.isWhitespace {
        flushContent()
        inSeparator = true
        // `isNewline` treats `\r\n` as the one grapheme it is, so CRLF feeds count once per line.
        if newlinesAreStructure, character.isNewline { currentSeparatorNewlines += 1 }
      } else {
        flushSeparator()
        currentContent.append(character)
      }
    }
    flushContent()
    flushSeparator()

    // No leading/trailing breaks or spaces.
    while case .separator = tokens.first { tokens.removeFirst() }
    while case .separator = tokens.last { tokens.removeLast() }
    guard tokens.isEmpty == false else { return nil }

    var result = ""
    for token in tokens {
      switch token {
      case .content(let text): result += text
      case .separator(.paragraph): result += "\n\n"
      case .separator(.line): result += "\n"
      case .separator(.space): result += " "
      }
    }
    return result
  }

  // A Private Use Area code point stands in for a block-tag boundary while `paragraphs` walks the
  // stripped text. A real feed never emits it, so it is distinct from ordinary whitespace.
  private static let paragraphSentinel: Character = "\u{E000}"

  /// Block-level tags become `blockBreak`, inline ones become nothing. The distinction matters in
  /// both directions: `One<br>Two` is two words, and `<em>fractures</em>,` must not become
  /// `fractures ,`. `plainText` uses a single space (its collapse pass folds runs to one), while
  /// `paragraphs` uses a sentinel it later turns into `\n\n`.
  private static func stripTags(_ value: String, blockBreak: String = " ") -> String {
    var output = ""
    output.reserveCapacity(value.count)
    var tag = ""
    var isInTag = false

    for character in value {
      if isInTag {
        if character == ">" {
          isInTag = false
          if breaksLine(tag) { output.append(blockBreak) }
        } else {
          tag.append(character)
        }
      } else if character == "<" {
        isInTag = true
        tag = ""
      } else {
        output.append(character)
      }
    }
    // An unterminated `<` is not a tag, or a description reading "5 < 6" would lose everything
    // after it.
    if isInTag { output.append("<\(tag)") }
    return output
  }

  private static func breaksLine(_ tag: String) -> Bool {
    let name =
      tag
      .drop { $0 == "/" }
      .prefix { $0.isLetter || $0.isNumber }
      .lowercased()
    return blockTags.contains(name)
  }

  private static let blockTags: Set<String> = [
    "br", "p", "div", "li", "ul", "ol", "tr", "td", "th", "table", "section", "article",
    "blockquote", "pre", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
  ]

  /// The five XML entities plus the ones feeds actually use, and both numeric forms. An unknown
  /// entity is left verbatim, since showing `&pounds;` is a smaller lie than eating it.
  private static func decodeEntities(_ value: String) -> String {
    guard value.contains("&") else { return value }
    var output = ""
    output.reserveCapacity(value.count)
    var remainder = Substring(value)

    while let ampersand = remainder.firstIndex(of: "&") {
      output.append(contentsOf: remainder[remainder.startIndex..<ampersand])
      let afterAmpersand = remainder.index(after: ampersand)
      guard
        let semicolon = remainder[afterAmpersand...].firstIndex(of: ";"),
        remainder.distance(from: afterAmpersand, to: semicolon) <= 10
      else {
        output.append("&")
        remainder = remainder[afterAmpersand...]
        continue
      }
      let name = remainder[afterAmpersand..<semicolon]
      output.append(decode(entity: name) ?? "&\(name);")
      remainder = remainder[remainder.index(after: semicolon)...]
    }
    output.append(contentsOf: remainder)
    return output
  }

  private static func decode(entity: Substring) -> String? {
    if let named = named[String(entity)] { return named }
    guard entity.hasPrefix("#") else { return nil }
    let digits = entity.dropFirst()
    let scalar: Unicode.Scalar?
    if digits.hasPrefix("x") || digits.hasPrefix("X") {
      scalar = UInt32(digits.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
    } else {
      scalar = UInt32(digits, radix: 10).flatMap(Unicode.Scalar.init)
    }
    return scalar.map { String(Character($0)) }
  }

  private static let named: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    // A non-breaking space is a space here: the collapse pass treats it as one, and a row that
    // kept them would break lines where the feed never intended.
    "nbsp": " ", "hellip": "…", "mdash": "—", "ndash": "–",
    "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
  ]
}
