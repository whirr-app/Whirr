import Foundation

/// Show notes split into the episode's own words and the publisher boilerplate that trails them:
/// membership plugs, sponsor reads, socials, credits, ad-choices notices. The card draws `primary`
/// and folds `supplementary` behind a disclosure; nothing is discarded.
///
/// Works on one episode's text, from `FeedHTML.paragraphs` output (`\n\n` between paragraphs, `\n`
/// between lines). Three signals, chosen to misfire rarely on real content:
/// - A divider line (`__________`, `- - -`, `***`) fences off boilerplate; everything after the
///   first one folds.
/// - A paragraph with an unambiguous ad marker folds wherever it sits. Sponsor wording counts only
///   at the start of a paragraph ("a bill sponsored by…" in the body stays); a discount code only
///   written as one ("use code EMPIRE"), not "replaced with code".
/// - A short paragraph opening with a call to action and a link with a path ("Try ZipRecruiter at
///   ziprecruiter.com/POLITICS") is a host-read sponsor plug. These rotate too fast to recur.
///
/// A `ShowNotesBoilerplate` built from the show's other episodes adds a fourth signal: a paragraph
/// the show repeats across episodes folds too.
///
/// Last, a one-line `Label: name` paragraph whose neighbours both fold, folds with them (rotating
/// credits like "Editor: …" are too varied to recur). That pass reads only the other rules'
/// results, so it never cascades down a run of credits.
///
/// If folding would leave nothing up front, nothing folds.
public struct PodcastShowNotes: Sendable, Equatable {
  /// The notes to show up front. Empty only when the input held nothing but divider lines.
  public let primary: String
  /// The folded remainder, or `nil` when nothing folded.
  public let supplementary: String?

  public init(_ notes: String, boilerplate: ShowNotesBoilerplate = .none) {
    func folds(_ paragraph: String) -> Bool {
      Self.isAdvertising(paragraph) || boilerplate.contains(paragraph: paragraph)
    }

    var entries: [(text: String, folds: Bool)] = []
    var isPastDivider = false

    for paragraph in notes.components(separatedBy: "\n\n") {
      let lines = paragraph.components(separatedBy: "\n")
      if isPastDivider {
        entries.append((Self.joinedWithoutDividers(lines), true))
        continue
      }
      if let divider = lines.firstIndex(where: Self.isDivider) {
        let before = lines[..<divider].joined(separator: "\n")
        entries.append((before, folds(before)))
        entries.append((Self.joinedWithoutDividers(lines[(divider + 1)...]), true))
        isPastDivider = true
      } else {
        entries.append((paragraph, folds(paragraph)))
      }
    }

    entries.removeAll { $0.text.isEmpty }
    let ruled = entries.map(\.folds)
    for index in entries.indices.dropFirst().dropLast()
    where ruled[index] == false && ruled[index - 1] && ruled[index + 1]
      && Self.isCreditLine(entries[index].text)
    {
      entries[index].folds = true
    }
    let kept = entries.filter { $0.folds == false }.map(\.text)
    let folded = entries.filter(\.folds).map(\.text)
    if kept.isEmpty || folded.isEmpty {
      primary = entries.map(\.text).joined(separator: "\n\n")
      supplementary = nil
    } else {
      primary = kept.joined(separator: "\n\n")
      supplementary = folded.joined(separator: "\n\n")
    }
  }

  private static func joinedWithoutDividers(_ lines: some Sequence<String>) -> String {
    lines.filter { isDivider($0) == false }.joined(separator: "\n")
  }

  /// Three or more rule characters and nothing else but spaces. Two dashes are an em-dash stand-in
  /// and three dots an ellipsis, so neither counts.
  static func isDivider(_ line: String) -> Bool {
    let marks = line.filter { $0.isWhitespace == false }
    return marks.count >= 3 && marks.allSatisfy(dividerCharacters.contains)
  }

  private static let dividerCharacters: Set<Character> = [
    "_", "-", "–", "—", "=", "*", "~", "•", "·",
  ]

  static func isAdvertising(_ paragraph: String) -> Bool {
    // Megaphone pads text with invisible word joiners, which would defeat a prefix match.
    let folded = String(paragraph.drop { $0.isLetter == false && $0.isNumber == false })
      .lowercased()
    return adOpenings.contains { folded.hasPrefix($0) }
      || adMarkers.contains { folded.contains($0) }
      || paragraph.contains(discountCode)
      || isSponsorPlug(folded)
  }

  /// "use code EMPIRE", "use the code 'TRIPUS'", "with code SUMMER26": the code itself must be
  /// written in capitals or digits, which is what separates it from prose about code.
  private static var discountCode: Regex<Substring> {
    /(?i:\b(?:use|with)\s+(?:the\s+)?code)\s+['"‘’“”]?[A-Z0-9]{3,}\b/
  }

  private static func isSponsorPlug(_ folded: String) -> Bool {
    folded.count <= maximumPlugLength
      && plugOpenings.contains { folded.hasPrefix($0) }
      && folded.contains(linkWithPath)
  }

  /// A host-read plug is a sentence or two; a body paragraph that opens "Visit…" runs longer.
  private static let maximumPlugLength = 240
  private static let plugOpenings = [
    "try ", "visit ", "go to ", "head to ", "get ", "sign up ", "download ", "check out ", "shop ",
  ]
  /// `example.com/show` with or without a scheme. A bare domain does not count: shows link their
  /// own sites from episode text, and sponsor plugs carry a per-show path to attribute the sale.
  private static var linkWithPath: Regex<Substring> {
    /(?:https?:\/\/)?(?:[a-z0-9-]+\.)+[a-z]{2,}\/[^\s\/)]+/
  }

  /// One short line shaped `Label: name` or `Label - name`, with a label of at most four words.
  static func isCreditLine(_ paragraph: String) -> Bool {
    guard paragraph.count <= 80, paragraph.contains("\n") == false,
      let separator = paragraph.firstRange(of: ": ") ?? paragraph.firstRange(of: " - ")
    else { return false }
    let label = paragraph[..<separator.lowerBound].split(separator: " ")
    let name = paragraph[separator.upperBound...]
    return (1...4).contains(label.count) && name.contains { $0.isLetter }
  }

  private static let adOpenings = [
    "sponsored by", "this episode is sponsored", "this episode is brought to you",
    "today's episode is brought to you", "today’s episode is brought to you",
    "thanks to our sponsor", "support for this show", "support for this podcast",
    "brought to you by",
  ]

  private static let adMarkers = [
    "ad choices", "adchoices", "podcastchoices.com", "acast.com/privacy", "promo code",
    "discount code",
  ]
}
