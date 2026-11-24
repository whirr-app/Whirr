import Foundation
import Testing

@testable import Whirr

/// A `List` builds only the rows it shows when it can count a row without building it, so the row
/// must resolve to a single view with no branch on the way. One `if` around a row, or in the body
/// of a modifier applied to it, makes the first Library visit build all 1,270 titles, not the 7
/// on screen. Nothing visibly breaks on regression, so the shape is pinned against the source.
@Suite("Library row laziness")
struct LibraryRowLazinessTests {
  @Test("the title row's two shapes sit inside one container")
  func titleRowIsOneView() throws {
    let text = try ViewSourceScan.executableText(ofFileNamed: "LibraryBrowseTitlesView.swift")
    let row = try #require(text.range(of: "private func itemRow("))
    let end = try #require(text.range(of: "private func selectItem(", range: row.upperBound..<text.endIndex))
    let body = String(text[row.upperBound..<end.lowerBound])

    #expect(ViewSourceScan.occurrences(of: ["return ZStack {"], in: body) == 1)
    #expect(ViewSourceScan.occurrences(of: ["Group {"], in: body) == 0)
    #expect(body.contains("@ViewBuilder") == false)
  }

  /// Both modifiers render through two unconditional `.swipeActions`; what varies is the buttons.
  @Test(
    "a swipe modifier's body never branches around its content",
    arguments: ["ItemSwipeActionsModifier.swift", "PodcastEpisodeSwipeActionsModifier.swift"])
  func swipeModifierBodyIsUnconditional(fileName: String) throws {
    let text = try ViewSourceScan.executableText(ofFileNamed: fileName)
    let start = try #require(text.range(of: "func body(content: Content) -> some View {"))
    let end = try #require(text.range(of: "\n  }\n", range: start.upperBound..<text.endIndex))
    let body = String(text[start.upperBound..<end.lowerBound])

    #expect(ViewSourceScan.occurrences(of: [".swipeActions(edge:"], in: body) == 2)
    #expect(ViewSourceScan.occurrences(of: ["if ", "switch ", "#if"], in: body) == 0)
    #expect(ViewSourceScan.occurrences(of: ["@ViewBuilder\n  func body("], in: text) == 0)
  }
}
