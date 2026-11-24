import Foundation
import Testing

@testable import DesignSystem

/// The one rule this file exists to keep: a card fill drawn inside a `List` cell that has swipe
/// actions is a bug.
///
/// The swipe container masks the cell as it shrinks, cutting the card's trailing corners square
/// while the cell's default backdrop stays behind at a different radius, leaving two hard edges.
///
/// Two mechanisms enforce it. The row components paint no fill
/// (`PodcastEpisodeCardRow.paintsCardBackground`, `MediaItemSummaryRow.paintsCardBackground`).
/// The compiler cannot see `.editorialCardSurface` applied to a row with swipe actions, so this
/// suite reads the sources and fails on that pairing, naming `editorialCardListRow` as the fix.
@Suite("Editorial card swipe chrome")
struct EditorialCardSwipeChromeTests {
  /// How far apart the two modifiers can sit and still be the same modifier chain. Chains run to
  /// a dozen-odd lines (insets, separator, identifier, `onAppear`, context menu).
  private static let chainWindow = 25

  @Test("no source applies the non-list card surface to a row with swipe actions")
  func cardSurfaceIsNeverPairedWithSwipeActions() throws {
    // Throws on an unreachable root or an implausibly small corpus, so the scan cannot pass empty.
    let sources = try DesignSystemSourceScan.all.get()

    var violations: [String] = []
    for source in sources {
      let lines = source.text.components(separatedBy: "\n")
      for (index, line) in lines.enumerated() where line.contains(".editorialCardSurface(") {
        let window = max(0, index - Self.chainWindow)...min(lines.count - 1, index + Self.chainWindow)
        guard lines[window].contains(where: { $0.contains(".swipeActions(") }) else { continue }
        violations.append("\(source.name):\(index + 1)")
      }
    }

    #expect(
      violations.isEmpty,
      """
      A card fill drawn inside a swipe-able List cell is masked square by the swipe container. \
      Use `.editorialCardListRow(wash)` instead of `.editorialCardSurface(wash)` for rows in a \
      List. Offending sites: \(violations.joined(separator: ", "))
      """)
  }

  @Test("the source scan fails closed on an unreachable root or a near-empty corpus")
  func theScanFailsClosed() {
    #expect(throws: DesignSystemSourceScan.Failure.self) {
      _ = try DesignSystemSourceScan.sources(root: URL(fileURLWithPath: "/nonexistent-root"))
    }
    #expect(throws: DesignSystemSourceScan.Failure.self) {
      _ = try DesignSystemSourceScan.sources(expectedAtLeast: .max)
    }
  }

  @Test("the scan blanks comments but keeps code after a URL literal")
  func theScanStripsComments() {
    let stripped = DesignSystemSourceScan.strippingComments(
      from: """
        // .editorialCardSurface(wash)
        let url = "https://example.invalid"; view.editorialCardSurface(wash) /* .swipeActions( */
        """)
    #expect(stripped.contains("// .editorial") == false)
    #expect(stripped.contains(".swipeActions(") == false)
    #expect(stripped.contains("view.editorialCardSurface(wash)"))
  }

  @MainActor @Test("the shared row components leave their card fill to the call site")
  func rowComponentsDoNotPaintTheirOwnFill() {
    // Pinned here beside the rule, so deleting either component's own pin still fails this suite.
    #expect(MediaItemSummaryRow<Never, Never, Never>.paintsCardBackground == false)
    #expect(PodcastEpisodeCardRow<Never>.paintsCardBackground == false)
  }
}
