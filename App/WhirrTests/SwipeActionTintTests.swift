import Foundation
import Testing

@testable import Whirr

/// Every swipe button in the app names its own tint.
///
/// An untinted swipe button takes the inherited tint. Sheets from the expanded player inherit
/// `.tint(Color.primary)`, near-white on the dark presentation, giving a white-on-white trash
/// button. A destructive role does not help: its red is itself a tint, and the inherited one wins.
/// Checked in source because no unit test can read a rendered colour.
@Suite("Swipe action tint")
struct SwipeActionTintTests {
  struct Block: CustomStringConvertible {
    let file: String
    let text: String
    var description: String { file }
  }

  /// The content closure of every `swipeActions` call in the view layer, modifier or method form.
  static func swipeBlocks() throws -> [Block] {
    let pattern = try Regex(#"\bswipeActions\s*[({]"#)
    var blocks: [Block] = []
    for source in try ViewSourceScan.sources() {
      let text = try ViewSourceScan.executableText(of: source)
      for match in text.matches(of: pattern) {
        guard let body = contentClosure(in: text, from: match.range) else { continue }
        blocks.append(Block(file: source.lastPathComponent, text: String(text[body])))
      }
    }
    return blocks
  }

  /// The closure that follows the call's argument list, braces balanced.
  static func contentClosure(in text: String, from match: Range<String.Index>) -> Range<String.Index>? {
    var index = text.index(before: match.upperBound)
    if text[index] == "(" {
      guard let close = balanced(in: text, from: index, open: "(", close: ")") else { return nil }
      guard let brace = text[close...].firstIndex(of: "{") else { return nil }
      index = brace
    }
    guard let end = balanced(in: text, from: index, open: "{", close: "}") else { return nil }
    return index..<end
  }

  private static func balanced(
    in text: String, from start: String.Index, open: Character, close: Character
  ) -> String.Index? {
    var depth = 0
    var index = start
    while index < text.endIndex {
      if text[index] == open { depth += 1 }
      if text[index] == close {
        depth -= 1
        if depth == 0 { return index }
      }
      index = text.index(after: index)
    }
    return nil
  }

  @Test("the scan finds the app's swipe actions")
  func scanFindsSwipeActions() throws {
    let files = Set(try Self.swipeBlocks().map(\.file))

    #expect(files.contains("PlayerBookmarks.swift"))
    #expect(files.contains("ListeningQueueSheet.swift"))
    #expect(files.contains("DownloadsViewRows.swift"))
    #expect(files.count >= 8)
  }

  @Test("every swipe button carries an explicit tint")
  func everySwipeButtonIsTinted() throws {
    for block in try Self.swipeBlocks() {
      // The shared episode renderer tints each button from its descriptor.
      if block.text.contains("podcastEpisodeSwipeButtons(") { continue }
      let buttons = ViewSourceScan.occurrences(of: ["Button(", "Button {"], in: block.text)
      let tints = ViewSourceScan.occurrences(of: [".tint("], in: block.text)

      #expect(buttons > 0, "\(block.file): a swipe block with no button")
      #expect(tints >= buttons, "\(block.file): \(buttons) swipe button(s), \(tints) tint(s)")
    }
  }
}
