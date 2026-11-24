import Foundation
import Testing

@testable import DesignSystem

/// The rule this file exists to keep: the editorial page background belongs to the `List`,
/// never to a `Section` inside it.
///
/// A plain modifier on a `Section` propagates to each row, so a paper fill there is painted inside
/// every cell's content, above its `listRowBackground`. That is invisible until a card moves its
/// fill to the row background, as `editorialCardListRow` does to survive a swipe (see
/// `EditorialCardSwipeChromeTests`); the card then draws flat paper while its wash accents show.
///
/// The compiler cannot tell the attachment points apart, so this suite reads the sources and
/// walks up each page-background modifier chain to its container.
@Suite("Editorial page background")
struct EditorialPageBackgroundTests {
  /// The modifiers that make up a page background. Either one on a `Section` is the bug. They are
  /// written as a pair, and the pair moves together.
  private static let pageBackgroundMarkers = [
    ".background(WhirrColorToken.editorialBackground",
    ".scrollContentBackground(",
  ]

  @Test("no source attaches the editorial page background to a Section")
  func pageBackgroundIsNeverAttachedToASection() throws {
    // Throws on an unreachable root or an implausibly small corpus, so the scan cannot pass empty.
    let sources = try DesignSystemSourceScan.all.get()

    var scanned = 0
    var violations: [String] = []
    for source in sources {
      let lines = source.text.components(separatedBy: "\n")
      for (index, line) in lines.enumerated()
      where Self.pageBackgroundMarkers.contains(where: line.contains) {
        scanned += 1
        guard let head = Self.containerHead(above: index, in: lines) else { continue }
        // The head declares the container, so match its opening token rather than searching the
        // line: `List(selection: visibleSections) {` is a `List`, but contains "Section".
        guard head.trimmingCharacters(in: .whitespaces).hasPrefix("Section") else { continue }
        violations.append("\(source.name):\(index + 1)")
      }
    }

    // The walk returning nothing everywhere would also pass. Pin that it found the call sites.
    #expect(scanned > 5, "the scan matched no page-background modifiers - check the markers")

    #expect(
      violations.isEmpty,
      """
      A page background on a `Section` is applied to every row in it, painting over each cell's \
      `listRowBackground` — which is where `editorialCardListRow` puts the card's fill. Attach \
      `.scrollContentBackground(.hidden)` and the editorial background to the `List` instead. \
      Offending sites: \(violations.joined(separator: ", "))
      """)
  }

  /// The companion rule: a plain `List` that hides its scroll-content background must also clear
  /// its rows' own cell fill.
  ///
  /// `scrollContentBackground(.hidden)` hides the scroll view's background, not each cell's, and an
  /// unstyled cell falls back to `systemBackground` (`#000000`/`#FFFFFF`), a few points off these
  /// near-black and near-white pages: plain in dark, invisible in light. A Library list drew
  /// pure-black rows on `#0B0D0E` this way. File-level: catches a page clearing none of its rows.
  @Test("a plain List that hides its background clears its rows' cell fill")
  func plainListRowsClearTheirCellFill() throws {
    let clearingMarkers = [
      ".listRowBackground(",
      ".plainListRow(",
      ".editorialListRow(",
      ".editorialCardListRow(",
      ".editorialCardSurface(",
      // The app's wide compact card applies `editorialCardListRow` on the row's behalf, so a page
      // made of those cards never names the chrome itself.
      "WideCompactCard(",
    ]

    // Every source by the type it declares. This codebase names a file after its primary type, so
    // the stem is the type name, enough to follow a page into the view it hands its rows to.
    var textByType: [String: String] = [:]
    var pages: [(name: String, text: String)] = []
    for source in try DesignSystemSourceScan.all.get() {
      let text = source.text
      textByType[(source.name as NSString).deletingPathExtension] = text
      guard text.contains(".listStyle(.plain)"), text.contains(".scrollContentBackground(") else {
        continue
      }
      pages.append((source.name, text))
    }

    let scanned = pages.count
    var violations: [String] = []
    for page in pages {
      guard clearingMarkers.contains(where: page.text.contains) == false else { continue }
      // A page long enough to split hands its rows to a content view and the chrome goes with
      // them (`PodcastShowView` keeps the `List`, `PodcastShowContentView` builds its rows).
      // Following one level into a composed view that applies row chrome keeps the rule on the
      // surface rather than on whichever file the rows live in.
      let delegatesRowChrome = textByType.contains { type, text in
        page.text.contains("\(type)(") && clearingMarkers.contains(where: text.contains)
      }
      guard delegatesRowChrome == false else { continue }
      violations.append(page.name)
    }

    // A rule that matched no pages would pass forever.
    #expect(scanned > 5, "the scan matched no plain background-hiding lists - check the markers")

    #expect(
      violations.isEmpty,
      """
      A plain `List` that hides its scroll-content background leaves each cell on \
      `systemBackground`, which is not the editorial page background — pure black behind every row \
      in dark appearance. Clear the row fill (`plainListRow`, `editorialListRow`, or \
      `listRowBackground(Color.clear)`). Offending files: \(violations.joined(separator: ", "))
      """)
  }

  /// The line declaring the container a modifier at `index` is attached to: skips the rest of the
  /// chain, then brace-matches back from the closing brace of the container's trailing closure.
  /// Returns nil when the modifier is applied to something that is not a trailing closure (a
  /// stored view, say), which this rule has nothing to say about.
  private static func containerHead(above index: Int, in lines: [String]) -> String? {
    var cursor = index - 1
    while cursor >= 0 {
      let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
      guard trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix(".") else { break }
      cursor -= 1
    }
    guard cursor >= 0, lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("}") else {
      return nil
    }

    var depth = 0
    while cursor >= 0 {
      for character in lines[cursor].reversed() {
        if character == "}" {
          depth += 1
        } else if character == "{" {
          depth -= 1
          if depth == 0 { return lines[cursor] }
        }
      }
      cursor -= 1
    }
    return nil
  }
}
